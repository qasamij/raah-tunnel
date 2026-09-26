#!/usr/bin/env bash
set -Eeuo pipefail

APP_ROOT="${RAAH_APP_ROOT:-/opt/raah-tunnel}"
REPO_URL="${RAAH_REPO_URL:-https://github.com/qasamij/raah-tunnel.git}"
REF="${RAAH_REF:-v0.11.0}"
MIN_SING_BOX_VERSION="1.14.0"
CONFIG=""
GENERATE=0
START=0
MENU=0
MODE=direct
AUTO_SNI=0
NO_DISCOVERY=0
HOP_ARG=""
RUNTIME_ROOT=""

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }
cleanup() {
  if [[ -n "$RUNTIME_ROOT" && "$RUNTIME_ROOT" == /tmp/raah-runtime.* && -d "$RUNTIME_ROOT" ]]; then
    rm -rf -- "$RUNTIME_ROOT"
  fi
  # Tarball staging paths are prefixed so the trap can recognise them even if the
  # download is interrupted.
  local stale
  for stale in /tmp/raah-tarball.*; do
    if [[ -d "$stale" ]]; then
      rm -rf -- "$stale"
    fi
  done
  for stale in /tmp/raah-tarball.*.tar.gz; do
    if [[ -f "$stale" ]]; then
      rm -f -- "$stale"
    fi
  done
}
trap cleanup EXIT

latest_release_ref() {
  git ls-remote --tags --sort='-v:refname' "$REPO_URL" 'refs/tags/v[0-9]*' 2>/dev/null \
    | awk -F/ '!/\^\{\}$/ { print $3; exit }'
}

ref_exists() {
  git ls-remote --exit-code "$REPO_URL" "refs/tags/$REF" "refs/heads/$REF" >/dev/null 2>&1
}

# Installing a pinned release that was never published fails deep inside git
# with "couldn't find remote ref" and then surfaces as a misleading complaint
# about a missing install-unit.sh. Check the ref up front and say what is wrong.
require_ref() {
  if ref_exists; then
    return 0
  fi
  local newest
  newest="$(latest_release_ref || true)"
  printf 'ERROR: %s has no branch or tag named "%s".\n' "$REPO_URL" "$REF" >&2
  if [[ -n "$newest" ]]; then
    printf 'The newest published release tag is %s.\n' "$newest" >&2
    printf 'Re-run with the published tag, or override explicitly:  --ref %s\n' "$newest" >&2
  else
    printf 'No v* release tag is published in this repository yet.\n' >&2
    printf 'Publish the tag first, or re-run against a branch:  --ref main\n' >&2
  fi
  exit 1
}

TARBALL_TIMEOUT="${RAAH_TARBALL_TIMEOUT:-90}"

# Reduce a Git URL to the owner/repo pair that codeload.github.com expects.
# Each expansion mirrors tests/test_raahctl.py::BashGlobTests, so a change to
# the URL format has to be reflected there.
repo_slug() {
  local url="${1%/}"
  url="${url%.git}"
  url="${url#*://}"
  url="${url#*@}"
  # An SSH remote separates the host from the path with ':' and has no '://' to
  # strip, so "#*/" below would eat the owner segment instead of the host and
  # yield "raah-tunnel/raah-tunnel". Normalise the separator first. A port
  # number cannot reach here, because the caller only accepts an https URL.
  url="${url//:/\/}"
  url="${url#*/}"
  url="${url%/}"
  printf '%s/%s\n' "${url%/*}" "${url##*/}"
}

# `git clone` stays the primary path because it leaves a real Git working tree,
# which the menu's update action depends on. When the Git transport is slow or
# blocked, one HTTPS request for the same ref is usually far quicker, and this
# repository is small enough that a tarball is a good second attempt.
fetch_tarball() {
  local dest="$1" slug archive work
  command -v curl >/dev/null 2>&1 || return 1
  command -v tar >/dev/null 2>&1 || return 1
  # repo_slug() only produces a meaningful codeload path for an https GitHub
  # URL, so reject anything else instead of building a broken archive URL.
  case "$REPO_URL" in
    https://github.com/*) ;;
    *) return 1 ;;
  esac
  slug="$(repo_slug "$REPO_URL")"
  archive="$(mktemp /tmp/raah-tarball.XXXXXXXX.tar.gz)"
  work="$(mktemp -d /tmp/raah-tarball.XXXXXXXX)"
  if ! curl -fsSL --max-time "$TARBALL_TIMEOUT" \
       "https://codeload.github.com/$slug/tar.gz/$REF" -o "$archive"; then
    return 1
  fi
  if ! tar -xzf "$archive" -C "$work" --strip-components=1; then
    return 1
  fi
  rm -f -- "$archive"
  mkdir -p "$dest"
  cp -a "$work/." "$dest/"
  rm -rf -- "$work"
}

