#!/usr/bin/env python3
"""Local-only aap-demo dashboard server."""

from __future__ import annotations

import argparse
import json
import os
import platform
import queue
import re
import secrets
import subprocess
import sys
import threading
import time
import webbrowser
from dataclasses import dataclass, field
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.error import URLError
from urllib.parse import urlparse
from urllib.request import ProxyHandler, build_opener

HOST = "127.0.0.1"
DEFAULT_PORT = 8765
MAX_BODY_BYTES = 4096
OPERATION_TIMEOUT_SECONDS = 3600


def load_catalog(repo_root: Path) -> dict[str, Any]:
    path = repo_root / "config" / "addons-dashboard.json"
    with path.open(encoding="utf-8") as stream:
        catalog = json.load(stream)
    addons = catalog.get("addons")
    if catalog.get("schema_version") != 1 or not isinstance(addons, list):
        raise ValueError(f"Invalid dashboard add-on catalog: {path}")
    ids = [addon.get("id") for addon in addons]
    if any(not isinstance(addon_id, str) for addon_id in ids) or len(ids) != len(set(ids)):
        raise ValueError(f"Dashboard add-on IDs must be unique strings: {path}")
    return catalog


def value_at_path(document: dict[str, Any], path: list[str]) -> Any:
    value: Any = document
    for key in path:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def active_dependencies(addon: dict[str, Any], inventory: dict[str, Any]) -> list[str]:
    active: list[str] = []
    for dependency in addon.get("dependencies", []):
        condition = dependency.get("when")
        if condition and value_at_path(inventory, condition["path"]) != condition["equals"]:
            continue
        active.append(dependency["id"])
    return active


def addon_state(addon: dict[str, Any], inventory: dict[str, Any]) -> str:
    if addon["id"] not in inventory.get("addons", []):
        return "disabled"
    health = addon.get("health", {"type": "configured"})
    if health["type"] == "configured":
        return "enabled"
    pods = inventory.get("pods", [])
    if health["type"] == "namespace":
        matches = [pod for pod in pods if pod.get("namespace") == health["namespace"]]
    elif health["type"] == "pod-prefix":
        matches = [
            pod
            for pod in pods
            if pod.get("namespace") == health["namespace"]
            and pod.get("name", "").startswith(health["prefix"])
        ]
    else:
        return "unknown"
    if not matches:
        return "degraded"
    if all(
        pod.get("phase") == "Running"
        and pod.get("ready_containers") == pod.get("total_containers")
        for pod in matches
    ):
        return "running"
    return "degraded"


def redact_output(output: str) -> str:
    patterns = [
        (re.compile(r"(?i)(authorization:\s*bearer\s+)\S+"), r"\1******"),
        (re.compile(r"(?i)(password\s*[:=]\s*)\S+"), r"\1******"),
        (re.compile(r"(?i)(token\s*[:=]\s*)\S+"), r"\1******"),
        (re.compile(r"(?i)(admin\s*/\s*)\S+"), r"\1******"),
    ]
    redacted = output
    for pattern, replacement in patterns:
        redacted = pattern.sub(replacement, redacted)
    return redacted[-12000:]


@dataclass
class OperationState:
    lock: threading.Lock = field(default_factory=threading.Lock)
    operation_id: str | None = None
    addon: str | None = None
    action: str | None = None
    status: str = "idle"
    message: str = ""
    output: str = ""
    started_at: float | None = None
    completed_at: float | None = None

    def snapshot(self) -> dict[str, Any]:
        with self.lock:
            return {
                "id": self.operation_id,
                "addon": self.addon,
                "action": self.action,
                "status": self.status,
                "message": self.message,
                "output": self.output,
                "started_at": self.started_at,
                "completed_at": self.completed_at,
            }


