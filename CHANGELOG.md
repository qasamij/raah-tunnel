# Changelog

**[English](CHANGELOG.md)** · **[فارسی](CHANGELOG.fa.md)** · [LICENSE](LICENSE) · [README](README.md) · [ARCHITECTURE](docs/ARCHITECTURE.md) · [PROTOCOLS](docs/PROTOCOLS.md)

All notable changes to this project are recorded here. The two files are kept
in step: anything described in `CHANGELOG.fa.md` is also described here, and
`tests/test-docs.sh` fails if they drift apart.

The Persian changelog starts at **0.11.0**. Releases older than that are
recorded here only.

## Unreleased

### IPv6 is now tested, and the limits are documented

The tunnel has always accepted an IPv6 address, but nothing checked it. Every
other validator only ever saw IPv4, because the test bundle was hardcoded to
documentation-range IPv4 addresses — so a whole address family rested on the
assumption that a bare IPv6 literal is fine in each field it lands in. That
assumption is now enforced, and the README states plainly what IPv6 does and
does not give you.

- CI builds the bundle **twice**, once per address family, and runs
  `sing-box check` over every generated config in both. sing-box is the only
  authority on whether a bare v6 literal is accepted in `server`, and that is
  not something an offline check can answer.
- `tests/test_ipv6.py` asserts the properties that matter: a v6 literal
  survives `valid_host`, brackets are stripped on the way in and never stored,
  the literal lands **bare** in every outbound, a v6-only bundle writes and
  round-trips through `secrets.json`, and the hop metadata is still emitted.
- A `urltest` group names its members by tag, so reading its `outbounds` list
  directly yields strings and any server-field check silently inspects nothing.
  The test resolves each tag to the outbound it names, and separately asserts
  that IPv6 addresses were actually seen — so it cannot pass by checking
  nothing.
- The port-hopping table is asserted to stay in the `inet` family with no
  address selector. Were it narrowed to `ip`, IPv6 would stop hopping and
  nothing anywhere would report an error.
- `tests/mutation-ipv6.sh` puts seven bugs back and requires the suite to
  object, including a bracketed `server` address. That one matters most: a
  bracketed literal still loads, the service still starts, and the tunnel simply
  never connects.
- Documented in both READMEs, including the part IPv6 does *not* do: each node
  holds exactly one address, so there is no cross-family failover. A server with
  both is reachable over whichever address you recorded. Listing it twice is a
  deliberate operator decision, not automatic behaviour.

### The installer can now reach the other server for you

Setting up the second server used to mean reading a block of `scp` and `ssh`
commands and typing them by hand, with several paths in them to get right. The
role setup now offers to do it.

- After the local config is installed, the installer offers to send the peer its half and start it there. Answer `y` and it checks for a usable SSH key, tests the login, warns if that server has no TLS certificate, shows exactly what will be sent, and waits for a second `y`.
- Every prompt shows the value it would use anyway, so **Enter accepts it**. The peer's address is read out of the bundle's own `secrets.json`, so it is right even on a run that reused an existing bundle and never saw the wizard.
- Only the config and its matching `.install.json` are sent, plus the installer itself to `/tmp/raah-install.sh`. TLS keys are never copied, because they are the one thing that has to stay put.
- If there is no usable SSH key it offers to create one and prints the public half to add to the other server. It never asks for, stores, or types a password, and every connection runs with `BatchMode=yes` so it cannot fall into an interactive prompt.
- Answer `n`, or `Ctrl-C` at any point, and nothing is sent. The manual commands are printed instead, and a prerequisite that cannot be satisfied downgrades to those same instructions rather than failing.
- The peer's public IP came from a variable that did not exist. On a run that reused an existing bundle the read tripped `set -u` and killed the installer before it printed the remaining steps.

### The installer now says which half belongs on this server

A bundle holds one config per server, and putting the wrong one in place is the quietest mistake in the project: `sing-box` accepts either file, the service starts, the tunnel comes up, and it simply never carries the traffic you expected, with nothing in the logs to say why.

- `install-unit.sh` reads each config and works out which half it is: the Outside entry has only `direct`/`block`/`dns` outbounds, the Iran exit carries an outbound that dials the peer, and a client profile is recognised by its `tun` inbound.
- The classification is read from the file's own structure, so a renamed or hand-copied half is still recognised.
- A mismatch with the declared role, or a client profile, produces a warning that names both halves. **It still installs.** Re-homing a server is legitimate, and a wrong guess must never be the reason a box cannot be brought up.
- Menu option 3 used to describe the two files backwards, calling `iran-01.json` the entry and `outside.json` the exit. It is exactly the reverse: `iran-01.json` runs on the Iran server and is that box's exit. It now asks which half belongs here first, and defaults the path from the answer.

