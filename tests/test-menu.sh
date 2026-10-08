#!/usr/bin/env bash
# Prove the role-based menu, especially the one thing that can silently break a
# pair: minting a second bundle on the second server.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/one-click-install.sh"

# The product defaults the bundle to /root/raah-private-bundle, but a CI runner
# is not root, so writing there fails and the whole suite errors out for a
# reason that has nothing to do with the code under test. Point it at a temp
# directory instead. setup_role reads BUNDLE_DIR, which the sourced installer
# derives from RAAH_BUNDLE, so this must be exported before the source below.
RAAH_BUNDLE="${RAAH_BUNDLE:-${TMPDIR:-/tmp}/raah-test-bundle}"
export RAAH_BUNDLE
BUNDLE="$RAAH_BUNDLE"
mkdir -p "$BUNDLE" 2>/dev/null || { echo "cannot create $BUNDLE"; exit 1; }
[[ -w "$BUNDLE" ]] || { echo "$BUNDLE is not writable; set TMPDIR"; exit 1; }
CNT="${TMPDIR:-/tmp}/raah-generate-calls"

pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }

LAST=$(grep -n '^menu() {' "$INSTALLER" | cut -d: -f1)
FN_END=$(awk -v s="$LAST" 'NR>=s && /^}$/ { print NR; exit }' "$INSTALLER")
UNIT="$ROOT/scripts/install-unit.sh"
# shellcheck disable=SC1090
source <(sed -n "1,${FN_END}p" "$INSTALLER")
# The sourced installer installs its own EXIT trap; clear it, then install ours
# so the counter files do not survive in TMPDIR.
trap - EXIT
trap 'rm -f "$CNT" "$CNT.rc"' EXIT
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
grep -q "Send the IRAN server its half" <<<"$out" && ok "guides the IRAN side" || bad "no IRAN guidance"
grep -q "client-linux.json" <<<"$out" && ok "reminds about the client file" || bad "no client reminder"
grep -q "DEPLOY.txt" <<<"$out" && ok "points at DEPLOY.txt for ports" || bad "no port pointer"
grep -q "Never put the contents of" <<<"$out" && ok "secrecy warning present" || bad "no secrecy warning"
grep -q "will act as the outside server" <<<"$out" && ok "states the chosen role" || bad "role not stated"

echo
echo "=== 5. no bundle + 'generate' as IRAN ==="
out=$(run_setup iran "generate")
[[ "$(calls)" -eq 1 ]] && ok "generated exactly one bundle" || bad "generate ran $(calls) times"
grep -q "It will install:  iran-01.json" <<<"$out" && ok "targets iran-01.json" || bad "wrong config"
grep -q "Send the OUTSIDE server its half" <<<"$out" && ok "guides the OUTSIDE side" || bad "no OUTSIDE guidance"
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
# the second server unconfigured with no obvious error. The manual fallback uses
# <DEST> because the destination is prompted for, so match the file name rather
# than a concrete directory.
out=$(run_setup iran "generate")
grep -q -- "--config <DEST>/outside.json" <<<"$out" \
  && ok "IRAN setup points at outside.json" || bad "IRAN setup does NOT point at outside.json"
# A path with an empty filename is the signature of the uppercase/lowercase
# role mix-up, and it renders as a command the user would paste and fail on.
grep -qE -- "--config +--start" <<<"$out" \
  && bad "IRAN setup prints an EMPTY config filename" || ok "IRAN setup has no empty filename"
grep -qE -- "--config <DEST>/iran-01\.json" <<<"$out" \
  && bad "IRAN setup tells the user to install its own half again" \
  || ok "IRAN setup never tells the user to reinstall iran-01.json"

out=$(run_setup outside "generate")
grep -q -- "--config <DEST>/iran-01.json" <<<"$out" \
  && ok "OUTSIDE setup points at iran-01.json" || bad "OUTSIDE setup does NOT point at iran-01.json"
grep -qE -- "--config +--start" <<<"$out" \
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
# The harness above runs with `set +e` because it has to source the installer
# and then replace python3/bash/systemctl. Testing errexit through that needs
# the subshell to turn it back on explicitly, otherwise a bare failing
# systemctl is silently ignored and this test passes with the guard removed.
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
  out=$(set -e; printf 'generate\n' | setup_role "$role" 2>&1) || out="$out"$'\n'"ABORTED:$?"
  printf '%s' "$?" > "$CNT.rc"
  printf '%s' "$out"
  return 0
}
out=$(setup_bad_restart iran); rc=$(cat "$CNT.rc")
# The remaining-steps list is the observable consequence: it is printed after
# the restart, so if errexit killed the function it can never appear.
if grep -q "ABORTED" <<<"$out"; then
  bad "set -e aborted the installer on a failed restart"
