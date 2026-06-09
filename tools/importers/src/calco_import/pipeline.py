import logging
import os
from collections.abc import Mapping, Sequence
from typing import cast

import requests
from tenacity import (
    before_sleep_log,
    retry,
    retry_if_exception,
    stop_after_attempt,
    wait_exponential,
)
from tqdm import trange

from calco_import.util import JsonRow, load_jsonl

FOODS_BATCH_SIZE = 500
NUTRIENTS_BATCH_SIZE = 1000
SERVINGS_BATCH_SIZE = 1000
SERVER_ERROR_MIN = 500
NOT_FOUND = 404

Headers = dict[str, str]

log = logging.getLogger(__name__)

SOURCE_LABELS = {
    "usda": "USDA",
    "off": "OFF",
    "ifct": "IFCT",
    "indb": "INDB",
    "merged": "MERGED",
}

SOURCE_FILES = {
    "usda": "usda_sr_legacy.jsonl",
    "off": "off_india.jsonl",
    "ifct": "ifct2017.jsonl",
    "indb": "indb_2024.jsonl",
    "merged": "merged.jsonl",
}


def _is_retryable(exc: BaseException) -> bool:
    if isinstance(exc, (requests.ConnectionError, requests.Timeout)):
        return True
    if isinstance(exc, requests.exceptions.HTTPError):
        return exc.response is not None and exc.response.status_code >= SERVER_ERROR_MIN
    return False


@retry(
    stop=stop_after_attempt(3),
    wait=wait_exponential(multiplier=1),
    retry=retry_if_exception(_is_retryable),
    reraise=True,
    before_sleep=before_sleep_log(log, logging.WARNING),
)
def _request(
    method: str,
    url: str,
    *,
    json: object | None = None,
    headers: Mapping[str, str] | None = None,
) -> requests.Response:
    resp = requests.request(method, url, json=json, headers=headers)  # type: ignore
    resp.raise_for_status()
    return resp


def int_field(row: Mapping[str, object], key: str) -> int:
    value = row.get(key, 0)
    return value if isinstance(value, int) else 0


def build_headers(session_token: str | None) -> Headers:
    headers: Headers = {"Content-Type": "application/json"}
    if session_token:
        headers["Cookie"] = f"calco_session={session_token}"
    return headers


def create_job(api_url: str, headers: Mapping[str, str], source: str) -> str:
    url = f"{api_url}/imports"
    payload = {"source": source}
    resp = _request("POST", url, json=payload, headers=headers)
    job = cast("JsonRow", resp.json())
    log.info(
        "Created import job %s (source=%s, status=%s)",
        job["id"],
        source,
        job.get("status"),
    )
    return str(job["id"])


def batch_upload(
    api_url: str,
    headers: Mapping[str, str],
    job_id: str,
    rows: Sequence[JsonRow],
    kind: str,
    batch_size: int,
) -> tuple[int, int]:
    accepted_total = 0
    rejected_total = 0
    total_batches = (len(rows) + batch_size - 1) // batch_size
    for i in trange(0, len(rows), batch_size, desc=f"Uploading {kind}"):
        batch = rows[i : i + batch_size]
        url = f"{api_url}/imports/{job_id}/{kind}"
        payload = {"rows": batch}
        resp = _request("POST", url, json=payload, headers=headers)
        result = cast("JsonRow", resp.json())
        accepted = int_field(result, "accepted")
        rejected = int_field(result, "rejected")
        accepted_total += accepted
        rejected_total += rejected
        log.info(
            "  batch %d/%d: %s accepted=%d rejected=%d",
            i // batch_size + 1,
            total_batches,
            kind,
            accepted,
            rejected,
        )
    return accepted_total, rejected_total


def commit_job(api_url: str, headers: Mapping[str, str], job_id: str) -> JsonRow:
    url = f"{api_url}/imports/{job_id}/commit"
    resp = _request("POST", url, headers=headers)
    result = cast("JsonRow", resp.json())
    log.info(
        "Committed: created=%d updated=%d nutrients=%d servings=%d errors=%d",
        result.get("products_created", 0),
        result.get("products_updated", 0),
        result.get("nutrients_inserted", 0),
        result.get("servings_inserted", 0),
        result.get("errors_logged", 0),
    )
    return result


