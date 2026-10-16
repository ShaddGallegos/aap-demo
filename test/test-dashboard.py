#!/usr/bin/env python3
"""Tests for the local aap-demo dashboard."""

from __future__ import annotations

import importlib.util
import json
import re
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
SERVER_PATH = REPO_ROOT / "dashboard" / "server.py"
SPEC = importlib.util.spec_from_file_location("aap_demo_dashboard", SERVER_PATH)
assert SPEC and SPEC.loader
dashboard = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = dashboard
SPEC.loader.exec_module(dashboard)


def fixture_inventory() -> dict[str, Any]:
    return {
        "addons": ["mcp-server", "ao", "ollama"],
        "api_keys": {"ao_llm": {"provider": "ollama"}},
        "pods": [
            {
                "namespace": "aap-operator",
                "name": "aap-mcp-server-abc",
                "phase": "Running",
                "ready_containers": 1,
                "total_containers": 1,
            },
            {
                "namespace": "automation-orchestrator",
                "name": "automation-orchestrator-ui-abc",
                "phase": "Running",
                "ready_containers": 1,
                "total_containers": 1,
            },
            {
                "namespace": "aap-demo-ollama",
                "name": "ollama-abc",
                "phase": "Running",
                "ready_containers": 1,
                "total_containers": 1,
            },
        ],
        "cluster": {"state": "running"},
        "storage": {
            "capacity_planning": {
                "actual_vm_disk_gib": 140,
                "actual_vm_used_gib": 110,
                "actual_vm_free_gib": 30,
                "configured_crc_disk_gib": 160,
                "recommended_vm_disk_gib": 160,
                "host_only_gib": 0,
                "needs_rebuild": True,
                "configured_not_applied": True,
                "addon_estimates": {
                    "mcp-server": {"vm_gib": 3, "host_gib": 0},
                    "portal": {"vm_gib": 8, "host_gib": 0},
                },
                "projected_vm_disk_gib": {
                    "mcp-server": 160,
                    "portal": 170,
                },
            }
        },
        "routes": [],
        "namespaces": [],
    }


