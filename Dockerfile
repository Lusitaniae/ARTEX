# syntax=docker/dockerfile:1
#
# Multi-stage build: `docker compose up -d --build` (or `docker build .`) produces
# the complete image from source. No prebuilt binary in the build context is needed,
# so a fresh `git clone` builds — dist/ is git-ignored and is no longer required.
#
#   frontend (web) -> Go binary with embedded UI (build) -> runtime image
#
# The Go binary is produced by build.sh with the same flags the release workflow's
# binaries job uses, so the image binary and the published release binary come from
# one source.
#
# LOCAL HARDENING (see HARDENING.md): every downloaded tool archive is verified
# against a SHA-256 pinned in this file, sqlmap is pinned to a commit, npm globals
# are pinned to exact versions, Node is copied from the pinned build stage instead
# of piping a remote install script into bash, and the container runs unprivileged.

# ---------------------------------------------------------------- frontend ---
# Pinned to the Node 22 line the CI/release workflows use. On the build platform
# only; the frontend static export is architecture-independent.
FROM --platform=$BUILDPLATFORM node:22.23.4-bookworm-slim@sha256:5ec23b7c622b00547753bc6ffd78085dd868a68aeb41c8e0a1418f033e13d96d AS web
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN npm ci --ignore-scripts
COPY web/ ./
RUN npm run build:static

# ------------------------------------------------------------- Go binary ---
# Pinned to the Go 1.26 line (matches go.mod and the release binaries job). The
# binary is CGO-free, so this stage runs on the build platform and cross-compiles
# to $TARGETARCH without QEMU.
FROM --platform=$BUILDPLATFORM golang:1.26.10-bookworm@sha256:5de7c99eb78ca5e515a4c340235d0955ec5964a5071c492c15503d7c267da473 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# Reuse the frontend built above; build.sh skips its own frontend step.
COPY --from=web /src/web/out ./server/webui/dist
ARG ARTEX_VERSION=dev
ARG TARGETOS
ARG TARGETARCH
# Same flags as the release binaries job (ARTEX_COMPRESS=0, -trimpath,
# -X main.version), driven through build.sh so there is one build path.
RUN ARTEX_SKIP_FRONTEND=1 \
    ARTEX_SKIP_NPM_CI=1 \
    ARTEX_COMPRESS=0 \
    ARTEX_OUTPUT=/out/artex \
    ARTEX_BUILD_VERSION="${ARTEX_VERSION}" \
    bash ./build.sh --target "${TARGETOS:-linux}/${TARGETARCH:-amd64}"

# ------------------------------------------------------------------ bbot ---
# bbot's own dependency installer (`--install-all-deps`) does three things that
# must not land in the runtime image: it apt-installs build tooling (gcc, make,
# libssl-dev, 7z, xz), it pip-installs per-module Python deps (django, numpy,
# kreuzberg, ...), and its dry-run downloads bbot's per-module *tool* cache
# (a second Chromium, a second Node, jadx, trufflehog, gowitness — ~1.5 GB) into
# $HOME/.bbot. Only the venv is carried into the final image, so the tooling and
# the tool cache are built here and thrown away. They were also unreadable at
# runtime: they lived in /root, and the container runs as uid 10001.
FROM python:3.12.16-slim-bookworm@sha256:935c3c5b12357a7e10caa9c1e6ca5692344d97cf229832ef584be2cec9fc03df AS bbotdeps
ARG BBOT_VERSION=3.0.2

