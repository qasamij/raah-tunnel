#!/usr/bin/env python3
"""Prove an IPv6 deployment generates a correct bundle, or say why not.

Every other validator in this project only ever saw IPv4, because the test
bundle was hardcoded to documentation-range IPv4 addresses. That left a whole
address family resting on the assumption that a bare IPv6 literal is fine in
each field it lands in. Closing that gap needs no host: generation runs offline
here, and the real `sing-box check` runs in CI against the same `--family 6`
bundle that `tests/ci_generate_bundle.py` builds.

Two things genuinely differ between the families, and both are worth naming:

1. An IPv6 literal contains colons. A field that a URL parser or a shell would
   re-split needs brackets; sing-box's `server` field needs none. Getting that
   backwards yields a config that parses as JSON and then cannot connect, which
   is the worst shape of bug there is.
2. nftables families. The port-hop table is `inet`, so one ruleset covers both.
   Were it `ip`, IPv6 would stop hopping and nothing would report an error.

Keys are fixed strings, as in test_raahctl.py, so this module needs no sing-box.
"""

import contextlib
import importlib.util
import inspect
import io
import ipaddress
import json
import tempfile
import unittest
from pathlib import Path


TEST_DIR = Path(__file__).resolve().parent


def repo_path(*layouts):
    """First existing path among the given layouts, anchored at the repo root.

    A GitHub web upload can drop this file into the repository root and flatten
    scripts/ as well, so anchoring only on TEST_DIR.parent would resolve to the
    runner's parent and fail with a confusing error. This mirrors the same
    helper in test_raahctl.py so both suites survive either layout.
    """
    for base in (TEST_DIR, TEST_DIR.parent):
        for parts in layouts:
            candidate = base.joinpath(*parts)
            if candidate.exists():
                return candidate
    wanted = " or ".join("/".join(parts) for parts in layouts)
    raise FileNotFoundError(f"{wanted} was not found next to, or above, {TEST_DIR.name}")


RAHCTL_PATH = repo_path(("raahctl.py",))
spec = importlib.util.spec_from_file_location("raahctl", RAHCTL_PATH)
raahctl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(raahctl)

PORT_HOP = repo_path(("scripts", "port-hop.sh"), ("port-hop.sh",))

# 2001:db8::/32 is the reserved IPv6 documentation range and 192.0.2.0/24 /
# 203.0.113.0/24 are the IPv4 equivalents, so nothing generated here can reach a
# real host.
V6_DE = "2001:db8:122::10"
V6_IR = "2001:db8:133::10"
V4_DE = "192.0.2.10"
V4_IR = "203.0.113.10"

CERT = "/etc/raah/tls/fullchain.pem"
KEY = "/etc/raah/tls/privkey.pem"


def data_for(de_address, ir_address):
    """A complete, credential-valid bundle dict for the given server addresses."""
    return {
        "de_address": de_address,
        "de_tls_name": "outside.example.com",
        "ir_tls_name": "iran.example.com",
        "de_reality_sni": "www.cloudflare.com",
        "ir_reality_sni": "www.cloudflare.com",
        "de_reality_snis": ["www.cloudflare.com"],
        "ir_reality_snis": ["www.cloudflare.com"],
        "de_hy2_port": 8443,
        "de_reality_port": 7788,
        "ir_hy2_port": 8443,
        "ir_reality_port": 8877,
        "de_hy2_server_ports": ["8443:8443", "8444:8474"],
        "ir_hy2_server_ports": ["8443:8443", "8444:8474"],
        "hy2_hop_count": 32,
        "hy2_hop_interval": "30s",
        "de_cert": CERT,
        "de_key": KEY,
        "ir_cert": CERT,
        "ir_key": KEY,
        "de_reality_private": "test-private-de",
        "de_reality_public": "test-public-de",
        "de_short_id": "0123456789abcdef",
        "relay_uuid": "11111111-1111-4111-8111-111111111111",
        "relay_password": "relay-password-for-tests",
        "relay_obfs": "relay-obfs-for-tests",
        "health_interval": "15s",
        "de_health_url": raahctl.DEFAULT_HEALTH_URL,
        "ir_health_url": raahctl.DEFAULT_HEALTH_URL,
        "iran_nodes": [{
            "address": ir_address,
            "tls_name": "iran.example.com",
            "cert": CERT,
            "key": KEY,
            "reality_private": "test-private-ir",
            "reality_public": "test-public-ir",
            "short_id": "fedcba9876543210",
            "user_uuid": "22222222-2222-4222-8222-222222222222",
            "user_password": "user-password-for-tests",
            "user_obfs": "user-obfs-for-tests",
        }],
    }


