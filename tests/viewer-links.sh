#!/usr/bin/env bash
#
# Check that links on the served viewer actually work — on a local Bee node and
# through public gateways.
#
#   ./tests/viewer-links.sh <viewer-hash> <repo-feed-manifest> [endpoint ...]
#
# Endpoints default to the local node and bzz.limo. For each one it:
#
#   1. renders the viewer and confirms the repository loaded, not an error
#   2. extracts every link from the rendered README
#   3. loads each INTERNAL link and confirms it opens that file, rather than
#      404ing against the gateway — the failure this test exists to catch
#   4. HEADs each EXTERNAL link and confirms it is reachable
#
# A README written for GitHub links to `docs/architecture.md`. Served from
# /bzz/<hash>/, a browser resolves that against the gateway and gets nothing:
# the document is not a file on the gateway, it is an object inside a packfile.

set -euo pipefail

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
VIEWER="${1:-}"
REPO="${2:-}"
shift 2 2>/dev/null || true
ENDPOINTS=("$@")
[ ${#ENDPOINTS[@]} -eq 0 ] && ENDPOINTS=("http://localhost:1633" "https://bzz.limo")

MAX_INTERNAL="${MAX_INTERNAL:-6}"
BUDGET_MS="${BUDGET_MS:-60000}"

fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*" >&2; exit 77; }

[ -n "$VIEWER" ] && [ -n "$REPO" ] || fail "usage: $0 <viewer-hash> <repo-feed-manifest> [endpoint ...]"
[ -x "$CHROME" ] || skip "headless Chrome not found at $CHROME"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

render() {  # render <url> <outfile>
  "$CHROME" --headless --disable-gpu --no-sandbox \
    --virtual-time-budget="$BUDGET_MS" --dump-dom "$1" >"$2" 2>/dev/null || return 1
  [ -s "$2" ] || return 1
}

# Anchors the viewer produced, split into internal (deep links into the repo)
# and external (left exactly as the author wrote them).
internal_links() { LC_ALL=C grep -oE 'href="#[^"]+/-/[^"]+"' "$1" | sed 's/href="//; s/"$//' | sort -u; }
external_links() { LC_ALL=C grep -oE 'href="https?://[^"]+"' "$1" | sed 's/href="//; s/"$//' | sort -u; }

overall_failed=0

for endpoint in "${ENDPOINTS[@]}"; do
  echo "════ $endpoint"
  base="$endpoint/bzz/$VIEWER/"
  root="$TMP/root.html"

  if ! render "$base#bzz/$REPO" "$root"; then
    echo "  UNREACHABLE — skipping this endpoint" >&2
    continue
  fi

  if LC_ALL=C grep -q 'class="status error"' "$root"; then
    LC_ALL=C grep -o 'class="status error">[^<]*' "$root" | head -1 >&2
    fail "$endpoint: viewer reported an error instead of loading the repository"
  fi
  LC_ALL=C grep -q 'id="repo-name">[^<]' "$root" || fail "$endpoint: repository did not render"
  echo "  ✓ repository rendered"

  # --- internal links -------------------------------------------------------
  # No mapfile: macOS ships bash 3.2.
  internal_links "$root" | head -"$MAX_INTERNAL" > "$TMP/internal.txt"
  [ -s "$TMP/internal.txt" ] || echo "  ! no internal links in the rendered README — nothing to check" >&2

  while IFS= read -r link; do
    [ -n "$link" ] || continue
    want="${link##*/-/}"
    want="${want%%#*}"
    out="$TMP/link.html"

    if ! render "$base$link" "$out"; then
      echo "  ✗ $want — render failed" >&2
      overall_failed=1
      continue
    fi
    if LC_ALL=C grep -q 'class="status error"' "$out"; then
      echo "  ✗ $want — viewer error" >&2
      overall_failed=1
      continue
    fi
    # The file panel must name the file the link pointed at.
    if LC_ALL=C grep -q "id=\"file-name\">$want<" "$out"; then
      echo "  ✓ $want"
    elif LC_ALL=C grep -q 'id="breadcrumb"' "$out" && LC_ALL=C grep -q "$want" "$out"; then
      echo "  ✓ $want (directory)"
    else
      echo "  ✗ $want — link resolved to something else" >&2
      overall_failed=1
    fi
  done < "$TMP/internal.txt"

  # --- external links -------------------------------------------------------
  for url in $(external_links "$root" | head -8); do
    code=$(curl -sL -m 25 -o /dev/null -w "%{http_code}" -A "Mozilla/5.0" "$url" || echo 000)
    case "$code" in
      2*|3*)  echo "  ✓ $code  $url" ;;
      000)    echo "  ! network error $url (not counted)" >&2 ;;
      4*|5*)  echo "  ✗ $code  $url" >&2; overall_failed=1 ;;
    esac
  done
done

echo
[ "$overall_failed" -eq 0 ] || fail "some links did not resolve"
echo "PASS — internal links open their file in the viewer, external links are reachable"
