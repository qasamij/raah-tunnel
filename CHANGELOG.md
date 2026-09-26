# Changelog

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
