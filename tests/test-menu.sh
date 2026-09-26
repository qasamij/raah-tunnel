#!/usr/bin/env bash
# Prove the role-based menu, especially the one thing that can silently break a
# pair: minting a second bundle on the second server.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/one-click-install.sh"
BUNDLE="/root/raah-private-bundle"
CNT="/tmp/raah-generate-calls"

pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }

LAST=$(grep -n '^menu() {' "$INSTALLER" | cut -d: -f1)
FN_END=$(awk -v s="$LAST" 'NR>=s && /^}$/ { print NR; exit }' "$INSTALLER")
# shellcheck disable=SC1090
source <(sed -n "1,${FN_END}p" "$INSTALLER")
trap - EXIT
set +e

calls() { local n; n=$(grep -c . "$CNT" 2>/dev/null) || n=0; printf '%s' "$n"; }

# run_setup <role> <typed-answer>
# Runs setup_role with the network, systemd and /root all stubbed, and echoes
# everything the user would have seen. The generate counter lives in a file
# because the pipeline puts setup_role in a subshell.
run_setup() {
  local role="$1" answer="$2" out
  : > "$CNT"
  rm -rf "$BUNDLE"
  python3() {
    echo x >> "$CNT"
    mkdir -p "$BUNDLE"
    printf '{}' > "$BUNDLE/outside.json"
    printf '{}' > "$BUNDLE/iran-01.json"
    printf '{}' > "$BUNDLE/client-linux.json"
    printf 'ports' > "$BUNDLE/DEPLOY.txt"
    return 0
  }
  bash() { return 0; }
  systemctl() { return 0; }
  prepare_environment() {
    RAAHCTL=/opt/raah-tunnel/raahctl.py
    UNIT_SCRIPT=/opt/raah-tunnel/scripts/install-unit.sh
    return 0
  }
  out=$(printf '%s\n' "$answer" | setup_role "$role" 2>&1)
  printf '%s' "$out"
  return 0
}

# with_bundle sets up a pre-existing bundle, as on a server that already has one.
with_bundle() {
  mkdir -p "$BUNDLE"
  printf '{}' > "$BUNDLE/outside.json"
  printf '{}' > "$BUNDLE/iran-01.json"
}

echo "=== 1. role_config maps each role to the right half ==="
for pair in "iran:iran-01.json" "outside:outside.json"; do
  role="${pair%%:*}"; want="${pair#*:}"; got="$(role_config "$role" 2>/dev/null)"
  [[ "$got" == "$want" ]] && ok "$role -> $got" || bad "$role -> got '$got' want '$want'"
done

echo
echo "=== 2. menu is reorganised around the role of THIS server ==="
menu_body=$(sed -n '/^menu() {/,/^}/p' "$INSTALLER")
for want in "1) IRAN server" "2) OUTSIDE server" "Select [0-9, h]"; do
  grep -qF -- "$want" <<<"$menu_body" && ok "menu contains: $want" || bad "menu missing: $want"
done
grep -qF "Generate direct tunnel" <<<"$menu_body" \
  && bad "old confusing wording still present" \
  || ok "old 'Generate direct tunnel' wording removed"

echo
echo "=== 3. no bundle: must ASK before minting keys ==="
out=$(run_setup outside "")
[[ "$(calls)" -eq 0 ]] && ok "declining generated nothing" || bad "generated without confirmation"
grep -q "Type 'generate' to create a new bundle here" <<<"$out" \
  && ok "asked for confirmation" || bad "did not ask"
grep -q "share the" <<<"$out" && ok "explains why keys are shared" || bad "no explanation of pairing"

echo
echo "=== 4. no bundle + 'generate' as OUTSIDE ==="
out=$(run_setup outside "generate")
[[ "$(calls)" -eq 1 ]] && ok "generated exactly one bundle" || bad "generate ran $(calls) times"
grep -q "It will install:  outside.json" <<<"$out" && ok "targets outside.json" || bad "wrong config"
grep -q "this whole folder to the IRAN server" <<<"$out" && ok "guides the IRAN side" || bad "no IRAN guidance"
grep -q "client-linux.json" <<<"$out" && ok "reminds about the client file" || bad "no client reminder"
grep -q "DEPLOY.txt" <<<"$out" && ok "points at DEPLOY.txt for ports" || bad "no port pointer"
grep -q "Never put the contents of" <<<"$out" && ok "secrecy warning present" || bad "no secrecy warning"
grep -q "will act as the outside server" <<<"$out" && ok "states the chosen role" || bad "role not stated"

