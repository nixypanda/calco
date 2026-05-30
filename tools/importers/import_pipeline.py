import argparse
import json
import logging
import os
import sys
import time

import requests

FOODS_BATCH_SIZE = 500
NUTRIENTS_BATCH_SIZE = 1000
MAX_RETRIES = 3
BASE_DELAY_SECONDS = 1

PROCESSED_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "data", "processed")

SOURCE_FILES = {
    "USDA": "usda_sr_legacy.jsonl",
    "OFF": "off_india.jsonl",
    "IFCT": "ifct2017.jsonl",
    "MERGED": "merged.jsonl",
}

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("pipeline")


def build_headers(session_token):
    headers = {"Content-Type": "application/json"}
    if session_token:
        headers["Cookie"] = f"calco_session={session_token}"
    return headers


def retry_request(method, url, **kwargs):
    last_exc = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            resp = kwargs.pop("session", requests).request(method, url, **kwargs)
            if resp.status_code < 500:
                return resp
            log.warning("HTTP %d on %s %s (attempt %d/%d)", resp.status_code, method.upper(), url, attempt, MAX_RETRIES)
        except requests.RequestException as e:
            log.warning("Request failed on %s %s (attempt %d/%d): %s", method.upper(), url, attempt, MAX_RETRIES, e)
            last_exc = e

        if attempt < MAX_RETRIES:
            delay = BASE_DELAY_SECONDS * (2 ** (attempt - 1))
            time.sleep(delay)

    if last_exc:
        raise last_exc
    resp.raise_for_status()
    return resp


def create_job(api_url, headers, source):
    url = f"{api_url}/imports"
    payload = {"source": source}
    resp = retry_request("POST", url, json=payload, headers=headers)
    resp.raise_for_status()
    job = resp.json()
    log.info("Created import job %s (source=%s, status=%s)", job["id"], source, job["status"])
    return job["id"]


def batch_upload(api_url, headers, job_id, rows, kind, batch_size):
    accepted_total = 0
    rejected_total = 0
    for i in range(0, len(rows), batch_size):
        batch = rows[i : i + batch_size]
        url = f"{api_url}/imports/{job_id}/{kind}"
        payload = {"rows": batch}
        resp = retry_request("POST", url, json=payload, headers=headers)
        resp.raise_for_status()
        result = resp.json()
        accepted_total += result.get("accepted", 0)
        rejected_total += result.get("rejected", 0)
        log.info(
            "  uploaded batch %d/%d: %s accepted=%d rejected=%d",
            i // batch_size + 1,
            (len(rows) + batch_size - 1) // batch_size,
            kind,
            result.get("accepted", 0),
            result.get("rejected", 0),
        )
    return accepted_total, rejected_total


def commit_job(api_url, headers, job_id):
    url = f"{api_url}/imports/{job_id}/commit"
    resp = retry_request("POST", url, headers=headers)
    resp.raise_for_status()
    result = resp.json()
    log.info(
        "Committed: created=%d updated=%d nutrients=%d errors=%d",
        result.get("products_created", 0),
        result.get("products_updated", 0),
        result.get("nutrients_inserted", 0),
        result.get("errors_logged", 0),
    )
    return result


def fetch_errors(api_url, headers, job_id):
    url = f"{api_url}/imports/{job_id}/errors"
    resp = retry_request("GET", url, headers=headers)
    if resp.status_code == 404:
        return []
    resp.raise_for_status()
    data = resp.json()
    items = data.get("items", data if isinstance(data, list) else [])
    for err in items:
        log.warning("  error row %s: %s", err.get("row_number", "?"), err.get("error", err))
    return items


def load_jsonl(filepath):
    foods = []
    nutrients = []
    with open(filepath, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            row = {k: v for k, v in obj.items() if k != "type"}
            if obj.get("type") == "food":
                foods.append(row)
            elif obj.get("type") == "nutrient":
                nutrients.append(row)
    return foods, nutrients


def main():
    parser = argparse.ArgumentParser(description="CalCo import pipeline")
    parser.add_argument("--api-url", default="http://localhost:3001", help="Backend API base URL")
    parser.add_argument("--session-token", default="", help="calco_session cookie value")
    parser.add_argument("--source", required=True, choices=list(SOURCE_FILES), help="Data source")
    parser.add_argument("--processed-dir", default=PROCESSED_DIR, help="Directory with processed JSONL files")
    args = parser.parse_args()

    source = args.source
    jsonl_file = os.path.join(args.processed_dir, SOURCE_FILES[source])

    if not os.path.exists(jsonl_file):
        log.error("Processed file not found: %s", jsonl_file)
        log.error("Run the appropriate convert script or merge_sources.py first.")
        sys.exit(1)

    headers = build_headers(args.session_token)

    log.info("Loading %s ...", jsonl_file)
    foods, nutrients = load_jsonl(jsonl_file)
    log.info("Loaded %d foods, %d nutrients", len(foods), len(nutrients))

    for f in foods:
        if f.get("name") is None:
            f["name"] = f"Unknown ({f['source']}:{f.get('source_id','?')})"
            f["brand"] = f.get("brand") or ""

    if not foods:
        log.error("No foods found in %s", jsonl_file)
        sys.exit(1)

    job_id = create_job(args.api_url, headers, source)

    log.info("Uploading foods (%d rows, batch=%d) ...", len(foods), FOODS_BATCH_SIZE)
    foods_accepted, foods_rejected = batch_upload(args.api_url, headers, job_id, foods, "foods", FOODS_BATCH_SIZE)
    log.info("Foods done: accepted=%d rejected=%d", foods_accepted, foods_rejected)

    log.info("Uploading nutrients (%d rows, batch=%d) ...", len(nutrients), NUTRIENTS_BATCH_SIZE)
    nut_accepted, nut_rejected = batch_upload(args.api_url, headers, job_id, nutrients, "nutrients", NUTRIENTS_BATCH_SIZE)
    log.info("Nutrients done: accepted=%d rejected=%d", nut_accepted, nut_rejected)

    result = commit_job(args.api_url, headers, job_id)

    errors = fetch_errors(args.api_url, headers, job_id)
    if errors:
        log.warning("Commit logged %d errors — check GET /imports/%s/errors", len(errors), job_id)

    log.info("Pipeline complete for %s (job %s)", source, job_id)
    log.info(
        "Summary: %d/%d foods, %d/%d nutrients, created=%d updated=%d nutrients_ins=%d errors=%d",
        foods_accepted, len(foods),
        nut_accepted, len(nutrients),
        result.get("products_created", 0),
        result.get("products_updated", 0),
        result.get("nutrients_inserted", 0),
        result.get("errors_logged", 0),
    )


if __name__ == "__main__":
    main()
