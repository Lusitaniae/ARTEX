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

## Changes in this fork (6)

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

## Not covered (know what this does not protect against)

- `apt-get` packages are version-constrained by the digest-pinned base image but are not
  individually hash-pinned; Debian security updates will change them between builds.
- `bbot -y --install-all-deps` installs bbot's *module* dependencies into the venv after
  the hashed lock. Those extra packages are not hash-verified. If that matters, drop
  the flag and preinstall only the modules you use from your own locked list.
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
> 127.0.0.1:8787), and the pinned hashes/images were resolved during that build. Re-verify
> after changing any version pin: `docker build --progress=plain -t artex:local .`.