### Failover interval is editable after the fact

- `edit-bundle` gained a health-interval field (menu item 12) and a `--health-interval` flag. It rewrites the `interval` of every `urltest` group in every regenerated file, so the two sides cannot end up failing over at different speeds.
- Values are Go durations and must be positive. `0s` is rejected because it makes `sing-box` hammer the health URL rather than fail over.

### Paths with spaces, and the systemd unit

- The generated `ExecStart` now quotes `$sing_box`, so an install under a path containing a space no longer produces a unit that cannot be started. The heredoc that builds the unit stays unquoted on purpose, because it is what expands `$sing_box` at install time.

### The install menu now asks which server you are on

The menu used to ask "which topology?", which is the wrong first question for
someone setting the project up for the first time. The question that actually
matters is "which machine am I logged into?", because the answer decides which
half of the bundle belongs here.

- Options 1 and 2 are now **IRAN server** and **OUTSIDE server**. Each one creates the bundle if it is missing, installs the matching config, and prints the exact commands for the *other* server. The old "Generate direct tunnel" wording is gone.
- The remaining options are regrouped: 3 install a config file, 4 build a bundle for another topology, 5 status, 6 end-to-end test, 7 edit a bundle, 8 update, 9 uninstall, `h` help, `0` exit.
- The menu closed at `Select [0-9, h]`; it previously advertised `[0-10]`, a range it did not accept, and rejected `h` even though the old help option was numbered 6.
- Both guides now tell the reader to pick option 1 or 2 to match the machine in front of them, instead of referring to a "Generate direct bundle" entry that no longer exists.

### A bundle can no longer be minted twice

The two servers must share keys, so the generator writes both halves in one
go and the folder is copied to the peer. Everything below is a case where that
invariant was broken silently.

- Role setup asks before creating a bundle, and states out loud which file it is about to install.
- A bundle is now recognised by *either* half. A folder holding only `iran-01.json` used to count as no bundle at all, so the installer would generate fresh keys and the two servers would stop matching with no error anywhere.
- A bundle that is missing the half this server needs is reported as a restore-the-folder error instead of being regenerated over.
- The peer-server instructions named the wrong file when setup ran on the Iran server, telling the reader to install `iran-01.json` on both machines.
- The peer instructions now copy the whole folder rather than a single config, because `install-unit.sh` also needs the matching `.install.json` metadata.

### Failures that stopped a first-time user dead

- `install-unit.sh` exits non-zero when the TLS files are missing, which on a fresh server is always. Role setup turned that into a fatal error, so the reader was thrown out of the installer *before* being told the one thing they had to do next. It now reports what is missing, confirms that nothing was changed, and hands control back so the same option can be repeated once the certificate is in place.
- A failed `systemctl restart` no longer aborts the installer under `set -e`; the remaining steps are still printed, because the config is already installed at that point.
- The lower-case and upper-case role names were conflated, which printed `--config /root/ --start` with no filename at all. The two are now separate variables.
- Role setup rebuilt the generate command from scratch and silently dropped `--auto-sni`, `--no-discovery` and `--hop`/`--no-hop`, so a flag the user had explicitly passed had no effect.
- Wizard prompts read from `/dev/tty` unconditionally. That aborts the whole installer under `ssh host 'command'`, in CI, and from cron, because there is no controlling terminal to open. Prompts now fall back to stdin.

### Testability and the release checks