# Prepare bbot under the *runtime* user's home, not root's. bbot records completed
# core-dependency installs in ~/.bbot/cache/<hash> and skips the installer when the
# marker is there; without it the installer shells out to `sudo` for apt, which does
# not exist in the runtime image and which bbot does not handle (FileNotFoundError
# escapes can_sudo_without_password and aborts the scan). Pre-seeding the marker and
# the ansible collection under /home/artex makes bbot work as uid 10001.
ENV HOME=/home/artex
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git curl xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /home/artex
COPY requirements-bbot.lock /tmp/requirements-bbot.lock
RUN set -eux; \
    python -m venv /opt/bbot; \
    /opt/bbot/bin/pip install --no-cache-dir --require-hashes -r /tmp/requirements-bbot.lock; \
    /opt/bbot/bin/python -c 'import bbot, sys; assert bbot.__version__ == sys.argv[1], bbot.__version__' "$BBOT_VERSION"; \
    rm -f /tmp/requirements-bbot.lock; \
    ln -s /opt/bbot/bin/bbot /usr/local/bin/bbot; \
    PIP_NO_CACHE_DIR=1 bbot -y --install-all-deps; \
    bbot --version >/dev/null; \
    bbot --dry-run -t example.com -m wafw00f,paramminer_getparams,lightfuzz,sslcert,gowitness >/dev/null 2>&1 || true; \
    bbot --dry-run -t example.com -m wafw00f,paramminer_getparams,lightfuzz,sslcert,gowitness --no-color >/tmp/bbot-dry.log 2>&1 || true; \
    ! grep -qE "Installing|ERRR|CRITICAL" /tmp/bbot-dry.log || { cat /tmp/bbot-dry.log; exit 1; }; \
    # Keep the core-dep marker, the ansible collection and the bbot config; drop the
    # tool cache (~1.5 GB of a second chrome/node/jadx/trufflehog) and run leftovers.
    # Tools re-download into the same place on first use, as uid 10001.
    rm -rf /home/artex/.bbot/tools /home/artex/.bbot/temp /home/artex/.bbot/logs \
           /home/artex/.bbot/scans /home/artex/.ansible/galaxy_cache \
           /home/artex/.cache /tmp/bbot-dry.log

# ---------------------------------------------------------------- runtime ---
FROM python:3.12.16-slim-bookworm@sha256:935c3c5b12357a7e10caa9c1e6ca5692344d97cf229832ef584be2cec9fc03df
ARG TARGETARCH

# Node 22 comes from the pinned build stage above rather than
# `curl https://deb.nodesource.com/setup_22.x | bash -`, which executes whatever
# that URL serves at build time as root. Same Node line, no remote script.
COPY --from=web /usr/local /usr/local

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates ripgrep curl wget vim git jq unzip \
      dnsutils iputils-ping netcat-openbsd inetutils-telnet whois nmap \
      p7zip-full xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && node --version && npm --version

# Web-recon toolbox (drost-community take 1, #100), installed into /usr/local/bin
# so hunt workers can run them directly through their Bash tool.
#
# Versions are pinned, and so is the SHA-256 of the archive for each architecture.
# If an upstream release asset is replaced, the build fails instead of silently
# installing different bytes. To upgrade: bump the version and the two hashes
# together (hashes come from the vendor's published checksums file).
ARG NUCLEI_VERSION=v3.11.1
ARG HTTPX_VERSION=v1.12.0
ARG SUBFINDER_VERSION=v2.17.0
ARG KATANA_VERSION=v1.8.0
ARG FFUF_VERSION=v2.3.0
ARG DALFOX_VERSION=v3.2.4

ARG NUCLEI_SHA256_AMD64=ea63d4ae232808cd7c6bc00d0142428e231fab59dae01042246097d195835ab6
ARG NUCLEI_SHA256_ARM64=8044e3d9768ba0a744b2872c1a87e813006f013da97ca9f50f7661a4203bec07
ARG HTTPX_SHA256_AMD64=9d8439e8b6c9aa7d1e2314817a392e00d5178da3af5652f7475f88868f418f76
ARG HTTPX_SHA256_ARM64=fd7b123c1dfbc3d69f19f524e4eebcd6ec06b9a6cbd56813c76f11645197331e
ARG SUBFINDER_SHA256_AMD64=a39c3e5c7a26ef3c430915c4d6cbf7716a00f26769a75e9405aba796142eba37
ARG SUBFINDER_SHA256_ARM64=24913d49dddc1d3a5e99a4a7580da5be980959b9415b96f52c4f7f4124392190
ARG KATANA_SHA256_AMD64=cb027ae99d0757061b70c07a15c7a80f62c5a535ab52c4a329f80c4b0a7309d2
ARG KATANA_SHA256_ARM64=80e269210727a855511ffac8dfb01297b2344742acec71a35e8ba4a67a90f0f2
ARG FFUF_SHA256_AMD64=b2a3c725fcb9da175159682f54d6e9149f2905b00d84d155e7efc5d599975ceb
ARG FFUF_SHA256_ARM64=e2d712615d53da797ee929006e41f2df5a7960a5353133db9c150ddaa22ae4e8
ARG DALFOX_SHA256_AMD64=c11cfd2f8261973f0a2a2a1eba5a147ce77712a29acfa6343f9847fb8bb7eca2
ARG DALFOX_SHA256_ARM64=fd56b0b7da2d06868cd73b504f41d21314629feffcd5bdc97718db1c9dd2fa70

