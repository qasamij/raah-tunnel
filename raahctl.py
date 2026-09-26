#!/usr/bin/env python3
"""Generate a private Raah sing-box pair bundle and run basic operational checks."""

from __future__ import annotations

import argparse
import copy
import datetime as dt
try:
    import fcntl
except ImportError:  # pragma: no cover - Raah bundle locking is POSIX-only.
    fcntl = None  # type: ignore[assignment]
import ipaddress
import json
import os
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import sys
import uuid
import time
import tempfile
import urllib.request
import urllib.parse
from pathlib import Path
from typing import Any


VERSION = "0.11.0"
DEFAULT_HEALTH_URL = "https://cp.cloudflare.com/generate_204"
# sing-quic rejects a Hysteria 2 port-hop interval below five seconds, and only
# when it dials, so `sing-box check` cannot catch a smaller value for us.
MIN_HOP_INTERVAL_SECONDS = 5.0
DOMAIN_RE = re.compile(r"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$")
DEFAULT_SNI_CANDIDATES = [
    "www.cloudflare.com",
    "www.microsoft.com",
    "www.apple.com",
    "www.amazon.com",
    "www.google.com",
    "www.gstatic.com",
    "www.speedtest.net",
]


def valid_host(value: str) -> bool:
    try:
        ipaddress.ip_address(value)
        return True
    except ValueError:
        return bool(DOMAIN_RE.fullmatch(value))


def ask(label: str, default: str | None = None) -> str:
    prompt = f"{label}{f' [{default}]' if default else ''}: "
    while True:
        value = input(prompt).strip()
        if not value and default is not None:
            value = default
        if value:
            return value
        print("This value is required.", file=sys.stderr)


def ask_port(label: str, default: int) -> int:
    while True:
        raw = ask(label, str(default))
        try:
            port = int(raw)
        except ValueError:
            port = 0
        if 1 <= port <= 65535:
            return port
        print("Choose a port from 1 to 65535.", file=sys.stderr)


def ask_positive_int(label: str, default: int, maximum: int) -> int:
    while True:
        raw = ask(label, str(default))
        try:
            value = int(raw)
        except ValueError:
            value = 0
        if 1 <= value <= maximum:
            return value
        print(f"Choose a number from 1 to {maximum}.", file=sys.stderr)


def ask_interval(label: str, default: str) -> str:
    pattern = re.compile(r"^[1-9][0-9]*(?:ms|s|m|h)$")
    while True:
        value = ask(label, default).lower()
        if pattern.fullmatch(value):
            return value
        print("Enter a sing-box duration like 10s, 15s, 1m, or 500ms.", file=sys.stderr)


def duration_seconds(value: str) -> float | None:
    match = re.fullmatch(r"([0-9]+)(ms|s|m|h)", value.strip().lower())
    if not match:
        return None
    return int(match.group(1)) * {"ms": 0.001, "s": 1.0, "m": 60.0, "h": 3600.0}[match.group(2)]


def valid_hop_interval(value: str) -> bool:
    seconds = duration_seconds(value)
    return seconds is not None and seconds >= MIN_HOP_INTERVAL_SECONDS


def ask_hop_interval(label: str, default: str) -> str:
    while True:
        value = ask_interval(label, default)
        if valid_hop_interval(value):
            return value
        print(f"Port-hop interval must be at least {MIN_HOP_INTERVAL_SECONDS}s, for example 30s or 1m.",
              file=sys.stderr)


def ask_yes_no(label: str, default: bool = True) -> bool:
    suffix = "Y/n" if default else "y/N"
    while True:
        value = input(f"{label} [{suffix}]: ").strip().lower()
        if not value:
            return default
        if value in {"y", "yes"}:
            return True
        if value in {"n", "no"}:
            return False
        print("Enter y or n.", file=sys.stderr)


def ask_host(label: str, default: str | None = None) -> str:
    while True:
        value = ask(label, default).strip().strip("[]")
        if valid_host(value):
            return value
        print("Enter a public IPv4/IPv6 address or DNS hostname.", file=sys.stderr)


def ask_name(label: str, default: str | None = None) -> str:
    while True:
        value = ask(label, default).lower().rstrip(".")
        if DOMAIN_RE.fullmatch(value):
            return value
        print("Enter a DNS hostname (not an IP address).", file=sys.stderr)


def ask_names(label: str, default: list[str] | None = None) -> list[str]:
    default_text = ",".join(default) if default else None
    while True:
        raw = ask(label, default_text).lower()
        names = list(dict.fromkeys(x.strip().rstrip(".") for x in raw.split(",") if x.strip()))
        if names and all(DOMAIN_RE.fullmatch(x) for x in names):
            return names
        print("Enter one or more comma-separated DNS hostnames.", file=sys.stderr)


def ask_hosts(label: str, default: str | None = None) -> list[str]:
    while True:
        raw = ask(label, default)
        hosts = list(dict.fromkeys(x.strip().strip("[]") for x in raw.split(",") if x.strip()))
        if hosts and all(valid_host(x) for x in hosts):
            return hosts
        print("Enter one or more comma-separated public IP addresses or DNS hostnames.", file=sys.stderr)


def ask_path(label: str, default: str) -> str:
    path = ask(label, default)
    if "\n" in path or "\x00" in path:
        raise ValueError("Certificate paths may not contain control characters.")
    return path


def valid_health_url(value: str) -> bool:
    try:
        parsed = urllib.parse.urlsplit(value)
    except ValueError:
        return False
    return parsed.scheme in {"http", "https"} and bool(parsed.hostname) and not parsed.username and not parsed.password


def ask_health_url(label: str, default: str = DEFAULT_HEALTH_URL) -> str:
    while True:
        value = ask(label, default).strip()
        if valid_health_url(value):
            return value
        print("Enter a complete HTTP(S) URL, for example https://example.com/generate_204.", file=sys.stderr)


def detect_public_ip() -> str | None:
    """Discover this host's egress address; never trust arbitrary response text."""
    services = (
        "https://api4.ipify.org",
        "https://ifconfig.me/ip",
        "https://icanhazip.com",
    )
    for url in services:
        try:
            request = urllib.request.Request(url, headers={"User-Agent": f"Raah-Tunnel/{VERSION}"})
            with urllib.request.urlopen(request, timeout=3) as response:
                value = response.read(128).decode("ascii").strip()
            address = ipaddress.ip_address(value)
            if address.is_global:
                return str(address)
        except (OSError, UnicodeError, ValueError):
            continue
    return None


def country_for_host(host: str) -> str | None:
    """Resolve a public IP and fetch its approximate country, if available."""
    try:
        try:
            addresses = [ipaddress.ip_address(host)]
        except ValueError:
            addresses = [ipaddress.ip_address(item[4][0]) for item in socket.getaddrinfo(host, None, type=socket.SOCK_STREAM)]
        address = next((ip for ip in addresses if ip.version == 4 and ip.is_global), None)
        address = address or next((ip for ip in addresses if ip.is_global), None)
        if address is None:
            return None
        # Use a canonical IP, never user-provided URL components.
        with urllib.request.urlopen(f"https://ipwho.is/{address.compressed}", timeout=3) as response:
            details = json.loads(response.read(4096))
        if not isinstance(details, dict) or details.get("success") is not True:
            return None
        name = details.get("country")
        return name if isinstance(name, str) and name and len(name) < 100 else None
    except (OSError, UnicodeError, ValueError, TypeError, json.JSONDecodeError):
        return None


def ask_server_role(default: str) -> str:
    while True:
        role = ask("Which server is THIS machine? Type Iran or Outside", default).lower()
        if role in ("iran", "outside"):
            return role
        print("Type Iran or Outside.", file=sys.stderr)


def scan_sni_candidates(candidates: list[str], timeout: float, count: int) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    context = ssl.create_default_context()
    for candidate in candidates:
        if not DOMAIN_RE.fullmatch(candidate):
            results.append({"sni": candidate, "ok": False, "error": "invalid hostname"})
            continue
        samples: list[float] = []
        errors: list[str] = []
        for _ in range(count):
            start = time.perf_counter()
            try:
                with socket.create_connection((candidate, 443), timeout=timeout) as raw:
                    with context.wrap_socket(raw, server_hostname=candidate):
                        samples.append((time.perf_counter() - start) * 1000)
            except OSError as exc:
                errors.append(str(exc))
            except ssl.SSLError as exc:
                errors.append(str(exc))
        if samples:
            avg = sum(samples) / len(samples)
            jitter = sum(abs(x - avg) for x in samples) / len(samples)
            results.append({
                "sni": candidate,
                "ok": len(errors) == 0,
                "successes": len(samples),
                "failures": len(errors),
                "latency_ms_avg": round(avg, 2),
                "jitter_ms_mean_deviation": round(jitter, 2),
                "score": round(avg + jitter + (len(errors) * 250), 2),
            })
        else:
            results.append({"sni": candidate, "ok": False, "successes": 0, "failures": len(errors), "error": errors[-1] if errors else "failed"})
    return sorted(results, key=lambda x: (not x.get("successes"), x.get("score", 10**9), x["sni"]))


def best_sni(candidates: list[str], timeout: float, count: int) -> str | None:
    for result in scan_sni_candidates(candidates, timeout, count):
        if result.get("successes"):
            return str(result["sni"])
    return None


def best_snis(candidates: list[str], timeout: float, count: int, limit: int) -> list[str]:
    results = scan_sni_candidates(candidates, timeout, count)
    return [str(result["sni"]) for result in results if result.get("successes")][:limit]


def reality_keypair() -> tuple[str, str]:
    try:
        proc = subprocess.run(
            ["sing-box", "generate", "reality-keypair"],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except FileNotFoundError as exc:
        raise RuntimeError("Install sing-box 1.14+ on this workstation to generate REALITY keys.") from exc
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"sing-box could not generate a REALITY keypair: {exc.stderr.strip()}") from exc
    values: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            values[key.strip().lower()] = value.strip()
    private = values.get("privatekey") or values.get("private_key")
    public = values.get("publickey") or values.get("public_key")
    if not private or not public:
        raise RuntimeError("Unexpected output from `sing-box generate reality-keypair`.")
    return private, public


def tls_reality_server(private: str, short_id: str, handshake: str) -> dict[str, Any]:
    return {
        "enabled": True,
        "reality": {
            "enabled": True,
            "handshake": {"server": handshake, "server_port": 443},
            "private_key": private,
            "short_id": [short_id],
        },
    }


def vless_out(host: str, port: int, user_id: str, sni: str, public_key: str, short_id: str, tag: str) -> dict[str, Any]:
    return {
        "type": "vless",
        "tag": tag,
        "server": host,
        "server_port": port,
        "uuid": user_id,
        "tls": {
            "enabled": True,
            "server_name": sni,
            "utls": {"enabled": True, "fingerprint": "chrome"},
            "reality": {"enabled": True, "public_key": public_key, "short_id": short_id},
        },
    }


def hy2_server_ports(data: dict[str, Any], side: str) -> list[str]:
    configured = data.get(f"{side}_hy2_server_ports")
    if configured:
        return normalize_port_specs(list(configured))
    return [port_spec(data[f"{side}_hy2_port"])]


def port_spec(port: int) -> str:
    return f"{int(port)}:{int(port)}"


