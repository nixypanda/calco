import logging
import os
import sys
from typing import TypedDict

import typer

from calco_import import merge as merge_mod
from calco_import import pipeline
from calco_import.fetch import dispatch as fetch_dispatch

log = logging.getLogger(__name__)


class Config(TypedDict):
    api_url: str
    session_token: str | None
    data_dir: str
    dry_run: bool


app = typer.Typer()


@app.callback()
def cli(
    ctx: typer.Context,
    api_url: str = typer.Option(
        "http://localhost:3001",
        envvar="CALCO_API_URL",
        help="Backend API base URL",
    ),
    session_token: str | None = typer.Option(
        None,
        envvar="CALCO_SESSION_TOKEN",
        help="calco_session cookie value",
    ),
    data_dir: str = typer.Option(
        "./data",
        envvar="CALCO_DATA_DIR",
        help="Data directory for raw/processed files",
    ),
    dry_run: bool = typer.Option(
        False, "--dry-run", help="Skip upload, show what would be sent",
    ),
) -> None:
    """CalCo dataset import tool."""
    if not session_token and sys.stdin.isatty():
        try:
            val = typer.prompt(
                "Session token (paste from browser)", hide_input=True, default=""
            )
            session_token = val or None
        except typer.Abort:
            session_token = None

    os.makedirs(os.path.join(data_dir, "raw"), exist_ok=True)
    os.makedirs(os.path.join(data_dir, "processed"), exist_ok=True)

    ctx.obj = Config(
        api_url=api_url,
        session_token=session_token,
        data_dir=data_dir,
        dry_run=dry_run,
    )


def _require_token(cfg: Config) -> None:
    if not cfg["session_token"] and not cfg["dry_run"]:
        log.error(
            "Session token required for upload. Set --session-token, "
            "CALCO_SESSION_TOKEN, or paste one interactively."
        )
        raise typer.Exit(1)


@app.command()
def fetch(
    ctx: typer.Context,
    dataset: str = typer.Argument(
        help="Dataset to fetch (usda, off, ifct, indb)",
    ),
) -> None:
    """Download raw data and convert to normalized JSONL."""
    fetch_dispatch(ctx.obj["data_dir"], dataset)


@app.command()
def merge(ctx: typer.Context) -> None:
    """Deduplicate all sources into merged.jsonl."""
    merge_mod.run(ctx.obj)


@app.command()
def upload(
    ctx: typer.Context,
    dataset: str = typer.Argument(
        help="Dataset to upload (usda, off, ifct, indb, merged)",
    ),
) -> None:
    """Upload processed JSONL to the backend API."""
    _require_token(ctx.obj)
    pipeline.upload(ctx.obj, dataset)


@app.command("import")
def import_cmd(
    ctx: typer.Context,
    dataset: str = typer.Argument(
        help="Dataset to import (usda, off, ifct, indb, merged)",
    ),
) -> None:
    """Fetch + upload (full pipeline for a dataset)."""
    _require_token(ctx.obj)

    if dataset == "merged":
        fetch_dispatch(ctx.obj["data_dir"], "usda")
        fetch_dispatch(ctx.obj["data_dir"], "off")
        fetch_dispatch(ctx.obj["data_dir"], "ifct")
        fetch_dispatch(ctx.obj["data_dir"], "indb")
        merge_mod.run(ctx.obj)
        pipeline.upload(ctx.obj, "merged")
    else:
        fetch_dispatch(ctx.obj["data_dir"], dataset)
        pipeline.upload(ctx.obj)


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s  %(levelname)s  %(message)s",
        datefmt="%H:%M:%S",
    )
    app()
