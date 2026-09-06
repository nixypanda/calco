import json
import logging
import os
from collections import defaultdict
from typing import cast

import rapidfuzz

from calco_import.util import (
    normalize_categories,
    normalize_name,
    serving_conversion,
    write_jsonl_row,
)

PREFERENCE = ["USDA", "IFCT", "INDB", "OFF"]
MACRO_CODES = {"ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G"}
MACRO_DIFF_THRESHOLD = 0.30
BASE_THRESHOLD = 90
LENGTH_RATIO_THRESHOLD = 0.50
MIN_MATCH_ENTRIES = 2
SUBSET_SCORE_PENALTY = 15

JsonRow = dict[str, object]
NutrientsByFood = dict[str, dict[str, float]]
ServingsByFood = dict[str, list[JsonRow]]
FoodsById = dict[str, JsonRow]
SourceData = tuple[FoodsById, NutrientsByFood, ServingsByFood]
SourcesData = dict[str, SourceData]
Group = dict[str, str]
MatchedKeys = set[tuple[str, str]]

log = logging.getLogger(__name__)

SOURCE_FILES = {
    "USDA": "usda_sr_legacy.jsonl",
    "INDB": "indb_2024.jsonl",
    "IFCT": "ifct2017.jsonl",
    "OFF": "off_india.jsonl",
}


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
                amount = obj.get("amount_per_100g")
                if isinstance(amount, str | int | float):
                    nutrients[sid][str(obj["nutrient_code"])] = float(amount)
            elif t == "serving":
                conversion = serving_conversion(obj)
                if conversion is not None:
                    unit, grams_per_unit = conversion
                    servings[sid].append(
                        {
                            "unit": unit,
                            "grams_per_unit": grams_per_unit,
                        }
                    )
    return foods, nutrients, servings


def find_barcode_matches(
    sources_data: SourcesData,
    preference: list[str] | None = None,
) -> list[Group]:
    order = preference or PREFERENCE
    bcode_map: dict[object, list[tuple[str, str]]] = defaultdict(list)
    for src in order:
        foods, _, _ = sources_data[src]
        for sid, f in foods.items():
            bc = f.get("barcode")
            if bc:
                bcode_map[bc].append((src, sid))

    groups: list[Group] = []
    for entries in bcode_map.values():
        if len(entries) < MIN_MATCH_ENTRIES:
            continue
        group: Group = {}
        for s, i in entries:
            group[s] = i
        groups.append(group)

    return groups


def _matched_keys(groups: list[Group]) -> MatchedKeys:
    return {(s, i) for g in groups for s, i in g.items()}