def normalize_port_specs(values: list[Any]) -> list[str]:
    """Return canonical sing-box `start:end` specs for a list of port specs.

    sing-box splits `server_ports` entries on a colon and rejects anything
    without one, so the colon form is what we store. The legacy `start-end` form
    written by the first 0.11.0 pre-release, and bare single ports, are accepted
    here so an already generated bundle keeps working and is rewritten in the
    correct form on the next run.
    """
    specs: list[str] = []
    for value in values:
        text = str(value).strip()
        canonical = re.fullmatch(r"([0-9]{1,5}):([0-9]{1,5})", text)
        legacy = re.fullmatch(r"([0-9]{1,5})(?:-([0-9]{1,5}))?", text)
        match = canonical or legacy
        if not match:
            raise ValueError(f"Invalid Hysteria 2 UDP port spec: {value}")
        start, end = match.group(1), match.group(2) or match.group(1)
        if not 1 <= int(start) <= int(end) <= 65535:
            raise ValueError(f"Invalid Hysteria 2 UDP port spec: {value}")
        specs.append(f"{int(start)}:{int(end)}")
    if not specs:
        raise ValueError("Hysteria 2 port hopping needs at least one UDP port spec.")
    return specs


def parse_port_specs(specs: list[Any]) -> list[tuple[int, int]]:
    """Parse port specs into inclusive (start, end) ranges.

    nftables spells a range with a dash instead of a colon, so
    scripts/port-hop.sh performs that translation when it builds its ruleset.
    """
    return [(int(spec.split(":")[0]), int(spec.split(":")[1]))
            for spec in normalize_port_specs(specs)]


def build_hy2_server_ports(base: int, count: int) -> list[str]:
    """Return sing-box port specs covering `count` consecutive UDP ports."""
    if count <= 1:
        return [port_spec(base)]
    end = base + count - 1
    if end > 65535:
        raise ValueError("Hysteria 2 hopping range exceeds port 65535; lower the base port or range size.")
    return [port_spec(base), f"{base + 1}:{end}"]


def hy2_port_ranges(data: dict[str, Any], side: str) -> list[tuple[int, int]]:
    return parse_port_specs(hy2_server_ports(data, side))


def install_metadata(data: dict[str, Any], side: str) -> dict[str, Any]:
    ports = hy2_server_ports(data, side)
    return {
        "version": 1,
        "hysteria2_port_hopping": {
            "enabled": len(ports) > 1,
            "listen_port": int(data[f"{side}_hy2_port"]),
            "server_ports": ports,
            "hop_interval": str(data.get("hy2_hop_interval", "30s")),
        },
    }


def hy2_port_line(data: dict[str, Any], side: str, label: str) -> str:
    ports = hy2_server_ports(data, side)
    if len(ports) == 1:
        start, end = hy2_port_ranges(data, side)[0]
        shown = str(start) if start == end else f"{start}-{end}"
        return f"{label}: UDP/{shown} (Hysteria 2)"
    shown = ",".join(str(start) if start == end else f"{start}-{end}"
                     for start, end in hy2_port_ranges(data, side))
    return f"{label}: UDP/{shown} (Hysteria 2 port hopping; open the complete range)"


def hysteria_out(host: str, data: dict[str, Any], side: str, password: str, obfs_password: str, sni: str, tag: str) -> dict[str, Any]:
    ports = hy2_server_ports(data, side)
    outbound: dict[str, Any] = {
        "type": "hysteria2",
        "tag": tag,
        "server": host,
        "password": password,
        "obfs": {"type": "salamander", "password": obfs_password},
        "tls": {"enabled": True, "server_name": sni, "alpn": ["h3"]},
    }
    ranges = hy2_port_ranges(data, side)
    if len(ranges) == 1:
        start, end = ranges[0]
        if start != end:
            raise ValueError(f"Hysteria 2 needs at least two UDP ports to hop, got {start}:{end}.")
        outbound["server_port"] = start
    else:
        outbound["server_ports"] = ports
        outbound["hop_interval"] = str(data.get("hy2_hop_interval", "30s"))
    return outbound


def server_common() -> dict[str, Any]:
    return {"log": {"level": "info", "timestamp": True}}


def health_interval(data: dict[str, Any]) -> str:
    return str(data.get("health_interval", "15s"))


def health_url(data: dict[str, Any], side: str) -> str:
    return str(data.get(f"{side}_health_url") or data.get("health_url") or DEFAULT_HEALTH_URL)


def reality_snis(data: dict[str, Any], side: str) -> list[str]:
    key = f"{side}_reality_snis"
    legacy_key = f"{side}_reality_sni"
    values = data.get(key) or [data[legacy_key]]
    return list(dict.fromkeys(str(x).lower().rstrip(".") for x in values if str(x).strip()))


def reality_port(data: dict[str, Any], side: str, index: int) -> int:
    return int(data[f"{side}_reality_port"]) + index


def reality_inbounds(data: dict[str, Any], side: str, users: dict[str, str] | list[dict[str, str]], key_owner: dict[str, str], tag_prefix: str) -> list[dict[str, Any]]:
    private_key = key_owner["reality_private"] if side == "ir" else data["de_reality_private"]
    short_id = key_owner["short_id"] if side == "ir" else data["de_short_id"]
    user_list = [users] if isinstance(users, dict) else users
    return [
        {
            "type": "vless",
            "tag": f"{tag_prefix}-reality-in-{index + 1}",
            "listen": "::",
            "listen_port": reality_port(data, side, index),
            "users": copy.deepcopy(user_list),
            "tls": tls_reality_server(private_key, short_id, sni),
        }
        for index, sni in enumerate(reality_snis(data, side))
    ]


def reality_outbounds(host: str, data: dict[str, Any], side: str, user_id: str, public_key: str, short_id: str, tag_prefix: str) -> list[dict[str, Any]]:
    return [
        vless_out(host, reality_port(data, side, index), user_id, sni, public_key, short_id, f"{tag_prefix}-reality-{index + 1}")
        for index, sni in enumerate(reality_snis(data, side))
    ]


def reality_port_lines(data: dict[str, Any], side: str, label: str) -> list[str]:
    return [
        f"{label}: TCP/{reality_port(data, side, index)} (VLESS/REALITY, SNI {sni})"
        for index, sni in enumerate(reality_snis(data, side))
    ]


def make_germany(data: dict[str, Any]) -> dict[str, Any]:
    inbounds = [
        {
            "type": "hysteria2",
            "tag": "relay-hy2-in",
            "listen": "::",
            "listen_port": data["de_hy2_port"],
            "users": [{"name": "iran-relay", "password": data["relay_password"]}],
            "obfs": {"type": "salamander", "password": data["relay_obfs"]},
            "tls": {
                "enabled": True,
                "server_name": data["de_tls_name"],
                "certificate_path": data["de_cert"],
                "key_path": data["de_key"],
                "alpn": ["h3"],
            },
        },
        *reality_inbounds(data, "de", {"name": "iran-relay", "uuid": data["relay_uuid"]}, data, "relay"),
    ]
    return {
        **server_common(),
        "inbounds": inbounds,
        "outbounds": [{"type": "direct", "tag": "direct"}],
        "route": {"final": "direct", "auto_detect_interface": True},
    }


def make_reverse_germany_entry(data: dict[str, Any]) -> dict[str, Any]:
    outbounds: list[dict[str, Any]] = []
    tags: list[str] = []
    for index, node in enumerate(data["iran_nodes"], 1):
        hy_tag = f"iran{index}-exit-hy2"
        outbounds.append(hysteria_out(node["address"], data, "ir", data["relay_password"], data["relay_obfs"], node.get("tls_name", data["ir_tls_name"]), hy_tag))
        reality_paths = reality_outbounds(node["address"], data, "ir", data["relay_uuid"], node["reality_public"], node["short_id"], f"iran{index}-exit")
        outbounds.extend(reality_paths)
        tags.extend([hy_tag, *[path["tag"] for path in reality_paths]])
    outbounds.append(
        {
            "type": "urltest",
            "tag": "iran-exit-auto",
            "outbounds": tags,
            "url": health_url(data, "ir"),
            "interval": health_interval(data),
            "tolerance": 100,
            "interrupt_exist_connections": False,
        }
    )
    return {
        **server_common(),
        "inbounds": [
            {
                "type": "hysteria2",
                "tag": "reverse-user-hy2-in",
                "listen": "::",
                "listen_port": data["de_hy2_port"],
                "users": [{"name": f"reverse-user-{index}", "password": node["user_password"]} for index, node in enumerate(data["iran_nodes"], 1)],
                "obfs": {"type": "salamander", "password": data["relay_obfs"]},
                "tls": {
                    "enabled": True,
                    "server_name": data["de_tls_name"],
                    "certificate_path": data["de_cert"],
                    "key_path": data["de_key"],
                    "alpn": ["h3"],
                },
            },
            *reality_inbounds(
                data,
                "de",
                [{"name": f"reverse-user-{index}", "uuid": node["user_uuid"]} for index, node in enumerate(data["iran_nodes"], 1)],
                data,
                "reverse-user",
            ),
        ],
        "outbounds": outbounds,
        "route": {"final": "iran-exit-auto", "auto_detect_interface": True},
    }


def make_reverse_iran_exit(data: dict[str, Any], node: dict[str, Any]) -> dict[str, Any]:
    return {
        **server_common(),
        "inbounds": [
            {
                "type": "hysteria2",
                "tag": "reverse-relay-hy2-in",
                "listen": "::",
                "listen_port": data["ir_hy2_port"],
                "users": [{"name": "outside-reverse-relay", "password": data["relay_password"]}],
                "obfs": {"type": "salamander", "password": data["relay_obfs"]},
                "tls": {
                    "enabled": True,
                    "server_name": node.get("tls_name", data["ir_tls_name"]),
                    "certificate_path": node.get("cert", data["ir_cert"]),
                    "key_path": node.get("key", data["ir_key"]),
                    "alpn": ["h3"],
                },
            },
            *reality_inbounds(data, "ir", {"name": "outside-reverse-relay", "uuid": data["relay_uuid"]}, node, "reverse-relay"),
        ],
        "outbounds": [{"type": "direct", "tag": "direct"}],
        "route": {"final": "direct", "auto_detect_interface": True},
    }


def make_reverse_client(data: dict[str, Any]) -> dict[str, Any]:
    outbounds: list[dict[str, Any]] = []
    tags: list[str] = []
    for index, node in enumerate(data["iran_nodes"], 1):
        hy_tag = f"de-reverse-user{index}-hy2"
        outbounds.append(hysteria_out(data["de_address"], data, "de", node["user_password"], data["relay_obfs"], data["de_tls_name"], hy_tag))
        reality_paths = reality_outbounds(data["de_address"], data, "de", node["user_uuid"], data["de_reality_public"], data["de_short_id"], f"de-reverse-user{index}")
        outbounds.extend(reality_paths)
        tags.extend([hy_tag, *[path["tag"] for path in reality_paths]])
    outbounds.append(
        {
            "type": "urltest",
            "tag": "reverse-auto-entry",
            "outbounds": tags,
            "url": health_url(data, "de"),
            "interval": health_interval(data),
            "tolerance": 100,
            "interrupt_exist_connections": False,
        }
    )
    client = make_client({**data, "iran_nodes": []})
    client["outbounds"] = outbounds
    client["route"]["final"] = "reverse-auto-entry"
    client["dns"]["servers"][0]["detour"] = "reverse-auto-entry"
    return client