class DashboardApp:
    def __init__(self, repo_root: Path, port: int) -> None:
        self.repo_root = repo_root
        self.port = port
        self.origin = f"http://{HOST}:{port}"
        self.session_token = secrets.token_urlsafe(32)
        self.instance_id = secrets.token_hex(12)
        self.catalog = load_catalog(repo_root)
        self.addons = {addon["id"]: addon for addon in self.catalog["addons"]}
        self.operation = OperationState()
        self.restart_requested = False
        self.cli = repo_root / "aap-demo.sh"
        self.static_dir = repo_root / "dashboard" / "static"

    def run_cli(self, *arguments: str, timeout: int = 120) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(self.cli), *arguments],
            cwd=self.repo_root,
            env=self.command_environment(),
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )

    @staticmethod
    def command_environment() -> dict[str, str]:
        environment = os.environ.copy()
        environment.update(
            {
                "QUIET": "true",
                "AAP_DEMO_NOTICE_SHOWN": "1",
            }
        )
        return environment

    def inventory(self) -> dict[str, Any]:
        result = self.run_cli("status", "--json")
        if result.returncode != 0:
            detail = redact_output(result.stderr or result.stdout).strip()
            raise RuntimeError(detail or "Unable to collect aap-demo status")
        return json.loads(result.stdout)

    def status_payload(self) -> dict[str, Any]:
        inventory = self.inventory()
        host = inventory.setdefault("host", {})
        if not host.get("os") or host["os"] == "unknown":
            host["os"] = f"{platform.system()} {platform.release()}"
        enabled = set(inventory.get("addons", []))
        addons = []
        for definition in self.catalog["addons"]:
            addon = dict(definition)
            addon["state"] = addon_state(definition, inventory)
            addon["enabled"] = definition["id"] in enabled
            addon["active_dependencies"] = active_dependencies(definition, inventory)
            capacity = inventory.get("storage", {}).get("capacity_planning", {})
            addon["capacity_estimate"] = capacity.get("addon_estimates", {}).get(
                definition["id"], {}
            )
            addon["projected_vm_disk_gib"] = capacity.get(
                "projected_vm_disk_gib", {}
            ).get(definition["id"])
            addons.append(addon)
        return {
            "inventory": inventory,
            "addons": addons,
            "operation": self.operation.snapshot(),
        }

    def dependent_addons(self, addon_id: str, inventory: dict[str, Any]) -> list[str]:
        enabled = set(inventory.get("addons", []))
        return [
            definition["id"]
            for definition in self.catalog["addons"]
            if definition["id"] in enabled
            and addon_id in active_dependencies(definition, inventory)
        ]

    def start_operation(self, addon_id: str, action: str) -> dict[str, Any]:
        with self.operation.lock:
            if self.restart_requested:
                raise RuntimeError("The dashboard is restarting")
            if self.operation.status == "running":
                raise RuntimeError("Another dashboard operation is already running")
            operation_id = secrets.token_hex(8)
            self.operation.operation_id = operation_id
            self.operation.addon = addon_id
            self.operation.action = action
            self.operation.status = "running"
            self.operation.message = f"{action.title()}ing {addon_id}"
            self.operation.output = ""
            self.operation.started_at = time.time()
            self.operation.completed_at = None
        thread = threading.Thread(
            target=self._execute_operation,
            args=(operation_id, addon_id, action),
            daemon=True,
        )
        thread.start()
        return self.operation.snapshot()

    def request_restart(self) -> None:
        with self.operation.lock:
            if self.operation.status == "running":
                raise RuntimeError("Wait for the current add-on operation before restarting the dashboard")
            if self.restart_requested:
                raise RuntimeError("The dashboard is already restarting")
            self.restart_requested = True

    def _execute_operation(self, operation_id: str, addon_id: str, action: str) -> None:
        process: subprocess.Popen[str] | None = None
        output_lines: list[str] = []
        try:
            process = subprocess.Popen(
                [str(self.cli), action, addon_id],
                cwd=self.repo_root,
                env=self.command_environment(),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            output_queue: queue.Queue[str | None] = queue.Queue()

            def read_output() -> None:
                assert process and process.stdout
                for line in process.stdout:
                    output_queue.put(line)
                output_queue.put(None)

            reader = threading.Thread(target=read_output, daemon=True)
            reader.start()
            deadline = time.monotonic() + OPERATION_TIMEOUT_SECONDS
            output_complete = False
            timed_out = False
            while process.poll() is None or not output_complete:
                if time.monotonic() >= deadline:
                    timed_out = True
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                    break
                try:
                    item = output_queue.get(timeout=0.25)
                except queue.Empty:
                    continue
                if item is None:
                    output_complete = True
                    continue
                output_lines.append(item)
                current_output = redact_output("".join(output_lines))
                with self.operation.lock:
                    if self.operation.operation_id == operation_id:
                        self.operation.output = current_output

            reader.join(timeout=2)
            while not output_queue.empty():
                item = output_queue.get_nowait()
                if item is not None:
                    output_lines.append(item)
            if process.stdout:
                process.stdout.close()
            return_code = process.wait()
            combined = "".join(output_lines)
            success = return_code == 0 and not timed_out
            message = (
                f"{addon_id} {action} completed"
                if success
                else (
                    f"{addon_id} {action} timed out"
                    if timed_out
                    else f"{addon_id} {action} failed with exit code {return_code}"
                )
            )
            status = "succeeded" if success else "failed"
        except Exception as error:  # surfaced through the operation endpoint
            if process and process.poll() is None:
                process.terminate()
            combined = str(error)
            message = f"{addon_id} {action} failed"
            status = "failed"
        with self.operation.lock:
            if self.operation.operation_id != operation_id:
                return
            self.operation.status = status
            self.operation.message = message
            self.operation.output = redact_output(combined)
            self.operation.completed_at = time.time()


def create_handler(app: DashboardApp) -> type[BaseHTTPRequestHandler]:
    class DashboardHandler(BaseHTTPRequestHandler):
        server_version = "aap-demo-dashboard/1"

        def valid_host(self) -> bool:
            if self.headers.get("Host") == f"{HOST}:{app.port}":
                return True
            self.json_response(HTTPStatus.FORBIDDEN, {"error": "Invalid request host"})
            return False

        def log_message(self, format_string: str, *args: object) -> None:
            print(f"[dashboard] {self.address_string()} {format_string % args}")

        def end_headers(self) -> None:
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header(
                "Content-Security-Policy",
                "default-src 'self'; style-src 'self'; script-src 'self'; "
                "connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'",
            )
            super().end_headers()

        def json_response(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def file_response(self, path: Path, content_type: str) -> None:
            if not path.is_file():
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            body = path.read_bytes()
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:  # noqa: N802
            if not self.valid_host():
                return
            path = urlparse(self.path).path
            if path == "/":
                self.file_response(app.static_dir / "index.html", "text/html; charset=utf-8")
            elif path == "/app.css":
                self.file_response(app.static_dir / "app.css", "text/css; charset=utf-8")
            elif path == "/app.js":
                self.file_response(app.static_dir / "app.js", "text/javascript; charset=utf-8")
            elif path == "/api/session":
                self.json_response(HTTPStatus.OK, {"token": app.session_token})
            elif path == "/api/health":
                self.json_response(HTTPStatus.OK, {
                    "service": "aap-demo-dashboard",
                    "repo_root": str(app.repo_root),
                    "pid": os.getpid(),
                    "instance": app.instance_id,
                })
            elif path == "/api/status":
                try:
                    self.json_response(HTTPStatus.OK, app.status_payload())
                except Exception as error:
                    self.json_response(
                        HTTPStatus.SERVICE_UNAVAILABLE,
                        {"error": str(error)},
                    )
            elif path == "/api/operation":
                self.json_response(HTTPStatus.OK, app.operation.snapshot())
            else:
                self.send_error(HTTPStatus.NOT_FOUND)

        def do_POST(self) -> None:  # noqa: N802
            if not self.valid_host():
                return
            if self.headers.get("Origin") != app.origin:
                self.json_response(HTTPStatus.FORBIDDEN, {"error": "Invalid request origin"})
                return
            if not secrets.compare_digest(
                self.headers.get("X-AAP-Demo-Token", ""),
                app.session_token,
            ):
                self.json_response(HTTPStatus.FORBIDDEN, {"error": "Invalid session token"})
                return
            try:
                content_length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                self.json_response(HTTPStatus.BAD_REQUEST, {"error": "Invalid content length"})
                return
            if content_length < 0 or content_length > MAX_BODY_BYTES:
                self.json_response(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "Request is too large"})
                return
            try:
                body = json.loads(self.rfile.read(content_length) or b"{}")
            except json.JSONDecodeError:
                self.json_response(HTTPStatus.BAD_REQUEST, {"error": "Invalid JSON"})
                return
            if not isinstance(body, dict):
                self.json_response(HTTPStatus.BAD_REQUEST, {"error": "Expected a JSON object"})
                return

            if urlparse(self.path).path == "/api/restart":
                try:
                    app.request_restart()
                except RuntimeError as error:
                    self.json_response(HTTPStatus.CONFLICT, {"error": str(error)})
                    return
                self.json_response(HTTPStatus.ACCEPTED, {"status": "restarting"})
                threading.Thread(target=self.server.shutdown, daemon=True).start()
                return

            match = re.fullmatch(r"/api/addons/([a-z0-9-]+)/(enable|disable)", urlparse(self.path).path)
            if not match:
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            addon_id, action = match.groups()
            if addon_id not in app.addons:
                self.json_response(HTTPStatus.NOT_FOUND, {"error": "Unknown add-on"})
                return
            if action == "disable" and body.get("confirm") is not True:
                self.json_response(
                    HTTPStatus.BAD_REQUEST,
                    {"error": "Disable confirmation is required"},
                )
                return
            try:
                inventory = app.inventory()
                if action == "disable":
                    dependents = app.dependent_addons(addon_id, inventory)
                    if dependents:
                        self.json_response(
                            HTTPStatus.CONFLICT,
                            {
                                "error": (
                                    f"Cannot disable {addon_id}; enabled add-ons depend on it: "
                                    + ", ".join(dependents)
                                )
                            },
                        )
                        return
                operation = app.start_operation(addon_id, action)
            except RuntimeError as error:
                self.json_response(HTTPStatus.CONFLICT, {"error": str(error)})
                return
            self.json_response(HTTPStatus.ACCEPTED, operation)

    return DashboardHandler


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the local aap-demo dashboard")
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("AAP_DEMO_DASHBOARD_PORT", DEFAULT_PORT)),
    )
    parser.add_argument("--no-open", action="store_true")
    parser.add_argument("--background", action="store_true", help="Start detached and return once ready")
    return parser.parse_args()