def fetch_errors(
    api_url: str, headers: Mapping[str, str], job_id: str
) -> list[JsonRow]:
    url = f"{api_url}/imports/{job_id}/errors"
    resp = _request("GET", url, headers=headers)
    if resp.status_code == NOT_FOUND:
        return []
    data = resp.json()
    items = data.get("items", data if isinstance(data, list) else [])
    items = cast("list[JsonRow]", items)
    for err in items:
        log.warning(
            "  error row %s: %s", err.get("row_number", "?"), err.get("error", err)
        )
    return items


def upload(cfg: dict[str, object], dataset: str | None = None) -> None:
    ds = dataset or str(cfg.get("dataset", ""))
    source = SOURCE_LABELS[ds]
    data_dir = str(cfg["data_dir"])
    jsonl_file = os.path.join(data_dir, "processed", SOURCE_FILES[ds])

    if cfg.get("dry_run"):
        log.info("Dry-run: would upload %s from %s", source, jsonl_file)
        return

    if not os.path.exists(jsonl_file):
        log.error("Processed file not found: %s", jsonl_file)
        log.error("Run 'calco-import fetch %s' first.", ds)
        return

    session_token = cfg.get("session_token")
    session_token_str = str(session_token) if session_token else None
    headers = build_headers(session_token_str)

    log.info("Loading %s ...", jsonl_file)
    foods, nutrients, servings = load_jsonl(jsonl_file)
    log.info(
        "Loaded %d foods, %d nutrients, %d servings",
        len(foods),
        len(nutrients),
        len(servings),
    )

    for f in foods:
        if f.get("name") is None:
            f["name"] = f"Unknown ({f['source']}:{f.get('source_id', '?')})"
            f["brand"] = f.get("brand") or ""

    if not foods:
        log.error("No foods found in %s", jsonl_file)
        return

    api_url = str(cfg["api_url"])
    job_id = create_job(api_url, headers, source)

    log.info("Uploading foods (%d rows, batch=%d) ...", len(foods), FOODS_BATCH_SIZE)
    foods_accepted, foods_rejected = batch_upload(
        api_url,
        headers,
        job_id,
        foods,
        "foods",
        FOODS_BATCH_SIZE,
    )
    log.info("Foods done: accepted=%d rejected=%d", foods_accepted, foods_rejected)

    log.info(
        "Uploading nutrients (%d rows, batch=%d) ...",
        len(nutrients),
        NUTRIENTS_BATCH_SIZE,
    )
    nut_accepted, nut_rejected = batch_upload(
        api_url,
        headers,
        job_id,
        nutrients,
        "nutrients",
        NUTRIENTS_BATCH_SIZE,
    )
    log.info("Nutrients done: accepted=%d rejected=%d", nut_accepted, nut_rejected)

    serv_accepted = 0
    serv_rejected = 0
    if servings:
        log.info(
            "Uploading servings (%d rows, batch=%d) ...",
            len(servings),
            SERVINGS_BATCH_SIZE,
        )
        serv_accepted, serv_rejected = batch_upload(
            api_url,
            headers,
            job_id,
            servings,
            "servings",
            SERVINGS_BATCH_SIZE,
        )
        log.info(
            "Servings done: accepted=%d rejected=%d",
            serv_accepted,
            serv_rejected,
        )

    result = commit_job(api_url, headers, job_id)

    errors = fetch_errors(api_url, headers, job_id)
    if errors:
        log.warning(
            "Commit logged %d errors — check GET /imports/%s/errors",
            len(errors),
            job_id,
        )

    log.info("Pipeline complete for %s (job %s)", source, job_id)
    log.info(
        "Summary: %d/%d foods, %d/%d nutrients, %d/%d servings, "
        "created=%d updated=%d nutrients_ins=%d servings_ins=%d errors=%d",
        foods_accepted,
        len(foods),
        nut_accepted,
        len(nutrients),
        serv_accepted,
        len(servings),
        result.get("products_created", 0),
        result.get("products_updated", 0),
        result.get("nutrients_inserted", 0),
        result.get("servings_inserted", 0),
        result.get("errors_logged", 0),
    )
