#!/usr/bin/env bash
# A test that cannot fail is worse than no test, because it reports safety.
# This puts each bug back one at a time and insists the suite notices.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

cp README.md /tmp/en.bak
cp README.fa.md /tmp/fa.bak
cp tests/test-docs.sh /tmp/suite.bak
cp .gitignore /tmp/ignore.bak
trap 'cp /tmp/en.bak README.md; cp /tmp/fa.bak README.fa.md; cp /tmp/suite.bak tests/test-docs.sh; cp /tmp/ignore.bak .gitignore; rm -f /tmp/en.bak /tmp/fa.bak /tmp/suite.bak /tmp/ignore.bak' EXIT

fails=0

run() {
  local out count
  out=$(bash tests/test-docs.sh 2>&1)
  count=$(grep -oE '[0-9]+ passed, [0-9]+ failed' <<<"$out" | tail -1)
  grep -E '^  FAIL' <<<"$out" | head -2 | sed 's/^/      /'
  echo "      $count"
  if [[ "$count" == *"0 failed"* ]]; then
    echo "  NOT DETECTED <-- the test is decorative"
    fails=$((fails+1))
  fi
}

# Restoring a bug in the test file itself, not the documents. A checker whose
# expected column count is hardcoded rejects the three-column tables this project
# now ships, which is the same failure as a checker that catches nothing: the
# next person disables it.
mutate_checker() { # <label> <perl expr> <regex that must be gone>
  local label="$1" expr="$2" gone="$3"
  echo "=== $label ==="
  if ! grep -qE -- "$gone" tests/test-docs.sh; then
    echo "  the target is no longer in the source; this mutation is stale"
    fails=$((fails+1))
    return
  fi
  perl -0pi -e "$expr" tests/test-docs.sh
  if grep -qE -- "$gone" tests/test-docs.sh; then
    echo "  mutation did not apply; the source has moved on"
    fails=$((fails+1))
    return
  fi
  run
  cp /tmp/suite.bak tests/test-docs.sh
}

echo "=== A. the Persian guide points 'install the newest release' at the wrong option ==="
perl -0pi -e 's/گزینهٔ `8` آخرین تگ/گزینهٔ `9` آخرین تگ/' README.fa.md
run
cp /tmp/fa.bak README.fa.md

echo
echo "=== B. two troubleshooting rows merged with '||' ==="
perl -0pi -e 's/\| Service will not start \| Option 5\. A missing TLS certificate is the usual cause\. \|\n\| Probe fails/| Service will not start | Option 5. A missing TLS certificate is the usual cause. || Probe fails/' README.md
run
cp /tmp/en.bak README.md

echo
echo "=== C. the Persian guide mentions an option the menu does not have ==="
perl -0pi -e 's/گزینهٔ `9` پس از نوشتن/گزینهٔ `10` پس از نوشتن/' README.fa.md
run
cp /tmp/fa.bak README.fa.md

echo
echo "=== D. the Persian guide sends 'editing a bundle' to 'update' ==="
perl -0pi -e 's/گزینهٔ `7` را انتخاب کن/گزینهٔ `8` را انتخاب کن/' README.fa.md
run
cp /tmp/fa.bak README.fa.md

echo
echo "=== E. a config file is documented without its .install.json ==="
perl -0pi -e 's/outside\.json \/root\/raah-private-bundle\/outside\.install\.json root\@OUTSIDE_IP/outside.json root\@OUTSIDE_IP/' README.md
run
cp /tmp/en.bak README.md

echo
echo "=== F. the table check is reverted to a hardcoded two columns ==="
mutate_checker "F. cell count hardcoded to 2" \
  's/      if \(\( expected == 0 \)\); then\n        expected="\$n"          # the first row of this block is its header\n      elif \(\( n != expected \)\); then/      if (( n != 2 )); then/' \
  'if \(\( n != expected \)\)'

echo
echo "=== G. DEPLOY.txt is no longer ignored ==="
# It is chmod 600 and ships inside the private bundle. A missing rule means a
# port fingerprint from a real deployment lands in the repository, and it looks
# harmless next to the JSON files that are correctly ignored.
if ! grep -qx 'DEPLOY.txt' .gitignore; then
  echo "  the target is no longer in the source; this mutation is stale"
  fails=$((fails+1))
