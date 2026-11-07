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

## Changes in this fork (4)

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

## Not covered (know what this does not protect against)

- `bbot` is version-pinned (`3.0.2`) but not hash-pinned: `pip` is invoked without
  `--require-hashes`. Adding a hashed `requirements.txt` is the next step if you care.
- `apt-get` packages and the base images are tag-pinned, not digest-pinned. For a
  reproducible build, pin `python:3.12-slim-bookworm@sha256:…`,
  `node:22-bookworm-slim@sha256:…` and `golang:1.26-bookworm@sha256:…`.
- The image build is not byte-reproducible (pip/npm/apt fetch at build time).
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

> Status: these Dockerfile changes were **not built** in the environment where they
> were written (no Docker available). Validate with `docker build .` before relying on
> them; the hash values come from each vendor's published checksums file and are
> correct as of the versions pinned above.
