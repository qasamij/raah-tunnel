#!/usr/bin/env bash
# Mutation-test the role/half checks added to the menu and the installer.
#
# A warning nobody sees is the same as no warning, so each of these mutations
# removes one protection and the suite has to notice. The installer is restored
# byte-for-byte afterwards, and a restore mismatch is itself a failure: a test
# run that leaves the tree modified is worse than no test.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/one-click-install.sh"
UNIT="$ROOT/scripts/install-unit.sh"
SUITE="$ROOT/tests/test-menu.sh"
BAK=$(mktemp -d)
cp "$INSTALLER" "$BAK/installer.orig"
cp "$UNIT" "$BAK/unit.orig"

pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }

restore() {
  cp "$BAK/installer.orig" "$INSTALLER"; cp "$BAK/unit.orig" "$UNIT"
}
trap 'restore; rm -rf "$BAK"' EXIT

run_suite() {
  local out
  out=$(bash "$SUITE" 2>&1)
  grep -Eo '[0-9]+ passed, [0-9]+ failed' <<<"$out" | tail -1
}

# survive <label> <file> <sed-expr> <regex present before> <text present after>
#
# Both patterns are checked, and that is the point. Checking only the result is
# how a stale mutation hides: the substitution silently does nothing, the suite
# stays green, and the run reports "not detected" -- which reads like a coverage
# gap when the truth is that the test stopped testing anything. Requiring the
# "before" pattern to exist turns that into an honest "this is stale".
survive() {
  local label="$1" file="$2" expr="$3" from="$4" to="$5" after
  if ! grep -qE -- "$from" "$file"; then
    restore
    bad "$label: the target is no longer in the source; this mutation is stale"
    return
  fi
  sed -i "$expr" "$file"
  if ! grep -qF -- "$to" "$file"; then
    restore
    bad "$label: mutation did not apply (the mutated text is absent)"
    return
  fi
  after=$(run_suite)
  local base_passed now_passed
  base_passed=$(sed -E 's/^([0-9]+) passed.*/\1/' <<<"$BASELINE")
  now_passed=$(sed -E 's/^([0-9]+) passed.*/\1/' <<<"${after:-0 passed, 9 failed}")
  if [[ "$after" == "$BASELINE" ]]; then
    bad "$label: SURVIVED - the suite reported the same result as the baseline"
  elif [[ "$now_passed" -gt "$base_passed" ]]; then
    bad "$label: the suite got BETTER ($now_passed > $base_passed); not a real regression"
  else
    ok "$label: caught ($BASELINE -> $after)"
  fi
  restore
}

BASELINE=$(run_suite)
printf '  baseline (unmutated): %s\n\n' "$BASELINE"

echo "=== A. option 3 stops asking which half belongs here ==="
survive "A: ask-which-half removed" "$INSTALLER" \
  's/Which half of the bundle belongs on THIS server?/Which file?/' \
  'Which half of the bundle belongs on THIS server' 'Which file?'

echo "=== B. the backwards entry/exit wording comes back ==="
survive "B: wrong labels restored" "$INSTALLER" \
  's/1) Iran server     ->  iran-01.json   (this box dials the Outside peer)/1) IRAN entry    ->  iran-01.json/' \
  'Iran server     ->  iran-01\.json' 'IRAN entry'

echo "=== C. option 3 stops declaring the chosen role ==="
survive "C: --role dropped from option 3" "$INSTALLER" \
  's/"\$node_file" --role "\$node_role"/"$node_file"/' \
  '\$node_file" --role "\$node_role"' '"$node_file"'

echo "=== D. setup_role stops declaring the role ==="
survive "D: --role dropped from setup_role" "$INSTALLER" \
  's/"\$cfg" --role "\$role"/"$cfg"/' \
  '\$cfg" --role "\$role"' '"$cfg"'

echo "=== E. the mismatch warning is dropped ==="
survive "E: mismatch warning removed" "$UNIT" \
  's/WARNING: this machine was declared the /NOTE: this machine was declared the /' \
  'WARNING: this machine was declared the' 'NOTE: this machine was declared the'

echo "=== F. the client-profile warning is dropped ==="
survive "F: client warning removed" "$UNIT" \
  's/WARNING: %s looks like a CLIENT profile, not a server config./NOTE: %s looks like a client profile./' \
  'looks like a CLIENT profile' 'looks like a client profile'

echo "=== G. a role mismatch starts BLOCKING instead of warning ==="
# The dangerous direction: refusing to install strands a server that was re-homed
# on purpose. The suite scans the mismatch branch for exit/die, so inserting one
# has to be caught.
survive "G: mismatch turned into a hard exit" "$UNIT" \
  '/^elif \[\[ -n "\$declared_role"/a\  die "this box is the $actual_role server, not $declared_role"' \
  '^elif \[\[ -n "\$declared_role"' 'die "this box is the'

echo "=== H. the structural classifier stops being used ==="
# Reverting to a guess is exactly the bug this replaced: a renamed or hand-copied
# file would be misclassified, and the suite pins the call site, not just the
# definition, so leaving the function unused is caught too.
survive "H: classifier replaced by a constant" "$UNIT" \
  's|^actual_role=.*|actual_role="unknown"|' \
  '^actual_role="\$\(role_of_config ' 'actual_role="unknown"'

echo "=== I. the tun-inbound rule is removed ==="
# Without this, a client profile reads as a server half and gets installed as a
# listening service.
survive "I: tun-inbound rule removed" "$UNIT" \
  's/== "tun" for item in inbounds/== "never" for item in inbounds/' \
  '== "tun" for item in inbounds' '== "never" for item in inbounds'

echo "=== J. direct/block/dns start counting as peer outbounds ==="
# The Outside half has outbounds, but only direct/block/dns. If those counted,
# every Outside config would read as the Iran half and warn on every install.
survive "J: direct/block/dns no longer excluded" "$UNIT" \
  's/{"direct", "block", "dns"}/{}/' \
  '"direct", "block", "dns"' '(o.get("type") or "") not in {}'

echo "=== K. an unreadable config starts printing an empty half-name ==="
# role_of_config signals "cannot read this" with an empty string. Comparing it to
# the word "unknown" is true, so the advice line would print "the  half of the
# bundle" with the name missing. The suite pins the -n test.
survive "K: empty role no longer excluded" "$UNIT" \
  's/&& -n "\$actual_role"/\&\& "\$actual_role" != unknown/' \
  '&& -n "\$actual_role"' '&& "$actual_role" != unknown'

echo
if cmp -s "$INSTALLER" "$BAK/installer.orig" && cmp -s "$UNIT" "$BAK/unit.orig"; then
  ok "both source files were restored byte-for-byte"
else
  bad "a source file was left modified after mutation testing"
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
