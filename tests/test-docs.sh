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
# Only the bolded number in a table row counts. Matching "the last cell" made
# this depend on column order, and taking every digit on the line pulled in
# port numbers, so a row like "| **1** (IRAN) | UDP 8443 |" would have invented
# an option 8 and a 4 and a 3.
grep -E '^\|' "$DOCS/README.md" | grep -oE '\*\*[0-9]\*\*' | grep -oE '[0-9]' | sort -u > $doc_nums
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
  # Plain strings, no regex escaping: with grep -F a needle like
  # "Select \[0-10\]" searches for the backslashes too and can never match, so
  # the check passed no matter what the file said.
  for bad_ref in "Option 10" "Select [0-10]" "Generate direct bundle"; do
    if grep -qF -- "$bad_ref" "$DOCS/$f"; then
      bad "$f still says: $bad_ref"
    else
      ok "$f is free of: $bad_ref"
    fi
  done
  # The same mistake in Persian digits is the one that actually shipped.
  for bad_fa in "گزینهٔ ۱۰" "گزینه ۱۰" "گزینهٔ ۱۱" ; do
    if grep -qF -- "$bad_fa" "$DOCS/$f"; then
      bad "$f still says: $bad_fa"
    else
      ok "$f is free of: $bad_fa"
    fi
  done
done

echo
echo "=== 5. the Persian doc points at the same new numbers ==="
for n in ۵ ۶; do
  grep -q "گزینهٔ $n" "$DOCS/README.fa.md" && ok "fa references option $n" || bad "fa missing option $n"
done

# Checking only that a digit appears somewhere is not enough: the Persian guide
# shipped four wrong ones, because a number drifting off its action sends a
# reader to "update" when they meant "edit" and to "uninstall" when they meant
# "update". Require the number to sit on the same line as the action it names.
check_fa_action() { # <digit> <keyword that must share the line> <label>
  # Anchor the number to the action instead of the other way round. Looking for
  # the action phrase and hoping the number is nearby fails as soon as the phrase
  # also appears in a heading; here the number and the action must share a line,
  # which is the only place a reader will actually read them.
  if grep -F "گزینهٔ \`$1\`" "$DOCS/README.fa.md" | grep -qF "$2"; then
    ok "fa ties option $1 to: $3"
  else
    bad "fa does not tie option $1 to: $3 (no line mentioning 'گزینهٔ \`$1\`' also mentions '$2')"
  fi
}
check_fa_action 7 "انتخاب کن"  "editing a bundle"
check_fa_action 8 "تگ پایدار"  "installing the newest release"
check_fa_action 9 "UNINSTALL"  "uninstalling"

echo
echo "=== 6. docs warn about the shared-key bundle ==="
for f in README.md README.fa.md; do
  if grep -qiE "same keys|کلیدهای یکسان" "$DOCS/$f"; then
    ok "$f explains the shared keys"
  else
    bad "$f does not explain the shared keys"
  fi
done

