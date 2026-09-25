"""Harness for the end-to-end importer pipeline test.

Creates throwaway Postgres databases, boots the backend against them, drives the
real importer CLIs, and captures a canonical logical snapshot of the result.

Run inside the project dev shell so ``psql``, ``sqlx``, ``cargo`` and ``uv`` are
on PATH (``just test-importers-e2e``).
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import socket
import subprocess
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
IMPORTERS_DIR = REPO_ROOT / "tools" / "importers"
DATA_SOURCES_DIR = IMPORTERS_DIR / "data-sources"
PERSONAL_DIR = IMPORTERS_DIR / "personal-data"
FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"

DEFAULT_PG_URL = "postgres://calco:calco@localhost:5432/postgres"
BACKEND_BINARY = REPO_ROOT / "backend" / "target" / "debug" / "calco-backend"
COOKIE_NAME = "calco_session"


class HarnessError(RuntimeError):
    """Raised when the harness cannot set up or drive the pipeline."""


def _env(**overrides: str) -> dict[str, str]:
    env = dict(os.environ)
    env.update(overrides)
    return env


def run(
    cmd: list[str],
    *,
    env: dict[str, str] | None = None,
    cwd: Path = REPO_ROOT,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        cmd,
        cwd=str(cwd),
        env=env or dict(os.environ),
        text=True,
        capture_output=True,
    )
    if check and result.returncode != 0:
        raise HarnessError(
            f"command failed ({result.returncode}): {' '.join(cmd)}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def maintenance_url() -> str:
    return os.environ.get("CALCO_TEST_PG_URL", DEFAULT_PG_URL)


def _database_url(name: str) -> str:
    prefix = maintenance_url().rsplit("/", 1)[0]
    return f"{prefix}/{name}"


def _psql(url: str, sql: str) -> list[str]:
    result = run(
        ["psql", url, "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c", sql],
    )
    return [line for line in result.stdout.splitlines() if line]


def query(database_url: str, sql: str) -> list[str]:
    """Run a query and return the non-empty output lines."""
    return _psql(database_url, sql)


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


class FreshDatabase:
    """A throwaway database created for (and dropped after) a single test run."""

    def __init__(self, label: str) -> None:
        self.name = f"calco_e2e_{label}_{uuid.uuid4().hex[:10]}"
        self.url = _database_url(self.name)

    def __enter__(self) -> "FreshDatabase":
        run(
            [
                "psql",
                maintenance_url(),
                "-v",
                "ON_ERROR_STOP=1",
                "-c",
                f'CREATE DATABASE "{self.name}"',
            ]
        )
        run(
            [
                "sqlx",
                "migrate",
                "run",
                "--source",
                str(REPO_ROOT / "backend" / "migrations"),
                "--database-url",
                self.url,
                "--ignore-missing",
            ]
        )
        return self

    def __exit__(self, *exc: object) -> None:
        run(
            [
                "psql",
                maintenance_url(),
                "-v",
                "ON_ERROR_STOP=1",
                "-c",
                f'DROP DATABASE IF EXISTS "{self.name}" WITH (FORCE)',
            ],
            check=False,
        )


def http_json(
    method: str,
    url: str,
    *,
    cookie: str | None = None,
    payload: object | None = None,
) -> tuple[int, object, str | None]:
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Accept", "application/json")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    if cookie is not None:
        request.add_header("Cookie", f"{COOKIE_NAME}={cookie}")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            body = response.read().decode()
            session = _session_from_headers(response.headers.get_all("Set-Cookie") or [])
            return response.status, (json.loads(body) if body else None), session
    except urllib.error.HTTPError as error:
        body = error.read().decode()
        return error.code, body, None


def _session_from_headers(headers: list[str]) -> str | None:
    for header in headers:
        first = header.split(";", 1)[0].strip()
        if first.startswith(f"{COOKIE_NAME}="):
            return first[len(COOKIE_NAME) + 1 :]
    return None


class Backend:
    """Builds once, then runs the backend binary against a fresh database."""

    def __init__(self, database_url: str) -> None:
        self.database_url = database_url
        self.port = free_port()
        self.process: subprocess.Popen[bytes] | None = None
        self.admin_cookie: str | None = None
        self.user_cookie: str | None = None

    @property
    def api_url(self) -> str:
        return f"http://127.0.0.1:{self.port}/api"

    def __enter__(self) -> "Backend":
        run(["cargo", "build", "--manifest-path", str(REPO_ROOT / "backend" / "Cargo.toml")])
        log_path = Path(os.environ.get("TMPDIR", "/tmp")) / "calco-e2e-backend.log"
        self._log = log_path.open("wb")
        self.process = subprocess.Popen(
            [str(BACKEND_BINARY)],
            cwd=str(REPO_ROOT),
            env=_env(
                DATABASE_URL=self.database_url,
                APP_HOST="127.0.0.1",
                APP_PORT=str(self.port),
                SESSION_COOKIE_SECURE="false",
            ),
            stdout=self._log,
            stderr=subprocess.STDOUT,
        )
        self._wait_until_ready(log_path)
        self._bootstrap_credentials()
        return self

    def _wait_until_ready(self, log_path: Path) -> None:
        deadline = time.time() + 60
        while time.time() < deadline:
            if self.process is not None and self.process.poll() is not None:
                raise HarnessError(
                    f"backend exited early; see {log_path}:\n"
                    f"{log_path.read_text(errors='replace')[-2000:]}"
                )
            try:
                status, _body, _session = http_json(
                    "GET", f"{self.api_url}/auth/bootstrap/status"
                )
                if status == 200:
                    return
            except OSError:
                pass
            time.sleep(0.25)
        raise HarnessError(f"backend did not become ready; see {log_path}")

    def _bootstrap_credentials(self) -> None:
        status, _body, session = http_json(
            "POST",
            f"{self.api_url}/auth/bootstrap/admin",
            payload={"username": "admin", "password": "adminpass123"},
        )
        if status != 201 or session is None:
            raise HarnessError(f"admin bootstrap failed: {status}")
        self.admin_cookie = session

        status, body, _session = http_json(
            "POST",
            f"{self.api_url}/admin/users",
            cookie=self.admin_cookie,
            payload={
                "username": "me",
                "display_name": "me",
                "initial_password": "calco-import-test",
            },
        )
        if status != 201:
            raise HarnessError(f"user creation failed: {status} {body}")

        status, _body, session = http_json(
            "POST",
            f"{self.api_url}/auth/login",
            payload={"username": "me", "password": "calco-import-test"},
        )
        if status != 200 or session is None:
            raise HarnessError(f"user login failed: {status}")
        self.user_cookie = session

    def __exit__(self, *exc: object) -> None:
        if self.process is not None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
        if getattr(self, "_log", None) is not None:
            self._log.close()


def _uv(project: Path, args: list[str]) -> list[str]:
    return ["uv", "run", "--project", str(project), *args]


def run_catalog_import(backend: Backend, work_dir: Path) -> None:
    """Copy fixtures, merge sources, and upload the merged catalog."""
    processed_dir = work_dir / "processed"
    processed_dir.mkdir(parents=True, exist_ok=True)
    for source in sorted((FIXTURES_DIR / "catalog" / "processed").glob("*.jsonl")):
        shutil.copy(source, processed_dir / source.name)

    assert backend.admin_cookie is not None
    env = _env(
        CALCO_DATA_DIR=str(work_dir),
        CALCO_API_URL=backend.api_url,
        CALCO_SESSION_TOKEN=backend.admin_cookie,
    )
    run(_uv(DATA_SOURCES_DIR, ["calco-import", "merge"]), env=env)
    run(_uv(DATA_SOURCES_DIR, ["calco-import", "upload", "merged"]), env=env)


def run_personal_import(backend: Backend, work_dir: Path) -> None:
    """Run the MFP serving review, matching, food creation, and history import."""
    step8 = work_dir / "step-8-out-canonicalize_food_descriptions.csv"
    step9 = work_dir / "step-9-out-serving-review.csv"
    step10 = work_dir / "step-10-out-food-match-review.csv"
    foods_to_create = work_dir / "foods_to_create.jsonl"
    empty_review = work_dir / "empty-review.csv"

    shutil.copy(
        FIXTURES_DIR / "personal" / "step-8-out-canonicalize_food_descriptions.csv",
        step8,
    )
    empty_review.write_text("")

    assert backend.user_cookie is not None
    run(
        _uv(
            PERSONAL_DIR,
            [
                "python",
                "generate_serving_review.py",
                "--input",
                str(step8),
                "--output",
                str(step9),
                "--existing-review",
                str(FIXTURES_DIR / "personal" / "existing-step-9-review.csv"),
            ],
        ),
        cwd=PERSONAL_DIR,
    )
    run(
        _uv(
            PERSONAL_DIR,
            [
                "python",
                "generate_food_match_review.py",
                "--input",
                str(step9),
                "--output",
                str(step10),
                "--existing-review",
                str(empty_review),
                "--matches-jsonl",
                str(work_dir / "existing_food_matches.jsonl"),
                "--database-url",
                backend.database_url,
                "--no-barcode-hints",
            ],
        ),
        cwd=PERSONAL_DIR,
    )
    run(
        _uv(
            PERSONAL_DIR,
            [
                "python",
                "generate_foods_to_create.py",
                "--input",
                str(step10),
                "--output",
                str(foods_to_create),
                "--selection",
                "all-unmatched",
            ],
        ),
        cwd=PERSONAL_DIR,
    )
    run(
        _uv(
            PERSONAL_DIR,
            [
                "python",
                "create_foods.py",
                "--api-url",
                f"http://127.0.0.1:{backend.port}",
                "--visibility",
                "private",
                "--input",
                str(foods_to_create),
                "--review-csv",
                str(step10),
                "--session-token",
                backend.user_cookie,
            ],
        ),
        cwd=PERSONAL_DIR,
    )
    run(
        _uv(
            PERSONAL_DIR,
            [
                "python",
                "import_history.py",
                "--api-url",
                f"http://127.0.0.1:{backend.port}",
                "--history-csv",
                str(step8),
                "--review-csv",
                str(step10),
                "--session-token",
                backend.user_cookie,
            ],
        ),
        cwd=PERSONAL_DIR,
    )


_SNAPSHOT_QUERIES = (
    "SELECT source||'|'||source_id||'|'||name||'|'||coalesce(brand,'')||'|'||"
    "coalesce(barcode,'')||'|'||array_to_string(categories,',')||'|'||"
    "coalesce(default_quantity::text,'')||'|'||coalesce(default_unit,'') "
    "FROM products WHERE deleted_at IS NULL ORDER BY source, source_id",
    "SELECT p.source||'|'||p.source_id||'|'||n.code||'|'||pn.amount_per_100g::text "
    "FROM product_nutrients pn JOIN products p ON p.id = pn.product_id "
    "JOIN nutrients n ON n.id = pn.nutrient_id "
    "ORDER BY p.source, p.source_id, n.code",
    "SELECT p.source||'|'||p.source_id||'|'||ps.unit||'|'||ps.grams_per_unit::text "
    "FROM product_servings ps JOIN products p ON p.id = ps.product_id "
    "ORDER BY p.source, p.source_id, ps.unit",
    "SELECT log_date::text||'|'||coalesce(meal_slot,'')||'|'||item_name||'|'||"
    "coalesce(item_brand,'')||'|'||quantity::text||'|'||unit||'|'||coalesce(notes,'') "
    "FROM food_logs ORDER BY log_date, meal_slot, item_name, quantity, unit, notes",
    "SELECT l.log_date::text||'|'||l.item_name||'|'||coalesce(l.notes,'')||'|'||"
    "n.code||'|'||ln.amount::text||'|'||ln.unit "
    "FROM food_log_nutrients ln JOIN food_logs l ON l.id = ln.food_log_id "
    "JOIN nutrients n ON n.id = ln.nutrient_id "
    "ORDER BY l.log_date, l.item_name, l.notes, n.code",
)


def snapshot(database_url: str) -> str:
    """Return a deterministic, UUID-independent digest of the imported state."""
    lines: list[str] = []
    for query in _SNAPSHOT_QUERIES:
        lines.append(f"-- {query}")
        lines.extend(_psql(database_url, query))
    joined = "\n".join(lines)
    digest = hashlib.sha256(joined.encode()).hexdigest()
    return f"{digest}\n{joined}"
