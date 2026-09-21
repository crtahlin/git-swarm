#!/usr/bin/env bash
# Assert what a Radicle storage repo actually contains.
#
# This test exists because two issues (#33, #34) were filed from assumptions
# about this layout and both were wrong. It is the regression guard: if Radicle
# changes the shape, a test fails instead of a design document going stale.
#
# Usage: fixture-shape.sh [rad-home] [rid]
# With no arguments it builds its own fixture in a temp directory.

set -euo pipefail

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
[ -f "$HERE/.env" ] && . "$HERE/.env"

fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*" >&2; exit 77; }

command -v rad >/dev/null 2>&1 || skip "rad not on PATH (set PATH to a radicle-bin directory)"

RAD_HOME_ARG="${1:-}"
RID="${2:-}"
CLEANUP=''

if [ -z "$RAD_HOME_ARG" ]; then
  RAD_HOME_ARG="$(mktemp -d)/rad"
  CLEANUP="$RAD_HOME_ARG"
  RID="$("$HERE/tests/stack/seed-fixture.sh" "$RAD_HOME_ARG" 2>/dev/null)" \
    || skip "could not build a fixture"
fi
[ -n "$RID" ] || fail "no RID given and none produced"

trap '[ -n "$CLEANUP" ] && rm -rf "$CLEANUP" "$CLEANUP.work"' EXIT

REPO="$RAD_HOME_ARG/storage/$RID"
[ -d "$REPO" ] || fail "no storage repo at $REPO"

refs="$(git -C "$REPO" for-each-ref --format='%(objecttype) %(refname)')"
nid="$(printf '%s\n' "$refs" | sed -n 's|.*refs/namespaces/\([^/]*\)/.*|\1|p' | sed -n '1p')"
[ -n "$nid" ] || fail "no refs/namespaces/<nid>/ found — is this a storage repo?"

echo "==> node id $nid"

# 1. Every ref is a commit. No blobs, no tags, no annotated anything.
#    A non-commit here would break the fast-forward check, which is the thing
#    #33 originally claimed was already happening.
nonc="$(printf '%s\n' "$refs" | grep -v '^commit ' || true)"
[ -z "$nonc" ] || fail "non-commit refs present:
$nonc"
echo "==> all refs are commits                        ok"

# 2. The refs an archive must carry to stay verifiable.
for suffix in \
  "refs/namespaces/$nid/refs/rad/sigrefs" \
  "refs/namespaces/$nid/refs/rad/id" \
  "refs/namespaces/$nid/refs/rad/root" \
  "refs/namespaces/$nid/refs/heads/main"
do
  printf '%s\n' "$refs" | grep -qF " $suffix" || fail "missing $suffix"
done
echo "==> namespace carries sigrefs, id, root, main    ok"

# 3. A top-level refs/heads/main exists — the canonical branch.
#    #34 assumed it did not, and concluded the manifest head would be null.
printf '%s\n' "$refs" | grep -q ' refs/heads/main$' \
  || fail "no top-level refs/heads/main — manifest head would be null (see #34)"
echo "==> top-level refs/heads/main present            ok"

# 4. sigrefs is a commit whose tree holds the refs and signature blobs.
#    This is where the blob/commit confusion came from: the blobs are real,
#    one level below the ref.
sig="refs/namespaces/$nid/refs/rad/sigrefs"
[ "$(git -C "$REPO" cat-file -t "$(git -C "$REPO" rev-parse "$sig")")" = commit ] \
  || fail "$sig is not a commit"
tree="$(git -C "$REPO" ls-tree --name-only "$sig" | sort | tr '\n' ' ')"
[ "$tree" = "refs signature " ] || fail "sigrefs tree is '$tree', expected 'refs signature '"
echo "==> sigrefs is a commit over refs+signature      ok"

# 5. A second push fast-forwards sigrefs. If this ever fails, mirror semantics
#    become a blocker rather than hardening (#33).
count="$(git -C "$REPO" rev-list --count "$sig")"
if [ "$count" -lt 2 ]; then
  echo "==> sigrefs has one entry; ancestry not exercised (fixture too shallow)"
else
  parent="$(git -C "$REPO" rev-parse "$sig^")"
  git -C "$REPO" merge-base --is-ancestor "$parent" "$(git -C "$REPO" rev-parse "$sig")" \
    || fail "sigrefs update is NOT a fast-forward — #33 becomes a blocker"
  echo "==> sigrefs update fast-forwards ($count entries) ok"
fi

echo
echo "PASS"
