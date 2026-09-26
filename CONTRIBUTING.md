# Contributing

Thanks for helping improve Raah. Keep changes small and testable.

## Before opening a pull request

1. Do not include real IPs, domains, passwords, UUIDs, certificates, keys, or client configs. Use documentation-only reserved example domains and addresses.
2. Run `python3 -m unittest discover -s tests -v`, `python3 -m py_compile raahctl.py tests/test_raahctl.py`, and `bash -n scripts/install-unit.sh`.
3. For config-schema changes, validate on the oldest and newest supported sing-box releases in a disposable VM and record the versions tested.
4. Test UDP and TCP separately. Report carrier, route, region, MTU, speed, latency, jitter and loss; never generalize a single ISP result to every network.
5. Do not describe a protocol as undetectable, unfilterable, or guaranteed to work.

## Security reports

Do not publish working credentials or sensitive topology in an issue. Report a minimal sanitized reproduction and affected version.