def find_name_matches(
    sources_data: SourcesData,
    existing_groups: list[Group],
    preference: list[str] | None = None,
) -> list[Group]:
    """
    Find cross-source food matches by fuzzy name comparison.

    Performance notes (was ~400s, now ~14s):
    - Originally ran nested Python loops over all candidate_a x pool_b
      pairs (~26M comparisons), calling normalize_name 2-3x per pair.
    - Fix: pre-compute normalize_name once per food upfront, then use
      rapidfuzz.process.extract() to push the inner loop into C with
      early score_cutoff termination. Only survivors get the token_set_ratio
      penalty check — safe because the penalty logic can only reduce scores,
      never raise them above the cutoff.
    """
    order = preference or PREFERENCE
    matched = _matched_keys(existing_groups)

    # Pre-normalize once per food instead of 2-3x per comparison
    unmatched: dict[str, list[tuple[str, str]]] = {}
    for src in order:
        foods, _, _ = sources_data[src]
        lst = [
            (sid, normalize_name(foods[sid].get("name", "")))
            for sid in foods
            if (src, sid) not in matched and foods[sid].get("name")
        ]
        unmatched[src] = lst

    new_groups: list[Group] = []

    for i, src_a in enumerate(order):
        for src_b in order[i + 1 :]:
            candidates_a = [
                (s, n) for s, n in unmatched[src_a] if (src_a, s) not in matched
            ]
            pool_b = {s: n for s, n in unmatched[src_b] if (src_b, s) not in matched}
            if not candidates_a or not pool_b:
                continue

            sids_a = [s for s, _ in candidates_a]
            names_a = [n for _, n in candidates_a]
            sids_b = list(pool_b.keys())
            names_b = list(pool_b.values())

            # Use extract() per query as a pre-filter instead of iterating
            # all pool_b items in Python. Runs the token_sort_ratio loop in C
            # with early cutoff, returning only pairs >= 90.
            all_matches: list[list[tuple[str, float, int]]] = []
            for q in names_a:
                matches = rapidfuzz.process.extract(
                    q,
                    names_b,
                    scorer=rapidfuzz.fuzz.token_sort_ratio,
                    score_cutoff=BASE_THRESHOLD,
                    limit=len(names_b),
                )
                all_matches.append(matches)

            claimed_b: set[str] = set()
            for idx_a, matches in enumerate(all_matches):
                if not matches:
                    continue
                sid_a = sids_a[idx_a]
                if (src_a, sid_a) in matched:
                    continue

                best_score = 0
                best_sid_b: str | None = None

                for _name_b, raw_score, idx_b in matches:
                    sid_b = sids_b[idx_b]
                    if (src_b, sid_b) in matched or sid_b in claimed_b:
                        continue

                    sort_score = int(raw_score)
                    set_score = rapidfuzz.fuzz.token_set_ratio(
                        names_a[idx_a], names_b[idx_b]
                    )

                    score = sort_score
                    if set_score - sort_score > SUBSET_SCORE_PENALTY:
                        score = min(sort_score, set_score - SUBSET_SCORE_PENALTY)

                    len_a = len(names_a[idx_a])
                    len_b = len(names_b[idx_b])
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
                    claimed_b.add(best_sid_b)
                    new_groups.append({src_a: sid_a, src_b: best_sid_b})

    return new_groups


def check_macros(
    sources_data: SourcesData,
    group: Group,
    preference: list[str] | None = None,
) -> list[tuple[str, str]]:
    order = preference or PREFERENCE
    warnings: list[tuple[str, str]] = []
    for code in MACRO_CODES:
        vals: dict[str, float] = {}
        for src in order:
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
            names: list[str] = []
            for src in order:
                if src in group:
                    foods, _, _ = sources_data[src]
                    sid = group[src]
                    names.append(f"{src}: {foods[sid].get('name', sid)}")
            warnings.append(
                (code, f"  {code} differs by {diff * 100:.0f}% — [{' | '.join(names)}]")
            )
    return warnings


def merge_group(
    sources_data: SourcesData,
    group: Group,
    preference: list[str] | None = None,
) -> tuple[JsonRow, dict[str, float], list[JsonRow]]:
    order = preference or PREFERENCE
    canonical_src = next(s for s in order if s in group)
    canonical_sid = group[canonical_src]
    _, _, servings = sources_data[canonical_src]
    foods, _, _ = sources_data[canonical_src]
    merged_food = dict(foods[canonical_sid])
    merged_servings = list(servings.get(canonical_sid, []))

    merged_nutrients: dict[str, float] = {}
    for src in order:
        if src not in group:
            continue
        _, nutrients, _ = sources_data[src]
        sid = group[src]
        if sid in nutrients:
            for code, amount in nutrients[sid].items():
                if code not in merged_nutrients:
                    merged_nutrients[code] = amount

    return merged_food, merged_nutrients, merged_servings


