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

# The live credentials live here. It is spelled once so the prompts, the
# uninstall and the setup paths cannot drift apart, and it stays overridable so
# the test suite can run as an unprivileged user.
BUNDLE_DIR="${RAAH_BUNDLE:-/root/raah-private-bundle}"

# The interactive wizard must read from the real terminal even when this script's
# stdin is a pipe, which is the normal case from the menu. Where there is no
# controlling terminal at all (a bare `ssh host 'command'`, a CI runner, a cron
# job) /dev/tty cannot be opened and the redirect would abort the whole
# installer, so fall back to stdin and let the wizard read what it is given.
if [[ -e /dev/tty ]] && : </dev/tty 2>/dev/null; then
  TTY_IN=/dev/tty
else
  TTY_IN=/dev/stdin
fi

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
info() { printf '\n==> %s\n' "$*"; }

# rm -rf is the one command in this script with no undo, and both of its
# arguments come from environment variables the reader may have set
# (RAAH_APP_ROOT, RAAH_BUNDLE) or from a path a failed git clone left behind.
# A bare "/" or "/opt" typed once in a shell profile turns a cleanup into a
# reinstall of the machine, so check the shape of the path rather than trusting
# the caller.
rm_tree() {
  local target="${1:-}"
  case "$target" in
    /*) ;;
    *) die "Refusing to remove a path that is not absolute: ${target:-<empty>}" ;;
  esac
  case "$target" in
    /|/opt|/usr|/etc|/var|/home|/root|/tmp|/bin|/sbin|/lib|/lib64|/srv|/boot|/proc|/sys|/dev|/mnt|/media|/run)
      die "Refusing to remove the system path: $target" ;;
  esac
  rm -rf -- "$target"
}
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
  # return, not exit: the menu reaches this through prepare_environment, and an
  # exit here would close the whole session over a typo in --ref.
  return 1
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
  # git leaves a partial directory behind when it cannot resolve the ref. The
  # destination is $APP_ROOT or a mktemp directory, and $APP_ROOT is whatever
  # RAAH_APP_ROOT said, so put it through the same guard as the uninstall.
  rm_tree "$1"
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
  rm_tree /etc/raah
  rm_tree "$APP_ROOT"
  systemctl daemon-reload
  systemctl reset-failed raah-sing-box raah-port-hop 2>/dev/null || true
  read -r -p "Also permanently delete $BUNDLE_DIR and its live credentials? [y/N]: " remove_bundle || true
  if [[ "$remove_bundle" == "y" || "$remove_bundle" == "Y" ]]; then
    rm_tree "$BUNDLE_DIR"
    printf 'Private bundle deleted permanently.\n'
  else
    printf 'Private bundle kept at %s.\n' "$BUNDLE_DIR"
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
  printf '   curl -fsSL https://raw.githubusercontent.com/qasamij/raah-tunnel/main/one-click-install.sh -o /tmp/raah-install.sh\n'
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

FIRST TIME, on either server, tell the installer what this machine is:
  sudo bash one-click-install.sh --menu
  then pick "1) IRAN server" or "2) OUTSIDE server"

The two servers must share one bundle, because the configs hold matching keys.
The role-based setup above mints it once, then offers to send the other server
its half over SSH and install it there. Every prompt accepts Enter, and if no
SSH key exists yet it offers to create one instead of asking for a password.

Manually, if you prefer:
  create the shared bundle:
    sudo bash one-click-install.sh --generate [--mode direct|reverse|both] [--auto-sni]
  install one file from that bundle on its matching server:
    sudo bash one-click-install.sh --config /root/raah-private-bundle/outside.json --start
    sudo bash one-click-install.sh --config /root/raah-private-bundle/iran-01.json --start
  or copy a half to the other server yourself:
    scp /root/raah-private-bundle/outside.json \
        /root/raah-private-bundle/outside.install.json root@OUTSIDE_IP:/root/
    ssh root@OUTSIDE_IP
    sudo bash /tmp/raah-install.sh --config /root/outside.json --start
  The .install.json is not optional; without it the far side runs with
  Hysteria 2 port hopping silently disabled.

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

role_config() {
  case "$1" in
    iran) printf 'iran-01.json\n' ;;
    outside) printf 'outside.json\n' ;;
    *) die "Unknown role: $1" ;;
  esac
}

# Options for every ssh/scp the deploy uses. BatchMode stops ssh from opening a
# password prompt, which would hang an unattended run; accept-new records a
# first-seen host key instead of blocking on the question, and would otherwise
# ask on a machine that has no terminal to answer with.
PEER_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

ssh_key_available() {
  local f
  if ssh-add -l >/dev/null 2>&1; then
    return 0
  fi
  for f in "$HOME"/.ssh/id_ed25519 "$HOME"/.ssh/id_rsa "$HOME"/.ssh/id_ecdsa; do
    [[ -f "$f" ]] && return 0
  done
  return 1
}

# Never type a password for the user. Either a key already works, or make one
# here and let the user paste the public half onto the other server by hand.
ensure_ssh_key() {
  local answer
  if ssh_key_available; then
    return 0
  fi
  printf '\n  No usable SSH key was found in %s/.ssh, so the copy cannot\n' "$HOME"
  printf '  authenticate. Raah will not ask for or store a password.\n'
  printf '  Create a key here and print the public half for the other server? [Y/n] '
  read -r answer || return 1
  case "$answer" in
    ''|y|Y|yes|Yes) ;;
    *) return 1 ;;
  esac
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    warn 'ssh-keygen is not installed (Ubuntu package: openssh-client).'
    return 1
  fi
  if ! ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N '' -C 'raah-deploy' >/dev/null 2>&1; then
    warn 'ssh-keygen failed, so no key was created.'
    return 1
  fi
  cat <<EOF

  Add this public key to the other server, as the user you will log in as:

$(sed 's/^/      /' "$HOME/.ssh/id_ed25519.pub")

      mkdir -p ~/.ssh && chmod 700 ~/.ssh
      printf '%s\n' '<the line above>' >> ~/.ssh/authorized_keys
      chmod 600 ~/.ssh/authorized_keys

EOF
  printf '  Press Enter to test the connection, or Ctrl-C to stop. '
  read -r answer || return 1
}

# The wizard already knows both public IPs, so every prompt below starts from
# the value it would use anyway and Enter accepts it.
deploy_peer() {
  local role="$1" bundle="$BUNDLE_DIR" answer
  local peer_role peer_name peer_default peer_cfg peer_meta
  if [[ "$role" == iran ]]; then
    peer_role=outside; peer_name=OUTSIDE
  else
    peer_role=iran; peer_name=IRAN
  fi
  peer_cfg="$(role_config "$peer_role")"
  peer_meta="$bundle/${peer_cfg%.json}.install.json"
  # The peer's address is whatever this bundle was generated with, which is more
  # trustworthy than anything typed in earlier, and it is the only record of it
  # on a run that reused an existing bundle and so never saw the wizard.
  peer_default=""
  if [[ -f "$bundle/secrets.json" ]]; then
    peer_default=$(python3 - "$bundle/secrets.json" "$peer_role" <<'PY' 2>/dev/null || true
import json
import sys

data = json.loads(open(sys.argv[1], encoding="utf-8").read())
if sys.argv[2] == "outside":
    print(data.get("de_address", "") or "")
else:
    nodes = data.get("iran_nodes") or []
    print((nodes[0].get("address", "") if nodes else "") or "")
PY
)
  fi

  manual() {
    # The missing metadata is reported further down; printing an scp command
    # that names a file this bundle does not have hands the reader a command
    # that fails for a reason unrelated to what they are doing.
    local copy_cmd="scp $bundle/$peer_cfg $peer_meta <SSH_USER>@<${peer_name}_PUBLIC_IP>:<DEST>/"
    if [[ ! -f "$peer_meta" ]]; then
      copy_cmd="scp $bundle/$peer_cfg <SSH_USER>@<${peer_name}_PUBLIC_IP>:<DEST>/"
    fi
    cat <<EOF
  Do it by hand instead:
      $copy_cmd
      ssh <SSH_USER>@<${peer_name}_PUBLIC_IP>
      sudo bash /tmp/raah-install.sh --config <DEST>/$peer_cfg --start
EOF
  }

  printf '\n  3. The %s server needs its own half: %s and %s.install.json\n' \
    "$peer_name" "$peer_cfg" "${peer_cfg%.json}"
  printf '     Shall this machine copy them over and install them there? [y/N] '
  read -r answer || { manual; return 0; }
  case "$answer" in
    y|Y|yes|Yes) ;;
    *) manual; return 0 ;;
  esac

  [[ -f "$bundle/$peer_cfg" ]] || { warn "$bundle/$peer_cfg is missing; nothing was sent."; return 0; }
  if [[ ! -f "$peer_meta" ]]; then
    warn "$peer_meta is missing."
    warn 'Without it the other server starts, but its Hysteria 2 port-hopping range'
    warn 'is never redirected, so traffic silently takes the slower path.'
  fi

  local ip user dest target copy_step
  if [[ -n "$peer_default" ]]; then
    printf '  %s server PUBLIC IP [%s]: ' "$peer_name" "$peer_default"
  else
    printf '  %s server PUBLIC IP: ' "$peer_name"
  fi
  read -r ip || return 0
  ip="${ip:-$peer_default}"
  if [[ -z "$ip" ]]; then
    warn 'An IP address is required.'
    return 0
  fi
  printf '  SSH user on that server [root]: '
  read -r user || return 0
  user="${user:-root}"
  printf '  Directory to place the files in on that server [/root]: '
  read -r dest || return 0
  dest="${dest:-/root}"
  target="$user@$ip"

  command -v ssh >/dev/null 2>&1 || { warn 'ssh is not installed (Ubuntu package: openssh-client).'; return 0; }
  command -v scp >/dev/null 2>&1 || { warn 'scp is not installed (Ubuntu package: openssh-client).'; return 0; }

  ensure_ssh_key || { printf '\n  Nothing was sent.\n'; manual; return 0; }

  printf '\n  Testing SSH to %s ... ' "$target"
  if ! ssh "${PEER_SSH_OPTS[@]}" "$target" true 2>/dev/null; then
    printf 'failed\n'
    warn "Could not log in to $target without a password."
    printf '  Check the IP and the user name, and that your public key is listed in\n'
    printf "  that account's ~/.ssh/authorized_keys.\n"
    manual
    return 0
  fi
  printf 'ok\n'

  # Hysteria 2 refuses to start without a certificate, and Raah will not invent
  # one. Say so before the copy, so a failure on the far side is not a surprise.
  printf '  Looking for a TLS certificate on %s ... ' "$ip"
  if ssh "${PEER_SSH_OPTS[@]}" "$target" \
       'test -s /etc/raah/tls/fullchain.pem && test -s /etc/raah/tls/privkey.pem' 2>/dev/null; then
    printf 'found\n'
  else
    printf 'missing\n'
    warn "Hysteria 2 will not start on $ip until /etc/raah/tls/fullchain.pem and"
    warn "/etc/raah/tls/privkey.pem are in place there. The copy below still runs,"
    warn 'but the install on that side will stop at that check.'
  fi

  if [[ -f "$peer_meta" ]]; then
    copy_step="1. copy $peer_cfg and ${peer_cfg%.json}.install.json into $dest/"
  else
    copy_step="1. copy $peer_cfg into $dest/   (no ${peer_cfg%.json}.install.json beside it: hopping stays off there)"
  fi
  cat <<EOF

  About to do this on $target:
    $copy_step
    2. copy the installer to /tmp/raah-install.sh
    3. run: sudo bash /tmp/raah-install.sh --config $dest/$peer_cfg --start

EOF
  printf '  Continue? [y/N] '
  read -r answer || return 0
  case "$answer" in
    y|Y|yes|Yes) ;;
    *) printf '  Nothing was sent.\n'; return 0 ;;
  esac

  local self="$SOURCE_ROOT/one-click-install.sh"
  [[ -f "$self" ]] || self="$0"

  # The metadata was already reported missing above. Passing a path scp cannot
  # read makes the whole transfer fail, so the config never reaches the peer at
  # all -- the exact opposite of what that warning promised ("The copy below
  # still runs"). Send what exists.
  local -a send_files=("$bundle/$peer_cfg")
  if [[ -f "$peer_meta" ]]; then
    send_files+=("$peer_meta")
  fi
  printf '\n  Copying files to %s ...\n' "$ip"
  if ! scp "${PEER_SSH_OPTS[@]}" "${send_files[@]}" "$target:$dest/"; then
    warn "scp failed. Nothing on $ip was changed."
    return 0
  fi
  if ! scp "${PEER_SSH_OPTS[@]}" "$self" "$target:/tmp/raah-install.sh"; then
    warn "the config arrived but the installer did not, so $ip cannot run it yet."
    manual
    return 0
  fi

  printf '\n  Installing on %s. First run downloads the repo, so this takes a while.\n' "$ip"
  if ssh -t "${PEER_SSH_OPTS[@]}" "$target" \
       "sudo bash /tmp/raah-install.sh --config '$dest/$peer_cfg' --start"; then
    printf '\n  %s is installed. Check it with: ssh %s sudo systemctl status raah-sing-box\n' \
      "$peer_name" "$target"
  else
    warn "the install on $ip did not finish cleanly."
    printf '  The config is already on disk there, so nothing is lost. Finish with:\n'
    printf '      ssh %s\n' "$target"
    printf "      sudo bash /tmp/raah-install.sh --config %s/%s --start\n" "$dest" "$peer_cfg"
  fi
}

# One bundle holds the keys for BOTH servers, so it must be created once and
# copied. Minting a second one on the other server silently produces a pair that
# cannot talk to each other, so ask before generating when the answer is not
# obviously yes, and always say out loud which half is being installed here.
setup_role() {
  local role="$1" bundle="$BUNDLE_DIR" want other_role other answer cfg prepared=0
  want="$(role_config "$role")"
  # Keep the lowercase name for role_config and the uppercase one for the text:
  # conflating them once printed "--config /root/ --start" with no filename.
  if [[ "$role" == iran ]]; then other_role=outside; other=OUTSIDE; else other_role=iran; other=IRAN; fi

  # $RAAHCTL and $UNIT_SCRIPT are only set by prepare_environment, and this
  # script runs under "set -u". Reaching the install step without it would abort
  # the whole installer, so prepare exactly once, whichever branch we take.
  ensure_ready() {
    [[ "$prepared" -eq 1 ]] && return 0
    prepare_environment || return 1
    prepared=1
  }

  printf '\n'
  printf '  This server will act as the %s server.\n' "$role"
  printf '  It will install:  %s\n' "$want"
  printf '  Bundle location:  %s\n' "$bundle"
  printf '\n'

  if [[ -f "$bundle/$want" ]]; then
    info "Using the existing $bundle/$want; its keys are shared with the other server"
  elif [[ -f "$bundle/outside.json" || -f "$bundle/iran-01.json" ]]; then
    # A bundle is a pair. Seeing only one half still means the keys already
    # exist, so refuse to mint a second set that could never match the peer.
    info "A bundle already exists in $bundle, so its keys will be reused"
    if [[ ! -f "$bundle/$want" ]]; then
      die "$bundle/$want is missing from the existing bundle. Restore the whole folder from the server that made it; do not generate a new one."
    fi
  else
    cat <<EOF
  No bundle found in $bundle.

  Raah writes both servers' configs together because they have to share the
  same keys. Create it ONCE here, then copy the whole folder to the $other
  server.

  If a bundle already exists on another machine, stop and copy it instead:
      scp -r <that-host>:${bundle} ${bundle}

EOF
    printf "  Type 'generate' to create a new bundle here: "
    read -r answer || { printf '  Nothing was changed.\n'; return 0; }
    case "$answer" in
      generate|yes|y) ;;
      *) printf '  Nothing was changed.\n'; return 0 ;;
    esac
    ensure_ready || return 1
    local gen_args=(generate --mode direct --out "$bundle")
    [[ "$AUTO_SNI" -eq 0 ]] || gen_args+=(--auto-sni)
    [[ "$NO_DISCOVERY" -eq 0 ]] || gen_args+=(--no-discovery)
    [[ -z "$HOP_ARG" ]] || gen_args+=("$HOP_ARG")
    if ! python3 "$RAAHCTL" "${gen_args[@]}" <"$TTY_IN"; then
      die "Bundle generation failed."
    fi
  fi

  cfg="$bundle/$want"
  [[ -f "$cfg" ]] || die "Expected $cfg but it is not there."

  ensure_ready || return 1
  info "Installing $cfg on this server"

  # install-unit.sh lists the exact files it needs and exits non-zero when they
  # are absent. On a first run they are always absent, so treat this as the
  # normal next step instead of killing the installer: the bundle is already
  # generated, and the user only has to supply TLS and press the same option.
  if ! bash "$UNIT_SCRIPT" "$cfg" --role "$role"; then
    printf '\n  Nothing was installed, so nothing was changed.\n'
    printf '  The config is generated and waiting at:\n      %s\n' "$cfg"
    printf '\n  To finish, put the TLS certificate and key on THIS server at the\n'
    printf '  paths listed above (normally /etc/raah/tls/), then choose this same\n'
    printf '  option again. The rest of the setup is already done.\n'
    printf '\n  The bundle stays at %s. Never put its contents on GitHub.\n' "$bundle"
    return 0
  fi

  if [[ -f "${cfg%.json}.install.json" ]]; then
    info "Deploy metadata for this server: ${cfg%.json}.install.json"
    printf '  Keep it next to %s if you copy this file to another host.\n' "$want"
  fi

  systemctl enable raah-sing-box >/dev/null 2>&1 || true
  # Do not let a failed restart abort the installer: the config is already in
  # place, and the user needs to see the remaining steps to finish the job.
  if ! systemctl restart raah-sing-box; then
    printf '\n  The config is installed, but the service did not start.\n'
    printf '  Check: systemctl --no-pager status raah-sing-box\n'
  else
    systemctl --no-pager --full status raah-sing-box || true
  fi

  printf '\n  This server is set up as %s. Remaining work:\n' "$role"
  printf '  1. Make sure a valid TLS cert+key is on this server in /etc/raah/tls/\n'
  printf '  2. Open every port listed in %s/DEPLOY.txt in BOTH the provider\n' "$bundle"
  printf '     panel and ufw (allow the full UDP range, not just one port).\n'
  printf '  3. Send the %s server its half and install it there.\n' "$other"
  deploy_peer "$role"
  printf '  4. Copy %s/client-linux.json to the device that uses the tunnel.\n' "$bundle"
  printf '  5. Verify: option 6 runs an end-to-end test through both servers.\n'
  printf '\n  Never put the contents of %s on GitHub.\n' "$bundle"
}

# Advanced path: build a bundle without installing anything here. Direct mode is
# covered by the role-based setup, so only the other topologies are offered.
build_bundle() {
  local choice bundle="$BUNDLE_DIR"
  printf '\n  Which topology?\n'
  printf '  2) Reverse  traffic enters OUTSIDE and leaves via IRAN\n'
  printf '  3) Both     build direct and reverse side by side\n'
  printf '  0) Cancel\n'
  printf '  Select [0-3]: '
  read -r choice || return 0
  case "$choice" in
    2) MODE=reverse ;;
    3) MODE=both ;;
    *) printf '  Nothing was changed.\n'; return 0 ;;
  esac
  prepare_environment || return 1
  if python3 "$RAAHCTL" generate --mode "$MODE" --out "$bundle" <"$TTY_IN"; then
    next_steps "$bundle" "$MODE"
  fi
}

menu() {
  local choice node_file node_role half client_file bundle_path
  while true; do
    printf '\n========================================\n'
    printf ' RAAH TUNNEL   |   qasamij/raah-tunnel\n'
    printf '========================================\n'
    printf '\n'
    printf '  SETUP - what is THIS server?\n'
    printf '    1) IRAN server      (entry point your users connect to)\n'
    printf '    2) OUTSIDE server   (exit node that reaches the internet)\n'
    printf '\n'
    printf '  MORE SETUP\n'
    printf '    3) Install a config file on this server\n'
    printf '    4) Build a bundle for another topology (reverse / both)\n'
    printf '\n'
    printf '  OPERATIONS\n'
    printf '    5) Service status\n'
    printf '    6) Test the tunnel end to end\n'
    printf '    7) Edit an existing bundle\n'
    printf '    8) Update to the latest release\n'
    printf '    9) Uninstall Raah completely\n'
    printf '\n'
    printf '    h) Help\n'
    printf '    0) Exit\n'
    printf '\n'
    printf '========================================\n'
    read -r -p 'Select [0-9, h]: ' choice || return 0
    case "$choice" in
      # Every action here can return non-zero: prepare_environment is the common
      # one (no network, no GitHub), and setup_role/build_bundle return 1 when it
      # fails. Inside `while true` under `set -e` an unguarded failure closes the
      # menu and drops the reader back at their shell with no explanation at all.
      1) setup_role iran \
           || printf 'The Iran setup did not finish; nothing was installed here.\n' >&2 ;;
      2) setup_role outside \
           || printf 'The Outside setup did not finish; nothing was installed here.\n' >&2 ;;
      3)
        # Ask which half first, then default the path from that answer. The old
        # wording asked for a path and left the reader to work out which file
        # was which, and it described them backwards: iran-01.json runs on the
        # Iran server and is that box's exit, while outside.json is the entry.
        printf '\n  Which half of the bundle belongs on THIS server?\n'
        printf '    1) Iran server     ->  iran-01.json   (this box dials the Outside peer)\n'
        printf '    2) Outside server  ->  outside.json   (this box is the entry)\n'
        printf '    0) Cancel\n'
        read -r -p '  Select [0-2]: ' half || return 0
        if [[ "$half" == 1 ]]; then
          node_role=iran
        elif [[ "$half" == 2 ]]; then
          node_role=outside
        else
          printf '  Nothing was changed.\n'
          # continue, not break: "0) Cancel" means back to the menu. Break left
          # the loop and ended the whole installer over a cancelled sub-prompt.
          continue
        fi
        read -r -p "  Config path [$BUNDLE_DIR/$(role_config "$node_role")]: " node_file || return 0
        node_file="${node_file:-$BUNDLE_DIR/$(role_config "$node_role")}"
        if [[ -f "$node_file" ]]; then
          if prepare_environment; then
            # Every command here can legitimately fail, and set -e is on. A menu
            # that exits takes the whole session with it, so each failure is
            # reported and the loop continues instead.
            if bash "$UNIT_SCRIPT" "$node_file" --role "$node_role"; then
              systemctl enable raah-sing-box \
                || printf 'Could not enable the service. Fix it with: sudo systemctl enable raah-sing-box\n' >&2
              systemctl restart raah-sing-box \
                || printf 'The config is installed but the service did not start. Check: sudo systemctl status raah-sing-box\n' >&2
            else
              printf 'The config was not installed. Nothing was changed.\n' >&2
            fi
          fi
        else printf 'Config file not found.\n' >&2; fi ;;
      4) build_bundle \
           || printf 'The bundle was not built; nothing was written.\n' >&2 ;;
      5) systemctl --no-pager status raah-sing-box raah-port-hop || true ;;
      6)
        # A closed stdin (piped menu, ssh without -t, EOF) makes this read fail;
        # unguarded, that non-zero ends the whole session instead of the menu.
        read -r -p "Client config path [$BUNDLE_DIR/client-linux.json]: " client_file || return 0
        client_file="${client_file:-$BUNDLE_DIR/client-linux.json}"
        if [[ -f "$client_file" ]]; then
          if prepare_environment; then
            # A probe that finds no traffic is the normal reason to reach for
            # this option, and it exits non-zero when that happens. Reporting
            # that as a reason to close the menu would be actively unhelpful,
            # and under `set -e` at the top of this file an unguarded failure
            # would take the whole session down.
            python3 "$RAAHCTL" e2e-probe "$client_file" --count 3 \
              || warn 'The probe did not complete. A non-zero exit usually just means no traffic was seen in time.'
          fi
        else printf 'Client config file not found.\n' >&2; fi ;;
      7)
        read -r -p "Bundle path [$BUNDLE_DIR]: " bundle_path || return 0
        bundle_path="${bundle_path:-$BUNDLE_DIR}"
        if [[ -d "$bundle_path" ]]; then
          if prepare_environment; then
            python3 "$RAAHCTL" edit-bundle "$bundle_path" <"$TTY_IN" \
              || printf 'The bundle was left unchanged.\n' >&2
          fi
        else printf 'Bundle directory not found.\n' >&2; fi ;;
      8)
        local newest
        prepare_environment || true
        # Matched the guard at the top of the file. If GitHub is unreachable,
        # an unguarded pipeline here exits the installer with no message at all.
        newest="$(latest_release_ref || true)"
        if [[ -z "$newest" ]]; then
          printf 'No stable v* release tag was found. Publish a GitHub release/tag first.\n' >&2
        else
          if [[ "$REF" != "$newest" ]]; then
            REF="$newest"
            # This branch sits inside `if/else`, so `set -e` is off for the call
            # and a failed fetch would still fall through to the success line
            # below, announcing an update that never happened.
            if ! prepare_environment; then
              printf 'The update to %s did not finish; the installed copy is unchanged.\n' "$REF" >&2
              continue
            fi
          fi
          printf 'Raah updated to %s.\n' "$REF"
        fi ;;
      9) uninstall_raah; return 0 ;;
      h|H) usage ;;
      0) return 0 ;;
      *) printf 'Invalid option. Enter 0-9, or h for help.\n' >&2 ;;
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
# Every `|| return 1` in this function exists because of how it is called. The
# menu invokes it as `if prepare_environment`, `prepare_environment || true`,
# and bare -- and bash switches `set -e` off for the whole body of a function
# called in a condition or on the right of `||`. Without explicit guards a
# failed apt-get falls straight through to the clone below and the caller is
# told the environment is ready.
info "Installing required Ubuntu packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update \
  || { warn 'apt-get update failed. Check the network access of this machine and run option 8 again.'; return 1; }
apt-get install -y --no-install-recommends ca-certificates curl git python3 tar util-linux nftables \
  || { warn 'Installing the required packages failed; nothing was set up.'; return 1; }

install_sing_box() {
  if command -v sing-box >/dev/null; then
    sing-box version || true
  else
    info "Installing sing-box from the official signed APT repository"
    install -d -m 0755 /etc/apt/keyrings \
      || { warn 'Cannot create /etc/apt/keyrings.'; return 1; }
    local key_tmp
    key_tmp="$(mktemp /etc/apt/keyrings/sagernet.asc.XXXXXXXX)" || return 1
    if ! curl -fsSL https://sing-box.app/gpg.key -o "$key_tmp"; then
      rm -f -- "$key_tmp"
      # Not die(): this runs from the menu too, where the reader needs the
      # prompt back rather than an empty shell.
      warn 'Cannot download the official sing-box APT signing key.'
      return 1
    fi
    chmod 0644 "$key_tmp" || return 1
    mv -f -- "$key_tmp" /etc/apt/keyrings/sagernet.asc || return 1
    cat >/etc/apt/sources.list.d/sagernet.sources <<'APT_SOURCE'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
APT_SOURCE
    apt-get update \
      || { warn 'apt-get update failed while adding the sing-box repository.'; return 1; }
    apt-get install -y --no-install-recommends sing-box \
      || { warn 'Installing sing-box failed.'; return 1; }
    sing-box version || true
  fi
  local installed_version
  installed_version="$(sing-box version | awk 'NR == 1 { sub(/^v/, "", $3); print $3 }')"
  if [[ -z "$installed_version" ]] || ! dpkg --compare-versions "$installed_version" ge "$MIN_SING_BOX_VERSION"; then
    warn "sing-box $MIN_SING_BOX_VERSION or newer is required; found: ${installed_version:-unknown}."
    return 1
  fi
}

install_sing_box || { warn 'No usable sing-box was installed; stopping here.'; return 1; }

info "Downloading Raah from GitHub"
require_ref || return 1
SOURCE_ROOT="$APP_ROOT"
if [[ -d "$APP_ROOT/.git" ]]; then
  # The installer invokes Python and shell files through their interpreters, so
  # executable-bit differences from GitHub web uploads are irrelevant. Ignore
  # those mode-only changes before checking for real local content edits.
  git -C "$APP_ROOT" config core.fileMode false || true
  current_repo="$(git -C "$APP_ROOT" remote get-url origin)" \
    || { warn "Could not read the origin of $APP_ROOT."; return 1; }
  dirty_files="$(git -C "$APP_ROOT" status --porcelain --untracked-files=normal)" \
    || { warn "Could not inspect $APP_ROOT for local changes."; return 1; }
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
python3 -m py_compile "$RAAHCTL" \
  || { warn "$RAAHCTL does not compile; the download is incomplete or broken."; return 1; }
install -o root -g root -m 0755 "$SOURCE_ROOT/one-click-install.sh" /usr/local/sbin/raah-install \
  || { warn 'Could not install /usr/local/sbin/raah-install.'; return 1; }

}

if [[ "$MENU" -eq 1 || ( "$GENERATE" -eq 0 && -z "$CONFIG" && -t 0 ) ]]; then
  menu
  exit 0
fi

prepare_environment

if [[ "$GENERATE" -eq 1 ]]; then
  bundle="$BUNDLE_DIR"
  info "Starting the interactive generator; create the pair only once"
  args=(generate --mode "$MODE" --out "$bundle")
  [[ "$AUTO_SNI" -eq 0 ]] || args+=(--auto-sni)
  [[ "$NO_DISCOVERY" -eq 0 ]] || args+=(--no-discovery)
  [[ -z "$HOP_ARG" ]] || args+=("$HOP_ARG")
  python3 "$RAAHCTL" "${args[@]}" <"$TTY_IN"
  next_steps "$bundle" "$MODE"
fi

if [[ -n "$CONFIG" ]]; then
  [[ -f "$CONFIG" ]] || die "Config file not found: $CONFIG"
  info "Validating and installing $CONFIG"
  bash "$UNIT_SCRIPT" "$CONFIG"
  if [[ "$START" -eq 1 ]]; then
    # A restart can fail for reasons outside this script, and the config is
    # already on disk at this point. Say what happened instead of exiting
    # silently, so the reader knows the remaining step.
    systemctl enable raah-sing-box || warn 'Could not enable the service; run: sudo systemctl enable raah-sing-box'
    systemctl restart raah-sing-box || warn 'The config is installed but the service did not start; check: sudo systemctl status raah-sing-box'
    systemctl --no-pager --full status raah-sing-box || true
  else
    printf 'Review DEPLOY.txt and firewall ports, then run: systemctl enable --now raah-sing-box\n'
  fi
fi

if [[ "$GENERATE" -eq 0 && -z "$CONFIG" ]]; then
  usage
  printf '\nDependencies and repository are installed. Choose --generate or --config on the next run.\n'
fi
