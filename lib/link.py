#!/usr/bin/env python3
"""Parse proxy share links and render a sing-box 1.14 config.

Supported uplinks: HTTP, SOCKS, VLESS, VMess, Trojan, Shadowsocks.
Transports: TCP, WebSocket, gRPC, HTTP, HTTPUpgrade, QUIC.
XHTTP is rejected with an explicit error. Official sing-box does not implement it.
"""

from __future__ import annotations

import argparse
import base64
import ipaddress
import json
import os
import shlex
import sys
from urllib.parse import parse_qs, unquote, urlparse

LISTEN_HOST = "127.0.0.1"
TUN_INTERFACE = "aether0"
TUN_ADDRESS = ["172.19.0.1/30", "fdfe:dcba:9876::1/126"]
PRIVATE_RULE = {"ip_is_private": True, "action": "route", "outbound": "direct"}

SUPPORTED_TRANSPORTS = {
    "tcp": "tcp",
    "raw": "tcp",
    "": "tcp",
    "ws": "ws",
    "websocket": "ws",
    "grpc": "grpc",
    "gun": "grpc",
    "http": "http",
    "h2": "http",
    "httpupgrade": "httpupgrade",
    "quic": "quic",
}

SS_METHODS = {
    "2022-blake3-aes-128-gcm",
    "2022-blake3-aes-256-gcm",
    "2022-blake3-chacha20-poly1305",
    "none",
    "aes-128-gcm",
    "aes-192-gcm",
    "aes-256-gcm",
    "chacha20-ietf-poly1305",
    "xchacha20-ietf-poly1305",
    "aes-128-ctr",
    "aes-192-ctr",
    "aes-256-ctr",
    "aes-128-cfb",
    "aes-192-cfb",
    "aes-256-cfb",
    "rc4-md5",
    "chacha20-ietf",
    "xchacha20",
    "chacha20-poly1305",
}


class LinkError(Exception):
    """The share link cannot be turned into a sing-box outbound."""


class Query:
    def __init__(self, raw: str) -> None:
        self._map = parse_qs(raw, keep_blank_values=False)

    def first(self, *keys: str, default: str = "") -> str:
        for key in keys:
            values = self._map.get(key)
            if values and values[0] != "":
                return values[0]
        return default


def _b64_text(value: str) -> str:
    padded = value.strip() + ("=" * (-len(value.strip()) % 4))
    for decoder in (base64.urlsafe_b64decode, base64.b64decode):
        try:
            return decoder(padded.encode()).decode()
        except Exception:
            continue
    raise LinkError("Could not decode the base64 payload in this link.")


def _port(value: int | None, default: int | None, label: str) -> int:
    if value is None:
        if default is None:
            raise LinkError(f"{label} is missing a port.")
        value = default
    if value < 1 or value > 65535:
        raise LinkError(f"{label} has an invalid port.")
    return value


def _safe_port(parsed, label: str, default: int | None = None) -> int:
    try:
        return _port(parsed.port, default, label)
    except ValueError as exc:
        raise LinkError(f"{label} has an invalid port.") from exc


def _is_ip(host: str) -> bool:
    try:
        ipaddress.ip_address(host)
    except ValueError:
        return False
    return True


def _meta(kind: str, server: str, port: int, name: str, security: str, transport: str) -> dict:
    return {
        "kind": kind,
        "server": server,
        "port": port,
        "name": name,
        "security": security or "none",
        "transport": transport,
    }


def _tls(server: str, query: Query, *, reality: bool) -> dict:
    tls: dict = {"enabled": True}
    sni = query.first("sni", "peer", "serverName", "servername", default=server)
    if sni:
        tls["server_name"] = sni
    alpn = query.first("alpn")
    if alpn:
        items = [item.strip() for item in alpn.split(",") if item.strip()]
        if items:
            tls["alpn"] = items
    fingerprint = query.first("fp", "fingerprint")
    if fingerprint:
        tls["utls"] = {"enabled": True, "fingerprint": fingerprint}
    allow = query.first("allowInsecure", "insecure", "allow_insecure").lower()
    if allow in ("1", "true", "yes"):
        tls["insecure"] = True
    if reality:
        public_key = query.first("pbk", "publicKey", "public_key")
        if not public_key:
            raise LinkError("Reality needs a public key (pbk).")
        reality_block: dict = {"enabled": True, "public_key": public_key}
        short_id = query.first("sid", "shortId", "short_id")
        if short_id:
            reality_block["short_id"] = short_id
        tls["reality"] = reality_block
    return tls


