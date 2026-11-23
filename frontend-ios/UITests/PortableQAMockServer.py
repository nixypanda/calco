#!/usr/bin/env python3
"""Bounded launcher for the QA-owned NativeCompletionQAMockServer fixture.

This file deliberately does not reimplement CalCo API behavior. It imports the
QA-owned ``NativeCompletionQAMockServer`` module from this directory and runs
the same ``FixtureState`` and ``Handler`` over an ephemeral loopback port.

The wrapper adds only lifecycle behavior needed by the portable device harness:

* bind ``127.0.0.1`` on port 0 by default;
* make a real ``GET /__qa/health`` request through the live QA handler and
  verify the fixture marker, fixed profile UUID, and distinct identity/profile
  UUIDs before publishing a ready marker;
* serve a bounded number of seconds/requests and then close the socket;
* stop on SIGINT/SIGTERM so the driver can guarantee no fixture survives a run;
* never call ``serve_forever()``, so there is no unbounded background server.

Reset semantics, fake credentials, and all API responses remain exactly those
of the QA-owned module.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import signal
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
QA_MOCK_PATH = os.path.join(HERE, "NativeCompletionQAMockServer.py")
FIXTURE_MARKER = "native-completion-qa"
FIXTURE_PROFILE_ID = "22222222-2222-4222-8222-222222222222"
DEFAULT_MAX_SECONDS = 3600.0
DEFAULT_IDLE_SECONDS = 0.0


def load_qa_mock():
    """Import the QA-owned fixture without copying or editing it."""
    spec = importlib.util.spec_from_file_location(
        "calco_native_completion_qa_mock", QA_MOCK_PATH
    )
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot load QA mock from {QA_MOCK_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    for attribute in ("FixtureState", "Handler"):
        if not hasattr(module, attribute):
            raise SystemExit(
                f"QA mock {QA_MOCK_PATH} no longer exposes {attribute}; "
                "update the portable wrapper rather than forking behavior"
            )
    return module


def validate_fixture_health(payload: dict) -> dict:
    """Reject a ready marker unless the live fixture contract is present."""
    if payload.get("fixture") != FIXTURE_MARKER:
        raise SystemExit(
            f"live fixture marker is not {FIXTURE_MARKER!r}: "
            f"{payload.get('fixture')!r}"
        )
    if payload.get("profile_id") != FIXTURE_PROFILE_ID:
        raise SystemExit("live fixture profile UUID does not match the contract")
    identity = payload.get("identity_id")
    if not isinstance(identity, str):
        raise SystemExit("live fixture has no identity UUID")
    try:
        identity_uuid = uuid.UUID(identity)
        profile_uuid = uuid.UUID(str(payload.get("profile_id")))
    except (ValueError, TypeError) as exc:
        raise SystemExit(f"live fixture UUIDs are malformed: {exc}") from exc
    if identity_uuid == profile_uuid:
        raise SystemExit("live fixture identity and profile UUIDs are not distinct")
    return payload


def loopback_opener() -> urllib.request.OpenerDirector:
    """Never route the loopback fixture through an HTTP proxy."""
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def fetch_health(port: int) -> dict:
    url = f"http://127.0.0.1:{port}/__qa/health"
    try:
        with loopback_opener().open(url, timeout=5) as response:
            if response.status != 200:
                raise SystemExit(f"live fixture health returned {response.status}")
            payload = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, json.JSONDecodeError, OSError) as exc:
        raise SystemExit(f"live fixture health request failed: {exc}") from exc
    if not isinstance(payload, dict):
        raise SystemExit("live fixture health was not a JSON object")
    return validate_fixture_health(payload)


def make_handler(qa_module):
    """Subclass the QA handler only to observe request/idle lifecycle."""

    class ObservedHandler(qa_module.Handler):
        def handle_one_request(self) -> None:  # noqa: N802
            server = self.server
            server.request_count += 1
            server.last_request_at = time.monotonic()
            super().handle_one_request()

    return ObservedHandler


def write_ready(path: str, payload: dict) -> None:
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    temporary = f"{path}.tmp.{os.getpid()}"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--max-seconds", type=float, default=DEFAULT_MAX_SECONDS)
    parser.add_argument("--idle-seconds", type=float, default=DEFAULT_IDLE_SECONDS)
    parser.add_argument("--max-requests", type=int, default=0)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)
    if args.port < 0 or args.port > 65535:
        parser.error("--port must be between 0 and 65535")
    if args.max_seconds <= 0:
        parser.error("--max-seconds must be positive")
    if args.idle_seconds < 0:
        parser.error("--idle-seconds cannot be negative")
    if args.max_requests < 0:
        parser.error("--max-requests cannot be negative")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    qa_module = load_qa_mock()
    ObservedHandler = make_handler(qa_module)

    server = ThreadingHTTPServer(("127.0.0.1", args.port), ObservedHandler)
    server.daemon_threads = True
    server.timeout = 0.25
    server.state = qa_module.FixtureState()  # type: ignore[attr-defined]
    server.verbose = args.verbose  # type: ignore[attr-defined]
    server.request_count = 0  # type: ignore[attr-defined]
    server.last_request_at = time.monotonic()  # type: ignore[attr-defined]

    stopping = threading.Event()

    def request_stop(_signum, _frame) -> None:
        stopping.set()

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    port = server.server_address[1]
    health_thread = threading.Thread(target=server.handle_request, daemon=True)
    health_thread.start()
    try:
        health = fetch_health(port)
    finally:
        health_thread.join(timeout=3)
        if health_thread.is_alive():
            server.server_close()
            raise SystemExit("live fixture health handling did not finish")

    ready = {
        "fixture": health["fixture"],
        "host": "127.0.0.1",
        "port": port,
        "base_url": f"http://127.0.0.1:{port}",
        "pid": os.getpid(),
        "profile_id": health["profile_id"],
        "identity_id": health["identity_id"],
        "qa_mock": QA_MOCK_PATH,
    }
    write_ready(args.ready_file, ready)
    print(
        f"PortableQAMockServer listening on {ready['base_url']} "
        f"(max {args.max_seconds:g}s, idle {args.idle_seconds:g}s)",
        flush=True,
    )

    deadline = time.monotonic() + args.max_seconds
    exit_reason = "max_seconds"
    try:
        while not stopping.is_set():
            if time.monotonic() >= deadline:
                break
            if args.max_requests and server.request_count >= args.max_requests:
                exit_reason = "max_requests"
                break
            if (
                args.idle_seconds
                and time.monotonic() - server.last_request_at >= args.idle_seconds
            ):
                exit_reason = "idle_timeout"
                break
            server.handle_request()
        if stopping.is_set():
            exit_reason = "signal"
    finally:
        server.server_close()
        print(
            f"PortableQAMockServer stopped ({exit_reason}, "
            f"{server.request_count} requests)",
            flush=True,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