else
  ok "errexit is armed and the restart failure did not abort"
fi
grep -q "did not start" <<<"$out" && ok "explains the service did not start" || bad "no explanation"
grep -q "Remaining work" <<<"$out" && ok "still prints the remaining steps" || bad "lost the remaining steps"

# Guard against the exact regression: the `if !` around the restart is the only
# thing standing between a failed restart and a truncated install. Assert it
# directly so the behaviour above is not the only thing protecting this.
if grep -qE '^\s*if ! systemctl restart raah-sing-box; then' "$INSTALLER"; then
  ok "the restart is guarded by 'if !'"
else
  bad "the restart is not guarded; a failure here aborts the installer"
fi

echo
echo "=== 16. option 3 asks which half, and describes each file correctly ==="
# The old wording was backwards: iran-01.json runs on the Iran server and is that
# box's exit, while outside.json is the entry. Reading it the other way round
# puts both halves on one machine and leaves the other unconfigured.
mb=$menu_body
grep -q "Which half of the bundle belongs on THIS server" <<<"$mb" \
  && ok "asks which half belongs here" || bad "option 3 does not ask which half"
grep -q "1) Iran server     ->  iran-01.json" <<<"$mb" \
  && ok "iran-01.json is labelled the Iran server" || bad "iran-01.json is mislabelled"
grep -q "2) Outside server  ->  outside.json" <<<"$mb" \
  && ok "outside.json is labelled the Outside server" || bad "outside.json is mislabelled"
grep -qE 'entry\s*->\s*iran-01|exit\s*->\s*outside' <<<"$mb" \
  && bad "the backwards entry/exit wording is still present" \
  || ok "the backwards entry/exit wording is gone"
# The role the user picks is what gets declared, so a mismatch is detectable.
grep -q 'UNIT_SCRIPT" "$node_file" --role "$node_role"' <<<"$mb" \
  && ok "option 3 passes the chosen role" || bad "option 3 does not pass the role"
grep -q 'UNIT_SCRIPT" "$cfg" --role "$role"' "$INSTALLER" \
  && ok "setup_role passes the role it was given" || bad "setup_role does not pass the role"

echo
echo "=== 17. the installer must classify a config by its own structure ==="
# A renamed or hand-copied file is still classified correctly, and a wrong half
# gets a warning instead of a service that starts and silently carries no traffic.
for fn in role_of_config actual_role; do
  grep -q "$fn" "$UNIT" && ok "$fn exists" || bad "$fn is missing"
done
grep -q 'WARNING: this machine was declared the' "$UNIT" \
  && ok "a declared-role mismatch is warned about" || bad "no mismatch warning"
grep -q 'WARNING: %s looks like a CLIENT profile' "$UNIT" \
  && ok "a client profile is called out" || bad "no client-profile warning"
# The check must not block: refusing to install would strand a re-homed server.
# Scope the scan to the mismatch branch, so an unrelated exit elsewhere in the
# file cannot make this look guarded.
mismatch_branch=$(sed -n '/^elif \[\[ -n "\$declared_role"/,/^elif \[\[ -z "\$declared_role"/p' "$UNIT")
[[ -n "$mismatch_branch" ]] \
  && ok "the mismatch branch was located" || bad "could not locate the mismatch branch"
grep -qE '^\s*(exit|die) ' <<<"$mismatch_branch" \
  && bad "a role mismatch BLOCKS the install" || ok "a role mismatch only warns"
# The classifier has to read the config, not guess from the filename, or a
# renamed or hand-copied half is silently misclassified. Pin the call site, not
# just the definition: leaving the function unused is the same regression.
grep -qE '^actual_role="\$\(role_of_config ' "$UNIT" \
  && ok "the role is read from the config at the call site" \
  || bad "the role is not read from the config at the call site"
# And the two rules that make the read meaningful.
grep -q '"tun"' "$UNIT" \
  && ok "a client is recognised by its tun inbound" || bad "no tun-inbound rule"
grep -qE '"direct", "block", "dns"' "$UNIT" \
  && ok "direct/block/dns are excluded from the peer test" || bad "no peer-outbound exclusion"
# role_of_config reports a config it cannot read by returning the empty string.
# Comparing that against the word "unknown" succeeds, so the advice line would
# print with the role name missing: "This config is the  half of the bundle."
grep -q '\-z "\$declared_role" && -n "\$actual_role"' "$UNIT" \
  && ok "an unreadable config prints no half-name advice" \
  || bad "an empty role would print 'the  half of the bundle'"

