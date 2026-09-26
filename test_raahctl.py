import importlib.util
import json
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import builtins
from argparse import Namespace
from pathlib import Path
from unittest.mock import patch


TEST_DIR = Path(__file__).resolve().parent


def repo_path(*layouts):
    """First existing path among the given layouts, anchored at the repo root.

    A GitHub web upload can drop test_raahctl.py into the repository root and
    flatten scripts/ into the root as well. Anchoring only on TEST_DIR.parent
    then resolves to the runner's parent directory, and the helper lookup fails
    with exit code 127 instead of a useful error. Searching both anchors keeps
    the suite runnable from either layout.
    """
    for base in (TEST_DIR, TEST_DIR.parent):
        for parts in layouts:
            candidate = base.joinpath(*parts)
            if candidate.exists():
                return candidate
    wanted = " or ".join("/".join(parts) for parts in layouts)
    raise FileNotFoundError(f"{wanted} was not found next to, or above, {TEST_DIR.name}")


MODULE_PATH = repo_path(("raahctl.py",))
spec = importlib.util.spec_from_file_location("raahctl", MODULE_PATH)
raahctl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(raahctl)

HELPER = repo_path(("scripts", "port-hop.sh"), ("port-hop.sh",))
BASH = shutil.which("bash")
requires_bash = unittest.skipUnless(BASH, "bash is not installed on this platform")


def embedded_parser_source():
    """Return the Python heredoc that port-hop.sh pipes into `python3 -`.

    The bash wrapper cannot run on Windows, so the tests below execute the
    embedded parser directly. That keeps the logic that actually ships under
    test on every platform instead of skipping it everywhere but Linux.
    """
    text = HELPER.read_text(encoding="utf-8")
    marker = "<<'PY'\n"
    start = text.index(marker) + len(marker)
    return text[start:text.index("\nPY\n", start)]


def run_embedded_parser(metadata):
    return subprocess.run(
        [sys.executable, "-", str(metadata)],
        input=embedded_parser_source(),
        capture_output=True,
        text=True,
    )


def sample():
    return {
        "de_address": "de.example.net",
        "iran_nodes": [
            {"address": "ir1.example.net", "tls_name": "ir1.example.net", "cert": "/etc/raah/ir1/fullchain.pem", "key": "/etc/raah/ir1/privkey.pem", "reality_private": "ir-1-private", "reality_public": "ir-1-public", "short_id": "8899aabbccddeeff", "user_uuid": "72f8cc63-e057-42ac-85d5-6a6d09c00651", "user_password": "client-1-password", "user_obfs": "client-1-obfs"},
            {"address": "203.0.113.10", "tls_name": "ir2.example.net", "cert": "/etc/raah/ir2/fullchain.pem", "key": "/etc/raah/ir2/privkey.pem", "reality_private": "ir-2-private", "reality_public": "ir-2-public", "short_id": "7766554433221100", "user_uuid": "7b09cc8c-8d8a-4232-92e3-2c6c7f3b70bb", "user_password": "client-2-password", "user_obfs": "client-2-obfs"},
        ],
        "de_tls_name": "de.example.net",
        "ir_tls_name": "ir.example.net",
        "de_reality_sni": "www.example.org",
        "ir_reality_sni": "www.example.com",
        "de_hy2_port": 8443,
        "de_reality_port": 7788,
        "ir_hy2_port": 8443,
        "ir_reality_port": 8877,
        "de_cert": "/etc/raah/tls/fullchain.pem",
        "de_key": "/etc/raah/tls/privkey.pem",
        "ir_cert": "/etc/raah/tls/fullchain.pem",
        "ir_key": "/etc/raah/tls/privkey.pem",
        "de_reality_private": "test-private-de",
        "de_reality_public": "test-public-de",
        "de_short_id": "0011223344556677",
        "relay_uuid": "bf000d23-0752-40b4-affe-68f7707a9661",
        "user_uuid": "72f8cc63-e057-42ac-85d5-6a6d09c00651",
        "relay_password": "relay-password",
        "relay_obfs": "relay-obfuscation-secret",
    }