def dashboard_health(port: int) -> dict[str, Any] | None:
    opener = build_opener(ProxyHandler({}))
    try:
        with opener.open(f"http://{HOST}:{port}/api/health", timeout=1) as response:
            payload = json.load(response)
    except (URLError, ConnectionError, TimeoutError):
        return None
    except (ValueError, OSError) as error:
        raise RuntimeError(f"Cannot identify the service on port {port}: {error}") from error
    if not isinstance(payload, dict) or payload.get("service") != "aap-demo-dashboard":
        raise RuntimeError(f"Port {port} is occupied by another service")
    return payload


def launch_background(repo_root: Path, port: int, open_browser: bool) -> int:
    url = f"http://{HOST}:{port}"
    health = dashboard_health(port)
    log_path = Path(os.environ.get("AAP_DEMO_DIR", Path.home() / ".aap-demo")) / "dashboard.log"
    if health is not None:
        if health.get("repo_root") != str(repo_root):
            raise RuntimeError(f"Another checkout's dashboard is already using {url}")
        print(f"aap-demo dashboard already running: {url} (PID {health['pid']})")
    else:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        flags = (
            {"creationflags": subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP}
            if os.name == "nt" else {"start_new_session": True}
        )
        command = [
            sys.executable, "-u", str(Path(__file__).resolve()),
            "--repo-root", str(repo_root), "--port", str(port), "--no-open",
        ]
        with log_path.open("ab") as log:
            os.chmod(log_path, 0o600)
            process = subprocess.Popen(
                command, cwd=repo_root, stdin=subprocess.DEVNULL,
                stdout=log, stderr=subprocess.STDOUT, **flags,
            )
        deadline = time.monotonic() + 10
        try:
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f"Dashboard exited with code {process.returncode}; see {log_path}")
                health = dashboard_health(port)
                if health and health.get("pid") == process.pid and health.get("repo_root") == str(repo_root):
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError(f"Dashboard did not become ready on {url}; see {log_path}")
        except (RuntimeError, OSError):
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            raise
        print(f"aap-demo dashboard running in background: {url} (PID {process.pid})")
    print(f"Dashboard log: {log_path}")
    if open_browser:
        webbrowser.open(url)
    return 0


