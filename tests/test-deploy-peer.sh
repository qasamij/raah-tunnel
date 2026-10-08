#!/usr/bin/env bash
# Drive deploy_peer with ssh/scp/ssh-keygen stubbed, so the prompt sequence, the
# exact file list and the command that runs on the far side can be checked
# without a second server.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/one-click-install.sh"

pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }

LAST=$(grep -n '^deploy_peer() {' "$INSTALLER" | cut -d: -f1)
FN_END=$(awk -v s="$LAST" 'NR>=s && /^}$/ { print NR; exit }' "$INSTALLER")
# Sourcing the top of the installer probes for /dev/tty, which this harness has
# no way to provide. The probe already falls back to stdin on its own, so the
# complaint is noise here.
# shellcheck disable=SC1090
source <(sed -n "1,${FN_END}p" "$INSTALLER") 2>/dev/null
# The sourced installer brings its own EXIT trap; replace it with ours.
trap - EXIT

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bin="$work/bin"; mkdir -p "$bin" "$work/.ssh"
export PATH="$bin:$PATH"
export HOME="$work"

LOG="$work/log"
: > "$LOG"

cat > "$bin/ssh" <<EOF
#!/usr/bin/env bash
printf 'ssh %s\n' "\$*" >> "$LOG"
for a in "\$@"; do
  case "\$a" in
    *fullchain.pem*) exit "\${FAKE_TLS:-0}" ;;
  esac
done
exit "\${FAKE_SSH:-0}"
EOF
cat > "$bin/scp" <<EOF
#!/usr/bin/env bash
printf 'scp %s\n' "\$*" >> "$LOG"
exit "\${FAKE_SCP:-0}"
EOF
# Only ever run when the user agreed to a new key, so creating the stub up front
# does not change what the other sections do. The real call is
# `ssh-keygen -t ed25519 -f <path> -N '' -C <comment>`, so the key path is the
# argument after -f.
cat > "$bin/ssh-keygen" <<EOF
#!/usr/bin/env bash
path=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -f) path="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "\$path" ]] || exit 1
printf 'ssh-ed25519 AAAAgenerated raah-deploy\n' > "\$path.pub"
exit 0
EOF
chmod +x "$bin/ssh" "$bin/scp" "$bin/ssh-keygen"

BUNDLE="$work/bundle"
mkdir -p "$BUNDLE"
for f in outside.json outside.install.json iran-01.json iran-01.install.json; do
  printf '{}' > "$BUNDLE/$f"
done
# deploy_peer reads the peer's address out of secrets.json, which is the only
# record of it on a run that reused an existing bundle and never saw the wizard.
cat > "$BUNDLE/secrets.json" <<'EOF'
{"de_address": "203.0.113.10", "iran_nodes": [{"address": "198.51.100.20"}]}
EOF
BUNDLE_DIR="$BUNDLE"
SOURCE_ROOT="$ROOT"

have_key() { printf 'ssh-ed25519 AAAAexisting raah-deploy\n' > "$HOME/.ssh/id_ed25519"; }
drop_key() { rm -f "$HOME"/.ssh/id_ed25519 "$HOME"/.ssh/id_ed25519.pub; }
# deploy_peer calls ssh_key_available, which consults ssh-add. Make it report an
# empty agent so the ~/.ssh files are the only thing that matters.
ssh-add() { return 1; }

run()  { out=$(printf '%b' "$2" | deploy_peer "$1" 2>&1); }
has()  { grep -qF -- "$2" <<<"$out" && ok "$1" || { bad "$1"; printf '        ---\n'; sed 's/^/        /' <<<"$out" | head -8; printf '        ---\n'; }; }
hasnt(){ grep -qF -- "$2" <<<"$out" && bad "$1" || ok "$1"; }

echo
echo "=== 1. this server is IRAN, so the OUTSIDE half goes out ==="
have_key
: > "$LOG"
run iran 'y\n\n\n\ny\n'
has "the OUTSIDE config is named"           "outside.json"
has "the metadata is named"                "outside.install.json"
has "the default IP is offered"            "OUTSIDE server PUBLIC IP [203.0.113.10]"
has "root is the default user"             "SSH user on that server [root]"
has "/root is the default destination"     "Directory to place the files in on that server [/root]"
has "the summary names the exact command"  "sudo bash /tmp/raah-install.sh --config /root/outside.json --start"
hasnt "nothing asks for a password"        "assword:"
if grep -q "scp .*outside\.json .*outside\.install\.json .*root@203\.0\.113\.10:/root/" "$LOG"; then
  ok "the config and its metadata go in one scp"
else
  bad "the scp did not carry both files"; sed 's/^/        /' "$LOG"
fi
if grep -q 'scp .*one-click-install\.sh .*root@203\.0\.113\.10:/tmp/raah-install\.sh' "$LOG"; then
  ok "the installer itself is sent so the far side can run it"
else
  bad "the installer was not sent"; sed 's/^/        /' "$LOG"
fi
if grep -q 'ssh -t .*root@203\.0\.113\.10 .*sudo bash /tmp/raah-install\.sh' "$LOG"; then
  ok "the far-side install gets a tty, so sudo can prompt"
else
  bad "the far-side install command was not issued"; sed 's/^/        /' "$LOG"
fi
# An unattended run must never stall on a password or a host-key question, and
# a destination directory with a space in it must arrive as one argument.
if grep -q 'BatchMode=yes' "$LOG"; then
  ok "ssh runs with BatchMode, so it cannot stop to ask for a password"