class RaahConfigTests(unittest.TestCase):
    def test_host_validation_accepts_ip_and_hostname(self):
        self.assertTrue(raahctl.valid_host("192.0.2.1"))
        self.assertTrue(raahctl.valid_host("2001:db8::1"))
        self.assertTrue(raahctl.valid_host("node.example.net"))
        self.assertFalse(raahctl.valid_host("https://node.example.net"))
        self.assertFalse(raahctl.valid_host("bad host"))

    def test_germany_config_has_only_direct_exit(self):
        config = raahctl.make_germany(sample())
        self.assertEqual([x["type"] for x in config["inbounds"]], ["hysteria2", "vless"])
        self.assertEqual(config["route"]["final"], "direct")
        self.assertEqual(config["inbounds"][0]["listen_port"], 8443)
        self.assertEqual(config["inbounds"][1]["tls"]["reality"]["short_id"], ["0011223344556677"])

    def test_iran_health_group_contains_both_transports(self):
        config = raahctl.make_iran(sample(), sample()["iran_nodes"][0])
        auto = next(x for x in config["outbounds"] if x["tag"] == "de-auto")
        self.assertEqual(auto["outbounds"], ["de-hy2", "de-reality-1"])
        self.assertEqual(config["route"]["final"], "de-auto")

    def test_hysteria_port_hopping_is_coordinated_with_install_metadata(self):
        data = sample()
        data["de_hy2_server_ports"] = ["8443:8443", "8444:8474"]
        data["ir_hy2_server_ports"] = ["8500:8500", "8501:8531"]
        data["ir_hy2_port"] = 8500
        data["hy2_hop_count"] = 32
        data["hy2_hop_interval"] = "30s"
        iran = raahctl.make_iran(data, data["iran_nodes"][0])
        outbound = next(item for item in iran["outbounds"] if item["type"] == "hysteria2")
        self.assertNotIn("server_port", outbound)
        self.assertEqual(outbound["server_ports"], ["8443:8443", "8444:8474"])
        self.assertEqual(outbound["hop_interval"], "30s")
        metadata = raahctl.install_metadata(data, "de")
        self.assertTrue(metadata["hysteria2_port_hopping"]["enabled"])
        self.assertEqual(metadata["hysteria2_port_hopping"]["listen_port"], 8443)

    def test_hysteria_port_specs_use_the_separator_sing_box_accepts(self):
        # sing-quic's hysteria.ParsePorts rejects any server_ports entry without
        # a colon ("bad port range"), so a dash range silently breaks the client
        # at startup. Pin the colon form for both the outbound and the metadata.
        data = sample()
        data["hy2_hop_count"] = 32
        ports = raahctl.build_hy2_server_ports(8443, 32)
        self.assertEqual(ports, ["8443:8443", "8444:8474"])
        for spec in ports + raahctl.install_metadata(data, "de")["hysteria2_port_hopping"]["server_ports"]:
            self.assertRegex(spec, r"^[0-9]{1,5}:[0-9]{1,5}$")
        self.assertEqual(raahctl.build_hy2_server_ports(8443, 1), ["8443:8443"])

    def test_legacy_and_malformed_port_specs_are_normalized_or_rejected(self):
        self.assertEqual(raahctl.normalize_port_specs(["8443", "8444-8474"]), ["8443:8443", "8444:8474"])
        self.assertEqual(raahctl.hy2_server_ports({"de_hy2_server_ports": ["8443", "8444-8474"],
                                                   "de_hy2_port": 8443}, "de"),
                         ["8443:8443", "8444:8474"])
        self.assertEqual(raahctl.parse_port_specs(["8444:8474"]), [(8444, 8474)])
        for bad in (["8444-"], ["8444:8443"], ["0:100"], ["8444:70000"], ["8444:x"], []):
            with self.assertRaises(ValueError):
                raahctl.normalize_port_specs(bad)

    def test_hysteria_port_hopping_rejects_port_overflow(self):
        with self.assertRaises(ValueError):
            raahctl.build_hy2_server_ports(65530, 32)

    def test_hop_interval_rejects_values_sing_box_refuses_at_dial_time(self):
        # sing-quic only enforces the five second floor when it dials, so
        # `sing-box check` passes for 1ms and the tunnel dies at runtime.
        self.assertTrue(raahctl.valid_hop_interval("5s"))
        self.assertTrue(raahctl.valid_hop_interval("30s"))
        self.assertTrue(raahctl.valid_hop_interval("1m"))
        self.assertFalse(raahctl.valid_hop_interval("1ms"))
        self.assertFalse(raahctl.valid_hop_interval("4999ms"))
        self.assertFalse(raahctl.valid_hop_interval("4s"))
        self.assertFalse(raahctl.valid_hop_interval("0s"))
        self.assertFalse(raahctl.valid_hop_interval("30"))

    @requires_bash
    def test_port_hop_metadata_passes_helper_validation(self):
        data = sample()
        data["de_hy2_server_ports"] = ["8443:8443", "8444:8474"]
        with tempfile.TemporaryDirectory() as directory:
            metadata = Path(directory) / "outside.install.json"
            raahctl.write_private(metadata, raahctl.install_metadata(data, "de"))
            checked = subprocess.run([BASH, str(HELPER), "check", str(metadata)], capture_output=True, text=True)
            self.assertEqual(checked.returncode, 0, checked.stderr)
            self.assertIn("range=8444-8474", checked.stdout)

    @requires_bash
    def test_port_hop_helper_still_reads_legacy_dash_metadata(self):
        # install_metadata() always normalises to the canonical start:end form,
        # so the legacy dash form has to be written by hand here. It is what an
        # install.json produced by an older release still looks like on disk.
        with tempfile.TemporaryDirectory() as directory:
            metadata = Path(directory) / "outside.install.json"
            raahctl.write_private(metadata, {
                "version": 1,
                "hysteria2_port_hopping": {
                    "enabled": True,
                    "listen_port": 8443,
                    "server_ports": ["8443", "8444-8474"],
                    "hop_interval": "30s",
                },
            })
            checked = subprocess.run([BASH, str(HELPER), "check", str(metadata)], capture_output=True, text=True)
            self.assertEqual(checked.returncode, 0, checked.stderr)
            self.assertIn("range=8444-8474", checked.stdout)