def main() -> int:
    args = parse_args()
    if not 1 <= args.port <= 65535:
        print("ERROR: Dashboard port must be between 1 and 65535", file=sys.stderr)
        return 1
    repo_root = args.repo_root.resolve()
    open_browser = not args.no_open and os.environ.get("AAP_DEMO_DASHBOARD_NO_OPEN") != "true"
    if args.background:
        try:
            return launch_background(repo_root, args.port, open_browser)
        except (RuntimeError, OSError) as error:
            print(f"ERROR: {error}", file=sys.stderr)
            return 1
    app = DashboardApp(repo_root, args.port)
    try:
        server = ThreadingHTTPServer((HOST, args.port), create_handler(app))
    except OSError as error:
        print(f"ERROR: Cannot start dashboard on {app.origin}: {error}", file=os.sys.stderr)
        return 1
    url = app.origin
    print(f"aap-demo dashboard: {url}")
    print("Localhost only. Press Ctrl+C to stop.")
    if open_browser:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping dashboard...")
    finally:
        server.server_close()
    if app.restart_requested:
        print("Restarting dashboard...", flush=True)
        os.execv(sys.executable, [
            sys.executable, "-u", str(Path(__file__).resolve()),
            "--repo-root", str(repo_root), "--port", str(args.port), "--no-open",
        ])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