def build_merged_rows(
    sources_data: SourcesData,
    groups: list[Group],
    preference: list[str] | None = None,
) -> list[JsonRow]:
    order = preference or PREFERENCE
    rows: list[JsonRow] = []
    written: dict[str, set[str]] = {src: set() for src in order}

    for group in groups:
        food, nutrients, servings = merge_group(sources_data, group)
        food["type"] = "food"
        rows.append(food)
        for code, amount in nutrients.items():
            rows.append(
                {
                    "type": "nutrient",
                    "source": food["source"],
                    "source_id": food["source_id"],
                    "nutrient_code": code,
                    "amount_per_100g": amount,
                }
            )
        rows.extend(
            {
                "type": "serving",
                "source": food["source"],
                "source_id": food["source_id"],
                "unit": s["unit"],
                "grams_per_unit": s["grams_per_unit"],
            }
            for s in servings
        )
        for src in order:
            if src in group:
                written[src].add(group[src])

    for src in order:
        foods, nutrients_by_sid, servings_by_sid = sources_data[src]
        for sid, food in foods.items():
            if sid in written[src]:
                continue
            food_row = dict(food)
            food_row["type"] = "food"
            rows.append(food_row)
            if sid in nutrients_by_sid:
                rows.extend(
                    {
                        "type": "nutrient",
                        "source": src,
                        "source_id": sid,
                        "nutrient_code": code,
                        "amount_per_100g": amount,
                    }
                    for code, amount in nutrients_by_sid[sid].items()
                )
            rows.extend(
                {
                    "type": "serving",
                    "source": src,
                    "source_id": sid,
                    "unit": s["unit"],
                    "grams_per_unit": s["grams_per_unit"],
                }
                for s in servings_by_sid.get(sid, [])
            )

    return rows


def run(cfg: dict[str, object]) -> None:
    if cfg.get("dry_run"):
        log.info("Dry-run: would merge all sources into merged.jsonl")
        return

    data_dir = str(cfg["data_dir"])
    processed_dir = os.path.join(data_dir, "processed")

    sources_data: SourcesData = {}
    for src in PREFERENCE:
        fp = os.path.join(processed_dir, SOURCE_FILES[src])
        if not os.path.exists(fp):
            log.error("%s not found at %s", src, fp)
            log.error("Run 'calco-import fetch' for all sources first.")
            return
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

    log.info("Phase 1: barcode matching ...")
    barcode_groups = find_barcode_matches(sources_data)
    log.info("  %d groups from barcode", len(barcode_groups))

    log.info("Phase 2: name similarity matching ...")
    barcode_matched = _matched_keys(barcode_groups)
    for src in PREFERENCE:
        foods, _, _ = sources_data[src]
        n_unmatched = sum(
            1
            for sid in foods
            if (src, sid) not in barcode_matched and foods[sid].get("name")
        )
        log.info("  %s: %d unmatched after barcode phase", src, n_unmatched)
    name_groups = find_name_matches(sources_data, barcode_groups)
    all_groups = barcode_groups + name_groups
    log.info("  %d total matched groups", len(all_groups))

    log.info("Checking macro consistency across matched groups ...")
    for group in all_groups:
        for _code, message in check_macros(sources_data, group):
            log.warning(message)

    rows = build_merged_rows(sources_data, all_groups)

    out_path = os.path.join(processed_dir, "merged.jsonl")
    with open(out_path, "w") as out:
        for row in rows:
            write_jsonl_row(out, row)

    food_count = sum(1 for r in rows if r.get("type") == "food")
    nutrient_count = sum(1 for r in rows if r.get("type") == "nutrient")
    serving_count = sum(1 for r in rows if r.get("type") == "serving")
    total_calories = [
        cast("float", r["amount_per_100g"])
        for r in rows
        if r.get("type") == "nutrient" and r.get("nutrient_code") == "ENERGY_KCAL"
    ]
    avg_cal = sum(total_calories) / len(total_calories) if total_calories else 0.0

    log.info("")
    log.info("Merge complete:")
    log.info("  -- Matched groups:   %d", len(all_groups))
    log.info("  -- Total products:   %d", food_count)
    log.info("  -- Nutrient rows:    %d", nutrient_count)
    log.info("  -- Serving rows:     %d", serving_count)
    log.info("  -- Avg calories/100g across merged products: %.1f", avg_cal)