V6_DATA = data_for(V6_DE, V6_IR)


def iter_outbounds(config):
    """Yield every concrete outbound dict, resolving urltest tags to members.

    A urltest group names its members by tag, so reading its `outbounds` list
    directly yields strings and any check that expects a dict silently inspects
    nothing. That failure mode is easy to miss, so resolve them properly.
    """
    outbounds = [o for o in config.get("outbounds", []) if isinstance(o, dict)]
    by_tag = {o.get("tag"): o for o in outbounds}
    for outbound in outbounds:
        if outbound.get("type") == "urltest":
            for tag in outbound.get("outbounds", []):
                member = by_tag.get(tag)
                if isinstance(member, dict):
                    yield member
        else:
            yield outbound


class TestAddressAcceptance(unittest.TestCase):
    """The wizard must take a v6 address, and must not store a bracketed one."""

    def test_ipv6_literal_is_accepted(self):
        # The colon is the whole reason this matters: a validator that only
        # understood dotted quads would reject the address before any config
        # was ever written.
        self.assertTrue(raahctl.valid_host(V6_DE))

    def test_ipv4_literal_is_still_accepted(self):
        self.assertTrue(raahctl.valid_host(V4_DE))

    def test_garbage_is_still_rejected(self):
        self.assertFalse(raahctl.valid_host("not an address"))

    def test_brackets_cannot_be_stored(self):
        # Users paste a bracketed address out of a URL. valid_host itself must
        # reject brackets, or a stored address could keep them and never connect.
        self.assertFalse(raahctl.valid_host(f"[{V6_DE}]"))

    def test_the_wizards_strip_produces_a_valid_literal(self):
        self.assertTrue(raahctl.valid_host(f"[{V6_DE}]".strip().strip("[]")))

    def test_each_prompt_strips_brackets(self):
        # Scoped to the function that must strip, not a bare search of the file.
        # A file-wide search keeps passing while one call site regresses, which
        # is exactly the bug worth catching: a user pastes "[2001:db8::1]" and
        # the wizard refuses their own address back to them forever.
        for fn in (raahctl.ask_host, raahctl.ask_hosts):
            with self.subTest(function=fn.__name__):
                body = inspect.getsource(fn)
                self.assertIn('.strip("[]")', body)

    def test_geo_lookup_falls_back_to_a_non_ipv4_address(self):
        # A v6-only host has no global IPv4 to offer, so it must take the
        # any-global fallback rather than get None and lose the country hint.
        source = RAHCTL_PATH.read_text(encoding="utf-8")
        self.assertIn("ip.version == 4 and ip.is_global", source)
        self.assertIn("or next((ip for ip in addresses if ip.is_global)", source)