echo
echo "=== 5. no bundle + 'generate' as IRAN ==="
out=$(run_setup iran "generate")
[[ "$(calls)" -eq 1 ]] && ok "generated exactly one bundle" || bad "generate ran $(calls) times"
grep -q "It will install:  iran-01.json" <<<"$out" && ok "targets iran-01.json" || bad "wrong config"
grep -q "this whole folder to the OUTSIDE server" <<<"$out" && ok "guides the OUTSIDE side" || bad "no OUTSIDE guidance"
grep -q "copy the whole folder to the OUTSIDE" <<<"$out" && ok "says to copy the bundle over" || bad "no copy instruction"

echo
echo "=== 6. THE KEY CASE: bundle already exists, must NOT mint new keys ==="
: > "$CNT"; with_bundle
out=$(printf 'generate\n' | setup_role outside 2>&1)
if [[ "$(calls)" -eq 0 ]]; then
  ok "reused the existing bundle, minted nothing"
else
  bad "MINTED A SECOND BUNDLE - the two servers would get different keys"
fi
if grep -qE "keys will be reused|keys are shared" <<<"$out"; then
  ok "explains that existing keys are reused"
else
  bad "did not explain the reuse"
fi

echo
echo "=== 7. every successful run warns about ports and secrecy ==="
for role in iran outside; do
  out=$(run_setup "$role" "generate")
  grep -q "Never put the contents of" <<<"$out" && ok "$role: secrecy warning" || bad "$role: no secrecy warning"
  grep -q "DEPLOY.txt" <<<"$out" && ok "$role: port pointer" || bad "$role: no port pointer"
  grep -q "tls" <<<"$out" && ok "$role: mentions the TLS step" || bad "$role: no TLS reminder"
done

echo
echo "=== 8. build_bundle only offers topologies the role setup omits ==="
bb=$(sed -n '/^build_bundle() {/,/^}/p' "$INSTALLER")
grep -qF "2) Reverse" <<<"$bb" && ok "offers reverse" || bad "no reverse"
grep -qF "3) Both" <<<"$bb" && ok "offers both" || bad "no both"
grep -qF "1) Direct" <<<"$bb" && bad "direct is offered twice" || ok "direct is not duplicated"

echo
echo "=== 9. TTY_IN falls back when there is no controlling terminal ==="
grep -q 'TTY_IN=/dev/stdin' "$INSTALLER" && ok "fallback defined" || bad "no stdin fallback"

echo
echo "=== 10. setup_role must not drop the flags the user passed ==="
# A user who ran "raah-install.sh --menu --no-discovery" asked for something.
# If the role path rebuilds the generate command from scratch it silently
# ignores that, which is the kind of bug that only shows up weeks later.
for pair in "AUTO_SNI:1:--auto-sni" "NO_DISCOVERY:1:--no-discovery"; do
  var="${pair%%:*}"; rest="${pair#*:}"; val="${rest%%:*}"; flag="${rest#*:}"
  if grep -A2 "gen_args=(" <<<"$(sed -n '/^setup_role() {/,/^}$/p' "$INSTALLER")" \
       | grep -q -- "$flag" \
     || sed -n '/^setup_role() {/,/^}$/p' "$INSTALLER" | grep -q "gen_args+=($flag)"; then
    ok "role setup forwards $flag"
  else
    bad "role setup DROPS $flag"
  fi
done
sed -n '/^setup_role() {/,/^}$/p' "$INSTALLER" | grep -q 'gen_args+=("$HOP_ARG")' \
  && ok "role setup forwards \$HOP_ARG" || bad "role setup DROPS \$HOP_ARG"

echo
echo "=== 11. the guidance must name the OTHER server's config ==="
# Getting this wrong tells the user to install their own half twice and leaves
# the second server unconfigured with no obvious error.
out=$(run_setup iran "generate")
grep -q -- "--config /root/outside.json" <<<"$out" \
  && ok "IRAN setup points at outside.json" || bad "IRAN setup does NOT point at outside.json"
# A path with an empty filename is the signature of the uppercase/lowercase
# role mix-up, and it renders as a command the user would paste and fail on.
grep -qE -- "--config /root/ *--start" <<<"$out" \
  && bad "IRAN setup prints an EMPTY config filename" || ok "IRAN setup has no empty filename"
grep -q -- "--config /root/iran-01.json --start" <<<"$out" \
  && bad "IRAN setup tells the user to install its own half again" \
  || ok "IRAN setup never tells the user to reinstall iran-01.json"

out=$(run_setup outside "generate")
grep -q -- "--config /root/iran-01.json" <<<"$out" \
  && ok "OUTSIDE setup points at iran-01.json" || bad "OUTSIDE setup does NOT point at iran-01.json"
