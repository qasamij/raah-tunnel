# Protocol review and choices

This review is scoped to a two-hop Iran-entry → Outside-exit service that needs TCP and UDP, optional TUN clients, failover, and a separate service boundary from x-ui. It does not claim to benchmark every ISP or provide a universally best protocol. Protocol behavior changes with carrier policy, routes, server location, kernel, MTU, congestion and load.

| Protocol / family | Strengths | Limitations for this project | Decision |
|---|---|---|---|
| WireGuard | Small protocol, fast kernel implementation, good L3 semantics | UDP signatures are easy to classify; UDP must pass; ordinary WireGuard domain endpoints do not create TLS disguise | Keep as a direct benchmark/optional trusted link, not censorship fallback |
| AmneziaWG | WireGuard-derived with configurable packet/header padding and signatures; preserves VPN-style operation | Still UDP; requires compatible client/server implementation and careful matched parameters; obfuscation is not a guarantee | Candidate for a later native L3 mode and controlled tests |
| Hysteria 2 | QUIC/UDP; supports TCP/UDP proxying and TUN; includes congestion handling, Salamander/Gecko obfuscation and port hopping | Requires UDP and valid TLS; UDP/QUIC blocking still blocks it; CDN proxying does not carry its authenticated custom protocol; tuning caps too high can worsen loss/jitter | Primary low-latency path where UDP works |
| VLESS + REALITY | TCP fallback with REALITY TLS handshake behavior and no public certificate requirement on the server | Not a generic IP tunnel by itself; TCP fallback for UDP applications adds delay/head-of-line effects; SNI target and config must be correct | Independent survival path |
| TUIC | QUIC-based TCP/UDP proxying; low-latency option where UDP passes | Same essential UDP availability limitation; adds another implementation/auth/config surface | Not enabled in the first cut; benchmark as an alternate QUIC transport |
| OpenVPN TCP / SSH tunnel | Broad client availability and useful for administration | TCP-over-TCP/reliability issues and less suitable for interactive UDP; SSH forwarding is TCP-only | Not data-plane default |
| OpenVPN UDP / IPsec / raw WireGuard | Mature VPN/L3 choices, broad ecosystem | UDP-dependent and commonly fingerprintable without separate transport obfuscation | Useful baseline comparisons, not fallback |
| Shadowsocks / Trojan / Naive / AnyTLS / ShadowTLS / XHTTP | Broad proxy ecosystem; different handshake and transport trade-offs | Application proxy models, varied UDP support, and protocol fingerprints evolve; adding every mode increases attack surface and operational complexity | Not combined into v0.1; add only after reproducible tests |
| Tixo TCP Relay (previously selected) | Simple TCP forwarding path | TCP-only mode does not meet the project's UDP/game traffic requirement; the alternate Netfilter Gateway is a separate implementation and needs its own audit/benchmark | Not the first-cut engine |
| Cloudflare/Arvan DNS, proxy and tunnel products | DNS management, health products, or HTTP proxying depending on service/plan | DNS answers alone do not preserve sessions; normal HTTP CDN proxy is not generic UDP/QUIC forwarding. Special products have provider-specific constraints and costs | DNS-only hostname use now; provider API failover is future work |

## Why sing-box is the initial engine

The official sing-box docs list Hysteria 2, VLESS, WireGuard and multiple other proxy types, plus URL-test outbound selection and TUN support. That gives the project one maintained configuration model for user traffic and two independent transport paths, without writing a new cryptographic protocol. Outside and Iran each use their own config and systemd unit; x-ui remains separate.

## References (primary project documentation)

- [sing-box inbound/outbound protocol matrix](https://sing-box.sagernet.org/configuration/outbound/)
- [sing-box Hysteria 2 inbound](https://sing-box.sagernet.org/configuration/inbound/hysteria2/) and [outbound](https://sing-box.sagernet.org/configuration/outbound/hysteria2/)
- [Hysteria 2 client config: UDP, obfuscation, TCP/UDP forwarding, TUN and congestion](https://v2.hysteria.network/docs/advanced/Full-Client-Config/)
- [Hysteria 2 and CDN limitations](https://v2.hysteria.network/docs/misc/CDN/)
- [sing-box VLESS inbound](https://sing-box.sagernet.org/configuration/inbound/vless/) and [outbound](https://sing-box.sagernet.org/configuration/outbound/vless/)
- [XTLS REALITY reference configuration](https://github.com/XTLS/REALITY/blob/main/README.md)
- [sing-box URLTest selection](https://sing-box.sagernet.org/configuration/outbound/urltest/) and [TUN inbound](https://sing-box.sagernet.org/configuration/inbound/tun/)
- [AmneziaWG Go implementation and protocol parameters](https://github.com/amnezia-vpn/amneziawg-go)
- [WireGuard official quick start](https://www.wireguard.com/quickstart/)