def make_iran(data: dict[str, Any], node: dict[str, Any]) -> dict[str, Any]:
    de_reality_paths = reality_outbounds(data["de_address"], data, "de", data["relay_uuid"], data["de_reality_public"], data["de_short_id"], "de")
    outbounds = [
        hysteria_out(data["de_address"], data, "de", data["relay_password"], data["relay_obfs"], data["de_tls_name"], "de-hy2"),
        *de_reality_paths,
        {
            "type": "urltest",
            "tag": "de-auto",
            "outbounds": ["de-hy2", *[path["tag"] for path in de_reality_paths]],
            "url": health_url(data, "de"),
            "interval": health_interval(data),
            "tolerance": 100,
            "interrupt_exist_connections": False,
        },
    ]
    return {
        **server_common(),
        "inbounds": [
            {
                "type": "hysteria2",
                "tag": "user-hy2-in",
                "listen": "::",
                "listen_port": data["ir_hy2_port"],
                "users": [{"name": "friends", "password": node["user_password"]}],
                "obfs": {"type": "salamander", "password": node["user_obfs"]},
                "tls": {
                    "enabled": True,
                    "server_name": node.get("tls_name", data["ir_tls_name"]),
                    "certificate_path": node.get("cert", data["ir_cert"]),
                    "key_path": node.get("key", data["ir_key"]),
                    "alpn": ["h3"],
                },
            },
            *reality_inbounds(data, "ir", {"name": "friends", "uuid": node["user_uuid"]}, node, "user"),
        ],
        "outbounds": outbounds,
        "route": {"final": "de-auto", "auto_detect_interface": True},
    }


def make_client(data: dict[str, Any]) -> dict[str, Any]:
    outbounds: list[dict[str, Any]] = []
    tags: list[str] = []
    for index, node in enumerate(data["iran_nodes"], 1):
        host = node["address"]
        hy_tag = f"ir{index}-hy2"
        outbounds.append(hysteria_out(host, data, "ir", node["user_password"], node["user_obfs"], node.get("tls_name", data["ir_tls_name"]), hy_tag))
        reality_paths = reality_outbounds(host, data, "ir", node["user_uuid"], node["reality_public"], node["short_id"], f"ir{index}")
        outbounds.extend(reality_paths)
        tags.extend([hy_tag, *[path["tag"] for path in reality_paths]])
    outbounds.append(
        {
            "type": "urltest",
            "tag": "auto-entry",
            "outbounds": tags,
            "url": health_url(data, "ir"),
            "interval": health_interval(data),
            "tolerance": 100,
            "interrupt_exist_connections": False,
        }
    )
    return {
        **server_common(),
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "interface_name": "raah0",
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                "mtu": 1380,
                "dns_mode": "hijack",
                "auto_route": True,
                "auto_redirect": True,
                "strict_route": True,
            }
        ],
        "outbounds": outbounds,
        "dns": {
            "servers": [
                {
                    "type": "https",
                    "tag": "secure-dns",
                    "server": "1.1.1.1",
                    "server_port": 443,
                    "path": "/dns-query",
                    "tls": {"enabled": True, "server_name": "cloudflare-dns.com"},
                    "detour": "auto-entry",
                },
                {"type": "local", "tag": "bootstrap-dns"},
            ],
            "final": "secure-dns",
            "strategy": "prefer_ipv4",
            "optimistic": {"enabled": True, "timeout": "3d"},
        },
        "route": {"final": "auto-entry", "auto_detect_interface": True, "default_domain_resolver": "bootstrap-dns"},
    }


