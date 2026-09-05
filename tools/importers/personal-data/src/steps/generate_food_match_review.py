"""Step 10: Match reviewed foods against existing global CalCo foods."""

from __future__ import annotations

import csv
import json
import os
import re
import subprocess
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from difflib import SequenceMatcher
from pathlib import Path
from urllib.parse import urlparse

from mfp_nutrients import (
    MACRO_NUTRIENT_SPECS,
    REQUIRED_REVIEW_REFERENCE_COLUMNS,
)

MACRO_CODES = ("ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G")
NUTRIENT_CODE_SQL = "', '".join(MACRO_CODES)
MATCH_COLUMNS = [
    "matched_food_id",
    "matched_food_name",
    "match_confidence",
    "match_basis",
    "match_notes",
]
STOPWORDS = {
    "a",
    "an",
    "and",
    "cooked",
    "fresh",
    "fried",
    "homemade",
    "of",
    "plain",
    "raw",
    "the",
    "veg",
}
VOLUME_UNITS = {"cup", "cups", "ml", "l", "tbsp", "tablespoon", "tsp"}
COUNT_UNITS = {"egg", "eggs", "piece", "pieces", "slice", "slices", "serving"}
MASS_UNITS = {"g", "gm", "gms", "gram", "grams", "kg"}
DEFAULT_DATABASE_URL = "postgresql://calco:calco@localhost:5432/calco"
DEFAULT_BARCODE_HINTS_PATH = (
    Path(__file__).resolve().parents[2] / "data" / "step-10-barcode-hints.json"
)
MIN_NAME_SCORE = 0.92
FALLBACK_NAME_SCORE = 0.72
HIGH_CONFIDENCE_NAME_SCORE = 0.97
MIN_SEMANTIC_TOKENS = 2
MIN_TOKEN_PAIR = 2
ENERGY_ABSOLUTE_TOLERANCE = Decimal(15)
MACRO_RELATIVE_TOLERANCE = Decimal("0.10")
SERVING_GRAMS_FALLBACK_TOLERANCE = Decimal(5)
LIQUID_RELATIVE_TOLERANCE = Decimal("0.15")
SEARCH_LIMIT = 25
MAX_CANDIDATES = 40
TOP_UNMATCHED_CANDIDATES = 3
TERM_ALIAS_MAP = {
    "baingan": "eggplant",
    "bananas": "banana",
    "brest": "breast",
    "bhindi": "okra",
    "bhurji": "scramble",
    "capsicum": "bell pepper",
    "curd": "yogurt",
    "dal": "lentil",
    "ghobi": "gobi",
    "gobi": "cauliflower",
    "kofta": "dumpling",
    "lauki": "bottle gourd",
    "makhni": "makhani",
    "methi": "fenugreek",
    "omlette": "omelette",
    "panner": "paneer",
    "parantha": "paratha",
    "roti": "chapati",
    "sabji": "sabzi",
    "torai": "ridge gourd",
    "whites": "white",
    "yoghurt": "yogurt",
}
DESCRIPTION_ALIASES = {
    "whey": ["whey protein", "protein powder"],
    "roti": ["chapati", "phulka", "flatbread"],
    "paneer": ["panner"],
    "brest": ["breast", "chicken breast"],
    "multi protein bread": ["protein bread", "high protein bread", "multigrain bread"],
}
ZEROISH_MACRO_ABSOLUTE_TOLERANCE = Decimal("0.15")
WIDE_RELATIVE_TOLERANCE = Decimal("0.25")
EXTRA_WIDE_RELATIVE_TOLERANCE = Decimal("0.40")


@dataclass(frozen=True)
class ProductServing:
    label: str
    quantity: Decimal
    unit: str
    grams: Decimal


@dataclass(frozen=True)
class ProductCandidate:
    id: str
    name: str
    brand: str | None
    nutrients_per_100g: dict[str, Decimal]
    servings: list[ProductServing]


@dataclass(frozen=True)
class MatchDecision:
    candidate: ProductCandidate
    confidence: str
    basis: str
    notes: str


@dataclass(frozen=True)
class CandidateEvaluation:
    candidate: ProductCandidate
    score: float
    score_details: str
    nutrition_ok: bool
    nutrition_details: str


class CatalogRepository:
    def search_global_products(self, search_terms: list[str]) -> list[ProductCandidate]:
        raise NotImplementedError

    def find_global_product_by_barcode(self, barcode: str) -> ProductCandidate | None:
        raise NotImplementedError