def _transport(network: str, query: Query, host_header: str = "", path_value: str = "") -> dict | None:
    key = network.lower()
    if key in ("xhttp", "splithttp"):
        raise LinkError(
            "XHTTP is not supported by the bundled sing-box build. "
            "Use TCP, WebSocket, gRPC, HTTP, HTTPUpgrade, or QUIC."
        )
    if key in ("kcp", "mkcp"):
        raise LinkError("mKCP is not supported. Use TCP, WebSocket, gRPC, HTTP, HTTPUpgrade, or QUIC.")
    if key not in SUPPORTED_TRANSPORTS:
        raise LinkError(f"Unsupported transport: {network}")
    canonical = SUPPORTED_TRANSPORTS[key]
    header_type = query.first("headerType", "header_type").lower()
    if canonical == "tcp":
        if header_type == "http":
            raise LinkError("TCP header obfuscation (headerType=http) is not supported.")
        return None

    path = query.first("path", default=path_value)
    host = query.first("host", default=host_header)

    if canonical == "ws":
        block: dict = {"type": "ws", "path": path or "/"}
        if host:
            block["headers"] = {"Host": host}
        early = query.first("ed", "max_early_data")
        if early.isdigit():
            block["max_early_data"] = int(early)
        early_header = query.first("eh", "early_data_header_name")
        if early_header:
            block["early_data_header_name"] = early_header
        return block

    if canonical == "grpc":
        service = query.first("serviceName", "service_name", "path", default=path_value)
        block = {"type": "grpc"}
        if service:
            block["service_name"] = service
        return block

    if canonical == "http":
        block = {"type": "http", "path": path or "/"}
        if host:
            block["host"] = [item.strip() for item in host.split(",") if item.strip()]
        return block

    if canonical == "httpupgrade":
        block = {"type": "httpupgrade", "path": path or "/"}
        if host:
            block["host"] = host
        return block

    return {"type": "quic"}


def _packet_encoding(outbound: dict, query: Query) -> None:
    encoding = query.first("packetEncoding", "packet_encoding").lower()
    if encoding in ("xudp", "packetaddr"):
        outbound["packet_encoding"] = encoding


def _http_outbound(parsed) -> tuple[dict, dict]:
    host = parsed.hostname
    if not host:
        raise LinkError("HTTP proxy must look like http://host:port")
    port = _safe_port(parsed, "HTTP proxy")
    outbound: dict = {"type": "http", "server": host, "server_port": port}
    if parsed.username:
        outbound["username"] = unquote(parsed.username)
        outbound["password"] = unquote(parsed.password or "")
    security = "tls" if (parsed.scheme or "").lower() == "https" else "none"
    if security == "tls":
        outbound["tls"] = {"enabled": True, "server_name": host}
    return outbound, _meta("http", host, port, unquote(parsed.fragment or ""), security, "-")


def _socks_outbound(parsed) -> tuple[dict, dict]:
    host = parsed.hostname
    if not host:
        raise LinkError("SOCKS proxy must look like socks5://host:port")
    port = _safe_port(parsed, "SOCKS proxy")
    scheme = (parsed.scheme or "socks5").lower()
    version = "5"
    kind = "socks5"
    if scheme == "socks4":
        version, kind = "4", "socks4"
    elif scheme == "socks4a":
        version, kind = "4a", "socks4a"
    outbound: dict = {
        "type": "socks",
        "server": host,
        "server_port": port,
        "version": version,
    }
    if parsed.username:
        outbound["username"] = unquote(parsed.username)
        outbound["password"] = unquote(parsed.password or "")
    return outbound, _meta(kind, host, port, unquote(parsed.fragment or ""), "none", "-")


