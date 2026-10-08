#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo $0 /path/to/config.json" >&2
  exit 1
fi
# The config path is the only required argument. --role is optional and is a
# cross-check, not a requirement, so this script stays usable on its own.
config_path=""
declared_role=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)
      [[ $# -ge 2 ]] || { echo "--role needs a value: iran or outside" >&2; exit 2; }
      declared_role="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: sudo $0 /path/to/config.json [--role iran|outside]" >&2
      exit 2 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *)
      [[ -z "$config_path" ]] || { echo "Only one config path is allowed." >&2; exit 2; }
      config_path="$1"; shift ;;
  esac
done
if [[ -z "$config_path" || ! -f "$config_path" ]]; then
  echo "Usage: sudo $0 /path/to/config.json [--role iran|outside]" >&2
  exit 2
fi
case "$declared_role" in
  ""|iran|outside) ;;
  *) echo "--role must be iran or outside, not: $declared_role" >&2; exit 2 ;;
esac
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
# The parse loop above shifts every argument away, so $1 no longer exists here
# and `set -u` would abort the whole install with "1: unbound variable". The
# path lives in $config_path, which is the only value the loop ever stores.
meta_source="${config_path%.json}.install.json"
staged_meta="/etc/raah/install.json.new"
if [[ -f "$meta_source" ]]; then
  install -o root -g root -m 0600 "$meta_source" "$staged_meta"
else
  printf '%s\n' '{"version":1,"hysteria2_port_hopping":{"enabled":false,"listen_port":1,"server_ports":["1:1"],"hop_interval":"30s"}}' >"$staged_meta"
  chmod 0600 "$staged_meta"
  # A bundle ships each config together with its own .install.json, and that
  # file is what enables the Hysteria 2 port hopping. Copying only the .json to
  # the peer server is the documented step, and the result is not an error: the
  # service starts, sing-box check passes, and the hopping range is simply
  # never redirected, so traffic silently never uses the low-latency path.
  # Therefore: loud, on stderr, every time.
  printf '\n' >&2
  printf 'WARNING: no %s was found next to this config.\n' "$(basename "$meta_source")" >&2
  printf '         Hysteria 2 port hopping is now DISABLED on this server.\n' >&2
  printf '         The config will still install and the service will still start,\n' >&2
  printf '         but clients will dial the hopping range and reach nothing.\n' >&2
  printf '         Copy the whole bundle folder, or run:\n' >&2
  printf '           scp %s root@THIS_SERVER_IP:/root/\n' "$(basename "$meta_source")" >&2
  printf '\n' >&2
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
install -o root -g root -m 0600 "$config_path" "$staged"
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

# A bundle holds one config per server, and putting the wrong half on a machine
# is the quietest mistake in the whole project: sing-box accepts it, the service
# starts, and the tunnel simply never carries traffic the way the reader expects.
#
# The half is read from the config's own structure rather than its filename, so a
# renamed or hand-copied file is still classified correctly. An Iran server dials
# the Outside peer, so its config carries real outbounds; the Outside entry has
# none beyond direct. A config with a tun inbound is a client profile, which is
# never something this script should install.
#
# This warns and never blocks. Someone re-homing a box is legitimate, and a wrong
# guess here must not be the reason a server cannot be brought up.
role_of_config() {
  # Anything it cannot read comes back empty, which every caller treats as
  # "unknown" and simply skips the advice. sing-box check has already run by
  # now, so a failure here is not a real error and must not add noise to an
  # install that is otherwise fine.
  python3 - "$1" <<'PY' 2>/dev/null || true
import json
import pathlib
import sys

config = json.loads(pathlib.Path(sys.argv[1]).read_text())
inbounds = config.get("inbounds") or []
if any((item.get("type") or "") == "tun" for item in inbounds):
    print("client")
elif any((o.get("type") or "") not in {"direct", "block", "dns"}
         for o in config.get("outbounds") or []):
    print("iran")
else:
    print("outside")
PY
}
actual_role="$(role_of_config "$staged" || true)"
if [[ "$actual_role" == client ]]; then
  printf '\n' >&2
  printf 'WARNING: %s looks like a CLIENT profile, not a server config.\n' "$(basename "$config_path")" >&2
  printf '         A client config has a tun inbound and dials the servers; this script\n' >&2
  printf '         installs a listening service. Install outside.json on the Outside\n' >&2
  printf '         server, or iran-01.json on the Iran server.\n' >&2
  printf '\n' >&2
elif [[ -n "$declared_role" && "$actual_role" != "$declared_role" ]]; then
  printf '\n' >&2
  printf 'WARNING: this machine was declared the %s server, but %s is the %s half\n' \
    "$declared_role" "$(basename "$config_path")" "$actual_role" >&2
  printf '         of the bundle. Installing anyway, because the file may be right and\n' >&2
  printf '         the role may have changed. If the tunnel does not pass traffic,\n' >&2
  printf '         swap in the other half: outside.json or iran-01.json.\n' >&2
  printf '\n' >&2
elif [[ -z "$declared_role" && -n "$actual_role" ]]; then
  # -n, not a comparison against "unknown": role_of_config reports a config it
  # cannot read by returning the empty string, and an empty role compared to the
  # word "unknown" is not equal, so this would announce "the  half of the
  # bundle" with the name missing.
  printf 'This config is the %s half of the bundle.\n' "$actual_role"
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

# The heredoc delimiter is deliberately unquoted, because $sing_box has to be
# substituted into ExecStart. Quoting it would write the literal text
# "$sing_box" into the unit and the service would fail to start with a confusing
# "No such file or directory". tests/test-install-unit.sh guards that.
# The path itself is quoted for systemd, so a sing-box living under a directory
# with a space in its name is still one argument rather than two.
cat >/etc/systemd/system/raah-sing-box.service <<UNIT
[Unit]
Description=Raah Tunnel (standalone sing-box instance)
Wants=network-online.target raah-port-hop.service
After=network-online.target raah-port-hop.service

[Service]
Type=simple
ExecStart="$sing_box" run -c /etc/raah/config.json
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
# The config is already in place at this point. Port hopping is on by default,
# so a failure here is common enough (no nf_tables, an IPv6-only host, a
# conflicting table) that killing the script would leave the reader with a new
# config, a service still running the old one, and no instructions.
if ! systemctl enable raah-port-hop.service; then
  printf 'WARNING: could not enable the port-hopping unit; Hysteria 2 hopping will not work.\n' >&2
  printf '         The config is installed. Once nftables is fixed, run:\n' >&2
  printf '         sudo systemctl enable --now raah-port-hop\n' >&2
elif ! systemctl restart raah-port-hop.service; then
  printf 'WARNING: the port-hopping DNAT table was not applied; Hysteria 2 hopping will not work.\n' >&2
  printf '         The config is installed. Once nftables is fixed, run:\n' >&2
  printf '         sudo systemctl restart raah-port-hop\n' >&2
fi

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