# sqlmap is a python checkout with no release binaries; pinned to a commit.
ARG SQLMAP_COMMIT=397a3bde2e2c2a07680dd9402b16cb37d3721027

RUN set -eux; \
    base="https://github.com"; \
    case "$TARGETARCH" in \
      amd64) FFUF_ARCH=amd64;  DALFOX_ARCH=x86_64; \
             NUCLEI_SHA="$NUCLEI_SHA256_AMD64"; HTTPX_SHA="$HTTPX_SHA256_AMD64"; \
             SUBFINDER_SHA="$SUBFINDER_SHA256_AMD64"; KATANA_SHA="$KATANA_SHA256_AMD64"; \
             FFUF_SHA="$FFUF_SHA256_AMD64"; DALFOX_SHA="$DALFOX_SHA256_AMD64" ;; \
      arm64) FFUF_ARCH=arm64;  DALFOX_ARCH=aarch64; \
             NUCLEI_SHA="$NUCLEI_SHA256_ARM64"; HTTPX_SHA="$HTTPX_SHA256_ARM64"; \
             SUBFINDER_SHA="$SUBFINDER_SHA256_ARM64"; KATANA_SHA="$KATANA_SHA256_ARM64"; \
             FFUF_SHA="$FFUF_SHA256_ARM64"; DALFOX_SHA="$DALFOX_SHA256_ARM64" ;; \
      *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    verify() { printf '%s  %s\n' "$1" "$2" | sha256sum -c - ; }; \
    install_found() { name="$1"; src=/tmp/td; \
      f="$(find "$src" -type f -name "$name" | head -1)"; \
      [ -n "$f" ] || { echo "expected binary $name missing from archive" >&2; exit 1; }; \
      install -m 0755 "$f" "/usr/local/bin/$name"; }; \
    fetch_zip() { repo="$1"; ver="$2"; name="$3"; want="$4"; nov="${ver#v}"; \
      curl -fsSL --proto '=https' --tlsv1.2 \
        "$base/$repo/releases/download/$ver/${name}_${nov}_linux_${TARGETARCH}.zip" -o /tmp/t.zip; \
      verify "$want" /tmp/t.zip; \
      rm -rf /tmp/td; unzip -q -o /tmp/t.zip -d /tmp/td; \
      install_found "$name"; rm -rf /tmp/t.zip /tmp/td; }; \
    fetch_tgz() { url="$1"; name="$2"; want="$3"; \
      curl -fsSL --proto '=https' --tlsv1.2 "$url" -o /tmp/t.tgz; \
      verify "$want" /tmp/t.tgz; \
      rm -rf /tmp/td; mkdir -p /tmp/td; tar -xzf /tmp/t.tgz -C /tmp/td; \
      install_found "$name"; rm -rf /tmp/t.tgz /tmp/td; }; \
    fetch_zip projectdiscovery/nuclei    "$NUCLEI_VERSION"    nuclei    "$NUCLEI_SHA"; \
    fetch_zip projectdiscovery/httpx     "$HTTPX_VERSION"     httpx     "$HTTPX_SHA"; \
    fetch_zip projectdiscovery/subfinder "$SUBFINDER_VERSION" subfinder "$SUBFINDER_SHA"; \
    fetch_zip projectdiscovery/katana    "$KATANA_VERSION"    katana    "$KATANA_SHA"; \
    fetch_tgz "$base/ffuf/ffuf/releases/download/$FFUF_VERSION/ffuf_${FFUF_VERSION#v}_linux_${FFUF_ARCH}.tar.gz" \
              ffuf "$FFUF_SHA"; \
    fetch_tgz "$base/hahwul/dalfox/releases/download/$DALFOX_VERSION/dalfox-${DALFOX_VERSION}-linux-${DALFOX_ARCH}-musl.tar.gz" \
              dalfox "$DALFOX_SHA"; \
    git init -q /opt/sqlmap; \
    git -C /opt/sqlmap remote add origin "$base/sqlmapproject/sqlmap"; \
    git -C /opt/sqlmap fetch -q --depth 1 origin "$SQLMAP_COMMIT"; \
    git -C /opt/sqlmap checkout -q FETCH_HEAD; \
    test "$(git -C /opt/sqlmap rev-parse HEAD)" = "$SQLMAP_COMMIT"; \
    ln -s /opt/sqlmap/sqlmap.py /usr/local/bin/sqlmap; \
    nuclei -version >/dev/null; httpx -version; subfinder -version; katana -version; \
    ffuf -V >/dev/null; dalfox --version >/dev/null 2>&1 || true; sqlmap --version >/dev/null