- The bundle location is now the single `BUNDLE_DIR` variable, defaulting to `/root/raah-private-bundle` and overridable with `RAAH_BUNDLE`. The setup paths, the menu prompts and the uninstall prompt can no longer disagree about where the credentials live.
- `tests/test-menu.sh` and `tests/test-docs.sh` are new and run in CI. They cover the cases that hurt a real user: a menu number the documentation contradicts, a role setup that mints a second bundle, an empty config filename, a first run that dies before printing the next instruction, and a failed restart that takes the installer with it.
- The documentation check derives the menu from the source and compares it against every option number quoted in both guides, so a stale number fails the build instead of sending a beginner to the wrong menu entry on a live server.
- The new suites initially wrote to the product's default bundle path under `/root`, which a GitHub Actions runner cannot write, so they passed on a workstation and failed in CI. They now use a private temporary directory and clean up after themselves.
- The peer deployment, the role check and the install unit each have a suite of their own, and every suite has a mutation test that puts the bug back and requires the suite to object. A test that cannot fail when the code is broken reports safety it has not earned.
- Two of those guards were decorative and are now real. The `latest_release_ref` assertion was not anchored to the copy inside `menu()`, so a second copy in `update()` satisfied it after the menu's guard was gone. The documentation cell-count check hardcoded two columns, which rejected the three-column tables this project now ships.
- The mutation harnesses only checked that their pattern was *gone* after mutating. A pattern the source had outgrown made the substitution a silent no-op, the suite stayed green, and the run reported "not detected" — which reads like a coverage gap when the truth is that the test had stopped testing anything. They now require the target to exist first, and say "stale" instead of "slipped".
- `tests/test-install-unit.sh` replaces a behavioural sandbox that had to be abandoned: it depended on file-descriptor and process-substitution behaviour that does not hold on Git Bash. The invariants are now asserted against the source, which is what actually matters for a generated unit file.
- The role classifier is the one part worth proving behaviourally, and it is where a behavioural test *is* reliable: pure JSON in, one string out. `tests/test-role-detect.sh` covers all three shapes, a renamed file, and a config it cannot parse.
- CI runs Python 3.12 alongside 3.9 to 3.11, syntax-checks every shell script under `tests/`, and runs the new suites and all four mutation harnesses. The POSIX-only `edit-bundle` tests skip on Windows, so CI is the only place they actually execute.

### Fixes from a full review of the tree

- `scripts/install-unit.sh` built its metadata path from `$1`, but the argument loop has shifted every argument away by then, so under `set -u` the install died at the `.install.json` lookup with `1: unbound variable` — before a single file was written. It reads `$config_path` now, and `tests/test-install-unit.sh` fails if any positional parameter is touched after the parse loop.
- `firewall-plan` on a single config file now reads the matching `.install.json` too. That call is what the README documents, and without the sibling metadata the plan opened only the base UDP port: the half-open firewall that makes port hopping fail on a real server, reproduced by following the guide.
- `edit-bundle --hop enabled` used to fail at the last prompt on a bundle generated with `--no-hop`, because the stored count of 1 is not a usable range. It falls back to the generator default, and `generate` enforces the same 2–256 window `edit-bundle` does, so a bundle can no longer be created in a state that cannot be edited.
- `write_bundle --mode both --force` runs its managed-file cleanup before the mode branch. Converting a bundle left the old top-level `outside.json` and `iran-01.json` — keys and ports included — beside the new `direct/` and `reverse/` directories, where a reader copying "the half for this server" would pick up the stale file.
- `status` no longer dies with a traceback off Linux: `os.getloadavg` does not exist on Windows and `except OSError` never covered the resulting `AttributeError`. `quota-check` rejects a zero or negative `--limit-gb` instead of reporting every interface as over quota.
- `deploy_peer` no longer hands `scp` a `.install.json` that is not there. The warning promised the copy still ran; the missing path failed the transfer and the config never arrived. The summary and the printed manual commands now name only the files that exist.
- The menu survives everything that can legitimately fail: options 1, 2 and 4 are guarded, the two bare `read` prompts hand control back on EOF, cancelling option 3 returns to the menu instead of ending the installer, and a failed update says so rather than printing the success line.
- `prepare_environment` guards every critical step explicitly. Bash switches `set -e` off for a whole function called in a condition, so the menu's `if prepare_environment` had made the body errexit-exempt and a failed `apt-get` fell straight through to the clone. `require_ref` returns instead of exiting, so a bad `--ref` no longer closes the session.
- Uninstall and the cleanup after a failed clone go through `rm_tree`, which refuses a non-absolute path and the single-level system roots: a stray `RAAH_APP_ROOT` or `RAAH_BUNDLE` can no longer turn a cleanup into a reinstall of the machine.
- `tests/test-deploy-peer.sh` gained the missing-metadata case, and the mutation that puts that bug back now targets the conditional file list instead of the old single `scp` line.


## 0.11.0

