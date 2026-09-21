#!/usr/bin/env bash
# "Not an ancestor" and "could not tell" must not be the same answer.
#
# `git merge-base --is-ancestor` exits 1 for no and 128 for a failure — a ref
# pointing at a non-commit, a missing object, a broken repository. isAncestor
# used to catch both and return false, so a push that could not be evaluated was
# reported as non-fast-forward: a wrong diagnosis that sends the reader after a
# history problem they do not have.
#
# The secondary half of #33. Needs no Bee node.

set -euo pipefail

HERE="$(cd "$(dirname "$0")/../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*" >&2; exit 77; }

command -v node >/dev/null 2>&1 || skip "node not on PATH"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"
git init -q -b main "$REPO"
# No global git config in a container, and commit refuses without an identity.
git -C "$REPO" config user.email probe@example.invalid
git -C "$REPO" config user.name probe
git -C "$REPO" commit -q --allow-empty -m one
C1="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" commit -q --allow-empty -m two
C2="$(git -C "$REPO" rev-parse HEAD)"
BLOB="$(printf 'not a commit' | git -C "$REPO" hash-object -w --stdin)"
MISSING=0000000000000000000000000000000000000000

# The helper shells out to git in the current working directory, so run from the
# repository under test and import the module by absolute path.
cd "$REPO"
out="$(HELPER="$HERE" node --input-type=module -e "
const { isAncestor } = await import('file://' + process.env.HELPER + '/src/gitplumbing.js')

const check = (label, fn, expect) => {
  let got
  try { got = fn() === true ? 'true' : 'false' } catch (e) { got = 'throws:' + e.message }
  const ok = expect === 'throws' ? got.startsWith('throws:') : got === expect
  console.log((ok ? 'ok   ' : 'FAIL ') + label + '  -> ' + got)
  if (!ok) process.exitCode = 1
}

check('forwards  (c1 -> c2)', () => isAncestor('$C1', '$C2'), 'true')
check('backwards (c2 -> c1)', () => isAncestor('$C2', '$C1'), 'false')
check('blob      (cannot tell)', () => isAncestor('$BLOB', '$BLOB'), 'throws')
check('missing   (cannot tell)', () => isAncestor('$MISSING', '$C2'), 'throws')
" 2>&1)"
rc=$?

printf '%s\n' "$out" | sed 's/^/    /'
[ $rc -eq 0 ] || fail "isAncestor did not distinguish the four cases"

# The thrown message has to carry git's own reason, or it is no better than the
# boolean it replaced.
printf '%s\n' "$out" | grep -q "blob" \
  || fail "the error for a non-commit ref does not mention what git said"

echo "==> not-an-ancestor and cannot-tell are distinct    ok"
echo "==> the error carries git's reason                  ok"

echo
echo "PASS"
