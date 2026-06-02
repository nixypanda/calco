import json
import logging
import os
import re
import sys
from collections import defaultdict
from collections.abc import Mapping
from typing import TextIO, cast

import rapidfuzz

PREFERENCE = ["USDA", "IFCT", "OFF"]
MACRO_CODES = {"ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G"}

MACRO_DIFF_THRESHOLD = 0.30
BASE_THRESHOLD = 90
LENGTH_RATIO_THRESHOLD = 0.50
MIN_MATCH_ENTRIES = 2
SUBSET_SCORE_PENALTY = 15

PROCESSED_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "data", "processed")

SOURCE_FILES = {
    "USDA": "usda_sr_legacy.jsonl",
    "IFCT": "ifct2017.jsonl",
    "OFF": "off_india.jsonl",
}

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("merge")

JsonRow = dict[str, object]
NutrientsByFood = dict[str, dict[str, float]]
ServingsByFood = dict[str, list[JsonRow]]
FoodsById = dict[str, JsonRow]
SourceData = tuple[FoodsById, NutrientsByFood, ServingsByFood]
SourcesData = dict[str, SourceData]
Group = dict[str, str]
MatchedKeys = set[tuple[str, str]]


def normalize_name(name: object) -> str:
    if not name:
        return ""
    name = str(name).lower()
    name = re.sub(r"[^a-z0-9\s]", " ", name)
    return re.sub(r"\s+", " ", name).strip()


def normalize_categories(row: JsonRow) -> JsonRow:
    values = []

    raw_categories = row.get("categories")
    if isinstance(raw_categories, list):
        values.extend(raw_categories)
    elif raw_categories:
        values.append(raw_categories)

    raw_category = row.get("category")
    if raw_category:
        values.append(raw_category)

    normalized = []
    for value in values:
        for part in str(value).split(","):
            category = part.strip().lower()
            if category and category not in normalized:
                normalized.append(category)

    row["categories"] = normalized
    row.pop("category", None)
    return row