echo
echo "=== 6b. every table row has the same number of cells as its header ==="
# Two rows were merged into one with "||", which rendered as a single broken row
# and silently dropped two troubleshooting entries. The existing checks only ever
# looked at the option table, so nothing noticed.
#
# The expected width comes from each table's own header rather than a fixed
# number. Hardcoding a column count looks like it works right up until someone
# adds a three-column table, at which point it rejects a correct document and
# trains everyone to ignore it.
for f in README.md README.fa.md; do
  broken=""
  expected=0
  in_table=0
  while IFS= read -r row || [[ -n "$row" ]]; do
    if [[ "$row" == "|"* ]]; then
      # A separator row closes the header; it is not a data row to compare.
      if [[ "$row" =~ ^\|[[:space:]]*[-:]+ ]]; then
        in_table=1
        continue
      fi
      cells="${row//[^|]/}"
      # A leading and trailing pipe is normal, so the count is delimiters minus 1.
      n=$(( ${#cells} - 1 ))
      if (( expected == 0 )); then
        expected="$n"          # the first row of this block is its header
      elif (( n != expected )); then
        broken="$broken
    $row"
      fi
      in_table=1
    else
      expected=0               # a non-table line ends this table
    fi
  done < "$DOCS/$f"
  if [[ -z "$broken" ]]; then
    ok "$f has no malformed table rows"
  else
    bad "$f has rows with the wrong cell count:$broken"
  fi
  # Both languages must carry the same tables, or a reader of one gets none.
  widths=$(grep -cE '^\|' "$DOCS/$f" || true)
  if (( widths > 0 )); then
    ok "$f still has table rows to check ($widths)"
  else
    bad "$f has no table rows at all; the check is vacuous"
  fi
done

echo
echo "=== 6c. copying a config to the other server also copies its metadata ==="
# install-unit.sh treats a missing .install.json as "hopping disabled" and exits
# 0, so following the documented scp of only the .json gives a server that starts
# cleanly and never applies the hopping DNAT table. Both guides must ship the pair.
for f in README.md README.fa.md; do
  # Look at the copy command itself, not the prose around it. A mention of
  # ".install.json" in the explanation is not the same as the scp line moving it.
  if grep -E '^\s*scp ' "$DOCS/$f" | grep -q '\.install\.json'; then
    ok "$f copies the .install.json alongside the config"
  else
    bad "$f has an scp line that moves the config without its .install.json"
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
echo "=== 9b. the IPv6 claim is documented honestly in both languages ==="
# Both READMEs must say what IPv6 does NOT give you. A guide that only lists the
# upsells is how a reader ends up believing a server with two addresses fails
# over between them, which is the one thing this project does not do.
for f in README.md README.fa.md; do
  grep -qiE '^#+ *IPv6 *$' "$DOCS/$f" && ok "$f has an IPv6 section" \
                                    || bad "$f has no IPv6 section"
done
# The bare-literal form is the instruction that is easy to get wrong, and a
# bracketed address in sing-box's server field loads without ever connecting.
# A plain substring search cannot catch the mistake: "[2001:db8:122::10]"
# still contains "2001:db8:122::10", so the bracketed form would pass. Require
# the bare form and the absence of the bracketed one.
for f in README.md README.fa.md; do
  if grep -qF '2001:db8:122::10' "$DOCS/$f"; then
    ok "$f shows the bare literal form"
  else
    bad "$f does not show the bare literal form"
  fi
  # The bracketed form is allowed to appear ONLY as a worked counter-example,
  # on a line that also carries the bare form. A document that shows the bare
  # literal and then says "not this" is teaching the reader something; a
  # document that shows only the bracketed literal is teaching them a value that
  # loads and then never connects.
  bracketed_lines=$(grep -cF '[2001:db8:122::10]' "$DOCS/$f" || true)
  bare_lines=$(grep -cF '`2001:db8:122::10`' "$DOCS/$f" || true)
  if [[ "$bracketed_lines" -eq 0 ]]; then
    ok "$f does not show a bracketed address at all"
  elif [[ "$bare_lines" -ge "$bracketed_lines" ]]; then
    ok "$f shows the bracketed form only as a counter-example"
  else
    bad "$f shows a bracketed address without the bare form beside it"
  fi
done
# CI is what actually validates an IPv6 bundle; claiming it without wiring it is
# exactly the kind of promise this changelog entry is about not making.
WORKFLOW="$DOCS/.github/workflows/python-package.yml"
if [[ ! -f "$WORKFLOW" ]]; then
  bad "the CI workflow is missing, so nothing validates an IPv6 bundle"
else
  grep -qF -- '--family' "$WORKFLOW" \
    && ok "CI generates a bundle per address family" \
    || bad "CI does not generate an IPv6 bundle"
  # Anchored to a command line, not a bare mention. The name also appears in the
  # layout-existence list, so a search for it anywhere would still pass after the
  # step that actually runs the harness was deleted.
  grep -qE '^ +bash tests/mutation-ipv6\.sh$' "$WORKFLOW" \
    && ok "CI runs the IPv6 mutation harness" \
    || bad "CI does not run the IPv6 mutation harness"
  # pytest collects the suite by name, so the layout list is enough to prove the
  # file is present but not that anything executes it; the compile step names it.
  grep -qF 'tests/test_ipv6.py' "$WORKFLOW" \
    && ok "CI compiles the IPv6 suite" || bad "CI does not compile the IPv6 suite"
  # Both families must actually be built. A loop over "4 6" that quietly only
  # ever ran 4 would still contain the word "6" everywhere.
  grep -qE 'for family in 4 6' "$WORKFLOW" \
    && ok "CI iterates over both address families" \
    || bad "CI does not iterate over both address families"
fi
# The limitation has to survive in the changelog, not only in the README.
for f in CHANGELOG.md CHANGELOG.fa.md; do
  grep -qF 'test_ipv6.py' "$DOCS/$f" && ok "$f records the IPv6 suite" \
                                     || bad "$f does not record the IPv6 suite"
done

echo
echo "=== 10. no generated artifact can be committed by accident ==="
# The generator's default output names, taken from raahctl.py rather than from
# memory. A .gitignore rule written for a name the code never produces looks
# correct and catches nothing, which is worse than having no rule at all because
# it is reviewed and trusted.
leaked=""
for f in outside.json secrets.json client-linux.json iran-01.json \
         iran-01.install.json DEPLOY.txt \
         iran-01.json.with-ali iran-01.json.revoked \
         iran-01.json.enforced iran-01.json.users.json; do
  git -C "$ROOT" check-ignore -q -- "$f" || leaked="$leaked $f"
done
if [[ -z "$leaked" ]]; then
  ok "every generated bundle artifact is ignored"
else
  bad "these generated files are NOT ignored:$leaked"
fi
# The default folder itself, which is where the real secrets land.
git -C "$ROOT" check-ignore -q -- raah-private-bundle/outside.json \
  && ok "the default bundle folder is ignored" \
  || bad "raah-private-bundle/ is not ignored"
# A pattern written for generated output must not sweep up the source. Without
# this, a fix for one leak can silently untrack the tool that generates them.
if git -C "$ROOT" ls-files --error-unmatch raahctl.py >/dev/null 2>&1; then
  ok "a .gitignore pattern is not broad enough to untrack raahctl.py"
else
  bad "raahctl.py is no longer tracked; a .gitignore pattern is too broad"
fi

echo
echo "=================================================="
printf '  %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
