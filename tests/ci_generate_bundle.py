#!/usr/bin/env python3
"""Generate a credential-valid bundle for CI's real sing-box schema check."""

from __future__ import annotations

import argparse
import importlib.util
import secrets
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("raahctl", ROOT / "raahctl.py")
assert SPEC and SPEC.loader
raahctl = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(raahctl)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    args = parser.parse_args()

    outside_private, outside_public = raahctl.reality_keypair()
    iran_private, iran_public = raahctl.reality_keypair()
    data = {
        "de_address": "192.0.2.10",
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
        "de_cert": args.cert,
        "de_key": args.key,
        "ir_cert": args.cert,
        "ir_key": args.key,
        "de_reality_private": outside_private,
        "de_reality_public": outside_public,
        "de_short_id": secrets.token_hex(8),
        "relay_uuid": str(uuid.uuid4()),
        "relay_password": secrets.token_urlsafe(32),
        "relay_obfs": secrets.token_urlsafe(32),
        "health_interval": "15s",
        "de_health_url": raahctl.DEFAULT_HEALTH_URL,
        "ir_health_url": raahctl.DEFAULT_HEALTH_URL,
        "iran_nodes": [{
            "address": "198.51.100.10",
            "tls_name": "iran.example.com",
            "cert": args.cert,
            "key": args.key,
            "reality_private": iran_private,
            "reality_public": iran_public,
            "short_id": secrets.token_hex(8),
            "user_uuid": str(uuid.uuid4()),
            "user_password": secrets.token_urlsafe(32),
            "user_obfs": secrets.token_urlsafe(32),
        }],
    }
    raahctl.write_bundle(Path(args.out), data, False, "both")


if __name__ == "__main__":
    main()