- Added coordinated Hysteria2 UDP port hopping: client `server_ports`/`hop_interval`, per-server install metadata, and an isolated nftables DNAT service.
- Port specs are stored in the `start:end` form sing-box requires. sing-box rejects any `server_ports` entry without a colon, so a dash range fails the client at startup; `scripts/port-hop.sh` translates the colon form into the dash form nftables needs. Bundles written by the first 0.11.0 pre-release are still read and are rewritten in the correct form.
- The generator enables hopping by default when accepted, uses 32 UDP ports per side, and supports `--hop`, `--no-hop`, `--hop-count`, plus bundle editing.
- Rejected hop intervals below five seconds. sing-quic only enforces that floor when it dials, so `sing-box check` cannot catch a smaller value and the tunnel would only fail at runtime.
- The `raah-port-hop` unit is now confined to `CAP_NET_ADMIN` with `ProtectSystem=strict` and the rest of the systemd hardening suite; it needs to read the install metadata and adjust netfilter, nothing more.
- Added local bootstrap DNS for hostname tunnel endpoints and optimistic encrypted-DNS caching while keeping normal client DNS inside the selected tunnel.
- Made `fcntl` optional at import time with a clear POSIX-only edit guard; permission-bit tests now skip on non-POSIX systems.
- Retain only the newest three bundle and installed-config backups and replaced the custom executable lookup with `shutil.which`.
- `one-click-install.sh` now verifies the requested tag or branch exists before downloading and aborts on a failed fetch or clone. Previously a missing release tag surfaced as `couldn't find remote ref` followed by a misleading `scripts/install-unit.sh was not found`.
- CI now runs the same 3.9/3.10/3.11 matrix that GitHub actually executed, keeps the blocking `E9,F63,F7,F82` lint gate, and additionally runs `bash -n`, the port-hop metadata check, and `sing-box check` on every generated profile. `sing-box check` is the only validator that catches a malformed `server_ports` range.
- The port-hop parser inside `scripts/port-hop.sh` is now executed directly by the test suite, so the translation logic is covered on every platform instead of only where bash is installed. The legacy dash form is exercised through hand-written metadata, because `install_metadata` always normalises to the canonical form.

## 0.10.0

- Added an interactive and scriptable `edit-bundle` command for Outside/Iran addresses, Hysteria ports, REALITY base ports, and per-side SNI pools.
- Added independently configurable Outside/Iran health URLs and changed the default probe to Cloudflare's HTTP 204 endpoint.
- Fixed reverse-mode credential isolation: end-user REALITY paths now use each Iran node's `user_uuid`; `relay_uuid` is reserved for the inter-server relay.
- Added `route.auto_detect_interface` to every generated server configuration and modern encrypted DNS with TUN DNS hijacking to client profiles.
- Hardened all JSON secret writes with `os.open(..., 0o600)` and no-follow behavior where supported.
- Added Python and sing-box 1.14+ preflight checks, staged-file cleanup traps, and a pinned default release tag.
- CI now installs official sing-box and runs `sing-box check` against direct and reverse generated profiles with real REALITY keys.
- Added stable-release update and guarded full-uninstall actions to the menu; installation also creates `sudo raah-install --menu`.
- Cleaned duplicate/root-only `.gitignore` rules so private bundle patterns work below the repository root.
- Bundle editing now takes a non-blocking lock, creates a private timestamped backup, preserves credentials, and regenerates every affected server/client configuration from `secrets.json`.
- Added safe bundle editing to the one-click menu with clear reinstall and client redistribution instructions.

## 0.9.9

- Made root `one-click-install.sh` and `scripts/install-unit.sh` the only canonical installer sources; removed duplicate copies.
- Added a non-blocking `flock` guard for config installation and tightened `/etc/raah` to mode `0700`.
- Added `e2e-probe`, which launches a temporary localhost-only sing-box client and verifies HTTP(S) traffic across the complete generated route.
- Added end-to-end probing to the interactive installer menu.

## 0.9.8

- Removed the real user IP from the Outside-address prompt.
- Added three public-IP discovery providers so setup can continue when one provider is unreachable.
- Preserve a modified `/opt/raah-tunnel` checkout and run the requested operation from a temporary clean checkout instead of stopping.

## 0.9.7

- Prevent repeated installer runs from treating executable-bit differences created by earlier releases as local source edits.
- Stop changing tracked file modes after checkout and show the actual changed paths when genuine local content changes remain.

## 0.9.6

- Detect the setup server's public IP and suggest its role using approximate country lookup, requiring role confirmation.
- Show approximate country for both Outside and each Iran address; fall back to manual IP entry if discovery is unavailable.
- Offer `--no-discovery` for offline/manual setup without external lookup requests.

## 0.9.5

- Simplified the default generator wizard with beginner-friendly Iran/Outside labels, defaults and fewer questions for a single Iran node.
- Kept separate SNI lists, health interval, certificate paths, and per-node overrides under `generate --advanced`.
- Showed concrete per-server installation and SCP next steps after bundle generation; clarified TLS certificate prerequisites.
- Reject installation early with a clear error when local inbound TLS certificate/key files do not exist.