def _vless_outbound(parsed) -> tuple[dict, dict]:
    user = unquote(parsed.username or "")
    host = parsed.hostname
    if not user or not host:
        raise LinkError("VLESS link needs a UUID and a server.")
    query = Query(parsed.query)
    security = query.first("security").lower()
    if security not in ("", "none", "tls", "reality", "xtls"):
        raise LinkError(f"Unsupported VLESS security: {security}")
    default_port = 443 if security in ("tls", "reality", "xtls") else None
    port = _safe_port(parsed, "VLESS link", default_port)
    network = query.first("type", "network", default="tcp")
    encryption = query.first("encryption")
    if encryption and encryption.lower() != "none":
        raise LinkError("This VLESS encryption mode is not supported. Use encryption=none.")

    outbound: dict = {"type": "vless", "server": host, "server_port": port, "uuid": user}
    transport = _transport(network, query)
    flow = query.first("flow")
    if flow:
        if transport is not None:
            raise LinkError("VLESS flow only works with TCP. Remove flow or set type=tcp.")
        outbound["flow"] = flow
    if security == "reality":
        outbound["tls"] = _tls(host, query, reality=True)
    elif security in ("tls", "xtls"):
        outbound["tls"] = _tls(host, query, reality=False)
    if transport is not None:
        outbound["transport"] = transport
    _packet_encoding(outbound, query)
    shown = security if security not in ("", "xtls") else ("tls" if security == "xtls" else "none")
    return outbound, _meta(
        "vless", host, port, unquote(parsed.fragment or ""), shown, SUPPORTED_TRANSPORTS[network.lower()]
    )


def _vmess_outbound(raw: str) -> tuple[dict, dict]:
    payload = raw[len("vmess://"):].split("#", 1)[0].strip()
    try:
        obj = json.loads(_b64_text(payload))
    except LinkError:
        raise
    except Exception as exc:
        raise LinkError("Invalid VMess link.") from exc
    if not isinstance(obj, dict):
        raise LinkError("Invalid VMess link.")

    server = str(obj.get("add") or "").strip()
    header_host = str(obj.get("host") or "").strip()
    if not server:
        server = header_host
        header_host = ""
    uuid = str(obj.get("id") or "").strip()
    try:
        port = int(obj.get("port"))
    except (TypeError, ValueError) as exc:
        raise LinkError("Invalid VMess link.") from exc
    port = _port(port, None, "VMess link")
    if not server or not uuid:
        raise LinkError("Invalid VMess link.")

    security_cipher = str(obj.get("scy") or "auto")
    try:
        alter_id = int(obj.get("aid") or 0)
    except (TypeError, ValueError):
        alter_id = 0
    outbound: dict = {
        "type": "vmess",
        "server": server,
        "server_port": port,
        "uuid": uuid,
        "security": security_cipher or "auto",
        "alter_id": alter_id,
    }
    query = Query("")
    query._map = {
        "path": [str(obj.get("path") or "")],
        "host": [header_host],
        "serviceName": [str(obj.get("serviceName") or obj.get("path") or "")],
        "headerType": [str(obj.get("type") or "")],
        "sni": [str(obj.get("sni") or "")],
        "fp": [str(obj.get("fp") or "")],
        "alpn": [str(obj.get("alpn") or "")],
        "pbk": [str(obj.get("pbk") or "")],
        "sid": [str(obj.get("sid") or "")],
        "allowInsecure": [str(obj.get("allowInsecure") or "")],
    }
    network = str(obj.get("net") or "tcp")
    transport = _transport(network, query, host_header=header_host, path_value=str(obj.get("path") or ""))
    tls_value = str(obj.get("tls") or "").lower()
    security = "none"
    if tls_value == "reality":
        outbound["tls"] = _tls(server, query, reality=True)
        security = "reality"
    elif tls_value and tls_value != "none":
        outbound["tls"] = _tls(server, query, reality=False)
        security = "tls"
    if transport is not None:
        outbound["transport"] = transport
    name = str(obj.get("ps") or "")
    canonical = SUPPORTED_TRANSPORTS.get(network.lower(), network.lower())
    return outbound, _meta("vmess", server, port, name, security, canonical)