class TestAddressPlacement(unittest.TestCase):
    """The literal must reach sing-box bare, in every config that dials out."""

    def _servers(self, config):
        for outbound in iter_outbounds(config):
            server = outbound.get("server")
            if isinstance(server, str):
                yield outbound.get("tag"), server

    def test_no_server_field_is_bracketed(self):
        # Brackets belong to URL parsers. sing-box's server field is not one, so
        # bracketing it produces a config that loads and then cannot connect.
        configs = {
            "client": raahctl.make_client(V6_DATA),
            "outside": raahctl.make_germany(V6_DATA),
            "iran": raahctl.make_iran(V6_DATA, V6_DATA["iran_nodes"][0]),
        }
        for label, config in configs.items():
            for tag, server in self._servers(config):
                with self.subTest(config=label, tag=tag):
                    self.assertFalse(server.startswith("["), f"{server!r} is bracketed")

    def test_the_outbounds_actually_carry_ipv6(self):
        # Otherwise the check above would pass by inspecting nothing.
        configs = {
            "client": raahctl.make_client(V6_DATA),
            "outside": raahctl.make_germany(V6_DATA),
            "iran": raahctl.make_iran(V6_DATA, V6_DATA["iran_nodes"][0]),
        }
        seen = 0
        for label, config in configs.items():
            for tag, server in self._servers(config):
                try:
                    parsed = ipaddress.ip_address(server)
                except ValueError:
                    continue          # a hostname, equally fine
                with self.subTest(config=label, tag=tag):
                    if parsed.version == 6:
                        seen += 1
        self.assertGreater(seen, 0, "no outbound carries an IPv6 address")

    def test_a_hostname_address_is_still_accepted(self):
        # A DNS name is a legitimate way to reach a v6-only host, so the
        # generator must not special-case literals into a different shape. The
        # client dials the Iran node; de_address belongs to the server configs
        # and correctly never appears in a client's outbounds.
        config = raahctl.make_client(data_for("outside.example.com", "iran.example.net"))
        servers = [s for _, s in self._servers(config)]
        self.assertIn("iran.example.net", servers)
        self.assertNotIn("outside.example.com", servers)

    def test_the_outside_address_reaches_the_iran_server_config(self):
        # The reverse hop carries de_address, so the generator's hostname path
        # has to hold for that side too, not only the client side.
        config = raahctl.make_iran(data_for("outside.example.com", "iran.example.net"),
                                   data_for("outside.example.com", "iran.example.net")["iran_nodes"][0])
        servers = [s for _, s in self._servers(config)]
        self.assertIn("outside.example.com", servers)


class TestBundleGeneration(unittest.TestCase):
    """A v6-only bundle must write, round-trip and remain inspectable."""

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        cls.dest = Path(cls._tmp.name) / "v6"
        raahctl.write_bundle(cls.dest, V6_DATA, False, "both")
        cls.configs = [p for p in sorted(cls.dest.rglob("*.json"))
                       if p.name != "secrets.json" and not p.name.endswith(".install.json")]

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def test_configs_are_written(self):
        self.assertTrue(self.configs, "write_bundle produced no configs")

    def test_every_config_is_valid_json(self):
        for path in self.configs:
            with self.subTest(config=path.name):
                json.loads(path.read_text(encoding="utf-8"))

    def test_the_addresses_reach_the_configs(self):
        # Without this the rest of the class would validate nothing.
        reached = [p.name for p in self.configs
                   if V6_DE in p.read_text(encoding="utf-8")
                   or V6_IR in p.read_text(encoding="utf-8")]
        self.assertTrue(reached, "no generated config contains an IPv6 address")

    def test_secrets_round_trip_unbracketed(self):
        stored = json.loads(next(self.dest.rglob("secrets.json")).read_text(encoding="utf-8"))
        self.assertEqual(stored.get("de_address"), V6_DE)
        self.assertEqual(stored["iran_nodes"][0]["address"], V6_IR)

    def test_hop_metadata_is_written(self):
        # Without it, hopping would be silently disabled on a v6 host.
        self.assertTrue(list(self.dest.rglob("*.install.json")))

    def test_the_firewall_plan_opens_both_transports(self):
        # ufw applies a rule to IPv4 and IPv6 together when IPV6=yes in
        # /etc/default/ufw, so protocol/port rules need no per-family form. What
        # must never happen is a plan listing only UDP, which would leave the
        # TCP REALITY path shut on a host where UDP is blocked.
        args = type("Args", (), {"ssh_port": 22, "path": str(self.dest)})()
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            try:
                raahctl.firewall_plan(args)
            except SystemExit:
                pass
        plan = buf.getvalue()
        self.assertIn("7788/tcp", plan)
        self.assertIn("8443/udp", plan)


class TestPortHopFamily(unittest.TestCase):
    """The nftables table must keep serving both address families."""

    @classmethod
    def setUpClass(cls):
        cls.source = PORT_HOP.read_text(encoding="utf-8")

    def test_the_table_is_inet(self):
        self.assertIn("table inet ", self.source)
        self.assertNotIn("table ip ", self.source)

    def test_the_redirect_rule_has_no_address_selector(self):
        # A `udp dport X redirect to :Y` rule with no address selector matches
        # a v6 packet exactly as it matches a v4 one.
        self.assertIn("udp dport", self.source)
        self.assertNotIn("ip6 saddr", self.source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