## 0.9.4

- Switched the installer menu to plain English for terminals without reliable Persian rendering.
- Show only the GitHub handle qasamij in the installer menu.

## 0.9.3

- Resolve raahctl.py correctly when tests are uploaded in either tests/ or the repository root.
- Make GitHub Actions report a missing root script clearly before running tests.

## 0.9.2

- Reworked installer menu for mixed Persian/English Ubuntu terminals: plain ASCII layout, separate lines per language, and ASCII/Persian/Arabic digit input.

## 0.9.1

- Install sing-box through its official signed APT repository; GitHub release checksum assets are no longer assumed.
- Update the GitHub Python workflow to run the available tests and shell syntax checks.

## 0.9.0

- Added a Persian installer menu with qasamij attribution and pointed installation at `qasamij/raah-tunnel`.
- Renamed generated outside config files and separated Iran and outside installation commands.
- Preserved automatic dependency installation from the 0.8.1 release.
- Clarified that x-ui routing must be configured separately.

## 0.8.1

- Made the installer compatible with both `scripts/install-unit.sh` and a flattened root-level `install-unit.sh` repository layout.
- Added a root-level installer entry point for the current GitHub repository layout.
- Corrected README download URLs to the repository's root-level `one-click-install.sh`.

## 0.8.0

- The one-click installer now installs Ubuntu dependencies, downloads Raah from `javadgh70/raah-tunnel`, and installs a checksum-verified official sing-box release.
- Added `--generate` for creating the shared pair bundle and retained `--config PATH --start` for installing the matching node configuration.
- Updated Persian and English deployment instructions with commands that work on a fresh Ubuntu server.

## 0.7.2

- Added a visible Persian guide link to the English README.
- Reworded Persian documentation and wizard prompts to use destination/outside terminology instead of a fixed country name.

## 0.7.1

- Added `scripts/one-click-install.sh` for repeatable node installation from a GitHub repository.
- Added Persian and English instructions for secure bundle transfer and one-command systemd setup.

## 0.7.0

- Clarified the production boundary: x-ui/3x-ui owns end-user accounts, quotas, expiry, and the panel; Raah remains the server-to-server transport layer.
- Added `audit-report` to aggregate Xray/x-ui access-log metadata by user, destination, protocol, and byte counters.
- Documented HTTPS visibility limits, retention, permissions, and privacy requirements for per-user audit logs.

## 0.6.0

- Added `add-user` with private sidecar ledger records for expiry and quota metadata.
- Added `enforce-users` to remove expired users from generated configs.
- Added `doctor` for deployment checks on generated config files and bundles.
- Clarified that x-ui/3x-ui quotas apply to panel-managed inbounds, while Raah traffic needs a separate stats/API layer for real per-user quota enforcement.

## 0.5.0

- Added configurable `urltest` health-check interval during generation.
- Added `list-users` and `revoke-user` for config-level user inspection and access removal.
- Added `firewall-plan` to print UFW commands from generated listen ports.
- Added `quota-check` for host/interface traffic limit checks.
- Updated documentation for firewall hardening, config-level revocation, bundle security, and quota limits.

## 0.4.0

- Added multi-SNI REALITY fallback pools with one TCP port per SNI.
- Changed default REALITY base ports to Germany TCP/7788 and Iran TCP/8877.
- Documented sequential port planning so SNI fallbacks do not collide.

## 0.3.0

- Added `raahctl sni-scan` to rank REALITY SNI candidates with real TLS handshakes.
- Added `generate --auto-sni` to suggest a REALITY SNI during bundle creation.
- Added `generate --mode direct|reverse|both`.
- Added reverse bundle output: Germany as the client entry and Iran nodes as exits.
- Documented direct/reverse topology differences and port collision rules.

## 0.2.0

- Added per-Iran-entry TLS hostname and certificate/key path overrides.
- Added `raahctl probe` for TCP connect latency and basic jitter measurement.
- Added `raahctl status` for load, memory, and optional interface traffic counters.
- Switched the documented test command to Python `unittest` so contributors do not need pytest.
- Updated Persian and English documentation for multi-entry TLS and monitoring behavior.

## 0.1.0

- Initial GitHub-ready project with sing-box config generation for Germany, Iran entries, and Linux TUN clients.
- Added Hysteria 2/QUIC and VLESS/REALITY/TCP paths, URLTest failover, install helper, stats, check, and watch utilities.
