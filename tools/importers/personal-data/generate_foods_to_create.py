#!/usr/bin/env python3
"""Generate custom-food creation JSONL from the merged step-10 review CSV."""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))

from steps.generate_foods_to_create import run

ROOT = Path(__file__).parent
DATA_DIR = ROOT / "data"
INPUT = DATA_DIR / "step-10-out-food-match-review-merged.csv"
OUTPUT = DATA_DIR / "foods_to_create.jsonl"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate JSONL for unmatched foods approved for custom creation"
    )
    parser.add_argument(
        "--input",
        default=str(INPUT),
        help="Merged step-10 review CSV",
    )
    parser.add_argument(
        "--output",
        default=str(OUTPUT),
        help="Output JSONL path",
    )
    parser.add_argument(
        "--selection",
        choices=("approved-policy", "all-unmatched"),
        default="approved-policy",
        help="Which unmatched rows to emit",
    )
    args = parser.parse_args()

    result = run(args.input, args.output, selection=args.selection)
    print(f"Wrote {result['created']} rows to {args.output}")
    print(f"  selection:          {args.selection}")
    print(f"  branded/commercial: {result['branded_commercial']}")
    print(f"  raw/basic:          {result['raw_basic']}")
    print(f"  deferred:           {result['deferred']}")


if __name__ == "__main__":
    main()