class BashGlobTests(unittest.TestCase):
    """Model the parameter expansions in one-click-install.sh.

    The bash helper that derives the codeload slug cannot be executed on every
    platform, and a wrong slug only fails at download time on a user's server.
    These tests reimplement bash's prefix/suffix removal for the literal-plus-
    star patterns the installer uses and pin the expected result.
    """

    @staticmethod
    def _glob_match(text, pattern):
        """Match a pattern built only from '*' and literal characters."""
        if "*" not in pattern:
            return text == pattern
        parts = pattern.split("*")
        if not pattern.startswith("*"):
            head = parts[0]
            if not text.startswith(head):
                return False
            text = text[len(head):]
        if not pattern.endswith("*"):
            tail = parts[-1]
            if not text.endswith(tail) or len(text) < len(tail):
                return False
            text = text[:len(text) - len(tail)]
        for part in parts[1:-1]:
            index = text.find(part)
            if index < 0:
                return False
            text = text[index + len(part):]
        return True

    def _strip_prefix(self, value, pattern, longest=False):
        order = range(len(value), -1, -1) if longest else range(len(value) + 1)
        for end in order:
            if self._glob_match(value[:end], pattern):
                return value[end:]
        return value

    def _strip_suffix(self, value, pattern, longest=False):
        order = range(len(value) + 1) if longest else range(len(value), -1, -1)
        for start in order:
            if self._glob_match(value[start:], pattern):
                return value[:start]
        return value

    def repo_slug(self, url):
        url = self._strip_suffix(url, "/")
        url = self._strip_suffix(url, ".git")
        url = self._strip_prefix(url, "*://")
        url = self._strip_prefix(url, "*@")
        # Mirrors ${url//:/\/}: an SSH remote has no "://" to strip, so its
        # "host:path" separator has to become a slash before "#*/" can find the
        # host boundary instead of the owner segment.
        url = url.replace(":", "/")
        url = self._strip_prefix(url, "*/")
        url = self._strip_suffix(url, "/")
        owner = self._strip_suffix(url, "/*")
        repo = self._strip_prefix(url, "*/", longest=True)
        return f"{owner}/{repo}"

    def test_slug_drops_scheme_host_and_git_suffix(self):
        self.assertEqual(
            self.repo_slug("https://github.com/qasamij/raah-tunnel.git"),
            "qasamij/raah-tunnel",
        )

    def test_slug_handles_plain_https_variants(self):
        for url in (
            "https://github.com/qasamij/raah-tunnel",
            "https://github.com/qasamij/raah-tunnel.git",
        ):
            self.assertEqual(self.repo_slug(url), "qasamij/raah-tunnel", url)

    def test_tarball_guard_only_accepts_https_github_urls(self):
        # fetch_tarball() bails out unless the URL matches https://github.com/*.
        # A looser *github.com/* also matches ssh:// and git@ remotes, where the
        # owner/repo slug repo_slug() derives is meaningless.
        guard = "https://github.com/*"
        for url in (
            "https://github.com/qasamij/raah-tunnel.git",
            "https://github.com/qasamij/raah-tunnel",
        ):
            self.assertTrue(self._glob_match(url, guard), url)
        for url in (
            "git@github.com:qasamij/raah-tunnel.git",
            "ssh://git@github.com/qasamij/raah-tunnel.git",
            "https://gitlab.com/qasamij/raah-tunnel.git",
        ):
            self.assertFalse(self._glob_match(url, guard), url)

    def test_installer_uses_the_strict_https_guard(self):
        shell = (TEST_DIR.parent / "one-click-install.sh").read_text(encoding="utf-8")
        self.assertIn("https://github.com/*) ;;", shell)

    def test_slug_survives_a_trailing_slash(self):
        self.assertEqual(
            self.repo_slug("https://github.com/qasamij/raah-tunnel.git/"),
            "qasamij/raah-tunnel",
        )

    def test_slug_handles_scp_style_ssh_remotes(self):
        # "git@host:owner/repo.git" has no "://", so a "#*/" strip that runs
        # before the ':' -> '/' rewrite eats the owner and returns
        # "raah-tunnel/raah-tunnel". Caught by running the real function in
        # bash; the model above has to agree with it.
        for url in (
            "git@github.com:qasamij/raah-tunnel.git",
            "git@github.com:qasamij/raah-tunnel",
            "ssh://git@github.com/qasamij/raah-tunnel.git",
        ):
            self.assertEqual(self.repo_slug(url), "qasamij/raah-tunnel", url)

    def test_codeload_url_built_from_the_slug(self):
        slug = self.repo_slug("https://github.com/qasamij/raah-tunnel.git")
        self.assertEqual(
            f"https://codeload.github.com/{slug}/tar.gz/v0.11.0",
            "https://codeload.github.com/qasamij/raah-tunnel/tar.gz/v0.11.0",
        )

    def test_installer_refs_the_same_slug_form(self):
        shell = (TEST_DIR.parent / "one-click-install.sh").read_text(encoding="utf-8")
        self.assertIn('local url="${1%/}"', shell)
        self.assertIn('url="${url%.git}"', shell)
        self.assertIn('url="${url#*/}"', shell)
        self.assertIn("https://codeload.github.com/$slug/tar.gz/$REF", shell)
        self.assertIn('"${url%/*}" "${url##*/}"', shell)

    def test_repository_paths_resolve_to_real_files(self):
        # A flattened upload used to make the helper lookup resolve outside the
        # checkout, so bash exited 127 and the failure named the wrong file.
        self.assertTrue(MODULE_PATH.is_file(), MODULE_PATH)
        self.assertTrue(HELPER.is_file(), HELPER)
        self.assertEqual(HELPER.name, "port-hop.sh")
        self.assertIn("import json", embedded_parser_source())
        self.assertEqual(raahctl.VERSION, "0.11.0")

    def test_embedded_helper_parser_translates_canonical_metadata(self):
        # The parser inside port-hop.sh is the only thing that turns sing-box's
        # `start:end` ports into the dash form nftables needs. Run it directly so
        # the contract is verified even where bash is unavailable.
        data = sample()
        data["de_hy2_server_ports"] = ["8443:8443", "8444:8474"]
        with tempfile.TemporaryDirectory() as directory:
            metadata = Path(directory) / "outside.install.json"
            raahctl.write_private(metadata, raahctl.install_metadata(data, "de"))
            result = run_embedded_parser(metadata)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("enabled=1", result.stdout)
        self.assertIn("base=8443", result.stdout)
        self.assertIn("range=8444-8474", result.stdout)
        # The base port is reached by the sing-box listener itself, so a rule for
        # it would loop the packet back into the same listener.
        self.assertNotIn("range=8443-8443", result.stdout)
        self.assertNotIn("range=8443\n", result.stdout)

    def test_embedded_helper_parser_accepts_legacy_dash_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            metadata = Path(directory) / "outside.install.json"
            raahctl.write_private(metadata, {
                "version": 1,
                "hysteria2_port_hopping": {
                    "enabled": True,
                    "listen_port": 8443,
                    "server_ports": ["8443", "8444-8474"],
                    "hop_interval": "30s",
                },
            })
            result = run_embedded_parser(metadata)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("range=8444-8474", result.stdout)

    def test_embedded_helper_parser_rejects_a_malformed_range(self):
        with tempfile.TemporaryDirectory() as directory:
            metadata = Path(directory) / "outside.install.json"
            raahctl.write_private(metadata, {
                "version": 1,
                "hysteria2_port_hopping": {
                    "enabled": True,
                    "listen_port": 8443,
                    "server_ports": ["8443:8444:not-a-port"],
                    "hop_interval": "30s",
                },
            })
            result = run_embedded_parser(metadata)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid UDP port/range", result.stderr)

    def test_embedded_helper_parser_rejects_hopping_without_a_range(self):
        # install_metadata derives enabled from len(ports) > 1, so it can never
        # emit this combination. It only happens with hand-edited or truncated
        # metadata, where the helper must refuse instead of installing a rule
        # that silently never fires.
        with tempfile.TemporaryDirectory() as directory:
            metadata = Path(directory) / "outside.install.json"
            raahctl.write_private(metadata, {
                "version": 1,
                "hysteria2_port_hopping": {
                    "enabled": True,
                    "listen_port": 8443,
                    "server_ports": ["8443:8443"],
                    "hop_interval": "30s",
                },
            })
            result = run_embedded_parser(metadata)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no hopping range is configured", result.stderr)

    def test_embedded_helper_parser_reports_a_disabled_profile(self):
        data = sample()
        with tempfile.TemporaryDirectory() as directory:
            metadata = Path(directory) / "outside.install.json"
            raahctl.write_private(metadata, raahctl.install_metadata(data, "de"))
            result = run_embedded_parser(metadata)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("enabled=0", result.stdout)
        self.assertNotIn("range=", result.stdout)

    def test_firewall_plan_opens_the_hopping_range_with_colon_syntax(self):
        data = sample()
        data["de_hy2_server_ports"] = ["8443:8443", "8444:8474"]
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "bundle"
            raahctl.write_bundle(bundle, data, False, "direct")
            plan = subprocess.run(
                [sys.executable, str(TEST_DIR.parent / "raahctl.py"), "firewall-plan", str(bundle)],
                capture_output=True, text=True)
            self.assertEqual(plan.returncode, 0, plan.stderr)
            self.assertIn("sudo ufw allow 8444:8474/udp", plan.stdout)
            self.assertIn("sudo ufw allow 8443/udp", plan.stdout)
            self.assertNotIn("8443:8443", plan.stdout)

    def test_client_health_group_contains_every_entry_and_transport(self):
        config = raahctl.make_client(sample())
        auto = next(x for x in config["outbounds"] if x["tag"] == "auto-entry")
        self.assertEqual(auto["outbounds"], ["ir1-hy2", "ir1-reality-1", "ir2-hy2", "ir2-reality-1"])
        self.assertEqual(config["route"]["final"], "auto-entry")
        self.assertTrue(config["route"]["auto_detect_interface"])
        self.assertEqual(config["inbounds"][0]["type"], "tun")
        self.assertEqual(config["inbounds"][0]["dns_mode"], "hijack")
        self.assertEqual(config["dns"]["servers"][0]["type"], "https")
        self.assertEqual(config["dns"]["servers"][0]["detour"], "auto-entry")
        self.assertEqual(config["dns"]["servers"][1]["tag"], "bootstrap-dns")
        self.assertEqual(config["route"]["default_domain_resolver"], "bootstrap-dns")

    def test_multiple_snis_create_separate_reality_ports(self):
        data = sample()
        data["de_reality_snis"] = ["www.example.org", "www.cloudflare.com"]
        data["ir_reality_snis"] = ["www.example.com", "www.microsoft.com"]
        germany = raahctl.make_germany(data)
        self.assertEqual([x["listen_port"] for x in germany["inbounds"] if x["type"] == "vless"], [7788, 7789])
        iran = raahctl.make_iran(data, data["iran_nodes"][0])
        auto = next(x for x in iran["outbounds"] if x["tag"] == "de-auto")
        self.assertEqual(auto["outbounds"], ["de-hy2", "de-reality-1", "de-reality-2"])
        client = raahctl.make_client(data)
        auto_client = next(x for x in client["outbounds"] if x["tag"] == "auto-entry")
        self.assertIn("ir1-reality-2", auto_client["outbounds"])

    def test_reverse_mode_routes_germany_entry_to_iran_exits(self):
        data = sample()
        config = raahctl.make_reverse_germany_entry(data)
        auto = next(x for x in config["outbounds"] if x["tag"] == "iran-exit-auto")
        self.assertEqual(auto["outbounds"], ["iran1-exit-hy2", "iran1-exit-reality-1", "iran2-exit-hy2", "iran2-exit-reality-1"])
        self.assertEqual(config["route"]["final"], "iran-exit-auto")
        self.assertEqual(config["inbounds"][1]["listen_port"], 7788)
        inbound_uuids = {user["uuid"] for user in config["inbounds"][1]["users"]}
        self.assertEqual(inbound_uuids, {node["user_uuid"] for node in data["iran_nodes"]})
        self.assertNotIn(data["relay_uuid"], inbound_uuids)
        client = raahctl.make_reverse_client(data)
        reality_uuids = {item["uuid"] for item in client["outbounds"] if item["type"] == "vless"}
        self.assertEqual(reality_uuids, {node["user_uuid"] for node in data["iran_nodes"]})
        self.assertNotIn(data["relay_uuid"], reality_uuids)
        self.assertEqual(client["dns"]["servers"][0]["detour"], "reverse-auto-entry")

    def test_server_routes_auto_detect_interface(self):
        data = sample()
        configs = [
            raahctl.make_germany(data),
            raahctl.make_iran(data, data["iran_nodes"][0]),
            raahctl.make_reverse_germany_entry(data),
            raahctl.make_reverse_iran_exit(data, data["iran_nodes"][0]),
        ]
        self.assertTrue(all(config["route"]["auto_detect_interface"] for config in configs))

    def test_per_side_health_urls_are_used(self):
        data = sample()
        data["de_health_url"] = "https://outside-health.example.net/204"
        data["ir_health_url"] = "https://iran-health.example.net/204"
        iran_auto = next(item for item in raahctl.make_iran(data, data["iran_nodes"][0])["outbounds"] if item["type"] == "urltest")
        client_auto = next(item for item in raahctl.make_client(data)["outbounds"] if item["type"] == "urltest")
        self.assertEqual(iran_auto["url"], data["de_health_url"])
        self.assertEqual(client_auto["url"], data["ir_health_url"])

    @unittest.skipUnless(os.name == "posix", "POSIX permission bits required")
    def test_reverse_bundle_files_are_private(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "bundle"
            raahctl.write_bundle(target, sample(), False, "reverse")
            for filename in ("reverse-outside-entry.json", "reverse-outside-entry.install.json", "reverse-iran-exit-01.json", "reverse-iran-exit-01.install.json", "reverse-iran-exit-02.json", "reverse-iran-exit-02.install.json", "reverse-client-linux.json", "secrets.json"):
                self.assertEqual((target / filename).stat().st_mode & 0o777, 0o600)
                json.loads((target / filename).read_text())

    def test_iran_node_can_override_tls_material(self):
        config = raahctl.make_iran(sample(), sample()["iran_nodes"][0])
        tls = config["inbounds"][0]["tls"]
        self.assertEqual(tls["server_name"], "ir1.example.net")
        self.assertEqual(tls["certificate_path"], "/etc/raah/ir1/fullchain.pem")
        self.assertEqual(tls["key_path"], "/etc/raah/ir1/privkey.pem")

    def test_probe_reports_latency_jitter(self):
        class FakeSocket:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False
        args = Namespace(host="127.0.0.1", port=443, count=2, interval=0, timeout=1)
        with patch.object(raahctl.socket, "create_connection", return_value=FakeSocket()), patch("sys.stdout", new_callable=io.StringIO) as out:
            self.assertEqual(raahctl.probe_endpoint(args), 0)
            data = json.loads(out.getvalue())
            self.assertEqual(data["attempts"], 2)
            self.assertEqual(data["failures"], 0)
            self.assertIn("jitter_ms_mean_deviation", data)

    def test_audit_report_groups_user_and_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "access.log"
            log.write_text(
                '{"timestamp":"2026-09-24T00:00:00Z","email":"ali","destination":"example.com:443","network":"tcp","bytes_sent":10,"bytes_received":20}\n'
                '{"timestamp":"2026-09-24T00:01:00Z","email":"ali","destination":"example.com:443","network":"tcp","bytes_sent":5,"bytes_received":7}\n',
                encoding="utf-8",
            )
            with patch("sys.stdout", new_callable=io.StringIO) as out:
                result = raahctl.audit_report(Namespace(log=str(log), user="ali"))
            self.assertEqual(result, 0)
            payload = json.loads(out.getvalue())
            self.assertEqual(payload["events"][0]["connections"], 2)
            self.assertEqual(payload["events"][0]["bytes_received"], 27)

    def test_sni_scan_ranks_successful_candidates(self):
        class FakeRaw:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

        class FakeTls:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

        class FakeContext:
            def wrap_socket(self, raw, server_hostname):
                return FakeTls()

        with patch.object(raahctl.ssl, "create_default_context", return_value=FakeContext()), patch.object(raahctl.socket, "create_connection", return_value=FakeRaw()):
            results = raahctl.scan_sni_candidates(["www.example.com"], 1, 2)
            self.assertEqual(results[0]["sni"], "www.example.com")
            self.assertEqual(results[0]["successes"], 2)

    @unittest.skipUnless(os.name == "posix", "POSIX permission bits required")
    def test_bundle_files_are_private(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "bundle"
            raahctl.write_bundle(target, sample(), False)
            for filename in ("outside.json", "outside.install.json", "iran-01.json", "iran-01.install.json", "iran-02.json", "iran-02.install.json", "client-linux.json", "secrets.json"):
                self.assertEqual((target / filename).stat().st_mode & 0o777, 0o600)
                json.loads((target / filename).read_text())
            self.assertEqual(target.stat().st_mode & 0o777, 0o700)

    def test_revoke_user_removes_matching_user(self):
        config = raahctl.make_iran(sample(), sample()["iran_nodes"][0])
        config["inbounds"][1]["users"].append({"name": "second", "uuid": "11111111-1111-4111-8111-111111111111"})
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "iran.json"
            output = Path(directory) / "iran.revoked.json"
            raahctl.write_config(source, config)
            with patch("sys.stdout", new_callable=io.StringIO):
                result = raahctl.revoke_user(Namespace(config=str(source), user="friends", out=str(output), in_place=False))
            self.assertEqual(result, 0)
            revoked = json.loads(output.read_text())
            users = raahctl.inbound_users(revoked)
            self.assertFalse(any(user.get("name") == "friends" for user in users))
            self.assertTrue(any(user.get("name") == "second" for user in users))

    def test_add_user_writes_config_and_ledger(self):
        config = raahctl.make_iran(sample(), sample()["iran_nodes"][0])
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "iran.json"
            output = Path(directory) / "iran.with-user.json"
            ledger = Path(directory) / "users.json"
            raahctl.write_config(source, config)
            args = Namespace(config=str(source), name="ali", expires_at="2026-12-31T23:59:00Z", quota_gb=50.0, ledger=str(ledger), out=str(output), in_place=False)
            with patch("sys.stdout", new_callable=io.StringIO):
                result = raahctl.add_user(args)
            self.assertEqual(result, 0)
            updated = json.loads(output.read_text())
            users = raahctl.inbound_users(updated)
            self.assertTrue(any(user.get("name") == "ali" and "password" in user for user in users))
            self.assertTrue(any(user.get("name") == "ali" and "uuid" in user for user in users))
            ledger_data = json.loads(ledger.read_text())
            self.assertEqual(ledger_data["users"][0]["quota_gb"], 50.0)

    def test_enforce_users_removes_expired_users(self):
        config = raahctl.make_iran(sample(), sample()["iran_nodes"][0])
        config["inbounds"][0]["users"].append({"name": "old", "password": "old-password"})
        config["inbounds"][1]["users"].append({"name": "old", "uuid": "11111111-1111-4111-8111-111111111111"})
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "iran.json"
            output = Path(directory) / "iran.enforced.json"
            ledger = Path(directory) / "users.json"
            raahctl.write_config(source, config)
            raahctl.write_ledger(ledger, {"version": 1, "users": [{"name": "old", "expires_at": "2000-01-01T00:00:00Z"}]})
            with patch("sys.stdout", new_callable=io.StringIO):
                result = raahctl.enforce_users(Namespace(config=str(source), ledger=str(ledger), out=str(output), in_place=False))
            self.assertEqual(result, 1)
            users = raahctl.inbound_users(json.loads(output.read_text()))
            self.assertFalse(any(user.get("name") == "old" for user in users))

    def test_firewall_plan_reads_config_ports(self):
        config = raahctl.make_iran(sample(), sample()["iran_nodes"][0])
        ports = set(raahctl.config_ports(config))
        self.assertIn(("udp", 8443), ports)
        self.assertIn(("tcp", 8877), ports)

    def test_doctor_reports_config(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "bundle"
            raahctl.write_bundle(target, sample(), False)
            with patch.object(raahctl.shutil, "which", return_value=None), patch("sys.stdout", new_callable=io.StringIO) as out:
                result = raahctl.doctor(Namespace(path=str(target), local_paths=False))
            self.assertEqual(result, 0)
            payload = json.loads(out.getvalue())
            self.assertGreaterEqual(len(payload["reports"]), 1)

    def test_wizard_emits_one_config_per_iran_node(self):
        answers = iter([
            "de.example.net", "ir1.example.net,198.51.100.2",
            "de.example.net", "ir.example.net", "www.example.org", "www.example.com",
            "", "", "", "", "", "", "", "",
            "", "", "", "", "", "", "", "", "",
        ])
        fake_result = type("Proc", (), {"stdout": "PrivateKey: private-value\nPublicKey: public-value\n"})()
        with tempfile.TemporaryDirectory() as directory, patch.object(builtins, "input", side_effect=lambda _: next(answers)), patch.object(raahctl.subprocess, "run", return_value=fake_result) as run, patch.object(raahctl, "detect_public_ip", return_value=None), patch.object(raahctl, "country_for_host", return_value=None), patch("sys.stdout", new_callable=io.StringIO):
            output = Path(directory) / "bundle"
            result = raahctl.generate(Namespace(out=str(output), force=False, advanced=True, hop=False))
            self.assertEqual(result, 0)
            self.assertEqual(run.call_count, 3)
            self.assertTrue((output / "iran-01.json").exists())
            self.assertTrue((output / "iran-02.json").exists())
            self.assertTrue((output / "client-linux.json").exists())
            first = json.loads((output / "iran-01.json").read_text())
            second = json.loads((output / "iran-02.json").read_text())
            self.assertNotEqual(first["inbounds"][1]["users"][0]["uuid"], second["inbounds"][1]["users"][0]["uuid"])

    def test_beginner_wizard_one_iran_server_needs_only_nine_answers(self):
        answers = iter([
            "203.0.113.10", "198.51.100.2", "outside.example.net", "iran.example.net",
            "", "", "", "", "",
        ])
        fake_result = type("Proc", (), {"stdout": "PrivateKey: private-value\nPublicKey: public-value\n"})()
        with tempfile.TemporaryDirectory() as directory, patch.object(builtins, "input", side_effect=lambda _: next(answers)), patch.object(raahctl.subprocess, "run", return_value=fake_result), patch.object(raahctl, "detect_public_ip", return_value=None), patch.object(raahctl, "country_for_host", return_value=None), patch("sys.stdout", new_callable=io.StringIO) as output_text:
            output = Path(directory) / "bundle"
            result = raahctl.generate(Namespace(out=str(output), force=False, hop=False))
            self.assertEqual(result, 0)
            self.assertTrue((output / "outside.json").exists())
            self.assertTrue((output / "iran-01.json").exists())
            self.assertIn("TLS certificate", output_text.getvalue())
            self.assertEqual(json.loads((output / "outside.json").read_text())["inbounds"][0]["listen_port"], 8443)

    def test_wizard_uses_local_iran_ip_only_when_role_confirmed(self):
        answers = iter(["", "203.0.113.10", "", "outside.example.net", "iran.example.net", "", "", "", "", ""])
        fake_result = type("Proc", (), {"stdout": "PrivateKey: private-value\nPublicKey: public-value\n"})()
        with tempfile.TemporaryDirectory() as directory, patch.object(builtins, "input", side_effect=lambda _: next(answers)), patch.object(raahctl.subprocess, "run", return_value=fake_result), patch.object(raahctl, "detect_public_ip", return_value="1.2.3.4"), patch.object(raahctl, "country_for_host", side_effect=lambda host: "Iran" if host == "1.2.3.4" else "Germany"), patch("sys.stdout", new_callable=io.StringIO) as output_text:
            output = Path(directory) / "bundle"
            self.assertEqual(raahctl.generate(Namespace(out=str(output), force=False, hop=False)), 0)
            self.assertEqual(json.loads((output / "secrets.json").read_text())["iran_nodes"][0]["address"], "1.2.3.4")
            self.assertIn("country: Iran", output_text.getvalue())

    def test_ip_discovery_rejects_invalid_or_private_service_response(self):
        with patch.object(raahctl.urllib.request, "urlopen", return_value=io.BytesIO(b"127.0.0.1")):
            self.assertIsNone(raahctl.detect_public_ip())
        with patch.object(raahctl.urllib.request, "urlopen", return_value=io.BytesIO(b"unexpected text")):
            self.assertIsNone(raahctl.detect_public_ip())
        with patch.object(raahctl.urllib.request, "urlopen", return_value=io.BytesIO(b"8.8.8.8")):
            self.assertEqual(raahctl.detect_public_ip(), "8.8.8.8")

    def test_ip_discovery_uses_fallback_provider(self):
        with patch.object(raahctl.urllib.request, "urlopen", side_effect=[OSError("offline"), io.BytesIO(b"8.8.4.4")]) as lookup:
            self.assertEqual(raahctl.detect_public_ip(), "8.8.4.4")
            self.assertEqual(lookup.call_count, 2)

    def test_country_lookup_uses_valid_public_ip_and_handles_api_failure(self):
        with patch.object(raahctl.urllib.request, "urlopen", return_value=io.BytesIO(b'{"success":true,"country":"Iran"}')) as lookup:
            self.assertEqual(raahctl.country_for_host("8.8.8.8"), "Iran")
            self.assertEqual(lookup.call_args.args[0], "https://ipwho.is/8.8.8.8")
        with patch.object(raahctl.urllib.request, "urlopen", return_value=io.BytesIO(b'{"success":false}')):
            self.assertIsNone(raahctl.country_for_host("8.8.8.8"))
        with patch.object(raahctl.urllib.request, "urlopen") as lookup:
            self.assertIsNone(raahctl.country_for_host("127.0.0.1"))
            lookup.assert_not_called()

    def test_e2e_probe_config_is_local_and_can_select_one_outbound(self):
        client = raahctl.make_client(sample())
        probe = raahctl.build_e2e_probe_config(client, 19080, "ir1-reality-1")
        self.assertEqual(probe["inbounds"], [{
            "type": "mixed",
            "tag": "raah-e2e-probe-in",
            "listen": "127.0.0.1",
            "listen_port": 19080,
        }])
        self.assertEqual(probe["route"]["final"], "ir1-reality-1")
        self.assertEqual(client["inbounds"][0]["type"], "tun")
        with self.assertRaises(ValueError):
            raahctl.build_e2e_probe_config(client, 19080, "missing-tag")

    @unittest.skipUnless(os.name == "posix", "POSIX permission bits required")
    def test_edit_bundle_backs_up_and_regenerates_all_matching_configs(self):
        with tempfile.TemporaryDirectory() as directory, patch("sys.stdout", new_callable=io.StringIO):
            root = Path(directory) / "bundle"
            original = sample()
            raahctl.write_bundle(root, original, False)
            args = Namespace(
                path=str(root),
                outside_address="outside-new.example.net",
                iran_address=["1=iran-new.example.net"],
                outside_hy2_port=9443,
                outside_reality_port=7798,
                iran_hy2_port=None,
                iran_reality_port=None,
                outside_sni="www.cloudflare.com,www.microsoft.com",
                iran_sni=None,
            )
            self.assertEqual(raahctl.edit_bundle(args), 0)
            updated = json.loads((root / "secrets.json").read_text())
            self.assertEqual(updated["de_address"], "outside-new.example.net")
            self.assertEqual(updated["iran_nodes"][0]["address"], "iran-new.example.net")
            self.assertEqual(updated["relay_uuid"], original["relay_uuid"])
            iran_config = json.loads((root / "iran-01.json").read_text())
            reality = next(item for item in iran_config["outbounds"] if item["tag"] == "de-reality-1")
            self.assertEqual(reality["server"], "outside-new.example.net")
            self.assertEqual(reality["server_port"], 7798)
            client = json.loads((root / "client-linux.json").read_text())
            entry = next(item for item in client["outbounds"] if item["tag"] == "ir1-reality-1")
            self.assertEqual(entry["server"], "iran-new.example.net")
            backups = list(Path(directory).glob("bundle.backup.*"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].stat().st_mode & 0o777, 0o700)
            self.assertEqual((root / "secrets.json").stat().st_mode & 0o777, 0o600)

    def test_bundle_backup_retention_keeps_only_three_newest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "bundle"
            root.mkdir()
            for index in range(5):
                (Path(directory) / f"bundle.backup.20260926T00000{index}.000000Z").mkdir()
            raahctl.prune_bundle_backups(root, 3)
            remaining = sorted(path.name for path in Path(directory).glob("bundle.backup.*"))
            self.assertEqual(remaining, [
                "bundle.backup.20260926T000002.000000Z",
                "bundle.backup.20260926T000003.000000Z",
                "bundle.backup.20260926T000004.000000Z",
            ])


if __name__ == "__main__":
    unittest.main()
