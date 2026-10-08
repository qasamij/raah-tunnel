#!/usr/bin/env bash
# Put each bug back in deploy_peer and confirm tests/test-deploy-peer.sh objects.
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

mutate() { # <label> <perl expr> <regex that must be present, then gone>
  local label="$1" expr="$2" gone="$3"
  printf '\n=== %s ===\n' "$label"
  # Check the target exists BEFORE mutating. Without this, a pattern the source
  # has since outgrown makes the substitution a silent no-op, the suite stays
  # green, and the mutation is reported as "not detected" -- which reads like a
  # coverage gap but is really a test that stopped testing anything.
  if ! grep -qE -- "$gone" "$installer"; then
    printf '  the target is no longer in the source; this mutation is stale.\n'
    slipped=$((slipped+1)); restore; return
  fi
  # /m matters: perl runs with -0, so without it ^ and $ anchor to the whole
  # file rather than to a line and the substitution silently does nothing.
  perl -0pi -e "$expr" "$installer"
  # -- matters because several of the patterns below start with a dash.
  if grep -qE -- "$gone" "$installer"; then
    printf '  mutation did not apply; the source has moved on. Update this test.\n'
    slipped=$((slipped+1)); restore; return
  fi
  local out count
  out=$(bash tests/test-deploy-peer.sh 2>&1)
  grep -E '^  FAIL' <<<"$out" | head -3 | sed 's/^/  /'
  count=$(grep -oE '[0-9]+ passed, [0-9]+ failed' <<<"$out" | tail -1)
  printf '      %s\n' "$count"
  if [[ "$count" == *"0 failed"* ]]; then
    printf '  NOT DETECTED <-- this test is decorative\n'
    fails=$((fails+1))
  fi
  restore
}

# The bug this project already shipped once: sending the .json without its
# .install.json leaves the far side running with hopping silently disabled. The
# file list is conditional now, so the mutation drops the line that adds the
# metadata -- which is the same regression, expressed the way the source reads.
mutate "A. the .install.json is left behind" \
  's/  if \[\[ -f "\$peer_meta" \]\]; then\n    send_files\+=\("\$peer_meta"\)\n  fi\n//' \
  'send_files\+=\("\$peer_meta"\)'

# Without BatchMode an unreachable or untrusted host drops into an interactive
# password prompt and the installer sits there forever.
mutate "B. ssh may stop to ask for a password" \
  's/^PEER_SSH_OPTS=\(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new\)$/PEER_SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)/m' \
  '^PEER_SSH_OPTS=\(-o BatchMode=yes'

# A config path with a space in it would arrive as two arguments.
mutate "C. the far-side config path is no longer quoted" \
  "s/\"sudo bash \/tmp\/raah-install\.sh --config '\\\$dest\/\\\$peer_cfg' --start\"/\"sudo bash \/tmp\/raah-install.sh --config \\\$dest\/\\\$peer_cfg --start\"/" \
  "--config '\\\$dest/\\\$peer_cfg'"

# Sending the IRAN half to the outside address, or the other way round, is the
# failure mode that is hardest to notice from the terminal. The peer address is
# read out of secrets.json, keyed by which half this box is, so the mutation
# pins the wrong key: every run would then offer the Outside address, even on
# the box that is supposed to be the Outside server. The check is for the text
# that disappears, not the one the mutation introduces.
mutate "D. the peer address comes from the wrong half of secrets.json" \
  's/    peer_default=\$\(python3 - "\$bundle\/secrets\.json" "\$peer_role"/    peer_default=\$(python3 - "\$bundle\/secrets.json" "outside"/' \
  'python3 - "\$bundle/secrets\.json" "\$peer_role"'

# Copying without asking first is the one that cannot be undone.
mutate "E. the transfer happens without a confirmation" \
  "s/  printf '  Continue\? \[y\/N\] '\n  read -r answer \|\| return 0\n  case \"\\\$answer\" in\n    y\|Y\|yes\|Yes\) ;;\n    \*\) printf '  Nothing was sent\.\\\\n'; return 0 ;;\n  esac\n//" \
  "Continue\? \[y/N\]"

# The certificate cannot be shipped, so the only useful thing is to say it is
# missing before the copy starts.
mutate "F. a missing far-side certificate is no longer mentioned" \
  "s/    warn \"Hysteria 2 will not start on \\\$ip until \/etc\/raah\/tls\/fullchain\.pem and\"\n    warn \"\/etc\/raah\/tls\/privkey\.pem are in place there\. The copy below still runs,\"\n    warn 'but the install on that side will stop at that check\.'\n//" \
  'will not start on \$ip until /etc/raah/tls/fullchain.pem'

printf '\n==================================================\n'
if [[ $fails -eq 0 && $slipped -eq 0 ]]; then
  printf '  every planted bug was caught\n'
else
  printf '  %d slipped through, %d mutation(s) no longer applied\n' "$fails" "$slipped"
fi
[[ $fails -eq 0 && $slipped -eq 0 ]]
