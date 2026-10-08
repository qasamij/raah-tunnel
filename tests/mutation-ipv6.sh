#!/usr/bin/env bash
# Mutation-test the IPv6 handling that tests/test_ipv6.py relies on.
#
# IPv6 is not a feature this project added; it is a set of properties that were
# already true and could silently stop being true. Nothing about a v6 literal is
# a syntax error when it goes wrong: a bracketed `server` loads, the config
# starts, and the tunnel simply never connects. The only defence is a test that
# fails loudly, so each mutation below removes one guarantee and the suite has
# to notice.
#
# Every file is restored byte-for-byte afterwards, and a restore mismatch is
# itself a failure: a test run that leaves the tree modified is worse than no
# test.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAHCTL="$ROOT/raahctl.py"
PORT_HOP="$ROOT/scripts/port-hop.sh"
SUITE="$ROOT/tests/test_ipv6.py"
BAK=$(mktemp -d)
cp "$RAHCTL" "$BAK/raahctl.orig"
cp "$PORT_HOP" "$BAK/port-hop.orig"

pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }

restore() {
  cp "$BAK/raahctl.orig" "$RAHCTL"; cp "$BAK/port-hop.orig" "$PORT_HOP"
}
trap 'restore; rm -rf "$BAK"' EXIT

# A restore that does not reproduce the original bytes means the run cannot be
# trusted: a later mutation would be applied to already-mutated source.
verify_restored() {
  if ! cmp -s "$RAHCTL" "$BAK/raahctl.orig" || ! cmp -s "$PORT_HOP" "$BAK/port-hop.orig"; then
    bad "$1: the tree was not restored byte-for-byte; every later result is suspect"
    return 1
  fi
  return 0
}

run_suite() {
  # Must propagate pytest's exit code. Forcing success here would make every
  # mutation look like a survivor, which is the failure mode this file exists
  # to detect -- in the harness itself.
  (cd "$ROOT" && python -m pytest "$SUITE" -q 2>&1)
}

# survive <label> <file> <python-expr to locate> <from> <to> <expected test fragment>
#
# Both patterns are checked, and that is the point. Checking only the result is
# how a stale mutation hides: the substitution silently does nothing, the suite
# stays green, and the run reports "not detected" -- which reads like a
# coverage gap when the truth is that the test stopped testing anything.
# Requiring the "before" pattern to exist turns that into an honest "stale".
#
# The expected test fragment is required too. Any non-zero exit would otherwise
# count as a catch, including a Python syntax error caused by a mutation that
# broke the module rather than the behaviour under test.
survive() {
  local label="$1" file="$2" from="$3" to="$4" expect="$5" out rc
  if ! grep -qF -- "$from" "$file"; then
    restore
    bad "$label: the target is no longer in the source; this mutation is stale"
    return
  fi
  python - "$file" "$from" "$to" <<'PY' || { restore; bad "$label: could not apply the mutation"; return; }
import sys
path, needle, replacement = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
assert needle in text, "target vanished"
with open(path, "w", encoding="utf-8", newline="") as handle:
    handle.write(text.replace(needle, replacement, 1))
PY
  if ! grep -qF -- "$to" "$file"; then
    restore
    bad "$label: mutation did not apply (the mutated text is absent)"
    return
  fi
  out=$(run_suite)
  rc=$?
  restore
  verify_restored "$label" || return
  if [[ $rc -eq 0 ]]; then
    bad "$label: SURVIVED - the suite stayed green, so nothing guards this"
  elif ! grep -qF -- "$expect" <<<"$out"; then
    bad "$label: failed, but not where expected (no '$expect' in the output); the catch may be accidental"
  else
    ok "$label: caught"
  fi
}

BASELINE=$(run_suite)
printf '  baseline (unmutated): %s\n\n' "$(grep -Eo '[0-9]+ (failed|passed)[^=]*' <<<"$BASELINE" | tail -1)"

echo "=== A. the address stops being stored bare ==="
# sing-box's `server` field wants a plain literal. Brackets are for URL parsers,
# and this field is not one, so bracketing it produces a config that loads and
# then cannot connect -- the worst shape of bug this project can ship.
survive "A: vless_out brackets the server address" "$RAHCTL" \
  '        "server": host,' '        "server": f"[{host}]",' \
  'test_no_server_field_is_bracketed'

echo "=== B. the port-hop table stops covering both families ==="
# One `inet` table with no address selector redirects a v6 packet exactly like a
# v4 one. Were the family narrowed to `ip`, IPv6 would stop hopping and nothing
# would report an error at all.
survive "B: the port-hop table drops inet for ip" "$PORT_HOP" \
  'table inet ' 'table ip ' \
  'test_the_table_is_inet'

survive "B2: the redirect rule becomes address-family specific" "$PORT_HOP" \
  "    udp dport %s redirect to :%s" "    ip6 saddr != :: udp dport %s redirect to :%s" \
  'test_the_redirect_rule_has_no_address_selector'

echo "=== C. the wizard stops accepting a v6 address ==="
# A validator that only understood dotted quads would refuse the address before
# any config was ever written, and the message would claim IPv6 is supported.
survive "C: valid_host stops accepting any IP address" "$RAHCTL" \
  '        return True
    except ValueError:' '        return False
    except ValueError:' \
  'test_ipv6_literal_is_accepted'

echo "=== D. the wizard starts storing the brackets it was given ==="
# A user pasting "[2001:db8::1]" out of a URL must get a usable address back,
# not a stored value that can never resolve.
survive "D: ask_host stops stripping brackets" "$RAHCTL" \
  'value = ask(label, default).strip().strip("[]")' \
  'value = ask(label, default).strip()' \
  'test_each_prompt_strips_brackets'

survive "D2: ask_hosts stops stripping brackets" "$RAHCTL" \
  'hosts = list(dict.fromkeys(x.strip().strip("[]") for x in raw.split(",") if x.strip()))' \
  'hosts = list(dict.fromkeys(x.strip() for x in raw.split(",") if x.strip()))' \
  'test_each_prompt_strips_brackets'

echo "=== E. the geo lookup loses a v6-only host ==="
# country_for_host prefers a global IPv4 then falls back to any global address.
# A v6-only host has no IPv4 to offer, so without the fallback it silently
# returns None and the country hint disappears.
survive "E: country_for_host loses the non-IPv4 fallback" "$RAHCTL" \
  '        address = address or next((ip for ip in addresses if ip.is_global), None)' \
  '        address = None' \
  'test_geo_lookup_falls_back_to_a_non_ipv4_address'

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]] || exit 1