grep -qE -- "--config /root/ *--start" <<<"$out" \
  && bad "OUTSIDE setup prints an EMPTY config filename" || ok "OUTSIDE setup has no empty filename"

echo
echo "=== 12. a half-present bundle must NOT be overwritten ==="
# If only one half arrived (a partial scp, a botched cleanup), regenerating
# would mint fresh keys and the surviving half would silently stop matching.
: > "$CNT"; rm -rf "$BUNDLE"; mkdir -p "$BUNDLE"; printf '{}' > "$BUNDLE/iran-01.json"
out=$(printf 'generate\n' | setup_role outside 2>&1)
if [[ "$(calls)" -eq 0 ]]; then
  ok "did not regenerate over a partial bundle"
else
  bad "REGENERATED over a partial bundle - the keys would no longer match"
fi
grep -qi "restore the whole folder" <<<"$out" && ok "tells the user to restore instead" || bad "no recovery advice"

echo
echo "=== 13. FIRST RUN without TLS must not kill the installer ==="
# install-unit.sh exits non-zero when the cert is missing, which on a fresh
# server is always. Dying there strands the user before the one instruction
# they actually need, so the role path has to hand control back instead.
# shellcheck disable=SC2317
setup_first_run() {
  local role="$1" out
  : > "$CNT"; rm -rf "$BUNDLE"
  python3() { echo x >> "$CNT"; mkdir -p "$BUNDLE"
    printf '{}' > "$BUNDLE/outside.json"; printf '{}' > "$BUNDLE/iran-01.json"
    printf 'ports' > "$BUNDLE/DEPLOY.txt"; return 0; }
  bash() { echo "Missing TLS files on THIS server." >&2; return 1; }   # as install-unit.sh does
  systemctl() { return 0; }
  prepare_environment() { RAAHCTL=/opt/x/raahctl.py; UNIT_SCRIPT=/opt/x/install.sh; return 0; }
  out=$(printf 'generate\n' | setup_role "$role" 2>&1)
  printf '%s' "$?" > "$CNT.rc"
  printf '%s' "$out"
  return 0
}
out=$(setup_first_run iran); rc=$(cat "$CNT.rc")
[[ "$rc" -eq 0 ]] && ok "role setup returns instead of exiting ($rc)" \
                  || bad "role setup exited with $rc on a normal first run"
grep -q "Nothing was installed" <<<"$out" && ok "says nothing was changed" || bad "no 'nothing changed' reassurance"
grep -q "choose this same" <<<"$out" && ok "tells the user what to do next" || bad "no next step"
grep -q "/etc/raah/tls/" <<<"$out" && ok "names the TLS directory" || bad "does not name the TLS directory"
grep -q "Never put" <<<"$out" && ok "still warns about the bundle" || bad "lost the secrecy warning"
# The old wording claimed the server was already set up, which is false here.
grep -q "This server is set up as" <<<"$out" \
  && bad "claims the server is set up when the install failed" \
  || ok "does not falsely claim success"

echo
echo "=== 14. a failed restart must not abort the installer ==="
# set -e is on. A bare failing systemctl would take the whole script down
# before the remaining-steps list is printed.
# shellcheck disable=SC2317
setup_bad_restart() {
  local role="$1" out
  : > "$CNT"; rm -rf "$BUNDLE"
  python3() { echo x >> "$CNT"; mkdir -p "$BUNDLE"
    printf '{}' > "$BUNDLE/outside.json"; printf '{}' > "$BUNDLE/iran-01.json"
    printf 'ports' > "$BUNDLE/DEPLOY.txt"; return 0; }
  bash() { return 0; }                      # install succeeds this time
  systemctl() { return 1; }                # but the service refuses to start
  prepare_environment() { RAAHCTL=/opt/x/raahctl.py; UNIT_SCRIPT=/opt/x/install.sh; return 0; }
  out=$(printf 'generate\n' | setup_role "$role" 2>&1)
  printf '%s' "$?" > "$CNT.rc"
  printf '%s' "$out"
  return 0
}
out=$(setup_bad_restart iran); rc=$(cat "$CNT.rc")
[[ "$rc" -eq 0 ]] && ok "survives a failed restart ($rc)" \
                  || bad "aborted on a failed restart (exit $rc)"
grep -q "did not start" <<<"$out" && ok "explains the service did not start" || bad "no explanation"
grep -q "Remaining work" <<<"$out" && ok "still prints the remaining steps" || bad "lost the remaining steps"

rm -rf "$BUNDLE"
echo
echo "=================================================="
printf '  %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
