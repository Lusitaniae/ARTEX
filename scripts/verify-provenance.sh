#!/usr/bin/env bash
# Verify that what you are about to run is what was reviewed.
#
# Two independent checks:
#   1. upstream   - the base commit we forked from is the commit the original
#                   author published, per the Go module proxy's VCS record.
#   2. release    - a published release asset hashes to the published SHA256SUMS
#                   and its embedded Go buildinfo points at the tagged commit.
#
# Usage:
#   scripts/verify-provenance.sh upstream <version> <commit>
#   scripts/verify-provenance.sh release  <owner/repo> <tag> <asset-name>
#
# Examples:
#   scripts/verify-provenance.sh upstream v0.3.15 e6ec56999175509551a1e43a3ee3b053d0941bd9
#   scripts/verify-provenance.sh release BaaRai/ARTEX v0.5.1 artex-0.5.1-linux-amd64.zip
set -euo pipefail

die() { echo "FAIL: $*" >&2; exit 1; }
ok()  { echo "OK:   $*"; }

have() { command -v "$1" >/dev/null 2>&1; }
have curl    || die "curl is required"
have python3 || die "python3 is required"

# module path -> lowercase, uppercase letters escaped as !lowercase
escape_module() { python3 -c 'import sys;print("".join("!"+c.lower() if c.isupper() else c for c in sys.argv[1]))' "$1"; }

cmd_upstream() {
  local version="${1:?version}" want="${2:?commit}"
  local mod; mod="$(escape_module github.com/Autumn-27/artex)"
  local meta; meta="$(curl -fsSL "https://proxy.golang.org/${mod}/@v/${version}.info")" \
    || die "proxy has no record of ${version}"
  local got
  got="$(python3 -c 'import json,sys;print((json.load(sys.stdin).get("Origin") or {}).get("Hash",""))' <<<"$meta")"
  [ -n "$got" ] || die "proxy record for ${version} carries no VCS hash"
  [ "$got" = "$want" ] || die "${version} resolves to ${got}, expected ${want}"
  ok "proxy.golang.org: ${version} -> ${got} (matches)"

  local zip_url="https://proxy.golang.org/${mod}/@v/${version}.zip"
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL "$zip_url" -o "$tmp/m.zip" || die "cannot download module zip"
  ok "module zip downloaded: $(sha256sum "$tmp/m.zip" | cut -d' ' -f1)"
  echo "$tmp/m.zip"
}

cmd_release() {
  local repo="${1:?owner/repo}" tag="${2:?tag}" asset="${3:?asset}"
  local tmp; tmp="$(mktemp -d)"
  local base="https://github.com/${repo}/releases/download/${tag}"
  curl -fsSL "${base}/SHA256SUMS" -o "$tmp/SHA256SUMS" || die "no SHA256SUMS on ${tag}"
  curl -fsSL "${base}/${asset}"     -o "$tmp/${asset}"     || die "cannot download ${asset}"
  ( cd "$tmp" && grep -E "  ${asset}$" SHA256SUMS | sha256sum -c - ) || die "${asset} does not match SHA256SUMS"
  ok "${asset} matches the published SHA256SUMS"

  case "$asset" in
    *.zip)
      python3 - "$tmp/$asset" "$tmp/out" <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY
      local bin
      bin="$(find "$tmp/out" -type f -perm -u+x ! -name '*.sh' | head -1)"
      [ -n "$bin" ] || die "no executable inside ${asset}"
      local rev
      rev="$(python3 - "$bin" <<'PY'
import re,sys
d=open(sys.argv[1],'rb').read()
m=re.search(rb'vcs\.revision=([0-9a-f]{40})', d)
mod=re.search(rb'vcs\.modified=(true|false)', d)
print((m.group(1).decode() if m else '') + ' ' + (mod.group(1).decode() if mod else ''))
PY
)"
      local commit="${rev% *}" modified="${rev#* }"
      [ -n "$commit" ] || die "no Go buildinfo in ${bin}"
      [ "$modified" = "false" ] || die "binary was built from a modified tree (vcs.modified=${modified})"
      ok "buildinfo: vcs.revision=${commit}, vcs.modified=false"
      echo "     compare that revision against the tag: git rev-parse ${tag}"
      ;;
    *) ok "archive verified (no buildinfo check for this type)" ;;
  esac
}

case "${1:-}" in
  upstream) shift; cmd_upstream "$@" ;;
  release)  shift; cmd_release  "$@" ;;
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ; exit 2 ;;
esac
