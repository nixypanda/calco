#!/usr/bin/env python3
"""Step 9: Generate a serving review CSV for manual correction.

Usage:
    python3 generate_serving_review.py

Reads data/step-8-out-canonicalize_food_descriptions.csv, groups distinct foods,
preserves any existing review edits from the current output file, and writes
data/step-9-out-serving-review.csv.
"""

import argparse
from pathlib import Path

from steps.generate_serving_review import run

ROOT = Path(__file__).parent
DATA_DIR = ROOT / "data"
INPUT = DATA_DIR / "step-8-out-canonicalize_food_descriptions.csv"
OUTPUT = DATA_DIR / "step-9-out-serving-review.csv"
EXISTING_REVIEW = OUTPUT


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate serving review CSV")
    parser.add_argument("--input", default=str(INPUT), help="Input CSV (step 8)")
    parser.add_argument("--output", default=str(OUTPUT), help="Output review CSV")
    parser.add_argument(
        "--existing-review",
        default=str(EXISTING_REVIEW),
        help="Existing review CSV for pre-population",
    )
    args = parser.parse_args()

    result = run(args.input, args.output, existing_review_path=args.existing_review)
    print(f"Wrote {result['review_rows_written']} rows to {args.output}")
    print(f"  mass:         {result['mass_mode_count']}")
    print(f"  volume:       {result['volume_mode_count']}")
    print(f"  serving_unit: {result['serving_unit_mode_count']}")


if __name__ == "__main__":
    main()