else
  grep -vx 'DEPLOY.txt' .gitignore > /tmp/gi.new && mv /tmp/gi.new .gitignore
  run
  cp /tmp/ignore.bak .gitignore
fi

echo
echo "=== H. the credential-copy patterns are dropped ==="
# add-user / revoke-user / enforce-users write a full copy of the config beside
# the original, carrying the relay password and every user credential. These
# names do not end in .json, so nothing else in the file catches them.
if ! grep -qx '\*.json.revoked' .gitignore; then
  echo "  the target is no longer in the source; this mutation is stale"
  fails=$((fails+1))
else
  grep -vx '\*.json.revoked' .gitignore > /tmp/gi.new && mv /tmp/gi.new .gitignore
  run
  cp /tmp/ignore.bak .gitignore
fi

echo
echo "=== I. the IPv6 section is dropped from a guide ==="
# The section carries the one thing a reader cannot work out alone: that there
# is no cross-family failover. Losing it leaves a guide that lists only the
# upsells, which is how someone ends up trusting a failover that does not exist.
if ! grep -qE '^#+ *IPv6 *$' README.md; then
  echo "  the target is no longer in the source; this mutation is stale"
  fails=$((fails+1))
else
  perl -0pi -e 's/^#+ *IPv6 *\n.*?(?=^## )//ms' README.md
  run
  cp /tmp/en.bak README.md
fi

echo
echo "=== J. the instruction is reduced to the bracketed form only ==="
# A bracketed address in sing-box's server field loads without error and then
# never connects, so the working form has to survive. Replacing every bare
# literal with a bracketed one leaves a document that only shows the value that
# does not work. Bracketing *in addition* is deliberately not used here: that
# mutation leaves the bare form intact and is a legitimate counter-example, so
# it is not a defect.
if ! grep -qF '`2001:db8:122::10`' README.md; then
  echo "  the target is no longer in the source; this mutation is stale"
  fails=$((fails+1))
else
  perl -0pi -e 's/`2001:db8:122::10`/`[2001:db8:122::10]`/g' README.md
  run
  cp /tmp/en.bak README.md
fi

echo
echo "=== K. CI stops validating an IPv6 bundle ==="
# The changelog now claims both families are checked. Narrowing the loop to IPv4
# leaves the claim a promise nothing enforces, which is the exact failure the
# rest of this file exists to catch.
if ! grep -qE 'for family in 4 6' .github/workflows/python-package.yml; then
  echo "  the target is no longer in the source; this mutation is stale"
  fails=$((fails+1))
else
  cp .github/workflows/python-package.yml /tmp/wf.bak
  perl -0pi -e 's/for family in 4 6/for family in 4/' .github/workflows/python-package.yml
  run
  cp /tmp/wf.bak .github/workflows/python-package.yml
  rm -f /tmp/wf.bak
fi

echo
echo "=== L. CI stops running the IPv6 mutation harness ==="
# Without the harness a regression in the IPv6 guarantees is silent: the suite
# and the mutation that proves the suite works are both unrun. The file name also
# appears in the layout list, so the check has to be anchored to the step that
# executes it -- and this mutation removes both that step and the compile line,
# which is what a real regression looks like.
if ! grep -qE '^ +bash tests/mutation-ipv6\.sh$' .github/workflows/python-package.yml; then
  echo "  the target is no longer in the source; this mutation is stale"
  fails=$((fails+1))
else
  cp .github/workflows/python-package.yml /tmp/wf.bak
  perl -0pi -e 's/^ +bash tests\/mutation-ipv6\.sh\n//m' .github/workflows/python-package.yml
  perl -0pi -e 's/ tests\/test_ipv6\.py//g' .github/workflows/python-package.yml
  if grep -qE '^ +bash tests/mutation-ipv6\.sh$' .github/workflows/python-package.yml; then
    echo "  mutation did not apply; the source has moved on"
    fails=$((fails+1))
  else
    run
  fi
  cp /tmp/wf.bak .github/workflows/python-package.yml
  rm -f /tmp/wf.bak
fi

echo
echo "=================================================="
if [[ $fails -eq 0 ]]; then
  printf '  every planted bug was caught\n'
else
  printf '  %d planted bug(s) slipped through\n' "$fails"
fi
[[ $fails -eq 0 ]]