def load_source(filepath: str) -> SourceData:
    foods: FoodsById = {}
    nutrients: NutrientsByFood = defaultdict(dict)
    servings: ServingsByFood = defaultdict(list)
    with open(filepath, encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.strip()
            if not line:
                continue
            obj = cast("JsonRow", json.loads(line))
            t = obj.pop("type", None)
            sid = str(obj.get("source_id", ""))
            if t == "food":
                obj = normalize_categories(obj)
                foods[sid] = obj
            elif t == "nutrient":
                amount = obj["amount_per_100g"]
                if isinstance(amount, str | int | float):
                    nutrients[sid][str(obj["nutrient_code"])] = float(amount)
            elif t == "serving":
                servings[sid].append(
                    {
                        "label": obj.get("label"),
                        "quantity": obj.get("quantity"),
                        "unit": obj.get("unit"),
                        "grams": obj.get("grams"),
                    }
                )
    return foods, nutrients, servings


def phase1_barcode(
    sources_data: SourcesData, matched: MatchedKeys, groups: list[Group]
) -> None:
    bcode_map: dict[object, list[tuple[str, str]]] = defaultdict(list)
    for src in PREFERENCE:
        foods, _, _ = sources_data[src]
        for sid, f in foods.items():
            bc = f.get("barcode")
            if bc:
                bcode_map[bc].append((src, sid))
    for entries in bcode_map.values():
        if len(entries) < MIN_MATCH_ENTRIES:
            continue
        already = any((s, i) in matched for s, i in entries)
        if already:
            continue
        group = {}
        for s, i in entries:
            matched.add((s, i))
            group[s] = i
        groups.append(group)


def phase2_name(  # noqa: PLR0912
    sources_data: SourcesData, matched: MatchedKeys, groups: list[Group]
) -> None:
    unmatched: dict[str, list[tuple[str, object]]] = {}
    for src in PREFERENCE:
        foods, _, _ = sources_data[src]
        lst = [
            (sid, foods[sid].get("name", ""))
            for sid in foods
            if (src, sid) not in matched and foods[sid].get("name")
        ]
        unmatched[src] = lst
        log.info("  %s: %d unmatched after barcode phase", src, len(lst))

    for i, src_a in enumerate(PREFERENCE):
        for src_b in PREFERENCE[i + 1 :]:
            candidates_a = [
                (s, n) for s, n in unmatched[src_a] if (src_a, s) not in matched
            ]
            pool_b = {s: n for s, n in unmatched[src_b] if (src_b, s) not in matched}
            if not candidates_a or not pool_b:
                continue

            for sid_a, name_a in candidates_a:
                if (src_a, sid_a) in matched:
                    continue
                key_a = normalize_name(name_a)
                best_score = 0
                best_sid_b = None
                for sid_b, name_b in pool_b.items():
                    if (src_b, sid_b) in matched:
                        continue
                    score = rapidfuzz.fuzz.token_sort_ratio(
                        key_a, normalize_name(name_b)
                    )
                    subset_ratio = rapidfuzz.fuzz.token_set_ratio(
                        key_a, normalize_name(name_b)
                    )
                    if subset_ratio - score > SUBSET_SCORE_PENALTY:
                        score = min(score, subset_ratio - SUBSET_SCORE_PENALTY)
                    len_a = len(key_a)
                    len_b = len(normalize_name(name_b))
                    if len_a > 0 and len_b > 0:
                        ratio = min(len_a, len_b) / max(len_a, len_b)
                        if ratio < LENGTH_RATIO_THRESHOLD:
                            score = min(score, BASE_THRESHOLD - 1)
                    if score > best_score:
                        best_score = score
                        best_sid_b = sid_b
                if best_score >= BASE_THRESHOLD and best_sid_b:
                    matched.add((src_a, sid_a))
                    matched.add((src_b, best_sid_b))
                    groups.append({src_a: sid_a, src_b: best_sid_b})
                    del pool_b[best_sid_b]


def check_macros(sources_data: SourcesData, group: Group) -> None:
    for code in MACRO_CODES:
        vals: dict[str, float] = {}
        for src in PREFERENCE:
            if src not in group:
                continue
            _, nutrients, _ = sources_data[src]
            sid = group[src]
            if sid in nutrients and code in nutrients[sid]:
                vals[src] = nutrients[sid][code]
        if len(vals) < MIN_MATCH_ENTRIES:
            continue
        mx = max(vals.values())
        mn = min(vals.values())
        if mx == 0:
            continue
        diff = abs(mx - mn) / mx
        if diff > MACRO_DIFF_THRESHOLD:
            names = []
            for src in PREFERENCE:
                if src in group:
                    foods, _, _ = sources_data[src]
                    sid = group[src]
                    names.append(f"{src}: {foods[sid].get('name', sid)}")
            log.warning(
                "  %s differs by %.0f%% — [%s]", code, diff * 100, " | ".join(names)
            )


def merge_group(
    sources_data: SourcesData, group: Group
) -> tuple[JsonRow, dict[str, float], list[JsonRow]]:
    canonical_src = next(s for s in PREFERENCE if s in group)
    canonical_sid = group[canonical_src]
    foods, _, servings = sources_data[canonical_src]
    merged_food = dict(foods[canonical_sid])
    merged_servings = list(servings.get(canonical_sid, []))

    merged_nutrients: dict[str, float] = {}
    for src in PREFERENCE:
        if src not in group:
            continue
        _, nutrients, _ = sources_data[src]
        sid = group[src]
        if sid in nutrients:
            for code, amount in nutrients[sid].items():
                if code not in merged_nutrients:
                    merged_nutrients[code] = amount

    return merged_food, merged_nutrients, merged_servings


def main() -> None:  # noqa: PLR0912, PLR0915
    sources_data: SourcesData = {}
    for src in PREFERENCE:
        fp = os.path.join(PROCESSED_DIR, SOURCE_FILES[src])
        if not os.path.exists(fp):
            log.error("%s not found at %s", src, fp)
            sys.exit(1)
        log.info("Loading %s ...", src)
        foods, nutrients, servings = load_source(fp)
        sources_data[src] = (foods, nutrients, servings)
        log.info(
            "  %s: %d foods, %d with nutrients, %d with servings",
            src,
            len(foods),
            len(nutrients),
            len(servings),
        )

    matched: MatchedKeys = set()
    groups: list[Group] = []

    log.info("Phase 1: barcode matching ...")
    phase1_barcode(sources_data, matched, groups)
    log.info("  %d groups from barcode", len(groups))

    log.info("Phase 2: name similarity matching ...")
    phase2_name(sources_data, matched, groups)
    log.info("  %d total matched groups", len(groups))

    log.info("Checking macro consistency across matched groups ...")
    for g in groups:
        check_macros(sources_data, g)

    out_path = os.path.join(PROCESSED_DIR, "merged.jsonl")
    merged_food_count = 0
    merged_nutrient_count = 0
    merged_serving_count = 0

    # Track which source_ids from each source have been written
    written: dict[str, set[str]] = {src: set() for src in PREFERENCE}

    def write_serving(out: TextIO, src: str, sid: str, s: Mapping[str, object]) -> None:
        row = {
            "type": "serving",
            "source": src,
            "source_id": sid,
            "label": s.get("label"),
            "quantity": s.get("quantity"),
            "unit": s.get("unit"),
            "grams": s.get("grams"),
        }
        out.write(json.dumps(row, ensure_ascii=False) + "\n")

    with open(out_path, "w") as out:
        for group in groups:
            food, nutrients, servings = merge_group(sources_data, group)
            food["type"] = "food"
            out.write(json.dumps(food, ensure_ascii=False) + "\n")
            merged_food_count += 1
            for code, amount in nutrients.items():
                row = {
                    "type": "nutrient",
                    "source": food["source"],
                    "source_id": food["source_id"],
                    "nutrient_code": code,
                    "amount_per_100g": amount,
                }
                out.write(json.dumps(row, ensure_ascii=False) + "\n")
                merged_nutrient_count += 1
            for s in servings:
                write_serving(out, str(food["source"]), str(food["source_id"]), s)
                merged_serving_count += 1
            for src in PREFERENCE:
                if src in group:
                    written[src].add(group[src])

        # Write unmatched products from each source
        for src in PREFERENCE:
            foods, nutrients, servings_by_sid = sources_data[src]
            for sid, food in foods.items():
                if sid in written[src]:
                    continue
                food["type"] = "food"
                out.write(json.dumps(food, ensure_ascii=False) + "\n")
                merged_food_count += 1
                if sid in nutrients:
                    for code, amount in nutrients[sid].items():
                        row = {
                            "type": "nutrient",
                            "source": src,
                            "source_id": sid,
                            "nutrient_code": code,
                            "amount_per_100g": amount,
                        }
                        out.write(json.dumps(row, ensure_ascii=False) + "\n")
                        merged_nutrient_count += 1
                for s in servings_by_sid.get(sid, []):
                    write_serving(out, src, sid, s)
                    merged_serving_count += 1

    total_products = sum(len(sources_data[s][0]) for s in PREFERENCE)
    log.info("")
    log.info(
        "Merge complete: %d matched groups, %d total products -> %s",
        len(groups),
        merged_food_count,
        out_path,
    )
    log.info(
        "  Original sources had %d total products; %d merged, "
        "%d passed through unmatched",
        total_products,
        sum(len(g) for g in groups),
        merged_food_count - len(groups),
    )
    log.info("  Nutrients in merged output: %d", merged_nutrient_count)
    log.info("  Servings in merged output: %d", merged_serving_count)


if __name__ == "__main__":
    main()
