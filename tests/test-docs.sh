#!/usr/bin/env bash
# The docs tell beginners to press a number. If a number in the README does not
# match the menu, they press the wrong thing on a real server. Derive the menu
# from the source and check every number the docs quote.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/one-click-install.sh"
DOCS="$ROOT"

pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }

# Only the lines the menu PRINTS matter. The case arms further down share the
# same "5) " shape but run commands instead of describing them, so cut the block
# off at the prompt and match the printf lines.
menu_body=$(sed -n "/^ *menu() {/,/Select \[0-9, h\]/p" "$SRC")

# opt_text <n> -> the label the menu prints for option n, empty if absent
opt_text() { grep -m1 "printf ' *$1) " <<<"$menu_body" | sed "s/^.*printf ' *//; s/'\$//"; }
has_opt()  { grep -q "printf ' *$1) " <<<"$menu_body"; }

echo "=== 1. numbers the menu actually accepts ==="
prompt=$(grep -oE 'Select \[[^]]*\]' <<<"$menu_body" | head -1)
printf '  prompt is: %s\n' "$prompt"
for n in 0 1 2 3 4 5 6 7 8 9; do
  has_opt "$n" && ok "option $n exists" || bad "option $n missing"
done

echo
echo "=== 2. every quoted number in README.md is a real option ==="
grep -oE '^\| .*\| \*\*[0-9]\*\*' "$DOCS/README.md" | grep -oE '[0-9]' | sort -u > /tmp/doc-nums
while read -r n; do
  has_opt "$n" && ok "README table references option $n" || bad "README references missing option $n"
done < /tmp/doc-nums

echo
echo "=== 3. doc claims about specific options still line up ==="
declare -A EXPECT=(
  [1]="IRAN server"
  [2]="OUTSIDE server"
  [5]="Service status"
  [6]="Test the tunnel end to end"
  [7]="Edit an existing bundle"
  [8]="Update to the latest release"
  [9]="Uninstall Raah completely"
)
for n in 1 2 5 6 7 8 9; do
  line=$(opt_text "$n")
  if [[ -n "$line" && "$line" == *"${EXPECT[$n]}"* ]]; then
    ok "option $n is: $line"
  else
    bad "option $n should contain '${EXPECT[$n]}' but the menu says: $line"
  fi
done

echo
echo "=== 4. no leftover references to the old 10-option menu ==="
for f in README.md README.fa.md; do
  for bad_ref in "Option 10" "Select \[0-10\]" "Generate direct bundle"; do
    if grep -qF -- "$bad_ref" "$DOCS/$f"; then
      bad "$f still says: $bad_ref"
    else
      ok "$f is free of: $bad_ref"
    fi
  done
done

echo
echo "=== 5. the Persian doc points at the same new numbers ==="
for n in ۵ ۶; do
  grep -q "گزینهٔ $n" "$DOCS/README.fa.md" && ok "fa references option $n" || bad "fa missing option $n"
done

echo
echo "=== 6. docs warn about the shared-key bundle ==="
for f in README.md README.fa.md; do
  if grep -qiE "same keys|کلیدهای یکسان" "$DOCS/$f"; then
    ok "$f explains the shared keys"
  else
    bad "$f does not explain the shared keys"
  fi
done

rm -f /tmp/doc-nums
echo
echo "=================================================="
printf '  %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
