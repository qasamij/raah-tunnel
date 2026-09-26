#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo $0 /path/to/config.json" >&2
  exit 1
fi
if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: sudo $0 /path/to/config.json" >&2
  exit 2
fi
if ! command -v flock >/dev/null; then
  echo "flock is required (Ubuntu package: util-linux)." >&2
  exit 2
fi
if ! command -v python3 >/dev/null; then
  echo "python3 is required (Ubuntu package: python3)." >&2
  exit 2
fi

staged=""
staged_meta=""
cleanup() {
  if [[ -n "$staged" && "$staged" == /etc/raah/config.json.new ]]; then
    rm -f -- "$staged"
  fi
  if [[ -n "$staged_meta" && "$staged_meta" == /etc/raah/install.json.new ]]; then
    rm -f -- "$staged_meta"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

install -d -o root -g root -m 0755 /run/lock
exec 9>/run/lock/raah-install.lock
if ! flock -n 9; then
  echo "Another Raah installation is already running. Wait for it to finish." >&2
  exit 3
fi

sing_box="$(command -v sing-box || true)"
if [[ -z "$sing_box" ]]; then
  echo "sing-box is not installed. Install it from the official project first." >&2
  exit 2
fi
minimum_version="1.14.0"
installed_version="$($sing_box version | awk 'NR == 1 { sub(/^v/, "", $3); print $3 }')"
if [[ -z "$installed_version" ]] || ! dpkg --compare-versions "$installed_version" ge "$minimum_version"; then
  echo "sing-box $minimum_version or newer is required; found: ${installed_version:-unknown}." >&2
  exit 2
fi

install -d -o root -g root -m 0700 /etc/raah
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
port_hop_source="$script_dir/port-hop.sh"
[[ -f "$port_hop_source" ]] || { echo "Missing installer helper: $port_hop_source" >&2; exit 2; }
meta_source="${1%.json}.install.json"
staged_meta="/etc/raah/install.json.new"
if [[ -f "$meta_source" ]]; then
  install -o root -g root -m 0600 "$meta_source" "$staged_meta"
else
  printf '%s\n' '{"version":1,"hysteria2_port_hopping":{"enabled":false,"listen_port":1,"server_ports":["1:1"],"hop_interval":"30s"}}' >"$staged_meta"
  chmod 0600 "$staged_meta"
  echo "No matching .install.json found; Hysteria 2 port hopping will be disabled."
fi
bash "$port_hop_source" check "$staged_meta" >/dev/null
if python3 - "$staged_meta" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(0 if (value.get("hysteria2_port_hopping") or {}).get("enabled") else 1)
PY
then
  command -v nft >/dev/null || { echo "nft is required (Ubuntu package: nftables)." >&2; exit 2; }
fi
staged="/etc/raah/config.json.new"
install -o root -g root -m 0600 "$1" "$staged"
if ! python3 - "$staged" <<'PY'
import json
import pathlib
import sys

config = json.loads(pathlib.Path(sys.argv[1]).read_text())
missing = []
for inbound in config.get("inbounds", []):
    tls = inbound.get("tls") or {}
    for label in ("certificate_path", "key_path"):
        path = tls.get(label)
        if path and not pathlib.Path(path).is_file():
            missing.append(f"{label}: {path}")
if missing:
    print("Missing TLS files on THIS server. Provide a matching certificate/key before installing:", file=sys.stderr)
    for item in missing:
        print("  " + item, file=sys.stderr)
    sys.exit(1)
PY
then
  exit 1
fi
if ! "$sing_box" check -c "$staged"; then
  echo "Config validation failed; the current config was left untouched." >&2
  exit 1
fi

if [[ -e /etc/raah/config.json ]]; then
  backup="/etc/raah/config.json.backup.$(date -u +%Y%m%dT%H%M%S.%NZ)"
  cp -a /etc/raah/config.json "$backup"
  echo "Previous Raah config saved as $backup"
fi
mv -f "$staged" /etc/raah/config.json
staged=""
mv -f "$staged_meta" /etc/raah/install.json
staged_meta=""
find /etc/raah -maxdepth 1 -type f -name 'config.json.backup.*' -printf '%T@ %p\n' \
  | sort -nr | awk 'NR > 3 { sub(/^[^ ]+ /, ""); print }' \
  | while IFS= read -r old_backup; do rm -f -- "$old_backup"; done

install -d -o root -g root -m 0755 /usr/local/libexec
install -o root -g root -m 0755 "$port_hop_source" /usr/local/libexec/raah-port-hop

cat >/etc/systemd/system/raah-port-hop.service <<'UNIT'
[Unit]
Description=Raah Hysteria 2 UDP port-hopping DNAT
Before=raah-sing-box.service
After=network-pre.target nftables.service

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/raah-port-hop apply /etc/raah/install.json
ExecStop=/usr/local/libexec/raah-port-hop remove /etc/raah/install.json
RemainAfterExit=yes
# The ruleset is streamed to `nft -f -`, so the unit only ever needs to read
# the install metadata and adjust netfilter; nothing else.
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
CapabilityBoundingSet=CAP_NET_ADMIN
AmbientCapabilities=CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
UNIT

cat >/etc/systemd/system/raah-sing-box.service <<UNIT
[Unit]
Description=Raah Tunnel (standalone sing-box instance)
Wants=network-online.target raah-port-hop.service
After=network-online.target raah-port-hop.service

[Service]
Type=simple
ExecStart=$sing_box run -c /etc/raah/config.json
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 /etc/systemd/system/raah-sing-box.service /etc/systemd/system/raah-port-hop.service
systemctl daemon-reload
systemctl enable raah-port-hop.service
systemctl restart raah-port-hop.service

cat <<'DONE'
Raah config validated and installed at /etc/raah/config.json.
Review listening ports and firewall rules before starting the service:
  sudo systemctl enable --now raah-sing-box
  sudo systemctl status raah-sing-box
  sudo journalctl -u raah-sing-box -f

This unit is separate from x-ui and never edits x-ui files. When hopping is
enabled, raah-port-hop maintains only Raah's dedicated nftables DNAT table; it
does not open UFW/provider-firewall ports for you.
DONE
