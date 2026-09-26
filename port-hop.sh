#!/usr/bin/env bash
set -Eeuo pipefail

TABLE=raah_porthop
ACTION="${1:-}"
META="${2:-/etc/raah/install.json}"

remove_rules() {
  command -v nft >/dev/null 2>&1 || return 0
  nft delete table inet "$TABLE" 2>/dev/null || true
}

[[ "$ACTION" == apply || "$ACTION" == remove || "$ACTION" == check ]] || {
  echo "Usage: $0 apply|remove|check [/path/to/install.json]" >&2
  exit 2
}
[[ "$ACTION" != remove ]] || { remove_rules; exit 0; }
[[ -f "$META" ]] || { echo "Port-hopping metadata not found: $META" >&2; exit 2; }

rules="$(python3 - "$META" <<'PY'
import json
import re
import sys

# install.json stores sing-box `start:end` port specs because that is the only
# form sing-box itself accepts. nftables spells a range with a dash, so the
# translation happens here, at the point the ruleset is generated.
CANONICAL = re.compile(r"([0-9]{1,5}):([0-9]{1,5})")
LEGACY = re.compile(r"([0-9]{1,5})(?:-([0-9]{1,5}))?")

value = json.load(open(sys.argv[1], encoding="utf-8"))
hop = value.get("hysteria2_port_hopping") or {}
enabled = bool(hop.get("enabled"))
base = int(hop.get("listen_port", 0))
ports = hop.get("server_ports") or []
if not 1 <= base <= 65535:
    raise SystemExit("Invalid Hysteria 2 listen port in install metadata")
parsed = []
for item in ports:
    text = str(item).strip()
    match = CANONICAL.fullmatch(text) or LEGACY.fullmatch(text)
    if not match:
        raise SystemExit(f"Invalid UDP port/range: {text}")
    start, end = int(match.group(1)), int(match.group(2) or match.group(1))
    if not 1 <= start <= end <= 65535:
        raise SystemExit(f"Invalid UDP port/range: {text}")
    parsed.append((start, end))
if enabled and len(parsed) < 2:
    raise SystemExit("Port hopping is enabled but no hopping range is configured")
print("enabled=" + ("1" if enabled else "0"))
print(f"base={base}")
for start, end in parsed:
    if start == end == base:
        continue
    print(f"range={start}" if start == end else f"range={start}-{end}")
PY
)"

[[ "$ACTION" != check ]] || { printf '%s\n' "$rules"; exit 0; }
enabled="$(printf '%s\n' "$rules" | awk -F= '$1 == "enabled" { print $2 }')"
[[ "$enabled" == 1 ]] || { remove_rules; exit 0; }
command -v nft >/dev/null 2>&1 || { echo "nft is required for Hysteria 2 port hopping." >&2; exit 2; }
base="$(printf '%s\n' "$rules" | awk -F= '$1 == "base" { print $2 }')"
remove_rules
# redirect (not dnat) is required: sing-quic rejects a Hysteria 2 hop whose
# reply arrives from a different port than the one it dialled, so the implicit
# SNAT of redirect is what makes the transparent hop work. The prerouting hook
# only ever sees inbound packets, so no iifname filter is needed; hardcoding an
# interface would break the hop on any host whose primary NIC is not eth0.
{
  printf 'table inet %s {\n' "$TABLE"
  printf '  chain prerouting {\n'
  printf '    type nat hook prerouting priority dstnat; policy accept;\n'
  while IFS= read -r range; do
    printf '    udp dport %s redirect to :%s\n' "$range" "$base"
  done < <(printf '%s\n' "$rules" | awk -F= '$1 == "range" { print $2 }')
  printf '  }\n}\n'
} | nft -f -
