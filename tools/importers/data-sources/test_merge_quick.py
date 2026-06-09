import logging
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "src"))

from calco_import import merge
from calco_import.util import write_jsonl_row

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)s  %(message)s",
)
log = logging.getLogger("test_merge_quick")

TEST_SOURCES = ["IFCT", "INDB"]

DATA_DIR = os.path.join(os.path.dirname(__file__), "data")


def load_sources(data_dir: str) -> merge.SourcesData:
    sources_data: merge.SourcesData = {}
    for src in TEST_SOURCES:
        fp = os.path.join(data_dir, "processed", merge.SOURCE_FILES[src])
        if not os.path.exists(fp):
            log.error("%s not found at %s", src, fp)
            log.error(
                "Fetch data first: calco-import fetch ifct && calco-import fetch indb"
            )
            sys.exit(1)
        log.info("Loading %s ...", src)
        foods, nutrients, servings = merge.load_source(fp)
        sources_data[src] = (foods, nutrients, servings)
        log.info(
            "  %s: %d foods, %d with nutrients, %d with servings",
            src,
            len(foods),
            len(nutrients),
            len(servings),
        )
    return sources_data


def main() -> None:
    data_dir = DATA_DIR
    if not os.path.exists(os.path.join(data_dir, "processed")):
        data_dir = os.path.join(os.path.dirname(__file__), "..", "data")

    sources_data = load_sources(data_dir)

    log.info("Phase 1: barcode matching ...")
    barcode_groups = merge.find_barcode_matches(sources_data, preference=TEST_SOURCES)
    log.info("  %d groups from barcode", len(barcode_groups))

    log.info("Phase 2: name similarity matching ...")
    name_groups = merge.find_name_matches(
        sources_data, barcode_groups, preference=TEST_SOURCES
    )
    all_groups = barcode_groups + name_groups
    log.info("  %d total matched groups", len(all_groups))

    log.info("Checking macro consistency ...")
    for group in all_groups:
        for _code, message in merge.check_macros(
            sources_data, group, preference=TEST_SOURCES
        ):
            log.warning(message)

    rows = merge.build_merged_rows(sources_data, all_groups, preference=TEST_SOURCES)

    out_dir = data_dir
    out_path = os.path.join(out_dir, "merged_ifct_indb.jsonl")
    with open(out_path, "w") as out:
        for row in rows:
            write_jsonl_row(out, row)

    food_count = sum(1 for r in rows if r.get("type") == "food")
    nutrient_count = sum(1 for r in rows if r.get("type") == "nutrient")
    serving_count = sum(1 for r in rows if r.get("type") == "serving")
    matched_foods = sum(len(g) for g in all_groups)

    log.info("")
    log.info("Quick merge complete (IFCT + INDB only):")
    log.info("  -- Matched groups:   %d", len(all_groups))
    log.info("  -- Matched foods:    %d", matched_foods)
    log.info("  -- Total products:   %d", food_count)
    log.info("  -- Nutrient rows:    %d", nutrient_count)
    log.info("  -- Serving rows:     %d", serving_count)
    log.info("  -- Output:           %s", out_path)

    if all_groups:
        log.info("")
        log.info("Sample matched groups:")
        for g in all_groups[:5]:
            names = []
            for src in TEST_SOURCES:
                if src in g:
                    sid = g[src]
                    foods, _, _ = sources_data[src]
                    names.append(f"  {src}[{sid}]: {foods[sid].get('name', '?')}")
            log.info("  group: %s", " | ".join(names))


if __name__ == "__main__":
    main()