echo
echo "=== 15. the menu survives an action that legitimately fails ==="
# The installer runs with `set -e`. Inside a menu loop that is wrong: the probe
# exists to be used *when* the tunnel is down, so its non-zero exit is the normal
# case, and a bare unguarded call closes the menu and dumps the user back to
# their shell with no explanation. Drive the real menu() for each such option.
# shellcheck disable=SC2317
menu_case() { # <label> <keystrokes> <python3 rc> <bash rc> <systemctl rc>
  local label="$1" keys="$2" out rc
  # Copy the wanted statuses into locals first. Using "$3" inside the stub would
  # read the stub's own positional parameters, not this function's.
  local py_rc="$3" sh_rc="$4" sys_rc="$5"
  rm -rf "$BUNDLE"; mkdir -p "$BUNDLE"
  printf '{}' > "$BUNDLE/client-linux.json"
  printf '{}' > "$BUNDLE/outside.json"
  printf '{}' > "$BUNDLE/node.json"
  printf '{}' > "$BUNDLE/node.install.json"
  printf 'ports' > "$BUNDLE/DEPLOY.txt"
  python3() { return "$py_rc"; }
  bash() { return "$sh_rc"; }
  systemctl() { return "$sys_rc"; }
  prepare_environment() { RAAHCTL=/opt/x/raahctl.py; UNIT_SCRIPT=/opt/x/install.sh; return 0; }
  latest_release_ref() { return 1; }
  # Call menu the way the installer does, as a simple command with stdin
  # redirected. Piping into it instead would put it on the right of a pipeline,
  # where errexit is measurably more forgiving, and every guard would then look
  # unnecessary -- which is exactly the mistake this test exists to prevent.
  out=$(set -e; menu < <(printf '%b' "$keys") 2>&1) || rc=$?
  rc=${rc:-0}
  if [[ "$rc" -eq 0 ]]; then
    ok "menu returns to the prompt after: $label"
  else
    bad "menu exited with $rc after: $label"
  fi
  unset -f python3 bash systemctl prepare_environment latest_release_ref
}
menu_case "option 6, the probe reports no traffic" '6\n\n0\n'                 1 0 0
menu_case "option 7, the bundle editor refuses"      '7\n\n0\n'                 1 0 0
menu_case "option 3, the install unit fails"         '3\n'"$BUNDLE"'/node.json\n0\n' 0 1 1
menu_case "option 8, GitHub is unreachable"          '8\n0\n'                  0 0 0
menu_case "option 4, the bundle builder fails"       '4\nn\n0\n'               1 0 0

echo
echo "=== 16. every fallible command in the menu is guarded in the source ==="
# Test 15 drives the menu, which is the behaviour that actually matters, but a
# behavioural test can only see the failure it happens to stage. The installer
# runs under `set -Eeuo pipefail` (line 2), so within a `while true` menu loop
# any unguarded non-zero command ends the session. Assert the guard is present
# for each command known to exit non-zero in normal use, so the invariant is
# pinned even where staging the failure is impractical.
guard() { # <label> <regex that must match>
  if grep -qE "$2" "$INSTALLER"; then
    ok "$1 is guarded"
  else
    bad "$1 is not guarded; under 'set -e' it would close the menu"
  fi
}
guard "the e2e probe (option 6)"        'e2e-probe .*--count 3 \\?$'
if grep -A1 -E 'e2e-probe .*--count 3 \\?$' "$INSTALLER" | grep -qE '^\s*\|\| (warn|printf)'; then
  ok "the e2e probe failure is reported, not swallowed"
else
  bad "the e2e probe has no '|| handler' on the following line"
fi
guard "edit-bundle (option 7)"          'edit-bundle .*\\?$'
if grep -A1 -E 'edit-bundle .*\\?$' "$INSTALLER" | grep -qE '^\s*\|\| (warn|printf)'; then
  ok "the bundle editor failure is reported"
else
  bad "edit-bundle has no '|| handler' on the following line"
fi
# Anchored to the eight-space copy inside menu(). The same call also appears
# with two spaces in update(); without the anchor that second copy satisfies
# this grep even after the menu's guard is gone, and the check becomes
# decoration that happens to look like coverage.
guard "latest_release_ref (option 8)"   '^        newest="\$\(latest_release_ref \|\| true\)"$'
guard "the raah-sing-box restart (option 3)" 'systemctl restart raah-sing-box \\?$'
if grep -A1 -E 'systemctl restart raah-sing-box \\?$' "$INSTALLER" | grep -qE '^\s*\|\| (warn|printf)'; then
  ok "a failed restart in option 3 is reported"
else
  bad "the restart in option 3 has no '|| handler' on the following line"
fi
# `set -e` itself has to be on, or none of the above matters.
if grep -qE '^set -Eeuo pipefail$' "$INSTALLER"; then
  ok "the installer really does run under 'set -e'"
else
  bad "the installer no longer sets 'set -e'; these guards are load-bearing"
fi

rm -rf "$BUNDLE"
echo
echo "=================================================="
printf '  %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
