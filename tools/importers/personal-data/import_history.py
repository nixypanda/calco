#!/usr/bin/env python3
"""Import historical MFP food rows into CalCo diary logs."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

ROOT = Path(__file__).parent
sys.path.insert(0, str(ROOT / "src"))

from history_import import (  # noqa: E402
    DEFAULT_API_URL,
    DEFAULT_COOKIE_NAME,
    DEFAULT_DEVICE_TIMEZONE,
    run,
)

DATA_DIR = ROOT / "data"
DEFAULT_HISTORY_CSV = DATA_DIR / "step-8-out-canonicalize_food_descriptions.csv"
DEFAULT_REVIEW_CSV = DATA_DIR / "step-10-out-food-match-review-merged.csv"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Import MFP food history into CalCo diary logs"
    )
    parser.add_argument("--api-url", default=os.environ.get("CALCO_API_URL", DEFAULT_API_URL))
    parser.add_argument("--history-csv", default=str(DEFAULT_HISTORY_CSV))
    parser.add_argument("--review-csv", default=str(DEFAULT_REVIEW_CSV))
    parser.add_argument(
        "--session-token",
        default=os.environ.get("CALCO_SESSION_TOKEN"),
        help=f"{DEFAULT_COOKIE_NAME} cookie token for the target user session",
    )
    parser.add_argument(
        "--cookie-name",
        default=os.environ.get("SESSION_COOKIE_NAME", DEFAULT_COOKIE_NAME),
    )
    parser.add_argument(
        "--device-timezone",
        default=os.environ.get("CALCO_DEVICE_TIMEZONE", DEFAULT_DEVICE_TIMEZONE),
    )
    parser.add_argument("--limit", type=int)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if not args.session_token:
        parser.error("--session-token is required")

    result = run(
        args.history_csv,
        args.review_csv,
        api_url=args.api_url.rstrip("/"),
        session_token=args.session_token,
        cookie_name=args.cookie_name,
        device_timezone=args.device_timezone,
        dry_run=args.dry_run,
        limit=args.limit,
    )

    print(f"food_rows:        {result['food_rows']}")
    print(f"imported:         {result['imported']}")
    print(f"skipped_existing: {result['skipped_existing']}")
    print(f"skipped_non_ready:{result['skipped_non_ready']}")
    print(f"skipped_non_pos:  {result['skipped_non_positive']}")


if __name__ == "__main__":
    main()