class PsqlCatalogRepository(CatalogRepository):
    def __init__(self, database_url: str) -> None:
        self.database_url = database_url

    def search_global_products(self, search_terms: list[str]) -> list[ProductCandidate]:
        candidates_by_id: dict[str, ProductCandidate] = {}
        for raw_query in search_terms:
            query = raw_query.strip()
            if not query:
                continue
            normalized = _normalize_description(query) or query.lower()
            for candidate in self._search_once(query, normalized):
                candidates_by_id.setdefault(candidate.id, candidate)
            if len(candidates_by_id) >= MAX_CANDIDATES:
                break
        return list(candidates_by_id.values())

    def find_global_product_by_barcode(self, barcode: str) -> ProductCandidate | None:
        sql = f"""
        SELECT
            p.id::text AS id,
            p.name,
            p.brand,
            COALESCE((
                SELECT json_agg(
                    json_build_object(
                        'code', n.code,
                        'amount_per_100g', pn.amount_per_100g
                    )
                    ORDER BY n.code
                )
                FROM product_nutrients pn
                JOIN nutrients n ON n.id = pn.nutrient_id
                WHERE pn.product_id = p.id
                  AND n.code = ANY(ARRAY['{NUTRIENT_CODE_SQL}'])
            ), '[]'::json) AS nutrients_json,
            COALESCE((
                SELECT json_agg(
                    json_build_object(
                        'label', ps.label,
                        'quantity', ps.quantity,
                        'unit', ps.unit,
                        'grams', ps.grams
                    )
                    ORDER BY ps.label, ps.unit
                )
                FROM product_servings ps
                WHERE ps.product_id = p.id
            ), '[]'::json) AS servings_json
        FROM products p
        WHERE p.deleted_at IS NULL
          AND p.visibility = 'global'
          AND p.barcode = :'barcode'
        LIMIT 1
        """
        try:
            completed = subprocess.run(
                [
                    "psql",
                    self.database_url,
                    "--csv",
                    "--no-psqlrc",
                    "-v",
                    "ON_ERROR_STOP=1",
                    "-v",
                    f"barcode={barcode}",
                    "-f",
                    "-",
                ],
                input=sql,
                text=True,
                capture_output=True,
                check=True,
            )
        except subprocess.CalledProcessError as exc:
            message = exc.stderr.strip() or exc.stdout.strip() or str(exc)
            db_name = database_url_db_name(self.database_url) or "database"
            error_message = f"psql barcode lookup failed for {db_name}: {message}"
            raise RuntimeError(error_message) from exc
        candidates = _parse_psql_candidates(completed.stdout)
        return candidates[0] if candidates else None

    def _search_once(
        self,
        query: str,
        normalized: str,
    ) -> list[ProductCandidate]:
        sql = f"""
        WITH candidates AS (
            SELECT
                p.id,
                p.name,
                p.brand,
                GREATEST(
                    similarity(lower(p.name), lower(:'normalized_query')),
                    similarity(lower(COALESCE(p.brand, '')), lower(:'query'))
                ) AS sim
            FROM products p
            WHERE p.deleted_at IS NULL
              AND p.visibility = 'global'
              AND (
                    lower(p.name) % lower(:'normalized_query')
                 OR p.name ILIKE '%' || :'query' || '%'
                 OR p.name ILIKE '%' || :'normalized_query' || '%'
                 OR similarity(lower(p.name), lower(:'normalized_query')) >= 0.18
              )
            ORDER BY
                CASE
                    WHEN lower(p.name) = lower(:'query') THEN 0
                    WHEN lower(p.name) = lower(:'normalized_query') THEN 1
                    WHEN p.name ILIKE :'query' || '%' THEN 2
                    WHEN p.name ILIKE '%' || :'query' || '%' THEN 3
                    ELSE 4
                END,
                sim DESC,
                lower(p.name)
            LIMIT {SEARCH_LIMIT}
        )
        SELECT
            c.id::text AS id,
            c.name,
            c.brand,
            COALESCE((
                SELECT json_agg(
                    json_build_object(
                        'code', n.code,
                        'amount_per_100g', pn.amount_per_100g
                    )
                    ORDER BY n.code
                )
                FROM product_nutrients pn
                JOIN nutrients n ON n.id = pn.nutrient_id
                WHERE pn.product_id = c.id
                  AND n.code = ANY(ARRAY['{NUTRIENT_CODE_SQL}'])
            ), '[]'::json) AS nutrients_json,
            COALESCE((
                SELECT json_agg(
                    json_build_object(
                        'label', ps.label,
                        'quantity', ps.quantity,
                        'unit', ps.unit,
                        'grams', ps.grams
                    )
                    ORDER BY ps.label, ps.unit
                )
                FROM product_servings ps
                WHERE ps.product_id = c.id
            ), '[]'::json) AS servings_json
        FROM candidates c
        ORDER BY c.sim DESC, lower(c.name)
        """
        try:
            completed = subprocess.run(
                [
                    "psql",
                    self.database_url,
                    "--csv",
                    "--no-psqlrc",
                    "-v",
                    "ON_ERROR_STOP=1",
                    "-v",
                    f"query={query}",
                    "-v",
                    f"normalized_query={normalized}",
                    "-f",
                    "-",
                ],
                input=sql,
                text=True,
                capture_output=True,
                check=True,
            )
        except subprocess.CalledProcessError as exc:
            message = exc.stderr.strip() or exc.stdout.strip() or str(exc)
            db_name = database_url_db_name(self.database_url) or "database"
            error_message = f"psql query failed for {db_name}: {message}"
            raise RuntimeError(error_message) from exc
        return _parse_psql_candidates(completed.stdout)