# bbot recursive recon orchestrator (#117): blacklanternsecurity/bbot, AGPL-3.0
# (same license as ARTEX; standalone CLI dependency, not linked code). Own venv to
# isolate it from the image python, installed from a fully hashed lock
# (requirements-bbot.lock, 68 packages, generated for cp312 on amd64 and arm64).
# Module dependencies are preinstalled (--install-all-deps) so scans never need pip
# at runtime, which would fail under a program's egress allowlist. Built in the
# bbotdeps stage above; only the venv is copied, so the build tooling and the
# build-time tool cache stay out of this image.
COPY --from=bbotdeps /opt/bbot /opt/bbot
RUN ln -s /opt/bbot/bin/bbot /usr/local/bin/bbot
# bbot's prepared home: core-dep marker in .bbot/cache, ansible collection, config.
COPY --from=bbotdeps /home/artex/.bbot /home/artex/.bbot
COPY --from=bbotdeps /home/artex/.ansible /home/artex/.ansible
COPY --from=bbotdeps /home/artex/.config /home/artex/.config

# Preinstall Playwright MCP and CLI (globally) so no npx network download is needed
# at runtime. Exact versions, not @latest: @latest makes the image non-reproducible
# and lets a future publish change what lands in the build.
# Browsers land in a shared path so the unprivileged runtime user can read them.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
ARG PLAYWRIGHT_MCP_VERSION=0.0.84
ARG PLAYWRIGHT_CLI_VERSION=0.1.23
ARG PLAYWRIGHT_VERSION=1.65.0
RUN npm install -g --no-fund --no-audit \
        "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}" \
        "@playwright/cli@${PLAYWRIGHT_CLI_VERSION}" \
        "playwright@${PLAYWRIGHT_VERSION}" \
    && playwright-cli --help \
    # --only-shell: ARTEX launches @playwright/mcp with --headless (db/db.go), and
    # headless Chromium runs the chromium-headless-shell build, so the ~420 MB headed
    # Chromium never starts. Drop it; ffmpeg stays (screenshots/video need it).
    && playwright install --with-deps --only-shell chromium \
    && rm -rf /var/lib/apt/lists/* /root/.npm /root/.cache/node

WORKDIR /app
# Binary compiled from source in the build stage above.
COPY --from=build /out/artex /app/artex
# Daemon startup script: relaunches the process after a crash and forwards SIGTERM
# to artex — docker stop only signals PID 1; without forwarding, artex never receives it,
# cannot shut down gracefully, and is hard-killed by SIGKILL after 10 seconds.
COPY start.sh /app/start.sh
COPY docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/artex /app/start.sh /app/docker-entrypoint.sh \
    && mkdir -p /app/keys /app/data

# persistence points: data/ (SQLite, task files) and keys/ (jwt.key, via ARTEX_JWT_KEY_DIR)
# Only the writable paths are handed to the runtime user; the binary and skills stay
# root-owned and read-only, so a compromised agent process cannot rewrite them.
RUN groupadd --gid 10001 artex \
    && useradd --uid 10001 --gid artex --home-dir /home/artex --create-home \
               --shell /usr/sbin/nologin artex \
    && chown -R artex:artex /app/data /app/keys /home/artex \
    && chmod -R a+rX /ms-playwright
COPY skills/ /app/skills/
VOLUME ["/app/data", "/app/keys"]
EXPOSE 8787 8788
ENV HOME=/home/artex
# Default user is unprivileged. docker-compose.yml overrides this with `user: "0:0"`
# because it bind-mounts ./data and ./keys from the host (created root-owned by the
# daemon); the entrypoint then chowns those two paths and drops back to uid 10001
# with setpriv before artex runs. A plain `docker run` without host bind mounts, and
# `kubectl` with runAsNonRoot, use uid 10001 directly and skip the handover.
USER artex
ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["-addr", ":8787", "-proxy", ":8788"]
