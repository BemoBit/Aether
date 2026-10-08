#!/usr/bin/env python3
"""Parser and sing-box config tests. No root and no network."""

from __future__ import annotations

import base64
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

from link import LinkError, build_config, parse_link  # noqa: E402

UUID = "123e4567-e89b-12d3-a456-426614174000"


def meta(link: str) -> dict:
    _outbound, info = parse_link(link)
    return info


def outbound(link: str) -> dict:
    item, _info = parse_link(link)
    return item


class ParseTests(unittest.TestCase):
    def test_vless_reality_tcp(self) -> None:
        link = (
            f"vless://{UUID}@example.com:443?encryption=none&flow=xtls-rprx-vision"
            "&security=reality&sni=www.example.com&fp=chrome&pbk=PUBLICKEY&sid=abcd"
            "&type=tcp&headerType=none#Node"
        )
        item = outbound(link)
        info = meta(link)
        self.assertEqual(item["type"], "vless")
        self.assertEqual(item["uuid"], UUID)
        self.assertEqual(item["flow"], "xtls-rprx-vision")
        self.assertNotIn("transport", item)
        self.assertEqual(item["tls"]["reality"]["public_key"], "PUBLICKEY")
        self.assertEqual(item["tls"]["reality"]["short_id"], "abcd")
        self.assertEqual(item["tls"]["utls"]["fingerprint"], "chrome")
        self.assertEqual(info["security"], "reality")
        self.assertEqual(info["transport"], "tcp")
        self.assertEqual(info["name"], "Node")

    def test_vless_ws_tls_and_early_data(self) -> None:
        link = (
            f"vless://{UUID}@example.com:443?encryption=none&security=tls"
            "&sni=www.example.com&type=ws&host=www.example.com&path=%2Fws&ed=2048#ws"
        )
        item = outbound(link)
        self.assertEqual(item["transport"]["type"], "ws")
        self.assertEqual(item["transport"]["path"], "/ws")
        self.assertEqual(item["transport"]["headers"]["Host"], "www.example.com")
        self.assertEqual(item["transport"]["max_early_data"], 2048)
        self.assertEqual(item["tls"]["server_name"], "www.example.com")
        self.assertNotIn("flow", item)

    def test_vless_grpc(self) -> None:
        link = (
            f"vless://{UUID}@example.com:443?encryption=none&security=tls"
            "&type=grpc&serviceName=gun&sni=www.example.com"
        )
        item = outbound(link)
        self.assertEqual(item["transport"]["type"], "grpc")
        self.assertEqual(item["transport"]["service_name"], "gun")

    def test_vless_httpupgrade(self) -> None:
        link = (
            f"vless://{UUID}@example.com:443?encryption=none&security=tls"
            "&type=httpupgrade&path=%2Fup&host=www.example.com&sni=www.example.com"
        )
        self.assertEqual(outbound(link)["transport"]["type"], "httpupgrade")

    def test_vless_xhttp_rejected(self) -> None:
        link = f"vless://{UUID}@example.com:443?encryption=none&security=tls&type=xhttp&path=%2F"
        with self.assertRaises(LinkError) as raised:
            parse_link(link)
        self.assertIn("XHTTP", str(raised.exception))

    def test_vless_flow_with_ws_rejected(self) -> None:
        link = (
            f"vless://{UUID}@example.com:443?encryption=none&security=tls"
            "&type=ws&path=%2F&flow=xtls-rprx-vision"
        )
        with self.assertRaises(LinkError):
            parse_link(link)

    def test_vless_encryption_rejected(self) -> None:
        link = f"vless://{UUID}@example.com:443?encryption=mlkem768x25519plus&security=tls&type=tcp"
        with self.assertRaises(LinkError):
            parse_link(link)

    def test_vless_reality_requires_pbk(self) -> None:
        link = f"vless://{UUID}@example.com:443?encryption=none&security=reality&type=tcp"
        with self.assertRaises(LinkError):
            parse_link(link)

    def test_vmess_ws(self) -> None:
        payload = {
            "v": "2",
            "ps": "vm",
            "add": "example.com",
            "port": "443",
            "id": UUID,
            "aid": "0",
            "scy": "auto",
            "net": "ws",
            "type": "none",
            "host": "www.example.com",
            "path": "/vm",
            "tls": "tls",
            "sni": "www.example.com",
        }
        encoded = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode()
        item = outbound("vmess://" + encoded)
        info = meta("vmess://" + encoded)
        self.assertEqual(item["type"], "vmess")
        self.assertEqual(item["alter_id"], 0)
        self.assertEqual(item["transport"]["path"], "/vm")
        self.assertEqual(item["tls"]["server_name"], "www.example.com")
        self.assertEqual(info["name"], "vm")
        self.assertEqual(info["transport"], "ws")

    def test_trojan_tls(self) -> None:
        link = "trojan://secret@example.com:443?security=tls&sni=www.example.com&type=tcp#tr"
        item = outbound(link)
        self.assertEqual(item["password"], "secret")
        self.assertTrue(item["tls"]["enabled"])
        self.assertNotIn("transport", item)
        self.assertEqual(meta(link)["name"], "tr")

    def test_shadowsocks_sip002(self) -> None:
        userinfo = base64.urlsafe_b64encode(b"aes-256-gcm:secret").decode().rstrip("=")
        link = f"ss://{userinfo}@example.com:8388#ss"
        item = outbound(link)
        self.assertEqual(item["method"], "aes-256-gcm")
        self.assertEqual(item["password"], "secret")
        self.assertEqual(item["server_port"], 8388)
        self.assertEqual(meta(link)["name"], "ss")

    def test_shadowsocks_plain_userinfo(self) -> None:
        item = outbound("ss://aes-256-gcm:secret@example.com:8388")
        self.assertEqual(item["method"], "aes-256-gcm")
        self.assertEqual(item["password"], "secret")

    def test_shadowsocks_legacy(self) -> None:
        encoded = base64.urlsafe_b64encode(b"aes-256-gcm:secret@example.com:8388").decode()
        item = outbound("ss://" + encoded)
        self.assertEqual(item["server"], "example.com")
        self.assertEqual(item["server_port"], 8388)

    def test_http_auth(self) -> None:
        item = outbound("http://user:p%40ss@proxy.example.com:8080")
        self.assertEqual(item["username"], "user")
        self.assertEqual(item["password"], "p@ss")
        self.assertEqual(item["server_port"], 8080)

    def test_https_proxy_enables_tls(self) -> None:
        item = outbound("https://proxy.example.com:443")
        self.assertTrue(item["tls"]["enabled"])

    def test_socks5(self) -> None:
        item = outbound("socks5://user:secret@127.0.0.1:1080")
        self.assertEqual(item["version"], "5")
        self.assertEqual(item["username"], "user")

    def test_socks4(self) -> None:
        self.assertEqual(outbound("socks4://10.0.0.1:1080")["version"], "4")

    def test_empty_and_unknown(self) -> None:
        with self.assertRaises(LinkError):
            parse_link("   ")
        with self.assertRaises(LinkError):
            parse_link("hysteria2://example.com:443")

    def test_ipv6_host(self) -> None:
        item = outbound(f"vless://{UUID}@[2001:db8::1]:443?encryption=none&security=tls&type=tcp")
        self.assertEqual(item["server"], "2001:db8::1")