def secure_write_json(path: Path, value: dict[str, Any]) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags, 0o600)
    try:
        if hasattr(os, "fchmod"):
            os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = -1
            json.dump(value, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
    finally:
        if fd >= 0:
            os.close(fd)


def write_private(path: Path, value: dict[str, Any]) -> None:
    secure_write_json(path, value)


def write_bundle(dest: Path, data: dict[str, Any], force: bool, mode: str = "direct") -> None:
    if dest.exists() and any(dest.iterdir()) and not force:
        raise RuntimeError(f"{dest} already exists and is not empty; choose a new path or pass --force.")
    dest.mkdir(parents=True, exist_ok=True, mode=0o700)
    dest.chmod(0o700)
    if mode == "both":
        write_bundle(dest / "direct", data, force, "direct")
        write_bundle(dest / "reverse", data, force, "reverse")
        write_private(dest / "secrets.json", data)
        notes = """Raah combined bundle
====================

This directory contains separate direct and reverse bundles.

- direct/: clients enter through Iran and Outside exits to the Internet.
- reverse/: clients enter through Outside and one of the Iran nodes exits.

Do not run both modes on the same numeric ports on the same host. If you need
both live at once, generate or edit one mode to use different ports first.
Use separated REALITY base ports to keep the two sides readable; for example,
Outside TCP/7788 and Iran TCP/8877. Extra SNI fallbacks use the next ports in
order.
"""
        (dest / "DEPLOY.txt").write_text(notes, encoding="utf-8")
        (dest / "DEPLOY.txt").chmod(0o600)
        return
    if force:
        managed = ["outside.json", "outside.install.json", "germany.json", "client-linux.json", "secrets.json", "DEPLOY.txt", *[p.name for p in dest.glob("iran-[0-9][0-9].json")], *[p.name for p in dest.glob("iran-[0-9][0-9].install.json")]]
        managed.extend(["reverse-outside-entry.json", "reverse-outside-entry.install.json", "reverse-germany-entry.json", "reverse-client-linux.json", *[p.name for p in dest.glob("reverse-iran-exit-[0-9][0-9].json")], *[p.name for p in dest.glob("reverse-iran-exit-[0-9][0-9].install.json")]])
        for name in managed:
            (dest / name).unlink(missing_ok=True)
    if mode == "reverse":
        write_private(dest / "reverse-outside-entry.json", make_reverse_germany_entry(data))
        write_private(dest / "reverse-outside-entry.install.json", install_metadata(data, "de"))
        for index, node in enumerate(data["iran_nodes"], 1):
            write_private(dest / f"reverse-iran-exit-{index:02d}.json", make_reverse_iran_exit(data, node))
            write_private(dest / f"reverse-iran-exit-{index:02d}.install.json", install_metadata(data, "ir"))
        write_private(dest / "reverse-client-linux.json", make_reverse_client(data))
        write_private(dest / "secrets.json", data)
        ports = [
            hy2_port_line(data, "de", "Outside entry"),
            *reality_port_lines(data, "de", "Outside entry"),
            *[line for index, _ in enumerate(data["iran_nodes"], 1) for line in [hy2_port_line(data, "ir", f"Iran exit {index}"), *reality_port_lines(data, "ir", f"Iran exit {index}")]],
        ]
        notes = """Raah private reverse deployment bundle
======================================

Reverse mode changes the public entry side: clients connect to Outside, then
Outside selects a healthy Iran exit. Use this when you want to test the opposite
traffic direction or keep direct and reverse profiles as separate options.

1. Copy each server JSON together with its matching `.install.json` file.
   Copy reverse-outside-entry.* to Outside and reverse-iran-exit-01.* to its
   matching Iranian host. Protect them as secrets (mode 0600).
2. Install sing-box 1.14+ from the official project/package source.
3. Ensure each host has the certificate/key paths entered in the wizard.
4. On each server run: sudo sing-box check -c /etc/raah/config.json
5. Open exactly the protocol/port pairs listed below in host and provider
   firewalls.
6. Import reverse-client-linux.json into a sing-box-compatible client that
   supports TUN.

Port planning tip: use separated REALITY base ports to avoid confusion, for
example Outside TCP/7788 and Iran TCP/8877. If you enter multiple REALITY SNIs,
Raah uses the base port and the next ports in order.

Required exposed ports:
""" + "\n".join(f"  - {line}" for line in ports) + "\n"
        (dest / "DEPLOY.txt").write_text(notes, encoding="utf-8")
        (dest / "DEPLOY.txt").chmod(0o600)
        return
    write_private(dest / "outside.json", make_germany(data))
    write_private(dest / "outside.install.json", install_metadata(data, "de"))
    for index, node in enumerate(data["iran_nodes"], 1):
        write_private(dest / f"iran-{index:02d}.json", make_iran(data, node))
        write_private(dest / f"iran-{index:02d}.install.json", install_metadata(data, "ir"))
    write_private(dest / "client-linux.json", make_client(data))
    write_private(dest / "secrets.json", data)
    ports = [
        hy2_port_line(data, "de", "Outside"),
        *reality_port_lines(data, "de", "Outside"),
        *[line for index, _ in enumerate(data["iran_nodes"], 1) for line in [hy2_port_line(data, "ir", f"Iran node {index}"), *reality_port_lines(data, "ir", f"Iran node {index}")]],
    ]
    notes = """Raah private deployment bundle
================================

1. Copy each server JSON together with its matching `.install.json` file.
   Copy outside.* to Outside and iran-01.* to the matching Iranian entry.
   Each entry has its own keys and credentials; do not swap the files.
2. Install sing-box 1.14+ from the official project/package source.
3. Ensure each host has the certificate/key paths entered in the wizard.
4. On each server run: sudo sing-box check -c /etc/raah/config.json
5. Run the service only after checking the output and opening exactly the
   protocol/port pairs listed below in both host and provider firewalls.
6. Import client-linux.json into a sing-box-compatible client that supports
   TUN. It contains credentials: deliver privately, never commit it.

Port planning tip: use separated REALITY base ports to avoid confusion, for
example Outside TCP/7788 and Iran TCP/8877. If you enter multiple REALITY SNIs,
Raah uses the base port and the next ports in order.

Do not replace x-ui files or services. Keep Raah on its own config path and
systemd unit. Existing connections can reset on failover.

Required exposed ports:
""" + "\n".join(f"  - {line}" for line in ports) + "\n"
    (dest / "DEPLOY.txt").write_text(notes, encoding="utf-8")
    (dest / "DEPLOY.txt").chmod(0o600)


def generate(args: argparse.Namespace) -> int:
    print(f"Raah Tunnel {VERSION} | Iran / Outside setup")
    print("Create this pair once. Keep the generated files private.")
    print("Outside = destination server; Iran = entry server (for Direct mode).")
    print("Press Enter to use values in [brackets]. One Iran server needs one IP.")
    print("IMPORTANT: Hysteria 2 needs a real DNS name and matching TLS certificate")
    print("and private key on EACH server. This wizard does not issue certificates.\n")
    try:
        d: dict[str, Any] = {}
        mode = getattr(args, "mode", "direct")
        advanced = getattr(args, "advanced", False)
        sni_defaults: list[str] | None = None
        if getattr(args, "auto_sni", False):
            candidates = [x.strip().lower().rstrip(".") for x in getattr(args, "sni_candidates", "").split(",") if x.strip()] or DEFAULT_SNI_CANDIDATES
            print("Scanning REALITY SNI candidates from this machine...")
            sni_defaults = best_snis(candidates, getattr(args, "sni_timeout", 3.0), getattr(args, "sni_count", 2), getattr(args, "sni_pool_size", 3))
            if sni_defaults:
                print(f"Suggested REALITY SNI pool: {', '.join(sni_defaults)}")
            else:
                print("No reachable SNI candidate was found; enter SNI values manually.")
        print("STEP 1/3 - PUBLIC ADDRESSES")
        print("Detecting the public IP of this server...")
        local_ip = None if getattr(args, "no_discovery", False) else detect_public_ip()
        local_role = None
        if local_ip:
            local_country = country_for_host(local_ip)
            print(f"Detected this server: {local_ip} | country: {local_country or 'unknown'}")
            print("The detected IP may belong to a proxy/NAT; check it against your VPS panel.")
            suggested_role = "Iran" if local_country and local_country.lower() == "iran" else "Outside"
            local_role = ask_server_role(suggested_role)
        else:
            print("Automatic public IP detection unavailable. Enter both server addresses manually.")
        d["de_address"] = ask_host("Outside server PUBLIC IP or domain",
                                   local_ip if local_role == "outside" else None)
        iran_addresses = ask_hosts("Iran server PUBLIC IP (one IP; separate multiple servers with commas)",
                                   local_ip if local_role == "iran" else None)
        if d["de_address"] in iran_addresses:
            raise ValueError("Iran and Outside cannot use the same public address. Check both VPS IPs.")
        if not getattr(args, "no_discovery", False):
            print(f"Outside: {d['de_address']} | country: {country_for_host(d['de_address']) or 'unknown'}")
            for index, address in enumerate(iran_addresses, 1):
                print(f"Iran server {index}: {address} | country: {country_for_host(address) or 'unknown'}")
            print("Country is an approximate IP lookup, not proof of the physical server location.")
        print("\nSTEP 2/3 - TLS DOMAINS (DNS must point to the matching server)")
        print("These are YOUR domains for the Hysteria 2 certificates, not the REALITY SNI.")
        d["de_tls_name"] = ask_name("Outside server certificate domain (example: outside.example.com)")
        d["ir_tls_name"] = ask_name("Iran server certificate domain (example: iran.example.com)")
        print("\nSTEP 3/3 - PORTS AND REALITY SNI")
        print("REALITY SNI is a reachable public website name; it is NOT your server IP.")
        d["de_reality_snis"] = ask_names("REALITY SNI (example: www.cloudflare.com)", sni_defaults or ["www.cloudflare.com"])
        d["ir_reality_snis"] = (ask_names("Iran REALITY SNI list (comma-separated)", d["de_reality_snis"])
                                if advanced else d["de_reality_snis"][:])
        d["de_reality_sni"] = d["de_reality_snis"][0]
        d["ir_reality_sni"] = d["ir_reality_snis"][0]
        d["de_hy2_port"] = ask_port("Outside server Hysteria 2 UDP port", 8443)
        d["de_reality_port"] = ask_port("Outside server REALITY TCP port", 7788)
        d["ir_hy2_port"] = ask_port("Iran server Hysteria 2 UDP port", 8443)
        d["ir_reality_port"] = ask_port("Iran server REALITY TCP port", 8877)
        hop_choice = getattr(args, "hop", None)
        if hop_choice is None:
            hop_choice = ask_yes_no("Enable coordinated Hysteria 2 UDP port hopping", True)
        hop_count = int(getattr(args, "hop_count", 32))
        if advanced and hop_choice:
            hop_count = ask_positive_int("UDP ports per Hysteria 2 hopping range", hop_count, 256)
        if hop_count < 2 and hop_choice:
            raise ValueError("Port hopping needs at least 2 UDP ports.")
        d["hy2_hop_enabled"] = bool(hop_choice)
        d["hy2_hop_count"] = hop_count if hop_choice else 1
        d["hy2_hop_interval"] = (ask_hop_interval("Hysteria 2 port-hop interval", "30s")
                                 if advanced and hop_choice else "30s")
        d["de_hy2_server_ports"] = build_hy2_server_ports(d["de_hy2_port"], d["hy2_hop_count"])
        d["ir_hy2_server_ports"] = build_hy2_server_ports(d["ir_hy2_port"], d["hy2_hop_count"])
        print("Open these ports in the VPS provider firewall as well as the server firewall.")
        if hop_choice:
            print(f"Outside UDP hopping ports: {','.join(d['de_hy2_server_ports'])}")
            print(f"Iran UDP hopping ports: {','.join(d['ir_hy2_server_ports'])}")
            print("The installer creates host DNAT; you MUST open each complete UDP range in the VPS provider firewall.")
        if len(d["de_reality_snis"]) > 1:
            print("Each extra SNI also uses the next TCP port on each server.")
        for prefix, label in (("de", "Outside"), ("ir", "Iran")):
            if d[f"{prefix}_reality_port"] + len(d[f"{prefix}_reality_snis"]) - 1 > 65535:
                raise ValueError(f"{label} REALITY fallback ports exceed 65535; choose a lower base port.")
        d["health_interval"] = ask_interval("Health-check interval", "15s") if advanced else "15s"
        d["de_health_url"] = (ask_health_url("Health URL used to test Outside paths")
                              if advanced else DEFAULT_HEALTH_URL)
        d["ir_health_url"] = (ask_health_url("Health URL used to test Iran paths")
                              if advanced else DEFAULT_HEALTH_URL)
        if advanced:
            d["de_cert"] = ask_path("Outside server certificate path", "/etc/raah/tls/fullchain.pem")
            d["de_key"] = ask_path("Outside server TLS private key path", "/etc/raah/tls/privkey.pem")
            d["ir_cert"] = ask_path("Iran server certificate path", "/etc/raah/tls/fullchain.pem")
            d["ir_key"] = ask_path("Iran server TLS private key path", "/etc/raah/tls/privkey.pem")
        else:
            d["de_cert"] = d["ir_cert"] = "/etc/raah/tls/fullchain.pem"
            d["de_key"] = d["ir_key"] = "/etc/raah/tls/privkey.pem"
            print("TLS paths on EACH server: /etc/raah/tls/fullchain.pem and /etc/raah/tls/privkey.pem")
            print("Use --advanced if your certificate files have different paths.")
        print("\nGenerating the destination/outside REALITY keypair with the local sing-box binary...")
        d["de_reality_private"], d["de_reality_public"] = reality_keypair()
        d["de_short_id"] = secrets.token_hex(8)
        d["relay_uuid"] = str(uuid.uuid4())
        d["relay_password"] = secrets.token_urlsafe(32)
        d["relay_obfs"] = secrets.token_urlsafe(32)
        d["iran_nodes"] = []
        for index, address in enumerate(iran_addresses, 1):
            print(f"Generating an independent REALITY keypair for Iran entry {index} ({address})...")
            private, public = reality_keypair()
            node_tls_name = (ask_name(f"Iran server {index} TLS certificate domain", d["ir_tls_name"])
                             if advanced or len(iran_addresses) > 1 else d["ir_tls_name"])
            node_cert = ask_path(f"Iran server {index} certificate path", d["ir_cert"]) if advanced else d["ir_cert"]
            node_key = ask_path(f"Iran server {index} TLS private key path", d["ir_key"]) if advanced else d["ir_key"]
            d["iran_nodes"].append({
                "address": address,
                "tls_name": node_tls_name,
                "cert": node_cert,
                "key": node_key,
                "reality_private": private,
                "reality_public": public,
                "short_id": secrets.token_hex(8),
                "user_uuid": str(uuid.uuid4()),
                "user_password": secrets.token_urlsafe(32),
                "user_obfs": secrets.token_urlsafe(32),
            })
        if d["de_hy2_port"] == d["de_reality_port"]:
            print("Note: destination/outside uses separate UDP/TCP transports; sharing a port number is valid.")
        if d["ir_hy2_port"] == d["ir_reality_port"]:
            print("Note: Iran uses separate UDP/TCP transports; sharing a port number is valid.")
        write_bundle(Path(args.out), d, args.force, mode)
    except (EOFError, KeyboardInterrupt):
        print("\nCancelled.", file=sys.stderr)
        return 130
    except (RuntimeError, ValueError, OSError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2
    print(f"\nPrivate {getattr(args, 'mode', 'direct')} bundle written to {args.out} (directory mode 0700; files mode 0600).")
    print("NEXT: Read DEPLOY.txt; install the matching JSON on each server.")
    print("Ensure TLS files exist on BOTH servers, then open the listed TCP/UDP ports.")
    print("The tunnel is not active until both services are installed and started.")
    return 0


def bundle_mode(path: Path) -> str:
    if (path / "direct").is_dir() and (path / "reverse").is_dir():
        return "both"
    if (path / "reverse-outside-entry.json").is_file():
        return "reverse"
    if (path / "outside.json").is_file():
        return "direct"
    raise ValueError("Unable to identify bundle mode (direct, reverse, or both).")


def protect_private_tree(path: Path) -> None:
    path.chmod(0o700)
    for item in path.rglob("*"):
        item.chmod(0o700 if item.is_dir() else 0o600)


def prune_bundle_backups(root: Path, retain: int = 3) -> None:
    backups = sorted(root.parent.glob(f"{root.name}.backup.*"), key=lambda item: item.name, reverse=True)
    for old in backups[retain:]:
        if old.is_dir() and old.parent == root.parent and old.name.startswith(f"{root.name}.backup."):
            shutil.rmtree(old)


def parse_indexed_host(value: str) -> tuple[int, str]:
    try:
        index_text, host = value.split("=", 1)
        index = int(index_text)
    except (ValueError, TypeError) as exc:
        raise ValueError("Iran address must use INDEX=HOST, for example 1=203.0.113.20.") from exc
    host = host.strip().strip("[]")
    if index < 1 or not valid_host(host):
        raise ValueError("Iran address must use a positive index and a valid public IP/domain.")
    return index, host


def parse_sni_list(value: str) -> list[str]:
    names = list(dict.fromkeys(item.strip().lower().rstrip(".") for item in value.split(",") if item.strip()))
    if not names or not all(DOMAIN_RE.fullmatch(item) for item in names):
        raise ValueError("SNI must contain one or more comma-separated DNS hostnames.")
    return names


def edit_bundle(args: argparse.Namespace) -> int:
    root = Path(args.path).expanduser().resolve()
    secrets_path = root / "secrets.json"
    lock_handle = None
    try:
        if fcntl is None:
            raise ValueError("Bundle editing requires a POSIX system such as Ubuntu/Linux.")
        if not root.is_dir() or not secrets_path.is_file():
            raise ValueError("Choose a generated bundle directory containing secrets.json.")
        lock_path = root / ".edit.lock"
        lock_handle = lock_path.open("a+", encoding="utf-8")
        lock_path.chmod(0o600)
        try:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ValueError("Another process is already editing this bundle.") from exc
        mode = bundle_mode(root)
        data = json.loads(secrets_path.read_text(encoding="utf-8"))
        if not isinstance(data, dict) or not isinstance(data.get("iran_nodes"), list) or not data["iran_nodes"]:
            raise ValueError("The bundle secrets file is incomplete.")

        changes: dict[str, Any] = {}
        iran_changes: list[str] = list(args.iran_address or [])
        outside_health_url = getattr(args, "outside_health_url", None)
        iran_health_url = getattr(args, "iran_health_url", None)
        hop_mode = getattr(args, "hop", None)
        hop_count = getattr(args, "hop_count", None)
        hop_interval = getattr(args, "hop_interval", None)
        if not any((args.outside_address, iran_changes, args.outside_hy2_port,
                    args.outside_reality_port, args.iran_hy2_port,
                    args.iran_reality_port, args.outside_sni, args.iran_sni,
                    outside_health_url, iran_health_url, hop_mode,
                    hop_count, hop_interval)):
            print(f"Bundle: {root} | mode: {mode}")
            print(f"1) Outside address: {data['de_address']}")
            for index, node in enumerate(data["iran_nodes"], 1):
                print(f"2.{index}) Iran server {index} address: {node['address']}")
            print(f"3) Outside Hysteria 2 UDP port: {data['de_hy2_port']}")
            print(f"4) Outside REALITY TCP base port: {data['de_reality_port']}")
            print(f"5) Iran Hysteria 2 UDP port: {data['ir_hy2_port']}")
            print(f"6) Iran REALITY TCP base port: {data['ir_reality_port']}")
            print(f"7) Outside REALITY SNI list: {','.join(reality_snis(data, 'de'))}")
            print(f"8) Iran REALITY SNI list: {','.join(reality_snis(data, 'ir'))}")
            print(f"9) Outside-path health URL: {health_url(data, 'de')}")
            print(f"10) Iran-path health URL: {health_url(data, 'ir')}")
            print(f"11) Hysteria 2 port hopping: {'enabled' if len(hy2_server_ports(data, 'de')) > 1 else 'disabled'}")
            print("0) Cancel")
            choice = ask("Select one setting to edit")
            if choice == "0":
                print("Cancelled.")
                return 0
            if choice == "1":
                args.outside_address = ask_host("New Outside public IP or domain", data["de_address"])
            elif choice.startswith("2"):
                parts = choice.split(".", 1)
                index = int(parts[1]) if len(parts) == 2 and parts[1].isdigit() else 1
                if not 1 <= index <= len(data["iran_nodes"]):
                    raise ValueError("Iran server index is out of range.")
                new_host = ask_host(f"New Iran server {index} public IP or domain", data["iran_nodes"][index - 1]["address"])
                iran_changes.append(f"{index}={new_host}")
            elif choice in {"3", "4", "5", "6"}:
                mapping = {
                    "3": ("outside_hy2_port", "New Outside Hysteria 2 UDP port", data["de_hy2_port"]),
                    "4": ("outside_reality_port", "New Outside REALITY TCP base port", data["de_reality_port"]),
                    "5": ("iran_hy2_port", "New Iran Hysteria 2 UDP port", data["ir_hy2_port"]),
                    "6": ("iran_reality_port", "New Iran REALITY TCP base port", data["ir_reality_port"]),
                }
                attribute, label, current = mapping[choice]
                setattr(args, attribute, ask_port(label, int(current)))
            elif choice == "7":
                args.outside_sni = ask("New Outside REALITY SNI list, comma-separated", ",".join(reality_snis(data, "de")))
            elif choice == "8":
                args.iran_sni = ask("New Iran REALITY SNI list, comma-separated", ",".join(reality_snis(data, "ir")))
            elif choice == "9":
                outside_health_url = ask_health_url("New Outside-path health URL", health_url(data, "de"))
            elif choice == "10":
                iran_health_url = ask_health_url("New Iran-path health URL", health_url(data, "ir"))
            elif choice == "11":
                enabled = ask_yes_no("Enable coordinated Hysteria 2 UDP port hopping", len(hy2_server_ports(data, "de")) > 1)
                hop_mode = "enabled" if enabled else "disabled"
                if enabled:
                    hop_count = ask_positive_int("UDP ports per hopping range", int(data.get("hy2_hop_count", 32)), 256)
                    hop_interval = ask_hop_interval("Port-hop interval", str(data.get("hy2_hop_interval", "30s")))
            else:
                raise ValueError("Choose 0, 1, 2.N, or 3 through 11.")

        if args.outside_address:
            host = args.outside_address.strip().strip("[]")
            if not valid_host(host):
                raise ValueError("Outside address must be a public IP address or DNS hostname.")
            changes["de_address"] = host
        for raw in iran_changes:
            index, host = parse_indexed_host(raw)
            if index > len(data["iran_nodes"]):
                raise ValueError(f"Iran server index {index} does not exist in this bundle.")
            data["iran_nodes"][index - 1]["address"] = host
        port_options = {
            "de_hy2_port": args.outside_hy2_port,
            "de_reality_port": args.outside_reality_port,
            "ir_hy2_port": args.iran_hy2_port,
            "ir_reality_port": args.iran_reality_port,
        }
        for key, value in port_options.items():
            if value is not None:
                if not 1 <= value <= 65535:
                    raise ValueError(f"{key} must be between 1 and 65535.")
                changes[key] = value
        if args.outside_sni:
            changes["de_reality_snis"] = parse_sni_list(args.outside_sni)
        if args.iran_sni:
            changes["ir_reality_snis"] = parse_sni_list(args.iran_sni)
        for key, value in (("de_health_url", outside_health_url), ("ir_health_url", iran_health_url)):
            if value:
                if not valid_health_url(value):
                    raise ValueError(f"{key} must be a complete HTTP(S) URL.")
                changes[key] = value
        hopping_enabled = (hop_mode == "enabled" if hop_mode is not None
                           else len(hy2_server_ports(data, "de")) > 1)
        count = int(hop_count if hop_count is not None else data.get("hy2_hop_count", 32 if hopping_enabled else 1))
        if hopping_enabled and not 2 <= count <= 256:
            raise ValueError("Hysteria 2 hop count must be from 2 to 256.")
        if hop_interval is not None and not valid_hop_interval(hop_interval):
            raise ValueError(f"Hysteria 2 hop interval must be at least "
                             f"{MIN_HOP_INTERVAL_SECONDS:g}s, for example 30s or 1m.")
        changes["hy2_hop_enabled"] = hopping_enabled
        changes["hy2_hop_count"] = count if hopping_enabled else 1
        changes["hy2_hop_interval"] = hop_interval or str(data.get("hy2_hop_interval", "30s"))
        data.update(changes)
        data["de_hy2_server_ports"] = build_hy2_server_ports(int(data["de_hy2_port"]), int(data["hy2_hop_count"]))
        data["ir_hy2_server_ports"] = build_hy2_server_ports(int(data["ir_hy2_port"]), int(data["hy2_hop_count"]))
        data["de_reality_sni"] = reality_snis(data, "de")[0]
        data["ir_reality_sni"] = reality_snis(data, "ir")[0]
        if data["de_address"] in [node["address"] for node in data["iran_nodes"]]:
            raise ValueError("Iran and Outside cannot use the same public address.")
        for side, label in (("de", "Outside"), ("ir", "Iran")):
            if int(data[f"{side}_reality_port"]) + len(reality_snis(data, side)) - 1 > 65535:
                raise ValueError(f"{label} REALITY fallback ports exceed 65535.")

        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        backup = root.with_name(f"{root.name}.backup.{stamp}")
        if backup.exists():
            raise ValueError(f"Backup path already exists: {backup}")
        shutil.copytree(root, backup, copy_function=shutil.copy2)
        protect_private_tree(backup)
        write_bundle(root, data, True, mode)
        protect_private_tree(root)
        prune_bundle_backups(root, 3)
    except (EOFError, KeyboardInterrupt):
        print("\nCancelled.", file=sys.stderr)
        return 130
    except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError) as exc:
        print(f"Bundle update failed: {exc}", file=sys.stderr)
        return 2
    finally:
        if lock_handle is not None:
            lock_handle.close()
    print(f"Bundle updated safely. Backup: {backup}")
    print("Reinstall the matching JSON on each affected server; the installer validates, backs up, and restarts safely.")
    print("Redistribute updated client profiles after an Iran entry address/port/SNI change.")
    return 0


def validate(args: argparse.Namespace) -> int:
    try:
        subprocess.run(["sing-box", "check", "-c", str(Path(args.config))], check=True)
    except FileNotFoundError:
        print("sing-box is not installed; install the official binary/package to validate its schema.", file=sys.stderr)
        return 2
    except subprocess.CalledProcessError as exc:
        return exc.returncode or 1
    return 0


def stats(args: argparse.Namespace) -> int:
    base = Path("/sys/class/net") / args.interface / "statistics"
    try:
        rx = int((base / "rx_bytes").read_text().strip())
        tx = int((base / "tx_bytes").read_text().strip())
    except (OSError, ValueError) as exc:
        print(f"Unable to read interface counters for {args.interface}: {exc}", file=sys.stderr)
        return 2
    print(json.dumps({"interface": args.interface, "rx_bytes_since_boot": rx, "tx_bytes_since_boot": tx, "total_bytes_since_boot": rx + tx}, indent=2))
    return 0


def _audit_value(record: dict[str, Any], *keys: str) -> str:
    for key in keys:
        value = record.get(key)
        if value is not None and str(value).strip():
            return str(value).strip()
    return "unknown"


def parse_audit_line(line: str) -> dict[str, Any] | None:
    """Normalize common Xray JSON/text access-log lines without inspecting payloads."""
    raw = line.strip()
    if not raw:
        return None
    record: dict[str, Any]
    try:
        value = json.loads(raw)
        record = value if isinstance(value, dict) else {}
    except json.JSONDecodeError:
        record = {}
    if record:
        destination = _audit_value(record, "destination", "target", "dest", "address")
        user = _audit_value(record, "user", "email", "client", "inbound_user")
        network = _audit_value(record, "network", "protocol", "type")
        timestamp = _audit_value(record, "timestamp", "time", "start")
        try:
            sent = int(record.get("bytes_sent", record.get("sent", 0)) or 0)
            received = int(record.get("bytes_received", record.get("received", 0)) or 0)
        except (TypeError, ValueError):
            sent = received = 0
        return {"timestamp": timestamp, "user": user, "destination": destination,
                "network": network, "bytes_sent": sent, "bytes_received": received}
    # Typical Xray text line: "... accepted tcp:example.com:443 ... email=user"
    destination_match = re.search(r"(?:accepted|proxy)\s+(?:(tcp|udp):)?([^\s\[\],]+)", raw, re.I)
    user_match = re.search(r"(?:email|user|inbound_user)[=:]([^\s\],]+)", raw, re.I)
    if not destination_match and not user_match:
        return None
    destination = destination_match.group(2) if destination_match else "unknown"
    network = destination_match.group(1).lower() if destination_match and destination_match.group(1) else "unknown"
    timestamp = raw[:24].strip() if re.match(r"^\d{4}/\d{2}/\d{2}", raw) else "unknown"
    return {"timestamp": timestamp, "user": user_match.group(1) if user_match else "unknown",
            "destination": destination, "network": network, "bytes_sent": 0, "bytes_received": 0}


def audit_report(args: argparse.Namespace) -> int:
    path = Path(args.log)
    if not path.is_file():
        print(f"Audit log does not exist: {path}", file=sys.stderr)
        return 2
    groups: dict[tuple[str, str, str], dict[str, Any]] = {}
    total_lines = 0
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                total_lines += 1
                event = parse_audit_line(line)
                if not event or (args.user and event["user"] != args.user):
                    continue
                key = (event["user"], event["destination"], event["network"])
                item = groups.setdefault(key, {"user": key[0], "destination": key[1], "network": key[2], "connections": 0, "bytes_sent": 0, "bytes_received": 0, "first_seen": event["timestamp"], "last_seen": event["timestamp"]})
                item["connections"] += 1
                item["bytes_sent"] += event["bytes_sent"]
                item["bytes_received"] += event["bytes_received"]
                if event["timestamp"] != "unknown":
                    item["last_seen"] = event["timestamp"]
    except OSError as exc:
        print(f"Could not read audit log: {exc}", file=sys.stderr)
        return 2
    payload = {"log": str(path), "lines_scanned": total_lines, "events": sorted(groups.values(), key=lambda x: (x["user"], x["destination"]))}
    print(json.dumps(payload, indent=2, ensure_ascii=False))
    return 0


def read_config(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Could not read JSON config {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise RuntimeError(f"{path} is not a JSON object.")
    return value


def write_config(path: Path, config: dict[str, Any]) -> None:
    secure_write_json(path, config)


def inbound_users(config: dict[str, Any]) -> list[dict[str, Any]]:
    users: list[dict[str, Any]] = []
    for inbound in config.get("inbounds", []):
        if not isinstance(inbound, dict):
            continue
        tag = inbound.get("tag", "")
        inbound_type = inbound.get("type", "")
        for user in inbound.get("users", []) or []:
            if isinstance(user, dict):
                users.append({"inbound": tag, "type": inbound_type, **user})
    return users


def list_users(args: argparse.Namespace) -> int:
    try:
        config = read_config(Path(args.config))
    except RuntimeError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2
    print(json.dumps({"config": args.config, "users": inbound_users(config)}, indent=2, ensure_ascii=False))
    return 0


def user_matches(user: dict[str, Any], needle: str) -> bool:
    return any(str(user.get(field, "")) == needle for field in ("name", "uuid", "password"))


def default_ledger_path(config: Path) -> Path:
    return config.with_suffix(config.suffix + ".users.json")


def read_ledger(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"version": 1, "users": []}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Could not read users ledger {path}: {exc}") from exc
    if not isinstance(value, dict) or not isinstance(value.get("users"), list):
        raise RuntimeError(f"{path} is not a Raah users ledger.")
    return value


def write_ledger(path: Path, value: dict[str, Any]) -> None:
    secure_write_json(path, value)


def parse_expiry(value: str | None) -> str | None:
    if not value:
        return None
    try:
        if value.endswith("Z"):
            parsed = dt.datetime.fromisoformat(value[:-1] + "+00:00")
        else:
            parsed = dt.datetime.fromisoformat(value)
    except ValueError as exc:
        raise RuntimeError("Use an ISO expiry such as 2026-12-31T23:59:00Z.") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def expired(expires_at: str | None, now: dt.datetime | None = None) -> bool:
    if not expires_at:
        return False
    now = now or dt.datetime.now(dt.timezone.utc)
    parsed = dt.datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
    return parsed <= now


def add_user(args: argparse.Namespace) -> int:
    source = Path(args.config)
    try:
        config = read_config(source)
        expires_at = parse_expiry(args.expires_at)
    except RuntimeError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2
    if not re.fullmatch(r"[A-Za-z0-9_.@-]{1,64}", args.name):
        print("User name may contain letters, digits, dot, underscore, dash, and @ only.", file=sys.stderr)
        return 2
    users = inbound_users(config)
    if any(user.get("name") == args.name for user in users):
        print(f"User {args.name!r} already exists in this config.", file=sys.stderr)
        return 1
    user_uuid = str(uuid.uuid4())
    hy_password = secrets.token_urlsafe(32)
    added = 0
    for inbound in config.get("inbounds", []):
        if not isinstance(inbound, dict):
            continue
        inbound_type = inbound.get("type")
        if inbound_type not in {"hysteria2", "vless"}:
            continue
        inbound.setdefault("users", [])
        if not isinstance(inbound["users"], list):
            continue
        if inbound_type == "hysteria2":
            inbound["users"].append({"name": args.name, "password": hy_password})
            added += 1
        elif inbound_type == "vless":
            inbound["users"].append({"name": args.name, "uuid": user_uuid})
            added += 1
    if added == 0:
        print("No Hysteria2 or VLESS inbound users list found.", file=sys.stderr)
        return 1
    target = source if args.in_place else Path(args.out or f"{source}.with-{args.name}")
    ledger_path = Path(args.ledger) if args.ledger else default_ledger_path(target)
    try:
        write_config(target, config)
        ledger = read_ledger(ledger_path)
        ledger["users"] = [entry for entry in ledger["users"] if entry.get("name") != args.name]
        ledger["users"].append({
            "name": args.name,
            "uuid": user_uuid,
            "hysteria_password": hy_password,
            "expires_at": expires_at,
            "quota_gb": args.quota_gb,
            "quota_enforcement": "metadata_only",
            "created_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        })
        write_ledger(ledger_path, ledger)
    except (OSError, RuntimeError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2
    print(json.dumps({
        "config": str(target),
        "ledger": str(ledger_path),
        "name": args.name,
        "uuid": user_uuid,
        "hysteria_password": hy_password,
        "expires_at": expires_at,
        "quota_gb": args.quota_gb,
        "restart": "sudo systemctl restart raah-sing-box",
        "quota_note": "quota_gb is recorded in the ledger; per-user traffic enforcement needs stats/API or a panel integration.",
    }, indent=2))
    return 0


def revoke_user(args: argparse.Namespace) -> int:
    source = Path(args.config)
    try:
        config = read_config(source)
    except RuntimeError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2
    removed = 0
    for inbound in config.get("inbounds", []):
        if not isinstance(inbound, dict) or not isinstance(inbound.get("users"), list):
            continue
        old_users = inbound["users"]
        new_users = [user for user in old_users if not (isinstance(user, dict) and user_matches(user, args.user))]
        removed += len(old_users) - len(new_users)
        inbound["users"] = new_users
    if removed == 0:
        print(f"No matching user found for {args.user!r}.", file=sys.stderr)
        return 1
    target = source if args.in_place else Path(args.out or f"{source}.revoked")
    try:
        write_config(target, config)
    except OSError as exc:
        print(f"Error: could not write {target}: {exc}", file=sys.stderr)
        return 2
    print(json.dumps({"source": str(source), "output": str(target), "removed_users": removed, "restart": "sudo systemctl restart raah-sing-box"}, indent=2))
    return 0


def enforce_users(args: argparse.Namespace) -> int:
    source = Path(args.config)
    ledger_path = Path(args.ledger) if args.ledger else default_ledger_path(source)
    try:
        ledger = read_ledger(ledger_path)
    except RuntimeError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2
    expired_names = [entry["name"] for entry in ledger["users"] if isinstance(entry, dict) and expired(entry.get("expires_at"))]
    if not expired_names:
        print(json.dumps({"config": str(source), "ledger": str(ledger_path), "expired_users": [], "changed": False}, indent=2))
        return 0
    try:
        config = read_config(source)
    except RuntimeError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2
    removed = 0
    for inbound in config.get("inbounds", []):
        if not isinstance(inbound, dict) or not isinstance(inbound.get("users"), list):
            continue
        old_users = inbound["users"]
        new_users = [user for user in old_users if not (isinstance(user, dict) and user.get("name") in expired_names)]
        removed += len(old_users) - len(new_users)
        inbound["users"] = new_users
    target = source if args.in_place else Path(args.out or f"{source}.enforced")
    try:
        write_config(target, config)
    except OSError as exc:
        print(f"Error: could not write {target}: {exc}", file=sys.stderr)
        return 2
    print(json.dumps({"config": str(target), "ledger": str(ledger_path), "expired_users": expired_names, "removed_users": removed, "restart": "sudo systemctl restart raah-sing-box"}, indent=2))
    return 1 if removed else 0


def config_ports(config: dict[str, Any]) -> list[tuple[str, int]]:
    ports: list[tuple[str, int]] = []
    for inbound in config.get("inbounds", []):
        if not isinstance(inbound, dict):
            continue
        port = inbound.get("listen_port")
        if not isinstance(port, int):
            continue
        protocol = "udp" if inbound.get("type") == "hysteria2" else "tcp"
        ports.append((protocol, port))
    return ports


def firewall_plan(args: argparse.Namespace) -> int:
    root = Path(args.path)
    configs = [root] if root.is_file() else sorted(root.rglob("*.json"))
    ports: set[tuple[str, int]] = set()
    udp_ranges: set[str] = set()
    errors: list[str] = []
    for path in configs:
        if path.name == "secrets.json":
            continue
        try:
            value = read_config(path)
            if path.name.endswith(".install.json"):
                hop = value.get("hysteria2_port_hopping") or {}
                if hop.get("enabled"):
                    listen_port = int(hop.get("listen_port", 0))
                    for start, end in parse_port_specs([str(item) for item in hop.get("server_ports") or []]):
                        if start == end == listen_port:
                            continue
                        udp_ranges.add(str(start) if start == end else f"{start}:{end}")
            else:
                ports.update(config_ports(value))
        except RuntimeError as exc:
            errors.append(str(exc))
    if errors:
        print(json.dumps({"errors": errors}, indent=2), file=sys.stderr)
        return 2
    commands = [
        "sudo ufw default deny incoming",
        "sudo ufw default allow outgoing",
        f"sudo ufw allow {args.ssh_port}/tcp comment 'SSH management'",
    ]
    for protocol, port in sorted(ports, key=lambda item: (item[1], item[0])):
        commands.append(f"sudo ufw allow {port}/{protocol} comment 'Raah tunnel'")
    for port_range in sorted(udp_ranges):
        commands.append(f"sudo ufw allow {port_range}/udp comment 'Raah Hysteria2 hopping'")
    commands.append("sudo ufw enable")
    print("\n".join(commands))
    return 0


def quota_check(args: argparse.Namespace) -> int:
    base = Path("/sys/class/net") / args.interface / "statistics"
    try:
        rx = int((base / "rx_bytes").read_text().strip())
        tx = int((base / "tx_bytes").read_text().strip())
    except (OSError, ValueError) as exc:
        print(f"Unable to read interface counters for {args.interface}: {exc}", file=sys.stderr)
        return 2
    total = rx + tx
    limit = int(args.limit_gb * 1024 * 1024 * 1024)
    payload = {
        "interface": args.interface,
        "rx_bytes_since_boot": rx,
        "tx_bytes_since_boot": tx,
        "total_bytes_since_boot": total,
        "limit_bytes": limit,
        "used_percent": round(total * 100 / limit, 2) if limit else 0,
        "over_limit": total >= limit,
    }
    print(json.dumps(payload, indent=2))
    return 1 if payload["over_limit"] else 0


def doctor(args: argparse.Namespace) -> int:
    root = Path(args.path)
    configs = [root] if root.is_file() else sorted(
        path for path in root.rglob("*.json") if path.name != "secrets.json" and not path.name.endswith(".install.json")
    )
    reports: list[dict[str, Any]] = []
    sing_box = shutil.which("sing-box")
    for path in configs:
        if path.name == "secrets.json" or path.name.endswith(".users.json"):
            continue
        report: dict[str, Any] = {"path": str(path), "ok": True, "warnings": [], "errors": []}
        try:
            config = read_config(path)
        except RuntimeError as exc:
            report["ok"] = False
            report["errors"].append(str(exc))
            reports.append(report)
            continue
        ports = config_ports(config)
        seen: set[tuple[str, int]] = set()
        duplicates = sorted({item for item in ports if item in seen or seen.add(item)})
        if duplicates:
            report["ok"] = False
            report["errors"].append(f"duplicate listen ports: {duplicates}")
        report["listen_ports"] = [{"protocol": proto, "port": port} for proto, port in sorted(set(ports), key=lambda x: (x[1], x[0]))]
        cert_paths: list[str] = []
        for inbound in config.get("inbounds", []):
            if not isinstance(inbound, dict):
                continue
            tls = inbound.get("tls")
            if isinstance(tls, dict):
                for key in ("certificate_path", "key_path"):
                    value = tls.get(key)
                    if isinstance(value, str) and value:
                        cert_paths.append(value)
        missing = [value for value in cert_paths if not Path(value).exists()]
        if missing and args.local_paths:
            report["ok"] = False
            report["errors"].append(f"missing local TLS files: {missing}")
        elif missing:
            report["warnings"].append("TLS certificate/key paths are not checked unless --local-paths is used on the target server.")
        if sing_box:
            proc = subprocess.run([sing_box, "check", "-c", str(path)], capture_output=True, text=True)
            report["sing_box_check"] = proc.returncode == 0
            if proc.returncode != 0:
                report["ok"] = False
                report["errors"].append((proc.stderr or proc.stdout).strip())
        else:
            report["warnings"].append("sing-box is not installed here; schema validation was skipped.")
        reports.append(report)
    payload = {"path": str(root), "sing_box": sing_box, "reports": reports}
    print(json.dumps(payload, indent=2, ensure_ascii=False))
    return 0 if all(report["ok"] for report in reports) else 1


def check_endpoint(args: argparse.Namespace) -> int:
    if not valid_host(args.host):
        print("Host must be a public IP address or DNS hostname.", file=sys.stderr)
        return 2
    if not 1 <= args.port <= 65535:
        print("Port must be from 1 to 65535.", file=sys.stderr)
        return 2
    try:
        with socket.create_connection((args.host, args.port), timeout=args.timeout):
            if not getattr(args, "quiet", False):
                print(f"OK TCP {args.host}:{args.port}")
            return 0
    except OSError as exc:
        message = f"Raah health check failed: TCP {args.host}:{args.port} ({exc})"
        if not getattr(args, "quiet", False):
            print(message, file=sys.stderr)
        if args.telegram_env:
            token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
            chat_id = os.environ.get("TELEGRAM_CHAT_ID", "")
            if not token or not chat_id:
                print("Telegram vars missing: set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID.", file=sys.stderr)
                return 2
            try:
                import urllib.parse
                import urllib.request

                payload = urllib.parse.urlencode({"chat_id": chat_id, "text": message}).encode()
                request = urllib.request.Request(f"https://api.telegram.org/bot{token}/sendMessage", data=payload)
                with urllib.request.urlopen(request, timeout=args.timeout) as response:
                    if response.status >= 300:
                        raise OSError(f"Telegram returned HTTP {response.status}")
            except Exception as alert_exc:  # report failed alert delivery without hiding the original outage
                print(f"Telegram alert failed: {alert_exc}", file=sys.stderr)
                return 2
        return 1


def send_telegram(message: str, timeout: float) -> None:
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    chat_id = os.environ.get("TELEGRAM_CHAT_ID", "")
    if not token or not chat_id:
        raise RuntimeError("Set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID before enabling Telegram alerts.")
    import urllib.parse
    import urllib.request

    payload = urllib.parse.urlencode({"chat_id": chat_id, "text": message}).encode()
    request = urllib.request.Request(f"https://api.telegram.org/bot{token}/sendMessage", data=payload)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        if response.status >= 300:
            raise OSError(f"Telegram returned HTTP {response.status}")


def probe_endpoint(args: argparse.Namespace) -> int:
    if not valid_host(args.host):
        print("Host must be a public IP address or DNS hostname.", file=sys.stderr)
        return 2
    if not 1 <= args.port <= 65535:
        print("Port must be from 1 to 65535.", file=sys.stderr)
        return 2
    if args.count < 1:
        print("Count must be at least 1.", file=sys.stderr)
        return 2
    samples_ms: list[float] = []
    failures = 0
    for index in range(args.count):
        start = time.perf_counter()
        try:
            with socket.create_connection((args.host, args.port), timeout=args.timeout):
                samples_ms.append((time.perf_counter() - start) * 1000)
        except OSError:
            failures += 1
        if index + 1 < args.count and args.interval > 0:
            time.sleep(args.interval)
    if not samples_ms:
        print(json.dumps({"host": args.host, "port": args.port, "ok": False, "attempts": args.count, "failures": failures}, indent=2))
        return 1
    avg = sum(samples_ms) / len(samples_ms)
    jitter = sum(abs(x - avg) for x in samples_ms) / len(samples_ms)
    ordered = sorted(samples_ms)
    p95_index = min(len(ordered) - 1, int(round((len(ordered) - 1) * 0.95)))
    print(json.dumps({
        "host": args.host,
        "port": args.port,
        "ok": failures == 0,
        "attempts": args.count,
        "successes": len(samples_ms),
        "failures": failures,
        "latency_ms_min": round(min(samples_ms), 2),
        "latency_ms_avg": round(avg, 2),
        "latency_ms_p95": round(ordered[p95_index], 2),
        "jitter_ms_mean_deviation": round(jitter, 2),
    }, indent=2))
    return 0 if failures == 0 else 1


def build_e2e_probe_config(client: dict[str, Any], port: int, outbound: str | None = None) -> dict[str, Any]:
    """Create a localhost-only SOCKS test profile from a generated client profile."""
    config = copy.deepcopy(client)
    outbounds = config.get("outbounds")
    if not isinstance(outbounds, list) or not outbounds:
        raise ValueError("Client config has no outbounds.")
    tags = {item.get("tag") for item in outbounds if isinstance(item, dict)}
    if outbound and outbound not in tags:
        raise ValueError(f"Outbound tag not found: {outbound}")
    config["log"] = {"level": "warn", "timestamp": True}
    config["inbounds"] = [{
        "type": "mixed",
        "tag": "raah-e2e-probe-in",
        "listen": "127.0.0.1",
        "listen_port": port,
    }]
    route = config.setdefault("route", {})
    if not isinstance(route, dict):
        raise ValueError("Client config route must be an object.")
    if outbound:
        route["final"] = outbound
    route["auto_detect_interface"] = True
    return config


def free_local_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def e2e_probe(args: argparse.Namespace) -> int:
    parsed = urllib.parse.urlparse(args.url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        print("Probe URL must be a valid HTTP or HTTPS URL.", file=sys.stderr)
        return 2
    if args.count < 1 or args.timeout <= 0:
        print("Count must be at least 1 and timeout must be positive.", file=sys.stderr)
        return 2
    sing_box = shutil.which("sing-box")
    curl = shutil.which("curl")
    if not sing_box or not curl:
        print("Both sing-box and curl are required for an end-to-end probe.", file=sys.stderr)
        return 2
    try:
        client_path = Path(args.client_config)
        client = json.loads(client_path.read_text(encoding="utf-8"))
        if not isinstance(client, dict):
            raise ValueError("Client config root must be an object.")
        port = free_local_port()
        config = build_e2e_probe_config(client, port, args.outbound)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"Unable to prepare end-to-end probe: {exc}", file=sys.stderr)
        return 2

    samples_ms: list[float] = []
    statuses: list[int] = []
    failures: list[str] = []
    process: subprocess.Popen[str] | None = None
    with tempfile.TemporaryDirectory(prefix="raah-e2e-") as directory:
        temp_root = Path(directory)
        temp_root.chmod(0o700)
        probe_config = temp_root / "client-probe.json"
        write_private(probe_config, config)
        checked = subprocess.run([sing_box, "check", "-c", str(probe_config)], capture_output=True, text=True)
        if checked.returncode != 0:
            print((checked.stderr or checked.stdout or "sing-box rejected the probe config.").strip(), file=sys.stderr)
            return 2
        log_path = temp_root / "sing-box.log"
        try:
            with log_path.open("w+", encoding="utf-8") as log_file:
                process = subprocess.Popen(
                    [sing_box, "run", "-c", str(probe_config)],
                    stdout=log_file,
                    stderr=subprocess.STDOUT,
                    text=True,
                )
                deadline = time.monotonic() + args.timeout
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        log_file.flush()
                        log_file.seek(0)
                        raise RuntimeError(log_file.read(4000).strip() or "sing-box exited before the local probe became ready.")
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                            break
                    except OSError:
                        time.sleep(0.1)
                else:
                    raise RuntimeError("Timed out waiting for the local sing-box probe.")

                for index in range(args.count):
                    started = time.perf_counter()
                    result = subprocess.run([
                        curl,
                        "--silent", "--show-error",
                        "--output", "/dev/null",
                        "--write-out", "%{http_code}",
                        "--proxy", f"socks5h://127.0.0.1:{port}",
                        "--max-time", str(args.timeout),
                        args.url,
                    ], capture_output=True, text=True)
                    elapsed = (time.perf_counter() - started) * 1000
                    try:
                        status = int(result.stdout.strip())
                    except ValueError:
                        status = 0
                    if result.returncode == 0 and 200 <= status < 400:
                        samples_ms.append(elapsed)
                        statuses.append(status)
                    else:
                        failures.append((result.stderr or f"HTTP {status or 'unavailable'}").strip())
                    if index + 1 < args.count and args.interval > 0:
                        time.sleep(args.interval)
        except (OSError, RuntimeError) as exc:
            print(f"End-to-end probe failed to start: {exc}", file=sys.stderr)
            return 2
        finally:
            if process and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)

    payload: dict[str, Any] = {
        "ok": not failures and len(samples_ms) == args.count,
        "client_config": str(Path(args.client_config)),
        "outbound": args.outbound or "configured final/urltest",
        "url": args.url,
        "attempts": args.count,
        "successes": len(samples_ms),
        "failures": len(failures),
        "http_statuses": statuses,
    }
    if samples_ms:
        average = sum(samples_ms) / len(samples_ms)
        payload.update({
            "latency_ms_min": round(min(samples_ms), 2),
            "latency_ms_avg": round(average, 2),
            "latency_ms_max": round(max(samples_ms), 2),
            "jitter_ms_mean_deviation": round(sum(abs(value - average) for value in samples_ms) / len(samples_ms), 2),
        })
    if failures:
        payload["last_error"] = failures[-1][:500]
    print(json.dumps(payload, indent=2))
    return 0 if payload["ok"] else 1


def sni_scan(args: argparse.Namespace) -> int:
    candidates = [x.strip().lower().rstrip(".") for x in args.candidates.split(",") if x.strip()] if args.candidates else DEFAULT_SNI_CANDIDATES
    results = scan_sni_candidates(candidates, args.timeout, args.count)
    print(json.dumps({"best_sni": next((x["sni"] for x in results if x.get("successes")), None), "results": results}, indent=2))
    return 0 if any(x.get("successes") for x in results) else 1


def system_status(args: argparse.Namespace) -> int:
    result: dict[str, Any] = {}
    try:
        one, five, fifteen = os.getloadavg()
        result["loadavg"] = {"1m": one, "5m": five, "15m": fifteen}
    except OSError:
        pass
    try:
        meminfo: dict[str, int] = {}
        for line in Path("/proc/meminfo").read_text().splitlines():
            key, raw = line.split(":", 1)
            parts = raw.strip().split()
            if parts and parts[0].isdigit():
                meminfo[key] = int(parts[0]) * 1024
        total = meminfo.get("MemTotal")
        available = meminfo.get("MemAvailable")
        if total and available is not None:
            result["memory"] = {
                "total_bytes": total,
                "available_bytes": available,
                "used_percent": round((total - available) * 100 / total, 2),
            }
    except (OSError, ValueError):
        pass
    if args.interface:
        base = Path("/sys/class/net") / args.interface / "statistics"
        try:
            rx = int((base / "rx_bytes").read_text().strip())
            tx = int((base / "tx_bytes").read_text().strip())
            result["interface"] = {"name": args.interface, "rx_bytes_since_boot": rx, "tx_bytes_since_boot": tx, "total_bytes_since_boot": rx + tx}
        except (OSError, ValueError) as exc:
            print(f"Unable to read interface counters for {args.interface}: {exc}", file=sys.stderr)
            return 2
    print(json.dumps(result, indent=2))
    return 0


def watch_endpoint(args: argparse.Namespace) -> int:
    if args.interval < 5:
        print("Use an interval of at least 5 seconds.", file=sys.stderr)
        return 2
    previous: bool | None = None
    print(f"Watching TCP {args.host}:{args.port} every {args.interval}s. Ctrl-C to stop.")
    try:
        while True:
            check_args = argparse.Namespace(host=args.host, port=args.port, timeout=args.timeout, telegram_env=False, quiet=True)
            up = check_endpoint(check_args) == 0
            if ((previous is None and not up) or (previous is not None and up != previous)) and args.telegram_env:
                state = "UP" if up else "DOWN"
                try:
                    send_telegram(f"Raah endpoint {state}: TCP {args.host}:{args.port}", args.timeout)
                except Exception as exc:
                    print(f"Telegram alert failed: {exc}", file=sys.stderr)
            previous = up
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("\nStopped.")
        return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="raahctl", description="Raah Tunnel config generator and health utilities")
    parser.add_argument("--version", action="version", version=f"Raah Tunnel {VERSION}")
    sub = parser.add_subparsers(dest="command", required=True)
    gen = sub.add_parser("generate", help="generate a private Outside/Iran/client configuration bundle")
    gen.add_argument("--out", default="./private-bundle", help="output directory (default: ./private-bundle)")
    gen.add_argument("--force", action="store_true", help="replace files in the chosen output directory")
    gen.add_argument("--advanced", action="store_true", help="ask for separate SNI lists, certificate paths, and per-server TLS overrides")
    gen.add_argument("--no-discovery", action="store_true", help="skip online public-IP and country lookups; enter addresses manually")
    gen.add_argument("--mode", choices=["direct", "reverse", "both"], default="direct", help="topology to generate (default: direct)")
    gen.add_argument("--auto-sni", action="store_true", help="scan SNI candidates and suggest the fastest reachable REALITY SNI")
    gen.add_argument("--sni-candidates", default="", help="comma-separated SNI candidates for --auto-sni")
    gen.add_argument("--sni-count", type=int, default=2, help="TLS handshakes per SNI candidate for --auto-sni")
    gen.add_argument("--sni-timeout", type=float, default=3.0, help="TLS connect timeout per SNI probe")
    gen.add_argument("--sni-pool-size", type=int, default=3, help="number of reachable SNI candidates to keep as fallbacks")
    hopping = gen.add_mutually_exclusive_group()
    hopping.add_argument("--hop", dest="hop", action="store_true", help="enable coordinated Hysteria 2 UDP port hopping")
    hopping.add_argument("--no-hop", dest="hop", action="store_false", help="disable Hysteria 2 UDP port hopping")
    gen.set_defaults(hop=None)
    gen.add_argument("--hop-count", type=int, default=32, help="number of UDP ports in each hopping range (default: 32)")
    gen.set_defaults(func=generate)
    edit = sub.add_parser("edit-bundle", help="safely update addresses, ports, or SNI values and regenerate a private bundle")
    edit.add_argument("path", help="generated bundle directory containing secrets.json")
    edit.add_argument("--outside-address", help="new Outside public IP or DNS hostname")
    edit.add_argument("--iran-address", action="append", metavar="INDEX=HOST", help="new address for an Iran node; repeat as needed")
    edit.add_argument("--outside-hy2-port", type=int)
    edit.add_argument("--outside-reality-port", type=int)
    edit.add_argument("--iran-hy2-port", type=int)
    edit.add_argument("--iran-reality-port", type=int)
    edit.add_argument("--outside-sni", help="new comma-separated Outside REALITY SNI list")
    edit.add_argument("--iran-sni", help="new comma-separated Iran REALITY SNI list")
    edit.add_argument("--outside-health-url", help="HTTP(S) probe URL used to test Outside paths")
    edit.add_argument("--iran-health-url", help="HTTP(S) probe URL used to test Iran paths")
    edit.add_argument("--hop", choices=["enabled", "disabled"], help="enable or disable coordinated Hysteria 2 UDP port hopping")
    edit.add_argument("--hop-count", type=int, help="number of UDP ports in each hopping range")
    edit.add_argument("--hop-interval", help="port hopping interval, for example 30s")
    edit.set_defaults(func=edit_bundle)
    val = sub.add_parser("validate", help="validate a config with sing-box check")
    val.add_argument("config")
    val.set_defaults(func=validate)
    stat = sub.add_parser("stats", help="show host-wide interface byte counters")
    stat.add_argument("--interface", required=True, help="network interface name, such as eth0")
    stat.set_defaults(func=stats)
    audit = sub.add_parser("audit-report", help="aggregate Xray/x-ui access-log metadata by user and destination")
    audit.add_argument("log", help="Xray access log file (JSON or common text format)")
    audit.add_argument("--user", help="filter to one x-ui/Xray user email or identifier")
    audit.set_defaults(func=audit_report)
    users = sub.add_parser("list-users", help="list users found in a generated sing-box config")
    users.add_argument("config")
    users.set_defaults(func=list_users)
    add = sub.add_parser("add-user", help="add a user to Hysteria2/VLESS inbounds and record expiry/quota metadata")
    add.add_argument("config")
    add.add_argument("--name", required=True)
    add.add_argument("--expires-at", help="UTC ISO timestamp, e.g. 2026-12-31T23:59:00Z")
    add.add_argument("--quota-gb", type=float, help="metadata only; per-user enforcement needs stats/API or panel integration")
    add.add_argument("--ledger", help="users ledger path; defaults to CONFIG.users.json")
    add.add_argument("--out", help="output config path; defaults to CONFIG.with-NAME")
    add.add_argument("--in-place", action="store_true", help="rewrite the source config directly")
    add.set_defaults(func=add_user)
    revoke = sub.add_parser("revoke-user", help="remove a user by name, UUID, or password from a generated config")
    revoke.add_argument("config")
    revoke.add_argument("--user", required=True, help="exact user name, UUID, or password to remove")
    revoke.add_argument("--out", help="output config path; defaults to CONFIG.revoked")
    revoke.add_argument("--in-place", action="store_true", help="rewrite the source config directly")
    revoke.set_defaults(func=revoke_user)
    enforce = sub.add_parser("enforce-users", help="remove expired users from a config using its users ledger")
    enforce.add_argument("config")
    enforce.add_argument("--ledger", help="users ledger path; defaults to CONFIG.users.json")
    enforce.add_argument("--out", help="output config path; defaults to CONFIG.enforced")
    enforce.add_argument("--in-place", action="store_true", help="rewrite the source config directly")
    enforce.set_defaults(func=enforce_users)
    fw = sub.add_parser("firewall-plan", help="print UFW allow commands for generated Raah config files")
    fw.add_argument("path", help="config file or bundle directory")
    fw.add_argument("--ssh-port", type=int, default=22, help="SSH management port to keep open")
    fw.set_defaults(func=firewall_plan)
    quota = sub.add_parser("quota-check", help="check host-wide interface traffic against a GB limit")
    quota.add_argument("--interface", required=True, help="network interface name, such as eth0")
    quota.add_argument("--limit-gb", required=True, type=float, help="host-wide traffic limit in GiB since boot")
    quota.set_defaults(func=quota_check)
    doc = sub.add_parser("doctor", help="inspect generated configs for common deployment problems")
    doc.add_argument("path", help="config file or bundle directory")
    doc.add_argument("--local-paths", action="store_true", help="check TLS certificate/key paths on this machine")
    doc.set_defaults(func=doctor)
    chk = sub.add_parser("check", help="check a TCP service from this host; optional Telegram alert on failure")
    chk.add_argument("--host", required=True)
    chk.add_argument("--port", required=True, type=int)
    chk.add_argument("--timeout", type=float, default=5.0)
    chk.add_argument("--telegram-env", action="store_true", help="send failure alerts using TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID")
    chk.set_defaults(func=check_endpoint)
    probe = sub.add_parser("probe", help="measure TCP connect latency and jitter to an endpoint")
    probe.add_argument("--host", required=True)
    probe.add_argument("--port", required=True, type=int)
    probe.add_argument("--count", type=int, default=10)
    probe.add_argument("--interval", type=float, default=1.0)
    probe.add_argument("--timeout", type=float, default=5.0)
    probe.set_defaults(func=probe_endpoint)
    e2e = sub.add_parser("e2e-probe", help="test a generated client config through Iran, Outside, and an HTTP endpoint")
    e2e.add_argument("client_config", help="generated client-linux.json or reverse-client-linux.json")
    e2e.add_argument("--url", default=DEFAULT_HEALTH_URL, help=f"HTTP(S) target (default: {DEFAULT_HEALTH_URL})")
    e2e.add_argument("--outbound", help="test one outbound tag instead of the configured final/urltest group")
    e2e.add_argument("--count", type=int, default=3)
    e2e.add_argument("--interval", type=float, default=1.0)
    e2e.add_argument("--timeout", type=float, default=10.0)
    e2e.set_defaults(func=e2e_probe)
    sni = sub.add_parser("sni-scan", help="rank REALITY SNI candidates with TLS handshake latency and jitter")
    sni.add_argument("--candidates", default="", help="comma-separated hostnames; built-in candidates are used when omitted")
    sni.add_argument("--count", type=int, default=2)
    sni.add_argument("--timeout", type=float, default=3.0)
    sni.set_defaults(func=sni_scan)
    status_cmd = sub.add_parser("status", help="show server load, memory, and optional interface traffic counters")
    status_cmd.add_argument("--interface", help="network interface name, such as eth0")
    status_cmd.set_defaults(func=system_status)
    watch = sub.add_parser("watch", help="continuously monitor a TCP endpoint and alert on state changes")
    watch.add_argument("--host", required=True)
    watch.add_argument("--port", required=True, type=int)
    watch.add_argument("--interval", type=int, default=30)
    watch.add_argument("--timeout", type=float, default=5.0)
    watch.add_argument("--telegram-env", action="store_true", help="alert on DOWN/UP transitions using Telegram env vars")
    watch.set_defaults(func=watch_endpoint)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
