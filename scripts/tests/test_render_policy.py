#!/usr/bin/env python3
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from .. import render_policy


class RenderPolicyTests(unittest.TestCase):
    def test_exact_hosts_and_ports(self) -> None:
        policy = render_policy.render(
            "example.com\napi.example.com:443\n",
        )
        self.assertIn('Host::"example.com"', policy)
        self.assertIn('Host::"api.example.com:443"', policy)

    def test_wildcard_is_explicit_and_rendered(self) -> None:
        policy = render_policy.render("*.example.com\n")
        self.assertIn('Host::"*.example.com"', policy)

    def test_no_wildcard_all(self) -> None:
        policy = render_policy.render("example.com\n", ["192.0.2.53"])
        self.assertNotIn('Host::"*"', policy)
        self.assertNotRegex(policy, r'Host::"\*"')

    def test_rejects_bare_star(self) -> None:
        with self.assertRaises(render_policy.PolicyError):
            render_policy.parse_allowlist("*\n")

    def test_rejects_scheme_path_credentials_and_query(self) -> None:
        for bad in (
            "https://example.com",
            "example.com/path",
            "user@example.com",
            "example.com?x=1",
        ):
            with self.subTest(bad=bad):
                with self.assertRaises(render_policy.PolicyError):
                    render_policy.parse_allowlist(bad + "\n")

    def test_rejects_bad_ports(self) -> None:
        for bad in (
            "example.com:0",
            "example.com:65536",
            "example.com:abc",
            ":443",
        ):
            with self.subTest(bad=bad):
                with self.assertRaises(render_policy.PolicyError):
                    render_policy.parse_allowlist(bad + "\n")

    def test_rejects_single_label_and_single_label_wildcard(self) -> None:
        for bad in ("localhost", "*.com", "com", "*.localhost"):
            with self.subTest(bad=bad):
                with self.assertRaises(render_policy.PolicyError):
                    render_policy.parse_allowlist(bad + "\n")

    def test_rejects_trailing_dot_and_inner_wildcard(self) -> None:
        for bad in ("example.com.", "api.*.example.com", "**.example.com"):
            with self.subTest(bad=bad):
                with self.assertRaises(render_policy.PolicyError):
                    render_policy.parse_allowlist(bad + "\n")

    def test_deduplicates_and_sorts(self) -> None:
        entries = render_policy.parse_allowlist(
            "www.example.com\nexample.com\nwww.example.com\n"
        )
        self.assertEqual(
            entries,
            [("example.com", None), ("www.example.com", None)],
        )

    def test_comments_and_blank_lines_are_ignored(self) -> None:
        entries = render_policy.parse_allowlist(
            "# comment\n\n   \nexample.com\n  # indented comment\n"
        )
        self.assertEqual(entries, [("example.com", None)])

    def test_dns_and_localhost_are_permitted(self) -> None:
        policy = render_policy.render("example.com\n", ["192.0.2.53"])
        self.assertIn('Host::"127.0.0.1"', policy)
        self.assertIn('Host::"192.0.2.53:53"', policy)
        self.assertIn('Host::"127.0.0.11:53"', policy)
        self.assertIn('Host::"127.0.0.53:53"', policy)

    def test_localhost_can_be_disabled(self) -> None:
        policy = render_policy.render(
            "example.com\n", include_localhost=False
        )
        self.assertNotIn('Host::"127.0.0.1"', policy)

    def test_empty_allowlist_is_rejected(self) -> None:
        with self.assertRaises(render_policy.PolicyError):
            render_policy.render("# only comments\n")

    def test_invalid_dns_is_rejected(self) -> None:
        with self.assertRaises(render_policy.PolicyError):
            render_policy.render("example.com\n", ["not-an-ip"])

    def test_render_is_deterministic(self) -> None:
        text = "b.example.com\na.example.com\nb.example.com\n"
        self.assertEqual(
            render_policy.render(text, ["192.0.2.53"]),
            render_policy.render(text, ["192.0.2.53"]),
        )

    def test_cli_roundtrip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            allowlist = root / "allowlist.txt"
            output = root / "nested" / "policy.cedar"
            allowlist.write_text("example.com\n", encoding="utf-8")
            rc = render_policy.main(
                [
                    "--allowlist",
                    str(allowlist),
                    "--output",
                    str(output),
                    "--dns",
                    "192.0.2.53",
                ]
            )
            self.assertEqual(rc, 0)
            policy = output.read_text(encoding="utf-8")
            self.assertIn('Host::"example.com"', policy)
            self.assertIn('Host::"192.0.2.53:53"', policy)
            self.assertNotIn('Host::"*"', policy)


if __name__ == "__main__":
    unittest.main(verbosity=2)
