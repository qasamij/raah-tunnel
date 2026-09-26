#!/usr/bin/env bash
# The docs tell beginners to press a number. If a number in the README does not
# match the menu, they press the wrong thing on a real server. Derive the menu
# from the source and check every number the docs quote.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/one-click-install.sh"
DOCS="$ROOT"

doc_nums="$(mktemp)"
trap 'rm -f "$doc_nums"' EXIT
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
grep -oE '^\| .*\| \*\*[0-9]\*\*' "$DOCS/README.md" | grep -oE '[0-9]' | sort -u > $doc_nums
while read -r n; do
  has_opt "$n" && ok "README table references option $n" || bad "README references missing option $n"
done < $doc_nums

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

rm -f $doc_nums

# The two changelogs are maintained by hand in two languages. The Persian file
# deliberately starts at 0.11.0, so the invariant is one-directional: anything
# the Persian file claims must also exist in the English one, and the Persian
# file must say where to find the older history. Demanding equal release counts
# would only force a translation of 23 releases nobody asked for.
echo
echo "=== 7. the two changelogs agree where they overlap ==="
for f in CHANGELOG.md CHANGELOG.fa.md; do
  if [[ -f "$DOCS/$f" ]]; then ok "$f exists"; else bad "$f is missing"; fi
done

if [[ -f "$DOCS/CHANGELOG.md" && -f "$DOCS/CHANGELOG.fa.md" ]]; then
  # Both must document the current, unreleased work.
  for f in CHANGELOG.md CHANGELOG.fa.md; do
    grep -qE '^## (Unreleased|منتشرنشده)' "$DOCS/$f" \
      && ok "$f has an unreleased section" || bad "$f has no unreleased section"
  done

  # Every numbered release claimed by the Persian file must exist in English.
  missing=""
  while IFS= read -r v; do
    grep -qF "$v" "$DOCS/CHANGELOG.md" || missing="$missing $v"
  done < <(grep -oE '^## [0-9]+\.[0-9]+\.[0-9]+' "$DOCS/CHANGELOG.fa.md" | sed 's/^## //')
  if [[ -z "$missing" ]]; then
    ok "every release in CHANGELOG.fa.md also exists in CHANGELOG.md"
  else
    bad "claimed only in Persian:$missing"
  fi

  # The English file is a superset, never a subset.
  en=$(grep -cE '^## [0-9]+\.[0-9]+\.[0-9]+' "$DOCS/CHANGELOG.md")
  fa=$(grep -cE '^## [0-9]+\.[0-9]+\.[0-9]+' "$DOCS/CHANGELOG.fa.md")
  [[ "$fa" -le "$en" ]] && ok "Persian covers $fa of $en releases (allowed to be fewer)" \
                       || bad "Persian lists $fa releases but English only has $en"

  # A reader who lands on the Persian file must be told the rest is English-only.
  if grep -qF 'CHANGELOG.md' "$DOCS/CHANGELOG.fa.md"; then
    ok "CHANGELOG.fa.md points at the English file for older releases"
  else
    bad "CHANGELOG.fa.md does not say where the older releases are"
  fi

  # Same number of subsections, so neither language gained or lost a topic.
  ens=$(awk '/^## /{on=1;next} /^### /{if(on)c++} END{print c+0}' "$DOCS/CHANGELOG.md")
  fas=$(awk '/^## /{on=1;next} /^### /{if(on)c++} END{print c+0}' "$DOCS/CHANGELOG.fa.md")
  [[ "$ens" -eq "$fas" ]] && ok "both files have $ens subsections" \
                         || bad "CHANGELOG.md has $ens subsections but CHANGELOG.fa.md has $fas"
fi

echo
echo "=== 8. each language links to its own changelog and the other language ==="
# A reader who lands on the Persian guide should not be sent to the English
# changelog, and the switcher has to work in both directions.
grep -qF '(CHANGELOG.fa.md)' "$DOCS/README.fa.md" \
  && ok "README.fa.md points at CHANGELOG.fa.md" || bad "README.fa.md does not point at CHANGELOG.fa.md"
grep -qF '(README.fa.md)' "$DOCS/README.md" \
  && ok "README.md links to the Persian guide" || bad "README.md does not link to README.fa.md"
grep -qF '(CHANGELOG.md)' "$DOCS/CHANGELOG.fa.md" \
  && ok "CHANGELOG.fa.md links back to the English one" || bad "CHANGELOG.fa.md has no link to CHANGELOG.md"
grep -qF '(CHANGELOG.fa.md)' "$DOCS/CHANGELOG.md" \
  && ok "CHANGELOG.md links to the Persian one" || bad "CHANGELOG.md has no link to CHANGELOG.fa.md"

echo
echo "=== 9. the newest entries cover the role-based menu in both languages ==="
for pair in "CHANGELOG.md:IRAN server" "CHANGELOG.fa.md:IRAN server"; do
  f="${pair%%:*}"; needle="${pair#*:}"
  grep -qF "$needle" "$DOCS/$f" && ok "$f mentions the role-based menu" \
                               || bad "$f does not mention the role-based menu"
done
for f in CHANGELOG.md CHANGELOG.fa.md; do
  grep -qE 'BUNDLE_DIR' "$DOCS/$f" && ok "$f documents BUNDLE_DIR" \
                                 || bad "$f does not document BUNDLE_DIR"
done

echo
echo "=================================================="
printf '  %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
