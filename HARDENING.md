# HARDENING — local fork notes

This branch (`hardening/local`) is a fork of [BaaRai/ARTEX](https://github.com/BaaRai/ARTEX),
which is itself derived from the deleted `Autumn-27/ARTEX`. Upstream code is AGPL-3.0;
this fork stays under AGPL-3.0 and keeps the original attribution and `LICENSE`.

It records *why* the fork exists and what was changed, so the delta can be re-reviewed
without redoing the audit.

## Provenance (verified, reproducible)

| Claim | How it was verified |
|---|---|
| The base tree is the original author's | `proxy.golang.org` records `v0.3.15` → `e6ec56999175509551a1e43a3ee3b053d0941bd9` for `github.com/Autumn-27/artex`; the module zip matched the git tree **600/600 files**. |
| All six public forks share that base | Identical root commit `0ef8561` and identical SHAs through `ad9f14f`; three forks carry upstream SHAs through `v0.3.15`. |
| `BaaRai/ARTEX` did not alter upstream content | Its re-rooted history has a tree hash identical to upstream at `v0.3.15` (`bcee5171…`), and 443/444 commit subjects+dates match in order. |
| The release binary matches the source | `v0.5.1` buildinfo: `vcs.revision=ce279d7`, `vcs.modified=false`, `-trimpath=true`; `ce279d7` is the `v0.5.1` tag commit. |

Re-run with:

```bash
scripts/verify-provenance.sh upstream v0.3.15 e6ec56999175509551a1e43a3ee3b053d0941bd9
scripts/verify-provenance.sh release BaaRai/ARTEX v0.5.1 artex-0.5.1-linux-amd64.zip
```

## Changes in this fork (8)

1. **Tool archives are hash-pinned.** nuclei, httpx, subfinder, katana, ffuf and dalfox
   are verified against a SHA-256 pinned in the `Dockerfile` for both `amd64` and
   `arm64`. Previously the version was pinned but the bytes were not: a replaced
   release asset would have been installed silently.
2. **`sqlmap` pinned to a commit** (`397a3bd`) instead of `git clone --depth 1` of a
   moving branch, and the checkout is verified after fetch.
3. **No remote install script.** Node 22 is copied from the pinned `node:22-bookworm-slim`
   build stage instead of `curl https://deb.nodesource.com/setup_22.x | bash -`.
   Playwright packages are pinned to exact versions instead of `@latest`.
4. **Container runs unprivileged** (`uid 10001`). `/app/artex` and `/app/skills` stay
   root-owned and read-only; only `/app/data` and `/app/keys` are writable.
   Under compose, `docker-entrypoint.sh` starts as root, hands those two volumes to
   `uid 10001` (compose bind-mounts them from the host, where the daemon creates them
   root-owned) and then `exec`s `setpriv --reuid=10001 --regid=10001`; artex and the
   agents it spawns never run as root.
5. **Base images pinned by digest** — `python:3.12-slim-bookworm`, `node:22-bookworm-slim`
   and `golang:1.26-bookworm` are referenced by multi-arch index digest, so a re-tagged
   base image cannot change what is built.
6. **`bbot` installed from a hashed lock** — `requirements-bbot.lock` (68 packages,
   generated with `uv pip compile --generate-hashes` for cp312 on both manylinux
   architectures) is installed with `pip --require-hashes`, and the import is checked
   against `BBOT_VERSION`. Verified by installing the lock under `--require-hashes` on
   CPython 3.12 before committing it.
7. **`bbot` is built in a throwaway stage** — `--install-all-deps` apt-installs gcc,
   make, libssl-dev, 7z and xz, pip-installs 40 module packages (django, numpy,
   kreuzberg, …), and its dry-run downloads bbot's per-module *tool* cache into `$HOME`
   (a second Chromium 693 MB, a second Node 164 MB, jadx 110 MB, trufflehog 34 MB,
   gowitness 47 MB — 1.5 GB total). Only `/opt/bbot` plus bbot's config, the core-dep
   marker and the ansible collection are copied into the runtime image; the build
   tooling and the tool cache never are. They were also unusable before: they lived in
   `/root`, which uid 10001 cannot read, so the image carried 1.5 GB that nothing could
   use. Tools download into `/home/artex/.bbot/tools` on first use instead.
8. **`bbot` works unprivileged** — bbot's installer skips core deps when
   `~/.bbot/cache/<hash>` exists and otherwise shells out to `sudo`, which the runtime
   image does not have (bbot only catches `CalledProcessError`, so the missing binary
   aborted the scan with `FileNotFoundError`). The build seeds the marker, the
   `bbot.yml`/`secrets.yml` config and the ansible collection under `/home/artex`, and
   the runtime image hands that directory to uid 10001, so bbot starts without root.
   Verified: `bbot --dry-run -m wafw00f,sslcert,paramminer_getparams` → `Setup
   succeeded for 13/13 modules`, exit 0, as uid 10001.

## Not covered (know what this does not protect against)

- `apt-get` packages are version-constrained by the digest-pinned base image but are not
  individually hash-pinned; Debian security updates will change them between builds.
- `bbot -y --install-all-deps` installs 40 distributions beyond the 68 in the hashed
  lock: django 5.2.19, numpy 2.5.4, kreuzberg 4.4.6, sqlalchemy 2.1.8, zstandard,
  asyncpg, pymysql, pymongo, aiokafka, neo4j, baddns, badsecrets, flask-unsign,
  wafw00f, … (≈234 MB of the 508 MB venv). They are **unpinned and unhashed**: pip
  resolves the newest compatible release at build time, so two builds of this
  Dockerfile can ship different code. The set is recorded in
  `BBOT-MODULE-DEPS.md`; pinning it would mean generating a second hashed lock
  for those 40 (plus their transitive deps) and dropping the flag for the modules you
  use.
- bbot's per-module tool cache is no longer baked in. On first use each module
  downloads its tools (chromium, node, jadx, trufflehog, gowitness, …) into
  `/home/artex/.bbot/tools`, up to ~1.5 GB. That needs egress to the vendors' release
  hosts; under a strict allowlist, either allow those hosts or pre-seed the directory
  as uid 10001 and accept the image size.
- The image build is not byte-reproducible (apt/pip/npm fetch at build time, and
  `npm ci` resolves from the lockfile's registry URLs).
- PID 1 of the container starts as root for the `/app/data` + `/app/keys` ownership
  handover before dropping to `uid 10001`. This only happens under `docker-compose.yml`,
  which sets `user: "0:0"` because it bind-mounts those paths from the host; the image
  default is `USER artex`, so `docker run` without host bind mounts (and
  `runAsNonRoot` in Kubernetes) start directly as `uid 10001`. Running the compose file
  with `--user 10001` skips the handover, and then the host directories must already be
  owned by `10001:10001`.
- The `bot.yml` workflow sends issue/PR text to DeepSeek and holds a token with
  `issues: write`. It cannot push code (`contents: read`). Delete that workflow in a
  private fork if you don't want it.

## Maintenance

Keep the patch set small and rebase it onto upstream tags:

```bash
git fetch origin --tags
git rebase --onto origin/v0.x.y <old-upstream-tag> hardening/local
```

If this fork is ever served to other people over a network, AGPL-3.0 §13 requires
offering them the corresponding source of the modified version.

> Status: the image builds and runs. Verified locally with `docker build -t artex:local .`
> plus `docker compose up -d --no-build` (postgres + artex healthy, UI answering on
> 127.0.0.1:8787, bbot 3.0.2 running as uid 10001). Re-verify after changing any version
> pin: `docker build --progress=plain -t artex:local .`
>
> Size: 6.49 GB → 2.58 GB (`docker system df -v`; 1.83 GB measured with `du`). Removed:
> 1.5 GB of bbot build junk in `/root` (tool cache + gcc/make/libssl-dev/ansible installs),
> 92 MB pip cache, 55 MB npm cache, the 422 MB headed Chromium that `--headless` never
> starts, 173 MB of Xvfb/mesa/libLLVM-15 that `--with-deps` installs for headed rendering
> (headless Chromium uses the bundled SwiftShader; screenshots and WebGL verified after
> removal), ~43 MB of `vim` + vim-runtime (no skill invokes it), and 7 MB of Node headers.
>
> What is left is mostly functional: `/opt/bbot` 508 MB (of which 234 MB is the unpinned
> module deps above), `/ms-playwright` 288 MB (headless shell + ffmpeg), the six Go tools
> in `/usr/local/bin` ~436 MB (already stripped; nuclei alone is 177 MB), Node 124 MB and
> Python 3.12. The three ways to go lower are capability trades, not cleanup: install bbot
> module deps only for the modules the skill uses (-234 MB, breaks ad-hoc modules), drop
> bbot (-508 MB), or drop the browser MCP (-412 MB for Playwright + Node).