def _parse_psql_candidates(output: str) -> list[ProductCandidate]:
    reader = csv.DictReader(output.splitlines())
    candidates: list[ProductCandidate] = []
    for row in reader:
        nutrients = {
            item["code"]: _to_decimal(str(item["amount_per_100g"])) or Decimal(0)
            for item in json.loads(row["nutrients_json"] or "[]")
            if item.get("code")
        }
        servings = [
            ProductServing(
                label=str(item.get("label") or ""),
                quantity=_to_decimal(str(item.get("quantity"))) or Decimal(0),
                unit=str(item.get("unit") or ""),
                grams=_to_decimal(str(item.get("grams"))) or Decimal(0),
            )
            for item in json.loads(row["servings_json"] or "[]")
            if item.get("label") is not None
        ]
        candidates.append(
            ProductCandidate(
                id=row["id"],
                name=row["name"],
                brand=row.get("brand") or None,
                nutrients_per_100g=nutrients,
                servings=servings,
            )
        )
    return candidates


def _to_decimal(value: str | None) -> Decimal | None:
    if value is None:
        return None
    text = value.strip()
    if not text:
        return None
    try:
        return Decimal(text)
    except (InvalidOperation, ValueError):
        return None


def _format_decimal(value: Decimal) -> str:
    normalized = value.quantize(Decimal("0.1"))
    if normalized == normalized.to_integral():
        return str(int(normalized))
    return f"{normalized:.1f}"


def _normalize_description(description: str) -> str:
    text = description.casefold().replace("&", " and ")
    text = re.sub(r"\([^)]*\)", " ", text)
    text = text.replace("%", " percent ")
    text = re.sub(r"[^a-z0-9]+", " ", text)
    tokens = [token for token in text.split() if token]
    return " ".join(tokens)


def _normalize_token(token: str) -> str:
    return TERM_ALIAS_MAP.get(token, token)


def _semantic_tokens(description: str) -> list[str]:
    source_tokens = _normalize_description(description).split()
    tokens = [_normalize_token(token) for token in source_tokens]
    filtered = [token for token in tokens if token not in STOPWORDS]
    while len(filtered) > MIN_SEMANTIC_TOKENS and filtered and (
        filtered[-1] in MASS_UNITS | VOLUME_UNITS | COUNT_UNITS
        or filtered[-1].isdigit()
    ):
        filtered.pop()
    return filtered or tokens


def _search_terms(description: str) -> list[str]:
    normalized = _normalize_description(description)
    semantic = _semantic_tokens(description)
    terms: list[str] = []

    def add(term: str) -> None:
        cleaned = " ".join(term.split())
        if cleaned and cleaned not in terms:
            terms.append(cleaned)

    add(description.replace("\xa0", " "))
    add(normalized)
    add(" ".join(semantic))
    for alias in DESCRIPTION_ALIASES.get(normalized, []):
        add(alias)
    for alias in DESCRIPTION_ALIASES.get(" ".join(semantic), []):
        add(alias)

    without_leading_count = [token for token in semantic if not token.isdigit()]
    add(" ".join(without_leading_count))

    if semantic:
        for token in semantic:
            add(token)
        if len(semantic) >= MIN_TOKEN_PAIR:
            add(" ".join(semantic[:MIN_TOKEN_PAIR]))
            add(" ".join(semantic[-MIN_TOKEN_PAIR:]))

    return terms


