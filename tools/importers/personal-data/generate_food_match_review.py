#!/usr/bin/env python3
"""Generate a DB food match review CSV from the serving review CSV."""

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).parent
sys.path.insert(0, str(ROOT / "src"))

from steps.generate_food_match_review import default_database_url, run  # noqa: E402

DATA_DIR = ROOT / "data"
INPUT = DATA_DIR / "step-9-out-serving-review.csv"
OUTPUT = DATA_DIR / "step-10-out-food-match-review.csv"
MATCHES_JSONL = DATA_DIR / "existing_food_matches.jsonl"


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate food match review CSV")
    parser.add_argument("--input", default=str(INPUT), help="Input review CSV (step 9)")
    parser.add_argument("--output", default=str(OUTPUT), help="Output review CSV")
    parser.add_argument(
        "--existing-review",
        default=str(OUTPUT),
        help="Existing step-10 review CSV for preserved manual decisions",
    )
    parser.add_argument(
        "--matches-jsonl",
        default=str(MATCHES_JSONL),
        help="Output JSONL for accepted existing-food matches",
    )
    parser.add_argument(
        "--database-url",
        default=default_database_url(),
        help="Postgres connection string for the CalCo catalog",
    )
    args = parser.parse_args()

    result = run(
        args.input,
        args.output,
        existing_review_path=args.existing_review,
        matches_jsonl_path=args.matches_jsonl,
        database_url=args.database_url,
    )
    print(f"Wrote {result['review_rows']} rows to {args.output}")
    print(f"  auto-matched: {result['auto_matched']}")
    print(f"  preserved:    {result['preserved_existing_matches']}")
    print(f"  unmatched:    {result['unmatched']}")
    print(f"  jsonl:        {args.matches_jsonl}")


if __name__ == "__main__":
    main()