else
  bad "ssh may prompt for a password and hang the installer"; sed 's/^/        /' "$LOG"
fi
if grep -q "scp .* $BUNDLE/outside\.json $BUNDLE/outside\.install\.json root@203\.0\.113\.10:/root/" "$LOG"; then
  ok "the two files are quoted as one destination, spaces and all"
else
  bad "the scp destination is not passed as a single argument"; sed 's/^/        /' "$LOG"
fi
if grep -qF "sudo bash /tmp/raah-install.sh --config '/root/outside.json' --start" "$LOG"; then
  ok "the far-side config path is quoted, so a space in it would survive"
else
  bad "the far-side config path is unquoted"; sed 's/^/        /' "$LOG"
fi

echo
echo "=== 2. this server is OUTSIDE, so the IRAN half goes out ==="
have_key
: > "$LOG"
run outside 'y\n\n\n\ny\n'
has "the IRAN config is named"              "iran-01.json"
has "the default IP is offered"            "IRAN server PUBLIC IP [198.51.100.20]"
if grep -q 'root@198\.51\.100\.20' "$LOG"; then
  ok "it goes to the Iran address"
else
  bad "wrong peer address"; sed 's/^/        /' "$LOG"
fi
if grep -q '203\.0\.113\.10' "$LOG"; then
  bad "it also touched the outside address, which is this server"
else
  ok "it never connects back to this server's own address"
fi

echo
echo "=== 3. the far-side certificate is checked, and its absence is stated ==="
have_key
FAKE_TLS=1 run iran 'y\n\n\n\ny\n'
has "a missing certificate is reported"     "fullchain.pem"
have_key
FAKE_TLS=0 run iran 'y\n\n\n\ny\n'
hasnt "a present certificate is not cried about" "fullchain.pem"

echo
echo "=== 4. declining leaves both servers alone ==="
have_key
: > "$LOG"
run iran 'n\n'
if [[ ! -s "$LOG" ]]; then
  ok "answering no runs neither ssh nor scp"
else
  bad "ssh/scp ran after declining"; sed 's/^/        /' "$LOG"
fi
has "the manual commands are printed instead" "scp $BUNDLE/outside.json"

echo
echo "=== 5. the copy is confirmed before anything leaves this server ==="
have_key
: > "$LOG"
run iran 'y\n\n\n\nn\n'
# The reachability probe and the certificate check are read-only and run before
# the summary on purpose: there is no point asking the user to confirm a copy
# that cannot land. What must not happen is a transfer or a remote install.
if grep -q '^scp ' "$LOG"; then
  bad "scp ran after the confirmation was declined"; sed 's/^/        /' "$LOG"
else
  ok "no scp after declining the confirmation"
fi
if grep -q 'ssh -t .*sudo bash' "$LOG"; then
  bad "the remote install ran anyway"; sed 's/^/        /' "$LOG"
else
  ok "the remote install did not run"
fi

echo
echo "=== 6. no key, and the user declines to make one ==="
drop_key
: > "$LOG"
run iran 'y\n\n\n\nn\n'
has "it says no password will be asked"     "will not ask for or store a password"
has "it falls back to the manual commands"  "scp $BUNDLE/outside.json"
if [[ ! -s "$LOG" ]]; then
  ok "nothing is sent without a key"
else
  bad "it tried to connect without a key"; sed 's/^/        /' "$LOG"
fi
if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
  ok "no key was created without permission"
else
  bad "a key was created anyway"
fi

echo
echo "=== 7. no key, and the user lets it make one ==="
drop_key
: > "$LOG"
# Shall, IP, user, dest, make a key?, then Enter at the connection test, then yes.
run iran 'y\n\n\n\ny\n\ny\n'
has "the new public key is printed"         "ssh-ed25519 AAAAgenerated raah-deploy"
has "the user is told how to authorize it"  "authorized_keys"
if grep -q 'ssh .*root@203\.0\.113\.10' "$LOG"; then
  ok "it goes on to test the connection once the key exists"
else
  bad "it never tested the connection"; sed 's/^/        /' "$LOG"
fi

echo
echo "=== 8. an unreachable peer is explained, not swallowed ==="
have_key
: > "$LOG"
FAKE_SSH=1 run iran 'y\n\n\n\ny\n'
has "the failure names the target"          "root@203.0.113.10"
has "the manual commands are offered again" "sudo bash /tmp/raah-install.sh --config <DEST>/outside.json --start"

echo
echo "=== 9. a missing .install.json does not stop the copy ==="
# The warning in deploy_peer says "the copy below still runs". If scp is still
# handed the missing path, the transfer fails outright and the config never
# reaches the peer -- the one outcome that warning rules out.
have_key
rm -f "$BUNDLE/outside.install.json"
: > "$LOG"
run iran 'y\n\n\n\ny\n'
if grep -q "^scp .* $BUNDLE/outside\.json .*root@203\.0\.113\.10:/root/" "$LOG"; then
  ok "the config is still copied when the metadata is absent"
else
  bad "the transfer aborted because the metadata was missing"; sed 's/^/        /' "$LOG"
fi
if grep -q 'outside\.install\.json' "$LOG"; then
  bad "scp was handed a file that does not exist"
else
  ok "the missing metadata is not passed to scp"
fi
has "the reader is told hopping stays off there" "port-hopping range"
has "the summary no longer promises a file that is not there" "(no outside.install.json beside it"
printf '{}' > "$BUNDLE/outside.install.json"

echo
echo "=================================================="
printf '  %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