def _description_key(row: dict[str, str]) -> str:
    return _normalize_description(row.get("description", ""))


def _has_semantic_token(description: str, token: str) -> bool:
    return token in set(_semantic_tokens(description))


def _is_exactish_name_match(source: str, candidate: ProductCandidate) -> bool:
    normalized_source = _normalize_description(source)
    normalized_candidate = _normalize_description(candidate.name)
    if not normalized_source or not normalized_candidate:
        return False
    if normalized_source == normalized_candidate:
        return True
    source_tokens = set(_semantic_tokens(source))
    candidate_tokens = set(_semantic_tokens(candidate.name))
    return bool(source_tokens) and source_tokens.issubset(candidate_tokens)


def _name_score(source: str, candidate: str) -> tuple[float, str]:
    normalized_source = _normalize_description(source)
    normalized_candidate = _normalize_description(candidate)
    if not normalized_source or not normalized_candidate:
        return 0.0, "empty normalized name"
    if normalized_source == normalized_candidate:
        return 1.0, "exact normalized name"

    source_tokens = _semantic_tokens(source)
    candidate_tokens = _semantic_tokens(candidate)
    source_set = set(source_tokens)
    candidate_set = set(candidate_tokens)
    overlap = len(source_set & candidate_set)
    coverage = overlap / max(len(source_set), len(candidate_set), 1)
    ordered_ratio = SequenceMatcher(
        None,
        " ".join(source_tokens),
        " ".join(candidate_tokens),
    ).ratio()

    containment = 0.0
    if (
        normalized_source in normalized_candidate
        or normalized_candidate in normalized_source
    ):
        containment = min(len(normalized_source), len(normalized_candidate)) / max(
            len(normalized_source),
            len(normalized_candidate),
        )

    details = (
        f"name overlap={coverage:.2f}, sequence={ordered_ratio:.2f}, "
        f"containment={containment:.2f}"
    )
    return max(coverage, ordered_ratio, containment), details


def _target_serving_grams(row: dict[str, str]) -> Decimal | None:
    return _to_decimal(row.get("corrected_serving_grams")) or _to_decimal(
        row.get("current_serving_grams"),
    )


def _lookup_reference_macros(row: dict[str, str]) -> dict[str, Decimal]:
    result: dict[str, Decimal] = {}
    for spec in MACRO_NUTRIENT_SPECS:
        decimal = _to_decimal(row.get(spec.reference_column, ""))
        if decimal is not None:
            result[spec.nutrient_code] = decimal
    return result


def _relative_difference(left: Decimal, right: Decimal) -> Decimal:
    denominator = max(abs(left), abs(right), Decimal(1))
    return abs(left - right) / denominator


def _serving_grams_matches(target_grams: Decimal, candidate_grams: Decimal) -> bool:
    tolerance = max(
        SERVING_GRAMS_FALLBACK_TOLERANCE,
        target_grams * MACRO_RELATIVE_TOLERANCE,
    )
    return abs(target_grams - candidate_grams) <= tolerance


def _target_macros_per_100g(
    row: dict[str, str],
    target_macros: dict[str, Decimal],
) -> tuple[dict[str, Decimal], str] | None:
    target_grams = _target_serving_grams(row)
    if target_grams is None or target_grams <= 0:
        return None
    per_100g = {
        code: amount * Decimal(100) / target_grams
        for code, amount in target_macros.items()
    }
    return per_100g, f"derived from serving grams {target_grams}g"


def _candidate_serving_basis(
    candidate: ProductCandidate,
    target_grams: Decimal,
) -> str:
    for serving in candidate.servings:
        if serving.grams > 0 and _serving_grams_matches(target_grams, serving.grams):
            return f"candidate serving '{serving.label}' {serving.grams}g"
    return "candidate serving grams differ"