class ConfigTests(unittest.TestCase):
    LINK = "socks5://10.1.1.1:1080"

    def test_tool_binds_loopback_only(self) -> None:
        config = build_config(self.LINK, 2080, "tool")
        self.assertEqual(len(config["inbounds"]), 1)
        inbound = config["inbounds"][0]
        self.assertEqual(inbound["type"], "mixed")
        self.assertEqual(inbound["listen"], "127.0.0.1")
        self.assertEqual(inbound["listen_port"], 2080)
        self.assertEqual(config["route"]["final"], "proxy")
        self.assertEqual(config["route"]["default_domain_resolver"], "local")
        self.assertEqual(config["dns"]["final"], "remote")
        proxy = config["outbounds"][0]
        self.assertEqual(proxy["tag"], "proxy")
        self.assertNotIn("domain_resolver", proxy)

    def test_domain_uplink_uses_local_resolver(self) -> None:
        config = build_config("socks5://proxy.example.com:1080", 2080, "system")
        self.assertEqual(config["outbounds"][0]["domain_resolver"], "local")
        self.assertEqual(len(config["inbounds"]), 1)

    def test_tunnel_has_tun_and_ssh_exclude(self) -> None:
        config = build_config(
            self.LINK,
            2080,
            "tunnel",
            protect_ips=["203.0.113.10"],
            auto_redirect=True,
        )
        kinds = [item["type"] for item in config["inbounds"]]
        self.assertEqual(kinds, ["mixed", "tun"])
        tun = config["inbounds"][1]
        self.assertEqual(tun["interface_name"], "aether0")
        self.assertTrue(tun["auto_route"])
        self.assertTrue(tun["strict_route"])
        self.assertTrue(tun["auto_redirect"])
        self.assertIn("203.0.113.10/32", tun["route_exclude_address"])
        cidr_rule = config["route"]["rules"][2]
        self.assertEqual(cidr_rule["ip_cidr"], ["203.0.113.10/32"])
        self.assertEqual(cidr_rule["outbound"], "direct")

    def test_tunnel_can_disable_auto_redirect(self) -> None:
        config = build_config(self.LINK, 2080, "tunnel", auto_redirect=False)
        self.assertFalse(config["inbounds"][1]["auto_redirect"])

    def test_bad_protect_ip(self) -> None:
        with self.assertRaises(LinkError):
            build_config(self.LINK, 2080, "tunnel", protect_ips=["not-an-ip"])

    def test_secrets_stay_out_of_meta(self) -> None:
        info = meta("http://user:secret@proxy.example.com:8080")
        blob = json.dumps(info)
        self.assertNotIn("secret", blob)
        self.assertNotIn("user", blob)


if __name__ == "__main__":
    unittest.main()