clone_ref() {
  if git clone --depth 1 --branch "$REF" "$REPO_URL" "$1"; then
    return 0
  fi
  # git leaves a partial directory behind when it cannot resolve the ref.
  rm -rf -- "$1"
  info "git could not fetch $REF; retrying over a direct HTTPS archive"
  if fetch_tarball "$1"; then
    info "Fetched $REF as an archive. Menu updates need git and will re-clone."
    return 0
  fi
  die "Could not download $REF from $REPO_URL over git or HTTPS."
}

update_ref() {
  git -C "$1" fetch --depth 1 origin "$REF" \
    || die "Could not fetch $REF from $REPO_URL."
  git -C "$1" checkout -B "$REF" FETCH_HEAD \
    || die "Could not check out $REF in $1."
}

uninstall_raah() {
  local confirmation remove_bundle
  printf '\nThis removes the Raah service, /etc/raah, %s, and /usr/local/sbin/raah-install.\n' "$APP_ROOT"
  printf 'The sing-box package is kept because another service may use it.\n'
  read -r -p 'Type UNINSTALL to continue: ' confirmation || return 0
  [[ "$confirmation" == "UNINSTALL" ]] || { printf 'Cancelled.\n'; return 0; }
  if [[ "$APP_ROOT" != /opt/* || "$APP_ROOT" == /opt/ ]]; then
    die "Unsafe RAAH_APP_ROOT for removal: $APP_ROOT"
  fi
  systemctl disable --now raah-sing-box 2>/dev/null || true
  systemctl disable --now raah-port-hop 2>/dev/null || true
  /usr/local/libexec/raah-port-hop remove /etc/raah/install.json 2>/dev/null || true
  rm -f -- /etc/systemd/system/raah-sing-box.service /etc/systemd/system/raah-port-hop.service /usr/local/sbin/raah-install /usr/local/libexec/raah-port-hop
  rm -rf -- /etc/raah "$APP_ROOT"
  systemctl daemon-reload
  systemctl reset-failed raah-sing-box raah-port-hop 2>/dev/null || true
  read -r -p 'Also permanently delete /root/raah-private-bundle and its live credentials? [y/N]: ' remove_bundle || true
  if [[ "$remove_bundle" == "y" || "$remove_bundle" == "Y" ]]; then
    rm -rf -- /root/raah-private-bundle
    printf 'Private bundle deleted permanently.\n'
  else
    printf 'Private bundle kept at /root/raah-private-bundle.\n'
  fi
  printf 'Raah was removed. sing-box remains installed.\n'
}

next_steps() {
  local bundle="$1" mode="$2" iran_file=iran-01.json outside_file=outside.json
  if [[ "$mode" == reverse ]]; then
    iran_file=reverse-iran-exit-01.json
    outside_file=reverse-outside-entry.json
  fi
  printf '\nNEXT STEPS (run commands on the named server):\n'
  if [[ "$mode" == both ]]; then
    printf 'Direct and reverse have separate folders and overlapping ports. Read %s/DEPLOY.txt before choosing one.\n' "$bundle"
    bundle="$bundle/direct"
  fi
  printf '1. Put matching TLS cert/key on EACH server at the paths entered in the wizard.\n'
  printf '   Default paths: /etc/raah/tls/fullchain.pem and /etc/raah/tls/privkey.pem.\n'
  printf '   Read %s/DEPLOY.txt for ports to open in BOTH firewalls.\n' "$bundle"
  printf '2. On this setup server, copy the Iran file over SSH:\n'
  printf '   scp %s/%s %s/%s.install.json root@<IRAN_PUBLIC_IP>:/root/\n' "$bundle" "$iran_file" "$bundle" "${iran_file%.json}"
  printf '3. On the Outside server, install the OUTSIDE config:\n'
  printf '   sudo bash /tmp/raah-install.sh --config %s/%s --start\n' "$bundle" "$outside_file"
  printf '   (Keep %s.install.json beside it; if this host is not Outside, copy both securely.)\n' "${outside_file%.json}"
  printf '4. On the Iran server, download installer and install the IRAN config:\n'
  printf '   curl -fsSL https://raw.githubusercontent.com/qasamij/raah-tunnel/main/one-click-install.sh -o /tmp/raah-install.sh\n'
  printf '   sudo bash /tmp/raah-install.sh --config /root/%s --start\n' "$iran_file"
  printf '5. On BOTH servers: sudo systemctl status raah-sing-box\n'
  printf 'Do not upload private bundle files to GitHub. x-ui routing needs separate setup.\n'
}

usage() {
  cat <<'EOF'
Raah Tunnel | Iran / Outside | qasamij

First server / trusted setup host (download dependencies and create one shared bundle):
  sudo bash one-click-install.sh --menu
  sudo bash one-click-install.sh --generate [--mode direct|reverse|both] [--auto-sni]

Install one file from that bundle on its matching server:
  sudo bash one-click-install.sh --config /root/raah-private-bundle/outside.json --start
  sudo bash one-click-install.sh --config /root/raah-private-bundle/iran-01.json --start

Options:
  --generate       Run the interactive Raah bundle generator after installation.
  --menu           Open the English interactive menu.
  --mode MODE      Generate direct, reverse, or both modes.
  --auto-sni       Scan SNI candidates from this host.
  --hop            Enable Hysteria 2 UDP port hopping without asking.
  --no-hop         Disable Hysteria 2 UDP port hopping without asking.
  --no-discovery   Skip online public-IP and country checks; enter IPs manually.
  --config PATH    Validate and install an existing node config.
  --start          Enable and start raah-sing-box after installing --config.
  --repo URL       Override the Git repository.
  --ref NAME       Git branch or tag (default: v0.11.0; use main only for development).
EOF
}

menu() {
  local choice node_file client_file bundle_path
  while true; do
    printf '\n========================================\n'
    printf 'RAAH TUNNEL  |  IRAN / OUTSIDE\n'
    printf 'qasamij  |  github.com/qasamij/raah-tunnel\n'
    printf '========================================\n'
    printf '1) Generate direct tunnel: Iran to Outside\n'
    printf '2) Generate reverse tunnel: Outside to Iran\n'
    printf '3) Generate both modes\n'
    printf '4) Install config on this server\n'
    printf '5) Service status\n'
    printf '6) Help\n'
    printf '7) End-to-end client probe\n'
    printf '8) Safely edit an existing bundle\n'
    printf '9) Update Raah to the latest stable release\n'
    printf '10) Uninstall Raah completely\n'
    printf '0) Exit\n'
    printf '========================================\n'
    read -r -p 'Select [0-10]: ' choice || return 0
    case "$choice" in
      1|2|3)
        case "$choice" in 1) MODE=direct ;; 2) MODE=reverse ;; 3) MODE=both ;; esac
        local args=(generate --mode "$MODE" --out /root/raah-private-bundle)
        [[ "$AUTO_SNI" -eq 0 ]] || args+=(--auto-sni)
        [[ "$NO_DISCOVERY" -eq 0 ]] || args+=(--no-discovery)
        [[ -z "$HOP_ARG" ]] || args+=("$HOP_ARG")
        if prepare_environment; then
          if python3 "$RAAHCTL" "${args[@]}" </dev/tty; then
            next_steps /root/raah-private-bundle "$MODE"
          fi
        fi ;;
      4)
        printf 'Outside server config: outside.json\nIran server config: iran-01.json\n'
        read -r -p 'Config path: ' node_file
        if [[ -f "$node_file" ]]; then
          if prepare_environment; then
            bash "$UNIT_SCRIPT" "$node_file" && { systemctl enable raah-sing-box; systemctl restart raah-sing-box; }
          fi
        else printf 'Config file not found.\n' >&2; fi ;;
      5) systemctl --no-pager status raah-sing-box raah-port-hop || true ;;
      6) usage ;;
      7)
        read -r -p 'Client config path [/root/raah-private-bundle/client-linux.json]: ' client_file
        client_file="${client_file:-/root/raah-private-bundle/client-linux.json}"
        if [[ -f "$client_file" ]]; then
          if prepare_environment; then
            python3 "$RAAHCTL" e2e-probe "$client_file" --count 3
          fi
        else printf 'Client config file not found.\n' >&2; fi ;;
      8)
        read -r -p 'Bundle path [/root/raah-private-bundle]: ' bundle_path
        bundle_path="${bundle_path:-/root/raah-private-bundle}"
        if [[ -d "$bundle_path" ]]; then
          if prepare_environment; then
            python3 "$RAAHCTL" edit-bundle "$bundle_path" </dev/tty
          fi
        else printf 'Bundle directory not found.\n' >&2; fi ;;
      9)
        local newest
        prepare_environment
        newest="$(latest_release_ref)"
        if [[ -z "$newest" ]]; then
          printf 'No stable v* release tag was found. Publish a GitHub release/tag first.\n' >&2
        else
          if [[ "$REF" != "$newest" ]]; then
            REF="$newest"
            prepare_environment
          fi
          printf 'Raah updated to %s. Run: sudo raah-install --menu\n' "$REF"
        fi ;;
      10) uninstall_raah; return 0 ;;
      0) return 0 ;;
      *) printf 'Invalid option. Enter a number from 0 to 10.\n' >&2 ;;
    esac
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --generate) GENERATE=1; shift ;;
    --menu) MENU=1; shift ;;
    --mode) [[ $# -ge 2 ]] || die '--mode needs a value'; MODE="$2"; shift 2 ;;
    --auto-sni) AUTO_SNI=1; shift ;;
    --hop) HOP_ARG=--hop; shift ;;
    --no-hop) HOP_ARG=--no-hop; shift ;;
    --no-discovery) NO_DISCOVERY=1; shift ;;
    --config) [[ $# -ge 2 ]] || die "--config needs a path"; CONFIG="$2"; shift 2 ;;
    --start) START=1; shift ;;
    --repo) [[ $# -ge 2 ]] || die "--repo needs a URL"; REPO_URL="$2"; shift 2 ;;
    --ref) [[ $# -ge 2 ]] || die "--ref needs a branch or tag"; REF="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "$MODE" == direct || "$MODE" == reverse || "$MODE" == both ]] || die 'Expected --mode direct, reverse, or both.'

[[ ${EUID} -eq 0 ]] || die "Run with sudo/root."
[[ -r /etc/os-release ]] || die "This installer requires Ubuntu with systemd."
# shellcheck disable=SC1091
source /etc/os-release
[[ ${ID:-} == "ubuntu" ]] || die "Supported operating system: Ubuntu 22.04/24.04 or newer."
command -v systemctl >/dev/null || die "systemd is required."

prepare_environment() {
info "Installing required Ubuntu packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git python3 tar util-linux nftables

install_sing_box() {
  if command -v sing-box >/dev/null; then
    sing-box version
  else
    info "Installing sing-box from the official signed APT repository"
    install -d -m 0755 /etc/apt/keyrings
    local key_tmp
    key_tmp="$(mktemp /etc/apt/keyrings/sagernet.asc.XXXXXXXX)"
    if ! curl -fsSL https://sing-box.app/gpg.key -o "$key_tmp"; then
      rm -f -- "$key_tmp"
      die 'Cannot download the official sing-box APT signing key.'
    fi
    chmod 0644 "$key_tmp"
    mv -f -- "$key_tmp" /etc/apt/keyrings/sagernet.asc
    cat >/etc/apt/sources.list.d/sagernet.sources <<'APT_SOURCE'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
APT_SOURCE
    apt-get update
    apt-get install -y --no-install-recommends sing-box
    sing-box version
  fi
  local installed_version
  installed_version="$(sing-box version | awk 'NR == 1 { sub(/^v/, "", $3); print $3 }')"
  if [[ -z "$installed_version" ]] || ! dpkg --compare-versions "$installed_version" ge "$MIN_SING_BOX_VERSION"; then
    die "sing-box $MIN_SING_BOX_VERSION or newer is required; found: ${installed_version:-unknown}."
  fi
}

install_sing_box

info "Downloading Raah from GitHub"
require_ref
SOURCE_ROOT="$APP_ROOT"
if [[ -d "$APP_ROOT/.git" ]]; then
  # The installer invokes Python and shell files through their interpreters, so
  # executable-bit differences from GitHub web uploads are irrelevant. Ignore
  # those mode-only changes before checking for real local content edits.
  git -C "$APP_ROOT" config core.fileMode false
  current_repo="$(git -C "$APP_ROOT" remote get-url origin)"
  dirty_files="$(git -C "$APP_ROOT" status --porcelain --untracked-files=normal)"
  if [[ -n "$dirty_files" ]]; then
    info "Local changes found in $APP_ROOT; preserving them and using a temporary clean copy"
    printf '%s\n' "$dirty_files"
    RUNTIME_ROOT="$(mktemp -d /tmp/raah-runtime.XXXXXXXX)"
    clone_ref "$RUNTIME_ROOT"
    SOURCE_ROOT="$RUNTIME_ROOT"
  elif [[ "$current_repo" != "$REPO_URL" ]]; then
    if [[ "$current_repo" == 'https://github.com/javadgh70/raah-tunnel.git' && "$REPO_URL" == 'https://github.com/qasamij/raah-tunnel.git' ]]; then
      info 'Migrating the clean checkout to the new repository'
      git -C "$APP_ROOT" remote set-url origin "$REPO_URL"
    else
      die "The installed repository is $current_repo. Review it and change its origin explicitly before using $REPO_URL."
    fi
  fi
  if [[ "$SOURCE_ROOT" == "$APP_ROOT" ]]; then
    update_ref "$APP_ROOT"
  fi
elif [[ -e "$APP_ROOT" ]]; then
  info "$APP_ROOT is not a Git checkout; preserving it and using a temporary clean copy"
  RUNTIME_ROOT="$(mktemp -d /tmp/raah-runtime.XXXXXXXX)"
  clone_ref "$RUNTIME_ROOT"
  SOURCE_ROOT="$RUNTIME_ROOT"
else
  clone_ref "$APP_ROOT"
fi

RAAHCTL="$SOURCE_ROOT/raahctl.py"
UNIT_SCRIPT="$SOURCE_ROOT/scripts/install-unit.sh"
[[ -f "$RAAHCTL" ]] || die "raahctl.py was not found in the downloaded repository."
[[ -f "$UNIT_SCRIPT" ]] || die "scripts/install-unit.sh was not found in the downloaded repository."
python3 -m py_compile "$RAAHCTL"
install -o root -g root -m 0755 "$SOURCE_ROOT/one-click-install.sh" /usr/local/sbin/raah-install

}

if [[ "$MENU" -eq 1 || ( "$GENERATE" -eq 0 && -z "$CONFIG" && -t 0 ) ]]; then
  menu
  exit 0
fi

prepare_environment

if [[ "$GENERATE" -eq 1 ]]; then
  bundle="/root/raah-private-bundle"
  info "Starting the interactive generator; create the pair only once"
  args=(generate --mode "$MODE" --out "$bundle")
  [[ "$AUTO_SNI" -eq 0 ]] || args+=(--auto-sni)
  [[ "$NO_DISCOVERY" -eq 0 ]] || args+=(--no-discovery)
  [[ -z "$HOP_ARG" ]] || args+=("$HOP_ARG")
  python3 "$RAAHCTL" "${args[@]}" </dev/tty
  next_steps "$bundle" "$MODE"
fi

if [[ -n "$CONFIG" ]]; then
  [[ -f "$CONFIG" ]] || die "Config file not found: $CONFIG"
  info "Validating and installing $CONFIG"
  bash "$UNIT_SCRIPT" "$CONFIG"
  if [[ "$START" -eq 1 ]]; then
    systemctl enable raah-sing-box
    systemctl restart raah-sing-box
    systemctl --no-pager --full status raah-sing-box || true
  else
    printf 'Review DEPLOY.txt and firewall ports, then run: systemctl enable --now raah-sing-box\n'
  fi
fi

if [[ "$GENERATE" -eq 0 && -z "$CONFIG" ]]; then
  usage
  printf '\nDependencies and repository are installed. Choose --generate or --config on the next run.\n'
fi