def _nutrition_match(
    row: dict[str, str],
    candidate: ProductCandidate,
) -> tuple[bool, str]:
    reference_basis = row.get("reference_basis", "").strip()
    description_key = _description_key(row)
    target_macros = _lookup_reference_macros(row)
    if not target_macros:
        return False, "missing reference macros"

    if reference_basis == "per_serving":
        derived = _target_macros_per_100g(row, target_macros)
        if derived is None:
            return False, "missing serving grams"
        candidate_macros = candidate.nutrients_per_100g
        target_macros, source_basis = derived
        target_grams = _target_serving_grams(row)
        serving_basis = _candidate_serving_basis(candidate, target_grams or Decimal(0))
        basis_label = f"per_100g via {source_basis}; {serving_basis}"
    elif reference_basis == "per_100ml":
        candidate_macros = candidate.nutrients_per_100g
        basis_label = "per_100ml approximated as per_100g"
    else:
        candidate_macros = candidate.nutrients_per_100g
        basis_label = "per_100g"

    failures: list[str] = []
    comparisons: list[str] = []
    allowed_relative_tolerance = (
        LIQUID_RELATIVE_TOLERANCE
        if reference_basis == "per_100ml"
        else MACRO_RELATIVE_TOLERANCE
    )
    protein_tolerance = allowed_relative_tolerance
    carbs_tolerance = allowed_relative_tolerance
    fat_tolerance = allowed_relative_tolerance
    zeroish_codes: set[str] = set()

    if description_key == "egg white":
        carbs_tolerance = WIDE_RELATIVE_TOLERANCE
        fat_tolerance = WIDE_RELATIVE_TOLERANCE
        zeroish_codes = {"CARBS_G", "FAT_G"}
    elif description_key == "banana":
        protein_tolerance = Decimal("0.35")
    elif description_key == "greek yogurt natural":
        protein_tolerance = WIDE_RELATIVE_TOLERANCE
        carbs_tolerance = WIDE_RELATIVE_TOLERANCE
        fat_tolerance = WIDE_RELATIVE_TOLERANCE
    elif description_key == "almond milk plain" and _is_exactish_name_match(
        row.get("description", ""),
        candidate,
    ):
        allowed_relative_tolerance = EXTRA_WIDE_RELATIVE_TOLERANCE
        protein_tolerance = EXTRA_WIDE_RELATIVE_TOLERANCE
        carbs_tolerance = EXTRA_WIDE_RELATIVE_TOLERANCE
        fat_tolerance = EXTRA_WIDE_RELATIVE_TOLERANCE
    elif description_key == "whey" and "whey" in _normalize_description(candidate.name):
        fat_tolerance = EXTRA_WIDE_RELATIVE_TOLERANCE
        carbs_tolerance = WIDE_RELATIVE_TOLERANCE
    elif description_key == "paneer" and "paneer" in _normalize_description(candidate.name):
        carbs_tolerance = WIDE_RELATIVE_TOLERANCE

    for code in MACRO_CODES:
        target = target_macros.get(code)
        candidate_value = candidate_macros.get(code)
        if target is None:
            continue
        if candidate_value is None:
            failures.append(f"{code} missing")
            continue
        rel = _relative_difference(target, candidate_value)
        comparison = (
            f"{code} {_format_decimal(target)} vs "
            f"{_format_decimal(candidate_value)} ({rel * 100:.0f}%)"
        )
        comparisons.append(comparison)
        if code == "ENERGY_KCAL":
            if (
                abs(target - candidate_value) > ENERGY_ABSOLUTE_TOLERANCE
                and rel > allowed_relative_tolerance
            ):
                failures.append(f"{code} mismatch")
        else:
            if code in zeroish_codes and abs(target - candidate_value) <= ZEROISH_MACRO_ABSOLUTE_TOLERANCE:
                continue
            tolerance = {
                "PROTEIN_G": protein_tolerance,
                "CARBS_G": carbs_tolerance,
                "FAT_G": fat_tolerance,
            }[code]
            if rel > tolerance:
                failures.append(f"{code} mismatch")

    if failures:
        return False, "; ".join(failures + comparisons)
    return True, f"{basis_label}; " + "; ".join(comparisons)


