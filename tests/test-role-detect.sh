#!/usr/bin/env bash
# Classify a server config by its own contents rather than by its filename.
#
# This is the one place a behavioural test is reliable: it is pure JSON in, one
# string out, with no file-descriptor or process-substitution tricks. That
# matters because the earlier install-unit sandbox had to be abandoned for
# exactly those reasons, and this check is the part most worth proving.
#
# A wrong half is the quietest failure in the project. sing-box accepts either
# config, the service starts, the tunnel comes up, and it simply never carries
# traffic the way the reader expected, with nothing in the logs to say why.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT="$ROOT/scripts/install-unit.sh"

pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

echo "=== 1. the classifier is defined in the installer ==="
if grep -q '^role_of_config() {' "$UNIT"; then
  ok "role_of_config exists"
else
  bad "role_of_config is missing from scripts/install-unit.sh"
  printf '\n  %d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi

# Extract the function instead of sourcing the installer, which would need a
# real host. The body is pure python, so this is faithful.
START=$(grep -n '^role_of_config() {' "$UNIT" | cut -d: -f1)
END=$(awk -v s="$START" 'NR>=s && /^}$/ { print NR; exit }' "$UNIT")
eval "$(sed -n "${START},${END}p" "$UNIT")"

echo
echo "=== 2. each real config shape is classified correctly ==="
# Iran server: dials the Outside peer, so it carries a real outbound.
cat > "$W/iran-01.json" <<'EOF'
{"inbounds":[{"type":"mixed","listen":"0.0.0.0","port":443}],
 "outbounds":[{"type":"direct","tag":"direct"},
              {"type":"vless","tag":"de-out","server":"203.0.113.10","port":443}]}
EOF
# Outside server: the entry, so every outbound is local.
cat > "$W/outside.json" <<'EOF'
{"inbounds":[{"type":"mixed","listen":"0.0.0.0","port":443}],
 "outbounds":[{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}]}
EOF
# Client: has a tun inbound and dials the servers.
cat > "$W/client-linux.json" <<'EOF'
{"inbounds":[{"type":"tun","tag":"tun-in","interface_name":"raah0"}],
 "outbounds":[{"type":"vless","tag":"proxy","server":"198.51.100.20","port":443},
              {"type":"direct","tag":"direct"}]}
EOF

for pair in "iran-01.json:iran" "outside.json:outside" "client-linux.json:client"; do
  f="${pair%%:*}"; want="${pair#*:}"; got="$(role_of_config "$W/$f" 2>/dev/null)"
  [[ "$got" == "$want" ]] && ok "$f -> $got" || bad "$f -> '$got', want '$want'"
done

echo
echo "=== 3. the classification does not depend on the filename ==="
# A renamed or hand-copied half must still be recognised, which is the whole
# reason the check reads the file instead of matching on its name.
cp "$W/outside.json" "$W/mystery.json"
got="$(role_of_config "$W/mystery.json" 2>/dev/null)"
[[ "$got" == outside ]] \
  && ok "a renamed Outside config is still recognised" \
  || bad "a renamed Outside config read as '$got'"

cp "$W/iran-01.json" "$W/config.json"
got="$(role_of_config "$W/config.json" 2>/dev/null)"
[[ "$got" == iran ]] \
  && ok "a renamed Iran config is still recognised" \
  || bad "a renamed Iran config read as '$got'"

echo
echo "=== 4. a config it cannot read must not take the installer down ==="
# A client profile is installable-looking, so the classifier also has to survive
# junk. sing-box's own check runs first and rejects these; role_of_config runs
# after it, so it only needs to degrade quietly rather than abort the install.
printf 'not json at all' > "$W/broken.json"
if got="$(role_of_config "$W/broken.json" 2>/dev/null)"; then
  [[ -z "$got" ]] && ok "unparseable config degrades to empty" \
                  || bad "unparseable config returned '$got'"
else
  bad "an unparseable config made role_of_config exit non-zero"
fi

# An empty object is valid JSON but says nothing about the role.
printf '{}' > "$W/empty.json"
if got="$(role_of_config "$W/empty.json" 2>/dev/null)"; then
  [[ "$got" == outside ]] \
    && ok "an empty config falls through to the Outside default" \
    || bad "an empty config read as '$got'"
else
  bad "an empty config made role_of_config exit non-zero"
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
