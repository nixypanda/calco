#!/usr/bin/env python3
"""Orchestrator for the MFP data cleaning pipeline.

Each step reads a CSV and writes a cleaned CSV. Output files follow the
pattern step-<n>-out-<name>.csv in the data directory.

Usage:
    python3 clean.py                    # run all steps
    python3 clean.py --skip 0           # skip step 0 (reuse existing)
"""

import argparse
import time
from pathlib import Path

from steps import step_path
from steps import (
    merge_fixed_serving,
    normalize_units,
    scale_values,
    flag_pseudo_grams,
    check_macro_calories,
    fix_macro_mismatches,
    deduplicate,
    resolve_serving_modes,
    canonicalize_food_descriptions,
)

STEPS = [
    ("merge_fixed_serving", merge_fixed_serving),
    ("normalize_units", normalize_units),
    ("scale_values", scale_values),
    ("flag_pseudo_grams", flag_pseudo_grams),
    ("check_macro_calories", check_macro_calories),
    ("fix_macro_mismatches", fix_macro_mismatches),
    ("resolve_serving_modes", resolve_serving_modes),
    ("deduplicate", deduplicate),
    ("canonicalize_food_descriptions", canonicalize_food_descriptions),
]

def main():
    parser = argparse.ArgumentParser(description="Clean MFP merged data.")
    parser.add_argument(
        "--data-dir",
        default="../data",
        help="Working data directory (default: ../data)",
    )
    parser.add_argument(
        "--skip",
        type=int,
        nargs="*",
        default=[],
        help="Step indices to skip (0-based)",
    )
    args = parser.parse_args()

    data_dir = Path(args.data_dir)

    print(f"Cleaning MFP data in {data_dir}/")
    print()

    for i, (name, module) in enumerate(STEPS):
        output = step_path(data_dir, i, name)

        if i in args.skip:
            print(f"  [{i}/{name}] skipped")
            continue

        t0 = time.time()
        if i == 0:
            raw = data_dir / "mfp-data.csv"
            fixed = data_dir / "mfp-data-fixed.csv"
            result = module.run(raw, fixed, output)
        else:
            prev_output = step_path(data_dir, i - 1, STEPS[i - 1][0])
            result = module.run(prev_output, output)

        elapsed = time.time() - t0
        print(f"  [{i}/{name}] done ({elapsed:.2f}s)")
        if result:
            for k, v in result.items():
                print(f"    {k}: {v}")
        print()

    print("Done.")


if __name__ == "__main__":
    main()