class DashboardUnitTests(unittest.TestCase):
    def setUp(self) -> None:
        self.catalog = dashboard.load_catalog(REPO_ROOT)
        self.addons = {addon["id"]: addon for addon in self.catalog["addons"]}

    def test_catalog_matches_public_cli_addons(self) -> None:
        cli = (REPO_ROOT / "aap-demo.sh").read_text(encoding="utf-8")
        match = re.search(r'^AVAILABLE_ADDONS="([^"]+)"', cli, re.MULTILINE)
        self.assertIsNotNone(match)
        cli_addons = set(match.group(1).split())
        catalog_addons = {addon["id"] for addon in self.catalog["addons"]}
        self.assertEqual(cli_addons, catalog_addons)

    def test_health_and_conditional_dependencies(self) -> None:
        inventory = fixture_inventory()
        self.assertEqual(dashboard.addon_state(self.addons["mcp-server"], inventory), "running")
        self.assertEqual(dashboard.addon_state(self.addons["portal"], inventory), "disabled")
        self.assertEqual(
            dashboard.active_dependencies(self.addons["ao"], inventory),
            ["mcp-server", "ollama"],
        )
        inventory["api_keys"]["ao_llm"]["provider"] = "external"
        self.assertEqual(
            dashboard.active_dependencies(self.addons["ao"], inventory),
            ["mcp-server"],
        )

    def test_operation_output_redacts_credentials(self) -> None:
        output = (
            "Authorization: Bearer secret-token\n"
            "Password: secret-password\n"
            "token=another-token\n"
            "aap-operator: admin / final-secret"
        )
        redacted = dashboard.redact_output(output)
        for secret in ("secret-token", "secret-password", "another-token", "final-secret"):
            self.assertNotIn(secret, redacted)
        self.assertGreaterEqual(redacted.count("******"), 4)

    def test_operation_output_streams_before_completion(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            cli = Path(temp_dir) / "aap-demo.sh"
            cli.write_text(
                "#!/usr/bin/env bash\n"
                "echo 'phase one'\n"
                "sleep 1\n"
                "echo 'phase two'\n",
                encoding="utf-8",
            )
            cli.chmod(0o700)
            app = dashboard.DashboardApp(REPO_ROOT, 0)
            app.cli = cli
            app.start_operation("portal", "enable")
            deadline = time.monotonic() + 1
            snapshot = app.operation.snapshot()
            while "phase one" not in snapshot["output"] and time.monotonic() < deadline:
                time.sleep(0.05)
                snapshot = app.operation.snapshot()
            self.assertEqual(snapshot["status"], "running")
            self.assertIn("phase one", snapshot["output"])

            deadline = time.monotonic() + 2
            while snapshot["status"] == "running" and time.monotonic() < deadline:
                time.sleep(0.05)
                snapshot = app.operation.snapshot()
            self.assertEqual(snapshot["status"], "succeeded")
            self.assertIn("phase two", snapshot["output"])

    def test_dashboard_capacity_markup_and_rendering(self) -> None:
        markup = (REPO_ROOT / "dashboard/static/index.html").read_text(encoding="utf-8")
        script = (REPO_ROOT / "dashboard/static/app.js").read_text(encoding="utf-8")
        self.assertIn("<h1>Ansible Automation Platform - MicroShift Demo</h1>", markup)
        self.assertIn("<h2>Environment Overview</h2>", markup)
        self.assertIn('id="capacity-panel"', markup)
        self.assertIn('role="status"', markup)
        self.assertIn("Configured CRC disk", script)
        self.assertIn("Projected recommendation", script)


class DashboardHttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.app = dashboard.DashboardApp(REPO_ROOT, 0)
        cls.app.inventory = fixture_inventory
        cls.server = dashboard.ThreadingHTTPServer(
            (dashboard.HOST, 0),
            dashboard.create_handler(cls.app),
        )
        cls.port = cls.server.server_address[1]
        cls.app.port = cls.port
        cls.app.origin = f"http://{dashboard.HOST}:{cls.port}"
        cls.base_url = cls.app.origin
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def request(
        self,
        path: str,
        *,
        method: str = "GET",
        body: dict[str, Any] | None = None,
        token: str | None = None,
        origin: str | None = None,
    ) -> tuple[int, dict[str, Any]]:
        data = json.dumps(body or {}).encode() if method == "POST" else None
        headers = {"Content-Type": "application/json"}
        if token is not None:
            headers["X-AAP-Demo-Token"] = token
        if origin is not None:
            headers["Origin"] = origin
        request = urllib.request.Request(
            self.base_url + path,
            data=data,
            headers=headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=3) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            with error:
                return error.code, json.load(error)

    def test_status_is_secret_free_and_reports_addons(self) -> None:
        status, payload = self.request("/api/status")
        self.assertEqual(status, 200)
        self.assertEqual(payload["inventory"]["cluster"]["state"], "running")
        self.assertEqual(
            next(addon for addon in payload["addons"] if addon["id"] == "mcp-server")["state"],
            "running",
        )
        self.assertNotIn("credentials", payload["inventory"])
        portal = next(addon for addon in payload["addons"] if addon["id"] == "portal")
        self.assertEqual(portal["projected_vm_disk_gib"], 170)
        self.assertEqual(portal["capacity_estimate"]["vm_gib"], 8)

    def test_mutation_requires_origin_and_session_token(self) -> None:
        status, _ = self.request(
            "/api/addons/portal/enable",
            method="POST",
            origin=self.app.origin,
        )
        self.assertEqual(status, 403)
        status, _ = self.request(
            "/api/addons/portal/enable",
            method="POST",
            token=self.app.session_token,
            origin="http://attacker.invalid",
        )
        self.assertEqual(status, 403)

    def test_disable_requires_confirmation_and_protects_dependencies(self) -> None:
        status, _ = self.request(
            "/api/addons/mcp-server/disable",
            method="POST",
            token=self.app.session_token,
            origin=self.app.origin,
        )
        self.assertEqual(status, 400)
        status, payload = self.request(
            "/api/addons/mcp-server/disable",
            method="POST",
            body={"confirm": True},
            token=self.app.session_token,
            origin=self.app.origin,
        )
        self.assertEqual(status, 409)
        self.assertIn("ao", payload["error"])

    def test_allowlisted_enable_operation_is_accepted(self) -> None:
        original = self.app.start_operation
        self.app.start_operation = lambda addon, action: {
            "id": "fixture",
            "addon": addon,
            "action": action,
            "status": "running",
        }
        try:
            status, payload = self.request(
                "/api/addons/portal/enable",
                method="POST",
                body={},
                token=self.app.session_token,
                origin=self.app.origin,
            )
        finally:
            self.app.start_operation = original
        self.assertEqual(status, 202)
        self.assertEqual(payload["addon"], "portal")

    def test_invalid_host_is_rejected(self) -> None:
        request = urllib.request.Request(
            self.base_url + "/api/status",
            headers={"Host": "attacker.invalid"},
        )
        with self.assertRaises(urllib.error.HTTPError) as context:
            urllib.request.urlopen(request, timeout=3)
        self.assertEqual(context.exception.code, 403)
        context.exception.close()

    def test_security_headers_are_present(self) -> None:
        request = urllib.request.Request(self.base_url + "/")
        with urllib.request.urlopen(request, timeout=3) as response:
            self.assertEqual(response.headers["X-Frame-Options"], "DENY")
            self.assertIn("frame-ancestors 'none'", response.headers["Content-Security-Policy"])


if __name__ == "__main__":
    unittest.main()