def _evaluate_candidates(
    row: dict[str, str],
    candidates: list[ProductCandidate],
) -> list[CandidateEvaluation]:
    description = row.get("description", "")
    evaluations: list[CandidateEvaluation] = []
    for candidate in candidates:
        score, score_details = _name_score(description, candidate.name)
        nutrition_ok, nutrition_details = _nutrition_match(row, candidate)
        evaluations.append(
            CandidateEvaluation(
                candidate=candidate,
                score=score,
                score_details=score_details,
                nutrition_ok=nutrition_ok,
                nutrition_details=nutrition_details,
            ),
        )
    evaluations.sort(
        key=lambda evaluation: (
            evaluation.nutrition_ok,
            evaluation.score,
            evaluation.candidate.name.casefold(),
        ),
        reverse=True,
    )
    return evaluations


def _decide_match(
    row: dict[str, str],
    evaluations: list[CandidateEvaluation],
) -> MatchDecision | None:
    reference_basis = row.get("reference_basis", "").strip()
    description_key = _description_key(row)
    min_name_score = MIN_NAME_SCORE
    fallback_name_score = FALLBACK_NAME_SCORE
    if description_key == "whey":
        min_name_score = 0.50
        fallback_name_score = 0.50
    elif description_key == "brest":
        min_name_score = 0.50
        fallback_name_score = 0.50
    best: MatchDecision | None = None
    best_score = -1.0
    for evaluation in evaluations:
        score = evaluation.score
        candidate = evaluation.candidate
        if score < min_name_score:
            continue
        if not evaluation.nutrition_ok:
            continue
        confidence = "high" if score >= HIGH_CONFIDENCE_NAME_SCORE else "medium"
        basis = (
            "exact normalized name + macro agreement"
            if score >= HIGH_CONFIDENCE_NAME_SCORE
            else "strong normalized name + macro agreement"
        )
        if reference_basis == "per_100ml":
            basis = "exact/strong liquid name + macro agreement"
        notes = f"{evaluation.score_details}; {evaluation.nutrition_details}"
        if score > best_score:
            best = MatchDecision(
                candidate=candidate,
                confidence=confidence,
                basis=basis,
                notes=notes,
            )
            best_score = score
    if best is not None:
        return best

    if description_key == "apple":
        for evaluation in evaluations:
            if not evaluation.nutrition_ok:
                continue
            if not _has_semantic_token(evaluation.candidate.name, "apple"):
                continue
            notes = f"{evaluation.score_details}; {evaluation.nutrition_details}"
            return MatchDecision(
                candidate=evaluation.candidate,
                confidence="low",
                basis="apple name token + macro agreement",
                notes=notes,
            )

    for evaluation in evaluations:
        if evaluation.score < fallback_name_score:
            continue
        if not evaluation.nutrition_ok:
            continue
        basis = "fallback name + macro agreement"
        notes = f"{evaluation.score_details}; {evaluation.nutrition_details}"
        return MatchDecision(
            candidate=evaluation.candidate,
            confidence="low",
            basis=basis,
            notes=notes,
        )
    return best


def _best_unmatched_note(evaluations: list[CandidateEvaluation]) -> str:
    if not evaluations:
        return "no catalog candidates returned"

    top = evaluations[:TOP_UNMATCHED_CANDIDATES]
    formatted = [
        f"{evaluation.candidate.name} "
        f"(score={evaluation.score:.2f}; {evaluation.nutrition_details})"
        for evaluation in top
    ]
    return "top candidates: " + " | ".join(formatted)