def _trojan_outbound(parsed) -> tuple[dict, dict]:
    password = unquote(parsed.username or "")
    host = parsed.hostname
    if not password or not host:
        raise LinkError("Trojan link needs a password and a server.")
    query = Query(parsed.query)
    security = query.first("security", default="tls").lower()
    if security not in ("tls", "reality", "none", "xtls"):
        raise LinkError(f"Unsupported Trojan security: {security}")
    port = _safe_port(parsed, "Trojan link", 443)
    network = query.first("type", "network", default="tcp")
    outbound: dict = {"type": "trojan", "server": host, "server_port": port, "password": password}
    transport = _transport(network, query)
    if security == "reality":
        outbound["tls"] = _tls(host, query, reality=True)
    elif security in ("tls", "xtls"):
        outbound["tls"] = _tls(host, query, reality=False)
    if transport is not None:
        outbound["transport"] = transport
    shown = "tls" if security == "xtls" else security
    return outbound, _meta(
        "trojan", host, port, unquote(parsed.fragment or ""), shown, SUPPORTED_TRANSPORTS[network.lower()]
    )


def _split_method_password(userinfo: str) -> tuple[str, str]:
    if ":" in userinfo:
        method, password = userinfo.split(":", 1)
        if method in SS_METHODS and password != "":
            return method, password
    decoded = _b64_text(userinfo)
    if ":" not in decoded:
        raise LinkError("Shadowsocks user info must contain a method and a password.")
    method, password = decoded.split(":", 1)
    if not method or password == "":
        raise LinkError("Shadowsocks user info must contain a method and a password.")
    return method, password


def _shadowsocks_outbound(raw: str) -> tuple[dict, dict]:
    body, _, fragment = raw[len("ss://"):].partition("#")
    parsed = urlparse(raw)
    name = unquote(fragment)
    # SIP002 puts userinfo and host around '@'. Legacy is one base64 blob.
    if "@" in body:
        port = _safe_port(parsed, "Shadowsocks link")
        userinfo = unquote(parsed.username or "")
        if parsed.password is not None and ":" not in userinfo:
            userinfo = userinfo + ":" + unquote(parsed.password)
        if not userinfo:
            raise LinkError("Shadowsocks link is missing method and password.")
        method, password = _split_method_password(userinfo)
        host = parsed.hostname
        query = Query(parsed.query)
    else:
        decoded = _b64_text(body)
        if "@" not in decoded or ":" not in decoded:
            raise LinkError("Invalid Shadowsocks link.")
        userinfo, hostport = decoded.rsplit("@", 1)
        if ":" not in hostport:
            raise LinkError("Invalid Shadowsocks link.")
        host, port_text = hostport.rsplit(":", 1)
        host = host.strip("[]")
        try:
            port = _port(int(port_text), None, "Shadowsocks link")
        except ValueError as exc:
            raise LinkError("Invalid Shadowsocks link.") from exc
        method, password = _split_method_password(userinfo)
        query = Query("")

    outbound: dict = {
        "type": "shadowsocks",
        "server": host,
        "server_port": port,
        "method": method,
        "password": password,
    }
    plugin = unquote(query.first("plugin"))
    if plugin:
        plugin_name, _, plugin_opts = plugin.partition(";")
        if plugin_name not in ("v2ray-plugin", "obfs-local"):
            raise LinkError(f"Unsupported Shadowsocks plugin: {plugin_name}")
        outbound["plugin"] = plugin_name
        if plugin_opts:
            outbound["plugin_opts"] = plugin_opts
    return outbound, _meta("shadowsocks", host, port, name, "none", "-")


def parse_link(raw: str) -> tuple[dict, dict]:
    raw = raw.strip()
    if not raw:
        raise LinkError("Uplink cannot be empty.")
    scheme = raw.split(":", 1)[0].lower()
    parsed = urlparse(raw)
    if scheme in ("http", "https"):
        return _http_outbound(parsed)
    if scheme in ("socks", "socks5", "socks4", "socks4a"):
        return _socks_outbound(parsed)
    if scheme == "vless":
        return _vless_outbound(parsed)
    if scheme == "vmess":
        return _vmess_outbound(raw)
    if scheme == "trojan":
        return _trojan_outbound(parsed)
    if scheme == "ss":
        return _shadowsocks_outbound(raw)
    raise LinkError("Supported links: http, https, socks5, socks4, vless, vmess, trojan, ss.")


