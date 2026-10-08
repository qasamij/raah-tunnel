#!/usr/bin/env bash
# install-unit.sh replaces /etc/raah/config.json and then rewrites the unit
# files, and only afterwards enables and restarts raah-port-hop. It runs under
# `set -e` as a plain command (`bash install-unit.sh <config>`), so an unguarded
# failure there truncates the script: the new config is on disk, the service is
# still running the old one, `--start` never happens, and none of the closing
# instructions are printed.
#
# These assertions read the source rather than running it. A behavioural version
# was written and did work when run directly, but it needed a sandbox that
# rewrites /etc, /run/lock and the root check, and that sandbox proved fragile
# across environments. A source assertion cannot rot that way, and it fails for
# the same reason the behaviour would.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/install-unit.sh"

pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }

echo
echo "=== 1. the port-hopping unit is not touched before the config is in place ==="
swap_line=$(grep -n 'mv -f "\$staged" /etc/raah/config.json' "$SCRIPT" | head -1 | cut -d: -f1)
hop_line=$(grep -n 'systemctl restart raah-port-hop' "$SCRIPT" | head -1 | cut -d: -f1)
if [[ -n "$swap_line" && -n "$hop_line" && "$hop_line" -gt "$swap_line" ]]; then
  ok "the restart (line $hop_line) happens after the config swap (line $swap_line)"
else
  bad "cannot establish the order: swap=$swap_line restart=$hop_line"
fi

echo
echo "=== 2. neither enable nor restart of the port-hop unit can abort the script ==="
# Both are the last thing before the closing instructions, so both have to be
# inside a conditional.
if grep -qE '^\s*if ! systemctl enable raah-port-hop\.service; then' "$SCRIPT"; then
  ok "the enable is guarded by 'if !'"
else
  bad "the enable is unguarded; a failure here truncates the install"
fi
if grep -qE '^\s*(el)?if ! systemctl restart raah-port-hop\.service; then' "$SCRIPT"; then
  ok "the restart is guarded by 'if !'"
else
  bad "the restart is unguarded; a failure here truncates the install"
fi

echo
echo "=== 3. when the hopping table cannot be applied, the reader is told ==="
if grep -q 'WARNING.*port-hopping' "$SCRIPT"; then
  ok "a failed port-hop prints a WARNING"
else
  bad "a failed port-hop is silent, so the reader thinks hopping works"
fi
if grep -q 'systemctl enable --now raah-port-hop' "$SCRIPT"; then
  ok "the warning says how to finish the job later"
else
  bad "the warning does not tell the reader how to recover"
fi

echo
echo "=== 4. the closing instructions come after all of that ==="
done_line=$(grep -n 'Raah config validated and installed' "$SCRIPT" | head -1 | cut -d: -f1)
if [[ -n "$done_line" && "$done_line" -gt "$hop_line" ]]; then
  ok "the closing instructions (line $done_line) are still reachable"
else
  bad "the closing instructions are not after the port-hop step"
fi

echo
echo "=== 5. a missing .install.json is reported loudly, on stderr ==="
# Without it, install-unit.sh writes enabled:false and still exits 0, so the
# reader gets a running service whose hopping range is never redirected.
if grep -q 'WARNING: no .* was found next to this config' "$SCRIPT"; then
  ok "the missing metadata is a WARNING"
else
  bad "the missing metadata is not reported"
fi
if grep -q '>&2' "$SCRIPT" && grep -q 'port hopping is now DISABLED' "$SCRIPT"; then
  ok "the warning says hopping is off and goes to stderr"
else
  bad "the warning does not state the consequence on stderr"
fi

echo
echo "=== 6. the unit file is written with the real path, not a literal ==="
# This is the trap in the opposite direction. The heredoc has to stay unquoted
# so $sing_box expands, and a reader who "tidies up" the delimiter writes the
# literal text "$sing_box" into ExecStart. The service then fails to start with
# a bare "No such file or directory" and nothing points at the cause.
if grep -qE "cat >/etc/systemd/system/raah-sing-box\.service <<'?UNIT'?" "$SCRIPT" \
   && grep -qE '^ExecStart="?\$sing_box"?' "$SCRIPT"; then
  if grep -qE '^ExecStart="\$sing_box" ' "$SCRIPT"; then
    ok "ExecStart expands the path and quotes it for systemd"
  else
    bad "ExecStart expands the path but is unquoted, so a space in it would split the command"
  fi
else
  bad "the sing-box unit no longer wires in \$sing_box; check the heredoc delimiter"
fi
if grep -qE "^ExecStart='\\\$sing_box" "$SCRIPT"; then
  bad "the heredoc is single-quoted, so the unit would contain a literal \$sing_box"
else
  ok "the heredoc is not single-quoted, so the path really is substituted"
fi

echo
echo "=== 7. nothing reads a shifted argument after the argument loop ==="
# The loop at the top shifts every argument away, so $1 is gone by the time the
# .install.json lookup runs. The old `meta_source="${1%.json}..."` therefore
# aborted the whole install under `set -u` with "line 79: 1: unbound variable":
# no config written, no unit written, no closing instructions. source-style
# assertions miss that only if they do not look, so this one does.
if grep -qF 'meta_source="${config_path%.json}.install.json"' "$SCRIPT"; then
  ok "the metadata path is derived from \$config_path"
else
  bad "the metadata path is not derived from \$config_path"
fi
# Between the end of the loop and the first helper function, no code may touch
# $1 or ${1}. Comments are skipped so the prose above can explain the trap.
stray=$(awk '
  /^done$/ && !seen { inmain = 1; seen = 1 }
  /^role_of_config\(\) \{/ { exit }
  inmain && !/^[[:space:]]*#/ && /(\$1|\$\{1)/ { print NR ": " $0 }
  END { if (!seen) print "PARSE_LOOP_NOT_FOUND" }' "$SCRIPT")
if [[ -z "$stray" ]]; then
  ok "no positional parameter is read after the parse loop"
elif [[ "$stray" == PARSE_LOOP_NOT_FOUND ]]; then
  bad "cannot find the end of the argument parse loop"
else
  bad "a shifted argument is still read: $stray"
fi

echo
echo "=================================================="
printf '  %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