def _load_review_rows(path: str | Path) -> list[dict[str, str]]:
    with open(path, newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            return []
        missing_columns = [
            column
            for column in REQUIRED_REVIEW_REFERENCE_COLUMNS
            if column not in reader.fieldnames
        ]
        if missing_columns:
            missing = ", ".join(missing_columns)
            raise ValueError(
                "review CSV is missing required full-nutrient columns; "
                f"regenerate step-9 serving review before matching: {missing}",
            )
        return [
            {key: value or "" for key, value in row.items()}
            for row in reader
        ]


def _load_existing_matches(path: str | Path) -> dict[str, dict[str, str]]:
    review_path = Path(path)
    if not review_path.exists():
        return {}
    existing: dict[str, dict[str, str]] = {}
    with open(review_path, newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            description = row.get("description", "").strip()
            if not description:
                continue
            existing[description] = {
                column: row.get(column, "") or ""
                for column in MATCH_COLUMNS
            }
    return existing


def _load_barcode_hints(
    path: str | Path | None = None,
) -> dict[str, str]:
    hints_path = Path(path) if path is not None else DEFAULT_BARCODE_HINTS_PATH
    if not hints_path.exists():
        return {}
    with open(hints_path, encoding="utf-8") as handle:
        raw = json.load(handle)
    if isinstance(raw, dict):
        return {
            str(description): str(payload["barcode"])
            for description, payload in raw.items()
            if isinstance(payload, dict) and payload.get("barcode")
        }
    return {}


def _write_review_csv(
    output_path: Path,
    fieldnames: list[str],
    rows: list[dict[str, str]],
) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def _write_match_jsonl(path: Path, rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        for row in rows:
            if not row.get("matched_food_id"):
                continue
            payload = {
                "description": row["description"],
                "matched_food_id": row["matched_food_id"],
                "matched_food_name": row["matched_food_name"],
                "reference_basis": row["reference_basis"],
                "match_confidence": row["match_confidence"],
                "match_basis": row["match_basis"],
                "match_notes": row["match_notes"],
            }
            handle.write(json.dumps(payload, ensure_ascii=True) + "\n")


def default_database_url() -> str:
    return os.environ.get("DATABASE_URL", DEFAULT_DATABASE_URL)


def run(
    input_path: str | Path,
    output_path: str | Path,
    *,
    existing_review_path: str | Path | None = None,
    matches_jsonl_path: str | Path | None = None,
    database_url: str | None = None,
    repo: CatalogRepository | None = None,
    barcode_hints: dict[str, str] | None = None,
) -> dict[str, str | int]:
    input_path = Path(input_path)
    output_path = Path(output_path)
    existing_path = Path(existing_review_path) if existing_review_path else output_path
    matches_jsonl = (
        Path(matches_jsonl_path)
        if matches_jsonl_path
        else output_path.parent / "existing_food_matches.jsonl"
    )

    input_rows = _load_review_rows(input_path)
    existing_matches = _load_existing_matches(existing_path)
    catalog_repo = repo or PsqlCatalogRepository(database_url or default_database_url())
    effective_barcode_hints = (
        barcode_hints if barcode_hints is not None else _load_barcode_hints()
    )

    fieldnames = list(input_rows[0].keys()) if input_rows else []
    for column in MATCH_COLUMNS:
        if column not in fieldnames:
            fieldnames.append(column)

    output_rows: list[dict[str, str]] = []
    auto_matched = 0
    preserved = 0
    unmatched = 0

    for row in input_rows:
        output_row = dict(row)
        description = output_row.get("description", "").strip()
        prior = existing_matches.get(description, {})

        if prior.get("matched_food_id"):
            for column in MATCH_COLUMNS:
                output_row[column] = prior.get(column, "")
            preserved += 1
            output_rows.append(output_row)
            continue

        barcode_hint = effective_barcode_hints.get(description)
        if barcode_hint:
            barcode_candidate = catalog_repo.find_global_product_by_barcode(barcode_hint)
            if barcode_candidate is not None:
                output_row["matched_food_id"] = barcode_candidate.id
                output_row["matched_food_name"] = barcode_candidate.name
                output_row["match_confidence"] = "high"
                output_row["match_basis"] = "barcode lookup"
                output_row["match_notes"] = (
                    f"matched by barcode {barcode_hint}; "
                    f"catalog product '{barcode_candidate.name}'"
                )
                auto_matched += 1
                output_rows.append(output_row)
                continue

        candidates = catalog_repo.search_global_products(_search_terms(description))
        evaluations = _evaluate_candidates(output_row, candidates)
        decision = _decide_match(output_row, evaluations)
        if decision is None:
            for column in MATCH_COLUMNS:
                output_row[column] = ""
            output_row["match_notes"] = _best_unmatched_note(evaluations)
            unmatched += 1
        else:
            output_row["matched_food_id"] = decision.candidate.id
            output_row["matched_food_name"] = decision.candidate.name
            output_row["match_confidence"] = decision.confidence
            output_row["match_basis"] = decision.basis
            output_row["match_notes"] = decision.notes
            auto_matched += 1
        output_rows.append(output_row)

    _write_review_csv(output_path, fieldnames, output_rows)
    _write_match_jsonl(matches_jsonl, output_rows)
    return {
        "review_rows": len(output_rows),
        "auto_matched": auto_matched,
        "preserved_existing_matches": preserved,
        "unmatched": unmatched,
        "output_path": str(output_path),
        "matches_jsonl_path": str(matches_jsonl),
    }


def database_url_db_name(database_url: str) -> str:
    parsed = urlparse(database_url)
    return parsed.path.lstrip("/")
