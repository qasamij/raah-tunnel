#!/usr/bin/env bash
# Put each bug back and confirm the suite objects. A test that cannot fail when
# the code is broken is decoration, so every guard this project relies on gets
# removed here at least once.
#
# The backup lives outside the repo and the EXIT trap always puts it back.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

installer=one-click-install.sh
backup=$(mktemp)
cp "$installer" "$backup"

restore() {
  cp "$backup" "$installer"
  if cmp -s "$backup" "$installer"; then
    printf '      [restored, %s bytes, byte-identical]\n' "$(wc -c <"$installer" | tr -d ' ')"
  else
    printf '      [RESTORE FAILED - the working file is still mutated]\n'
    exit 2
  fi
}
trap 'restore; rm -f "$backup"' EXIT

fails=0
slipped=0

# mutate <label> <perl expression> <regex that must be present, then gone>
mutate() {
  local label="$1" expr="$2" gone="$3"
  printf '\n=== %s ===\n' "$label"
  # Check the target exists BEFORE mutating. Without this, a pattern the source
  # has since outgrown makes the substitution a silent no-op, the suite stays
  # green, and the mutation is reported as "not detected" -- which reads like a
  # coverage gap but is really a test that stopped testing anything.
  if ! grep -qE "$gone" "$installer"; then
    printf '  the target is no longer in the source; this mutation is stale.\n'
    slipped=$((slipped+1))
    restore
    return
  fi
  perl -0pi -e "$expr" "$installer"
  if grep -qE "$gone" "$installer"; then
    printf '  mutation did not apply; the source has moved on. Update this test.\n'
    slipped=$((slipped+1))
    restore
    return
  fi
  local out
  out=$(bash tests/test-menu.sh 2>&1)
  grep -E '^  FAIL' <<<"$out" | head -4 | sed 's/^/  /'
  local count
  count=$(grep -oE '[0-9]+ passed, [0-9]+ failed' <<<"$out" | tail -1)
  printf '      %s\n' "$count"
  if [[ "$count" == *"0 failed"* ]]; then
    printf '  NOT DETECTED <-- this test is decorative\n'
    fails=$((fails+1))
  fi
  restore
}

# The probe. Under `set -Eeuo pipefail` an unguarded non-zero here ends the
# session, and the probe's whole purpose is to be run when the tunnel is down.
mutate "A. the e2e probe loses its handler" \
  's/            python3 "\$RAAHCTL" e2e-probe "\$client_file" --count 3 \\\n              \|\| warn [^\n]*\n/            python3 "\$RAAHCTL" e2e-probe "\$client_file" --count 3\n/' \
  'e2e-probe .*--count 3 \\'

# The bundle editor. Same reasoning: the user is told to use it, and it refuses
# for ordinary reasons.
mutate "B. edit-bundle loses its handler" \
  's/            python3 "\$RAAHCTL" edit-bundle "\$bundle_path" <"\$TTY_IN" \\\n              \|\| printf [^\n]*\n/            python3 "\$RAAHCTL" edit-bundle "\$bundle_path" <"\$TTY_IN"\n/' \
  'edit-bundle .*\\'

# A GitHub outage must not read as "no releases" and must not kill the loop.
# The same call also appears in update(), indented by two spaces; target the
# eight-space copy inside menu() so the mutation lands where it is meant to.
mutate "C. the update arm stops tolerating an unreachable GitHub" \
  's/        newest="\$\(latest_release_ref \|\| true\)"/        newest="\$(latest_release_ref)"/' \
  '^        newest="\$\(latest_release_ref \|\| true\)"$'

# The restart after a fresh config install.
mutate "D. a failed raah-sing-box restart stops being reported" \
  's/  if ! systemctl restart raah-sing-box; then\n/  systemctl restart raah-sing-box || true\n  if false; then\n/' \
  'if ! systemctl restart raah-sing-box; then'

# The guard is only load-bearing while errexit is on. If this one turns the
# whole question off, every other guard above is decoration.
mutate "E. errexit is turned off, making the other guards meaningless" \
  's/^set -Eeuo pipefail$/set -uo pipefail/m' \
  '^set -Eeuo pipefail$'

printf '\n==================================================\n'
if [[ $fails -eq 0 && $slipped -eq 0 ]]; then
  printf '  every planted bug was caught\n'
else
  printf '  %d slipped through, %d mutation(s) no longer applied\n' "$fails" "$slipped"
fi
[[ $fails -eq 0 && $slipped -eq 0 ]]