def _protect_cidrs(values: list[str]) -> list[str]:
    cidrs: list[str] = []
    for value in values:
        value = value.strip()
        if not value:
            continue
        try:
            ip = ipaddress.ip_address(value)
        except ValueError as exc:
            raise LinkError(f"Not an IP address: {value}") from exc
        cidrs.append(f"{ip}/{ip.max_prefixlen}")
    return cidrs


def build_config(
    raw: str,
    listen_port: int,
    scope: str,
    protect_ips: list[str] | None = None,
    auto_redirect: bool = True,
) -> dict:
    if scope not in ("tool", "system", "tunnel"):
        raise LinkError(f"Unknown scope: {scope}")
    if listen_port < 1 or listen_port > 65535:
        raise LinkError("Listen port is invalid.")

    outbound, _meta_info = parse_link(raw)
    outbound["tag"] = "proxy"
    if not _is_ip(str(outbound.get("server", ""))):
        outbound["domain_resolver"] = "local"

    mixed = {
        "type": "mixed",
        "tag": "mixed-in",
        "listen": LISTEN_HOST,
        "listen_port": listen_port,
    }
    inbounds = [mixed]
    rules: list[dict] = [
        {"action": "sniff"},
        {"protocol": "dns", "action": "hijack-dns"},
    ]
    protect = _protect_cidrs(protect_ips or [])
    if scope == "tunnel" and protect:
        rules.append({"ip_cidr": protect, "action": "route", "outbound": "direct"})
    rules.append(dict(PRIVATE_RULE))

    if scope == "tunnel":
        tun: dict = {
            "type": "tun",
            "tag": "tun-in",
            "interface_name": TUN_INTERFACE,
            "address": list(TUN_ADDRESS),
            "mtu": 1500,
            "auto_route": True,
            "strict_route": True,
            "auto_redirect": auto_redirect,
            "stack": "mixed",
        }
        if protect:
            tun["route_exclude_address"] = protect
        inbounds.append(tun)

    return {
        "log": {"level": "warn", "timestamp": True},
        "dns": {
            "servers": [
                {"type": "local", "tag": "local"},
                {
                    "type": "udp",
                    "tag": "remote",
                    "server": "1.1.1.1",
                    "server_port": 53,
                    "detour": "proxy",
                },
            ],
            "final": "remote",
            "strategy": "prefer_ipv4",
        },
        "inbounds": inbounds,
        "outbounds": [
            outbound,
            {"type": "direct", "tag": "direct"},
        ],
        "route": {
            "auto_detect_interface": True,
            "default_domain_resolver": "local",
            "rules": rules,
            "final": "proxy",
        },
    }


def _emit_shell(meta: dict) -> None:
    fields = ("kind", "server", "port", "name", "security", "transport")
    for key in fields:
        print(f"AETHER_{key.upper()}={shlex.quote(str(meta[key]))}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="link.py")
    sub = parser.add_subparsers(dest="command", required=True)

    parse_cmd = sub.add_parser("parse")
    parse_cmd.add_argument("--link", required=True)
    parse_cmd.add_argument("--json", action="store_true")

    render_cmd = sub.add_parser("render")
    render_cmd.add_argument("--link", required=True)
    render_cmd.add_argument("--out", required=True)
    render_cmd.add_argument("--port", required=True, type=int)
    render_cmd.add_argument("--scope", required=True, choices=("tool", "system", "tunnel"))
    render_cmd.add_argument("--protect-ip", action="append", default=[])
    render_cmd.add_argument("--no-auto-redirect", action="store_true")

    args = parser.parse_args(argv)
    try:
        if args.command == "parse":
            _outbound, meta = parse_link(args.link)
            if args.json:
                json.dump(meta, sys.stdout, ensure_ascii=False)
                sys.stdout.write("\n")
            else:
                _emit_shell(meta)
            return 0

        config = build_config(
            args.link,
            args.port,
            "tunnel" if args.scope == "tunnel" else "tool",
            protect_ips=args.protect_ip,
            auto_redirect=not args.no_auto_redirect,
        )
        payload = json.dumps(config, indent=2, ensure_ascii=False) + "\n"
        temporary = args.out + ".tmp"
        with open(temporary, "w", encoding="utf-8") as handle:
            handle.write(payload)
        os.chmod(temporary, 0o600)
        os.replace(temporary, args.out)
        os.chmod(args.out, 0o600)
        return 0
    except LinkError as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
