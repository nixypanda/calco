use std::cmp::Ordering;

use chrono::{DateTime, NaiveDate, Utc};

use super::{Barcode, Brand, Category, CategorySuggestion, ProductId, ProductName};

/// Trigram-containment threshold for fuzzy catalog matches.
///
/// Exact, prefix, and substring matches bypass this gate. The underlying
/// `rust_fuzzy_search` score is asymmetric: it measures how much of the query's
/// trigrams appear in the candidate.
pub const DEFAULT_FUZZY_THRESHOLD: f64 = 0.50;
pub const PRODUCT_SEARCH_LIMIT: usize = 50;

/// A validated fuzzy-match threshold.
///
/// Only finite values in `0.0..=1.0` can be represented, so an invalid
/// threshold cannot silently become permissive or reject every match.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct FuzzyThreshold(f64);

impl FuzzyThreshold {
    pub(crate) fn new(value: f64) -> Option<Self> {
        (value.is_finite() && (0.0..=1.0).contains(&value)).then_some(Self(value))
    }

    pub(crate) fn value(self) -> f64 {
        self.0
    }
}

impl Default for FuzzyThreshold {
    fn default() -> Self {
        Self::new(DEFAULT_FUZZY_THRESHOLD).expect("default fuzzy threshold must be valid")
    }
}

/// Fuzzy gates differ by call site: product matches use `>=`, while category
/// suggestions preserve the previous exclusive `> threshold` gate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ThresholdGate {
    Inclusive,
    Exclusive,
}

impl ThresholdGate {
    fn accepts(self, similarity: Similarity, threshold: FuzzyThreshold) -> bool {
        match self {
            Self::Inclusive => similarity.value() >= threshold.value(),
            Self::Exclusive => similarity.value() > threshold.value(),
        }
    }
}

/// Text normalized once at the search boundary.
///
/// The inner string is private so callers cannot construct an unnormalized
/// value and accidentally compare raw user input with normalized candidates.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct NormalizedText(String);

impl NormalizedText {
    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum MatchKind {
    Exact,
    Prefix,
    Substring,
    Fuzzy,
}

/// A bounded similarity score.
///
/// Invalid values cannot be represented: construction clamps to `0.0..=1.0`
/// and maps NaN to `0.0`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Similarity(f64);

impl Similarity {
    pub(crate) fn new(value: f64) -> Self {
        if value.is_nan() {
            Self(0.0)
        } else {
            Self(value.clamp(0.0, 1.0))
        }
    }

    pub(crate) fn value(&self) -> f64 {
        self.0
    }

    pub(crate) fn total_cmp(&self, other: &Self) -> Ordering {
        self.0.total_cmp(&other.0)
    }
}

impl Default for Similarity {
    fn default() -> Self {
        Self(0.0)
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct ValueMatch {
    pub(crate) kind: MatchKind,
    pub(crate) similarity: Similarity,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct DocumentMatches {
    pub(crate) identifier: Option<ValueMatch>,
    pub(crate) name: Option<ValueMatch>,
    pub(crate) brand: Option<ValueMatch>,
    pub(crate) term: Option<ValueMatch>,
    pub(crate) name_similarity: Similarity,
    pub(crate) brand_similarity: Similarity,
}

impl DocumentMatches {
    pub(crate) fn is_match(&self) -> bool {
        self.identifier.is_some()
            || self.name.is_some()
            || self.brand.is_some()
            || self.term.is_some()
    }

    pub(crate) fn name_brand_similarity(&self) -> Similarity {
        match self.name_similarity.total_cmp(&self.brand_similarity) {
            Ordering::Less => self.brand_similarity,
            Ordering::Equal | Ordering::Greater => self.name_similarity,
        }
    }
}

#[cfg(test)]
#[derive(Debug, Clone, Copy)]
pub(crate) struct SearchDocument<'a> {
    pub(crate) name: &'a str,
    pub(crate) brand: Option<&'a str>,
    pub(crate) identifier: Option<&'a str>,
    pub(crate) terms: &'a [Category],
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct TextMatcher {
    threshold: FuzzyThreshold,
}

impl TextMatcher {
    pub(crate) fn new(threshold: FuzzyThreshold) -> Self {
        Self { threshold }
    }

    pub(crate) fn normalize(&self, text: &str) -> NormalizedText {
        let mut collapsed = String::with_capacity(text.len());
        for word in text.split_whitespace() {
            if !collapsed.is_empty() {
                collapsed.push(' ');
            }
            collapsed.push_str(word);
        }
        NormalizedText(collapsed.to_lowercase())
    }

    fn normalize_optional(&self, value: Option<&str>) -> Option<NormalizedText> {
        value
            .filter(|value| !value.trim().is_empty())
            .map(|value| self.normalize(value))
    }

    #[cfg(test)]
    pub(crate) fn match_value(&self, query: &NormalizedText, value: &str) -> Option<ValueMatch> {
        let value = self.normalize(value);
        self.match_value_normalized(query, &value, ThresholdGate::Inclusive)
    }

    #[cfg(test)]
    pub(crate) fn match_document(
        &self,
        query: &NormalizedText,
        document: &SearchDocument<'_>,
    ) -> DocumentMatches {
        let name = self.normalize(document.name);
        let brand = self.normalize_optional(document.brand);
        let identifier = self.normalize_optional(document.identifier);
        let terms = document
            .terms
            .iter()
            .map(|term| self.normalize(term.0.as_str()))
            .collect::<Vec<_>>();

        self.match_document_fields(query, &name, brand.as_ref(), identifier.as_ref(), &terms)
    }

    #[cfg(test)]
    fn match_document_fields(
        &self,
        query: &NormalizedText,
        name: &NormalizedText,
        brand: Option<&NormalizedText>,
        identifier: Option<&NormalizedText>,
        terms: &[NormalizedText],
    ) -> DocumentMatches {
        let mut matches = self.match_fields(query, name, brand, identifier);
        // Term matches can never outrank a name, brand, or identifier match.
        if !matches.is_match() {
            matches.term = self.match_terms(query, terms);
        }
        matches
    }

    fn match_fields(
        &self,
        query: &NormalizedText,
        name: &NormalizedText,
        brand: Option<&NormalizedText>,
        identifier: Option<&NormalizedText>,
    ) -> DocumentMatches {
        let identifier_match = identifier.and_then(|value| self.match_identifier(query, value));
        let (name_match, name_similarity) =
            self.match_value_scored(query, name, ThresholdGate::Inclusive);
        let (brand_match, brand_similarity) = brand
            .map(|value| self.match_value_scored(query, value, ThresholdGate::Inclusive))
            .unwrap_or((None, Similarity::default()));

        DocumentMatches {
            identifier: identifier_match,
            name: name_match,
            brand: brand_match,
            term: None,
            name_similarity,
            brand_similarity,
        }
    }

    fn match_terms(&self, query: &NormalizedText, terms: &[NormalizedText]) -> Option<ValueMatch> {
        terms
            .iter()
            .filter_map(|term| self.match_value_normalized(query, term, ThresholdGate::Inclusive))
            .fold(None, best_value_match)
    }

    fn match_value_normalized(
        &self,
        query: &NormalizedText,
        value: &NormalizedText,
        gate: ThresholdGate,
    ) -> Option<ValueMatch> {
        self.match_value_scored(query, value, gate).0
    }

    /// Returns the accepted match (if any) together with the raw similarity.
    ///
    /// The similarity is needed for tie-breaking even when the fuzzy gate
    /// rejects the field, so the ranker never has to compute it twice.
    fn match_value_scored(
        &self,
        query: &NormalizedText,
        value: &NormalizedText,
        gate: ThresholdGate,
    ) -> (Option<ValueMatch>, Similarity) {
        let value_text = value.as_str();
        if value_text.is_empty() {
            return (None, Similarity::default());
        }
        if query.as_str().is_empty() {
            return (
                Some(ValueMatch {
                    kind: MatchKind::Prefix,
                    similarity: Similarity::default(),
                }),
                Similarity::default(),
            );
        }

        let similarity = text_similarity(query, value);
        let kind = if value_text == query.as_str() {
            MatchKind::Exact
        } else if value_text.starts_with(query.as_str()) {
            MatchKind::Prefix
        } else if value_text.contains(query.as_str()) {
            MatchKind::Substring
        } else if gate.accepts(similarity, self.threshold) {
            MatchKind::Fuzzy
        } else {
            return (None, similarity);
        };

        (Some(ValueMatch { kind, similarity }), similarity)
    }

    fn match_identifier(
        &self,
        query: &NormalizedText,
        value: &NormalizedText,
    ) -> Option<ValueMatch> {
        let value_text = value.as_str();
        if value_text.is_empty() {
            return None;
        }
        if query.as_str().is_empty() {
            return Some(ValueMatch {
                kind: MatchKind::Prefix,
                similarity: Similarity::default(),
            });
        }

        let kind = if value_text == query.as_str() {
            MatchKind::Exact
        } else if value_text.starts_with(query.as_str()) {
            MatchKind::Prefix
        } else if value_text.contains(query.as_str()) {
            MatchKind::Substring
        } else {
            return None;
        };

        // Identifier similarity is not used by tiers or name/brand tie-breaking.
        Some(ValueMatch {
            kind,
            similarity: Similarity::default(),
        })
    }
}

impl Default for TextMatcher {
    fn default() -> Self {
        Self::new(FuzzyThreshold::default())
    }
}

fn text_similarity(query: &NormalizedText, candidate: &NormalizedText) -> Similarity {
    Similarity::new(f64::from(rust_fuzzy_search::fuzzy_compare(
        query.as_str(),
        candidate.as_str(),
    )))
}

fn match_kind_priority(kind: MatchKind) -> u8 {
    match kind {
        MatchKind::Exact => 0,
        MatchKind::Prefix => 1,
        MatchKind::Substring => 2,
        MatchKind::Fuzzy => 3,
    }
}

fn best_value_match(current: Option<ValueMatch>, candidate: ValueMatch) -> Option<ValueMatch> {
    let Some(current) = current else {
        return Some(candidate);
    };
    let candidate_priority = match_kind_priority(candidate.kind);
    let current_priority = match_kind_priority(current.kind);
    if candidate_priority < current_priority
        || (candidate_priority == current_priority
            && candidate.similarity.total_cmp(&current.similarity) == Ordering::Greater)
    {
        Some(candidate)
    } else {
        Some(current)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProductSearchFields {
    id: ProductId,
    name: ProductName,
    brand: Option<Brand>,
    barcode: Option<Barcode>,
}

impl ProductSearchFields {
    pub fn new(
        id: ProductId,
        name: ProductName,
        brand: Option<String>,
        barcode: Option<String>,
    ) -> Self {
        Self {
            id,
            name,
            brand: brand
                .map(|value| value.trim().to_owned())
                .filter(|value| !value.is_empty())
                .map(Brand),
            barcode: barcode
                .map(|value| value.trim().to_owned())
                .filter(|value| !value.is_empty())
                .map(Barcode),
        }
    }

    pub fn id(&self) -> ProductId {
        self.id
    }

    pub fn name(&self) -> &ProductName {
        &self.name
    }

    pub fn brand(&self) -> Option<&Brand> {
        self.brand.as_ref()
    }

    pub fn barcode(&self) -> Option<&Barcode> {
        self.barcode.as_ref()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SearchRecency {
    last_log_date: NaiveDate,
    last_logged_at: DateTime<Utc>,
}

impl SearchRecency {
    pub fn new(last_log_date: NaiveDate, last_logged_at: DateTime<Utc>) -> Self {
        Self {
            last_log_date,
            last_logged_at,
        }
    }

    pub fn last_log_date(&self) -> NaiveDate {
        self.last_log_date
    }

    pub fn last_logged_at(&self) -> DateTime<Utc> {
        self.last_logged_at
    }
}

#[derive(Debug, Clone)]
pub struct HistorySearchCandidate {
    fields: ProductSearchFields,
    categories: Vec<Category>,
    recency: SearchRecency,
}

impl HistorySearchCandidate {
    pub fn new(
        fields: ProductSearchFields,
        categories: Vec<Category>,
        recency: SearchRecency,
    ) -> Self {
        Self {
            fields,
            categories: categories
                .into_iter()
                .filter(|category| !category.0.trim().is_empty())
                .collect(),
            recency,
        }
    }

    pub fn fields(&self) -> &ProductSearchFields {
        &self.fields
    }

    pub fn categories(&self) -> &[Category] {
        &self.categories
    }

    pub fn recency(&self) -> SearchRecency {
        self.recency
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CategoryCount {
    value: Category,
    count: i64,
}

impl CategoryCount {
    pub fn new(value: Category, count: i64) -> Option<Self> {
        (count >= 0 && !value.0.trim().is_empty()).then_some(Self { value, count })
    }

    pub fn value(&self) -> &Category {
        &self.value
    }

    pub fn count(&self) -> i64 {
        self.count
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum ProductTier {
    BarcodeExact,
    BarcodePrefix,
    NamePrefix,
    NameSubstring,
    BrandPrefix,
    BrandSubstring,
    Fuzzy,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum CategoryTier {
    Prefix,
    Substring,
    Fuzzy,
}

struct RankedProduct {
    id: ProductId,
    tier: ProductTier,
    similarity: Similarity,
    normalized_name: NormalizedText,
}

struct RankedHistoryProduct {
    id: ProductId,
    recency: SearchRecency,
    tier: ProductTier,
    similarity: Similarity,
    normalized_name: NormalizedText,
}

struct RankedCategory {
    value: String,
    count: i64,
    tier: CategoryTier,
    similarity: Similarity,
    normalized_value: NormalizedText,
}

pub fn rank_catalog_candidates(
    query: &str,
    candidates: Vec<ProductSearchFields>,
    limit: usize,
) -> Vec<ProductId> {
    let matcher = TextMatcher::default();
    let query = matcher.normalize(query);
    rank_catalog_with(&matcher, &query, candidates, limit)
}

fn rank_catalog_with(
    matcher: &TextMatcher,
    query: &NormalizedText,
    candidates: Vec<ProductSearchFields>,
    limit: usize,
) -> Vec<ProductId> {
    let mut ranked = Vec::with_capacity(candidates.len());

    for fields in candidates {
        let name = matcher.normalize(fields.name().as_str());
        let brand = matcher.normalize_optional(fields.brand().map(|brand| brand.0.as_str()));
        let identifier =
            matcher.normalize_optional(fields.barcode().map(|barcode| barcode.0.as_str()));
        let matches = matcher.match_fields(query, &name, brand.as_ref(), identifier.as_ref());
        let Some(tier) = product_tier(&matches) else {
            continue;
        };

        ranked.push(RankedProduct {
            id: fields.id(),
            tier,
            similarity: matches.name_brand_similarity(),
            normalized_name: name,
        });
    }

    ranked.sort_by(|a, b| {
        a.tier
            .cmp(&b.tier)
            .then_with(|| b.similarity.total_cmp(&a.similarity))
            .then_with(|| a.normalized_name.cmp(&b.normalized_name))
            .then_with(|| a.id.0.cmp(&b.id.0))
    });

    ranked
        .into_iter()
        .take(limit)
        .map(|candidate| candidate.id)
        .collect()
}

pub fn rank_history_candidates(
    query: &str,
    candidates: Vec<HistorySearchCandidate>,
    limit: usize,
) -> Vec<ProductId> {
    let matcher = TextMatcher::default();
    let query = matcher.normalize(query);
    rank_history_with(&matcher, &query, candidates, limit)
}

fn rank_history_with(
    matcher: &TextMatcher,
    query: &NormalizedText,
    candidates: Vec<HistorySearchCandidate>,
    limit: usize,
) -> Vec<ProductId> {
    let mut ranked = Vec::with_capacity(candidates.len());

    for candidate in candidates {
        let name = matcher.normalize(candidate.fields().name().as_str());
        let brand =
            matcher.normalize_optional(candidate.fields().brand().map(|brand| brand.0.as_str()));
        let identifier = matcher.normalize_optional(
            candidate
                .fields()
                .barcode()
                .map(|barcode| barcode.0.as_str()),
        );
        let mut matches = matcher.match_fields(query, &name, brand.as_ref(), identifier.as_ref());
        if !matches.is_match() {
            let terms = candidate
                .categories()
                .iter()
                .map(|term| matcher.normalize(term.0.as_str()))
                .collect::<Vec<_>>();
            matches.term = matcher.match_terms(query, &terms);
        }
        let Some(tier) = product_tier(&matches) else {
            continue;
        };

        ranked.push(RankedHistoryProduct {
            id: candidate.fields().id(),
            recency: candidate.recency(),
            tier,
            similarity: matches.name_brand_similarity(),
            normalized_name: name,
        });
    }

    ranked.sort_by(|a, b| {
        b.recency
            .last_log_date()
            .cmp(&a.recency.last_log_date())
            .then_with(|| b.recency.last_logged_at().cmp(&a.recency.last_logged_at()))
            .then_with(|| a.tier.cmp(&b.tier))
            .then_with(|| b.similarity.total_cmp(&a.similarity))
            .then_with(|| a.normalized_name.cmp(&b.normalized_name))
            .then_with(|| a.id.0.cmp(&b.id.0))
    });

    ranked
        .into_iter()
        .take(limit)
        .map(|candidate| candidate.id)
        .collect()
}

pub fn rank_category_suggestions(
    query: &str,
    counts: Vec<CategoryCount>,
    limit: usize,
) -> Vec<CategorySuggestion> {
    let matcher = TextMatcher::default();
    rank_category_suggestions_with(&matcher, query, counts, limit)
}

fn rank_category_suggestions_with(
    matcher: &TextMatcher,
    query: &str,
    counts: Vec<CategoryCount>,
    limit: usize,
) -> Vec<CategorySuggestion> {
    let query = matcher.normalize(query);
    let mut ranked = Vec::with_capacity(counts.len());

    for count in counts {
        let normalized = matcher.normalize(count.value().0.as_str());
        let Some(value_match) =
            matcher.match_value_normalized(&query, &normalized, ThresholdGate::Exclusive)
        else {
            continue;
        };

        ranked.push(RankedCategory {
            value: count.value().0.clone(),
            count: count.count(),
            tier: category_tier(value_match.kind),
            similarity: value_match.similarity,
            normalized_value: normalized,
        });
    }

    ranked.sort_by(|a, b| {
        a.tier
            .cmp(&b.tier)
            .then_with(|| b.count.cmp(&a.count))
            .then_with(|| b.similarity.total_cmp(&a.similarity))
            .then_with(|| a.normalized_value.cmp(&b.normalized_value))
            .then_with(|| a.value.cmp(&b.value))
    });

    ranked
        .into_iter()
        .take(limit)
        .map(|category| CategorySuggestion {
            value: category.value,
            count: category.count,
        })
        .collect()
}

fn product_tier(matches: &DocumentMatches) -> Option<ProductTier> {
    if let Some(identifier) = matches.identifier {
        match identifier.kind {
            MatchKind::Exact => return Some(ProductTier::BarcodeExact),
            MatchKind::Prefix => return Some(ProductTier::BarcodePrefix),
            MatchKind::Substring | MatchKind::Fuzzy => {}
        }
    }

    if let Some(name) = matches.name {
        match name.kind {
            MatchKind::Exact | MatchKind::Prefix => return Some(ProductTier::NamePrefix),
            MatchKind::Substring => return Some(ProductTier::NameSubstring),
            MatchKind::Fuzzy => {}
        }
    }

    if let Some(brand) = matches.brand {
        match brand.kind {
            MatchKind::Exact | MatchKind::Prefix => return Some(ProductTier::BrandPrefix),
            MatchKind::Substring => return Some(ProductTier::BrandSubstring),
            MatchKind::Fuzzy => {}
        }
    }

    matches.is_match().then_some(ProductTier::Fuzzy)
}

fn category_tier(kind: MatchKind) -> CategoryTier {
    match kind {
        MatchKind::Exact | MatchKind::Prefix => CategoryTier::Prefix,
        MatchKind::Substring => CategoryTier::Substring,
        MatchKind::Fuzzy => CategoryTier::Fuzzy,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rstest::rstest;
    use uuid::Uuid;

    fn matcher(threshold: f64) -> TextMatcher {
        TextMatcher::new(FuzzyThreshold::new(threshold).expect("valid fuzzy threshold"))
    }

    fn assert_similarity_eq(actual: f64, expected: f64) {
        const TOLERANCE: f64 = 1e-4;
        assert!(
            (actual - expected).abs() < TOLERANCE,
            "expected similarity {expected}, got {actual}"
        );
    }

    fn fields(
        id: u128,
        name: &str,
        brand: Option<&str>,
        barcode: Option<&str>,
    ) -> ProductSearchFields {
        ProductSearchFields::new(
            product_id(id),
            ProductName::new(name).unwrap(),
            brand.map(str::to_owned),
            barcode.map(str::to_owned),
        )
    }

    fn recency(date: (i32, u32, u32), hour: u32) -> SearchRecency {
        let date = NaiveDate::from_ymd_opt(date.0, date.1, date.2).unwrap();
        let last_logged_at = date.and_hms_opt(hour, 0, 0).unwrap().and_utc();
        SearchRecency::new(date, last_logged_at)
    }

    fn history(
        id: u128,
        name: &str,
        brand: Option<&str>,
        barcode: Option<&str>,
        categories: &[&str],
        date: (i32, u32, u32),
        hour: u32,
    ) -> HistorySearchCandidate {
        HistorySearchCandidate::new(
            fields(id, name, brand, barcode),
            categories
                .iter()
                .map(|value| Category::new(value).unwrap())
                .collect(),
            recency(date, hour),
        )
    }

    fn category_count(value: &str, count: i64) -> CategoryCount {
        CategoryCount::new(Category::new(value).unwrap(), count).unwrap()
    }

    fn rank_catalog(
        query: &str,
        candidates: Vec<ProductSearchFields>,
        limit: usize,
    ) -> Vec<ProductId> {
        rank_catalog_candidates(query, candidates, limit)
    }

    fn product_id(value: u128) -> ProductId {
        ProductId(Uuid::from_u128(value))
    }

    #[test]
    fn normalize_trims_lowercases_and_collapses_whitespace() {
        let matcher = TextMatcher::default();

        assert_eq!(
            matcher.normalize("  Greek \t  Yogurt\n").as_str(),
            "greek yogurt"
        );
    }

    #[rstest]
    #[case::exact("greek yogurt", "  Greek   Yogurt ", Some(MatchKind::Exact))]
    #[case::prefix("greek", "Greek Yogurt", Some(MatchKind::Prefix))]
    #[case::substring("yog", "Greek Yogurt", Some(MatchKind::Substring))]
    #[case::fuzzy("yogrt", "yogurt", Some(MatchKind::Fuzzy))]
    #[case::rejected("zzzz", "Greek Yogurt", None)]
    fn match_value_classifies_exact_prefix_substring_fuzzy_and_rejected(
        #[case] query: &str,
        #[case] value: &str,
        #[case] expected_kind: Option<MatchKind>,
    ) {
        let matcher = TextMatcher::default();

        let matched = matcher.match_value(&matcher.normalize(query), value);

        assert_eq!(matched.map(|matched| matched.kind), expected_kind);
    }

    #[test]
    fn fuzzy_threshold_is_enforced() {
        let strict = matcher(0.99);
        assert_eq!(
            strict.match_value(&strict.normalize("yogrt"), "yogurt"),
            None
        );

        let exact = matcher(1.0);
        assert_eq!(
            exact
                .match_value(&exact.normalize("yogurt"), "Yogurt")
                .unwrap()
                .kind,
            MatchKind::Exact
        );
    }

    #[rstest]
    #[case::nan(f64::NAN)]
    #[case::just_below_zero(-0.1)]
    #[case::just_above_one(1.1)]
    #[case::positive_infinity(f64::INFINITY)]
    #[case::negative_infinity(f64::NEG_INFINITY)]
    fn fuzzy_threshold_rejects_invalid_values(#[case] value: f64) {
        assert!(
            FuzzyThreshold::new(value).is_none(),
            "expected {value} to be rejected"
        );
    }

    #[rstest]
    #[case::lower_boundary(Some(0.0), 0.0)]
    #[case::upper_boundary(Some(1.0), 1.0)]
    #[case::default(None, DEFAULT_FUZZY_THRESHOLD)]
    fn fuzzy_threshold_accepts_valid_boundaries_and_default(
        #[case] value: Option<f64>,
        #[case] expected: f64,
    ) {
        let threshold = match value {
            Some(value) => FuzzyThreshold::new(value).expect("boundary must be valid"),
            // `None` exercises the `Default` impl rather than `new`.
            None => FuzzyThreshold::default(),
        };

        assert_eq!(threshold.value(), expected);
    }

    #[test]
    fn fuzzy_similarity_uses_query_first_trigram_containment() {
        let matcher = TextMatcher::default();
        let query = matcher.normalize("chese");
        let candidate = matcher.normalize("Cheese Cube");

        // `milk almond` / `Almond Milk` happens to be symmetric in this crate,
        // so use a pair whose containment differs to pin query-first behavior.
        let forward = text_similarity(&query, &candidate);
        let reverse = text_similarity(&candidate, &query);
        assert_similarity_eq(forward.value(), 0.8333);
        assert_similarity_eq(reverse.value(), 0.4167);
        assert!(forward.value() > reverse.value());

        let matched = matcher
            .match_value(&query, "Cheese Cube")
            .expect("chese should fuzzy-match Cheese Cube");
        assert_eq!(matched.kind, MatchKind::Fuzzy);
        assert_similarity_eq(matched.similarity.value(), forward.value());
    }

    #[rstest]
    #[case::chese_cheese_cube("chese", "Cheese Cube", 0.8333)]
    #[case::chese_chase("chese", "Chase", 0.5)]
    #[case::milk_almond_almond_milk("milk almond", "Almond Milk", 0.8333)]
    #[case::yoghurt_greek_yogurt("yoghurt", "Greek Yogurt", 0.5)]
    #[case::chiken_chicken_breast("chiken", "Chicken Breast", 0.7143)]
    #[case::chiken_grilled_chicken_breast("chiken", "Grilled Chicken Breast", 0.5714)]
    #[case::vegtable_other_vegetables("vegtable", "other-vegetables", 0.4444)]
    #[case::cheese_chess("cheese", "chess", 0.4286)]
    #[case::coke_cookies("coke", "Cookies", 0.4)]
    #[case::rice_rce("rice", "rce", 0.4)]
    #[case::almnd_salmon("almnd", "Salmon", 0.1667)]
    #[case::granila_rani("granila", "Rani", 0.25)]
    #[case::vegtable_feta("vegtable", "feta", 0.0)]
    #[case::dairy_cadbury("dairy", "Cadbury", 0.1667)]
    #[case::chedar_mature_cheddar("chedar", "Mature Cheddar", 0.7143)]
    #[case::strawbery_ice_creams_strawberry("strawbery", "Ice Creams, Strawberry", 0.8)]
    #[case::choclate_almond_chocolate("choclate", "Almond Chocolate", 0.6667)]
    #[case::brocolli_broccoli_raw("brocolli", "Broccoli, raw", 0.5556)]
    #[case::avacado_avocado("avacado", "Avocado", 0.625)]
    #[case::vegtable_vegetables("vegtable", "vegetables", 0.6667)]
    // Orientation matters: `dairy` -> `dary` is exactly 0.5, while the
    // reverse (`dary` -> `Dairy`) is 0.6.
    #[case::dairy_dary("dairy", "dary", 0.5)]
    #[case::dary_dairy("dary", "Dairy", 0.6)]
    #[case::abc124_abc123("abc124", "abc123", 0.7143)]
    fn rust_fuzzy_search_scores_match_documented_goldens(
        #[case] query: &str,
        #[case] candidate: &str,
        #[case] expected: f64,
    ) {
        let matcher = TextMatcher::default();
        let actual = text_similarity(&matcher.normalize(query), &matcher.normalize(candidate));
        assert_similarity_eq(actual.value(), expected);
    }

    #[test]
    fn rejected_near_miss_can_be_recovered_by_lower_threshold() {
        let default_matcher = TextMatcher::default();
        let query = default_matcher.normalize("vegtable");
        assert_eq!(
            default_matcher.match_value(&query, "other-vegetables"),
            None
        );

        let lowered = matcher(0.44);
        let matched = lowered
            .match_value(&query, "other-vegetables")
            .expect("lowered threshold should accept the old match");
        assert_eq!(matched.kind, MatchKind::Fuzzy);
        assert_similarity_eq(matched.similarity.value(), 0.4444);
        assert!(matched.similarity.value() < DEFAULT_FUZZY_THRESHOLD);
    }

    #[test]
    fn fuzzy_ranking_prefers_cheese_cube_over_brand_chase() {
        let candidates = vec![
            fields(1, "Plain base", Some("Chase"), None),
            fields(2, "Cheese Cube", None, None),
        ];

        assert_eq!(
            rank_catalog("chese", candidates, 10),
            vec![product_id(2), product_id(1)]
        );
    }

    #[rstest]
    #[case::rice_does_not_match_beans("rice", "beans")]
    #[case::coke_does_not_match_milk("coke", "milk")]
    fn short_unrelated_queries_do_not_match(#[case] query: &str, #[case] candidate_name: &str) {
        assert!(rank_catalog(query, vec![fields(1, candidate_name, None, None)], 10).is_empty());
    }

    #[test]
    fn category_suggestions_match_known_typos() {
        let counts = vec![category_count("vegetables", 1)];

        assert_eq!(
            rank_category_suggestions("vegtable", counts, 10),
            vec![CategorySuggestion {
                value: "vegetables".into(),
                count: 1,
            }]
        );
    }

    #[test]
    fn category_suggestions_admit_trigram_near_miss_but_reject_old_match() {
        let matcher = TextMatcher::default();
        let query = matcher.normalize("vegtable");

        assert_similarity_eq(
            text_similarity(&query, &matcher.normalize("vegetables")).value(),
            0.6667,
        );
        assert_similarity_eq(
            text_similarity(&query, &matcher.normalize("other-vegetables")).value(),
            0.4444,
        );
        assert_similarity_eq(
            text_similarity(&query, &matcher.normalize("feta")).value(),
            0.0,
        );

        let ranked = rank_category_suggestions(
            "vegtable",
            vec![
                category_count("vegetables", 1),
                category_count("other-vegetables", 1),
                category_count("feta", 1),
            ],
            10,
        );

        assert_eq!(
            ranked,
            vec![CategorySuggestion {
                value: "vegetables".into(),
                count: 1,
            }],
            "the trigram near-miss passes; the old match and unrelated category are rejected"
        );
    }

    #[test]
    fn inclusive_and_exclusive_threshold_gates_use_trigram_containment() {
        let default_matcher = TextMatcher::default();

        let product_match = default_matcher
            .match_value(&default_matcher.normalize("chese"), "Chase")
            .expect("product fuzzy gate is inclusive at exactly 0.5");
        assert_eq!(product_match.kind, MatchKind::Fuzzy);
        assert_similarity_eq(product_match.similarity.value(), 0.5);

        let counts = vec![category_count("chase", 1)];
        assert!(
            rank_category_suggestions_with(&default_matcher, "chese", counts.clone(), 10)
                .is_empty(),
            "category fuzzy gate is exclusive at exactly 0.5"
        );

        let below = matcher(DEFAULT_FUZZY_THRESHOLD - 0.000_001);
        assert_eq!(
            rank_category_suggestions_with(&below, "chese", counts, 10),
            vec![CategorySuggestion {
                value: "chase".into(),
                count: 1,
            }]
        );

        let yoghurt_match = default_matcher
            .match_value(&default_matcher.normalize("yoghurt"), "Greek Yogurt")
            .expect("product fuzzy gate accepts the 0.5 word-order match");
        assert_eq!(yoghurt_match.kind, MatchKind::Fuzzy);
        assert_similarity_eq(yoghurt_match.similarity.value(), 0.5);

        assert!(
            rank_category_suggestions_with(
                &default_matcher,
                "yoghurt",
                vec![category_count("greek yogurt", 1)],
                10,
            )
            .is_empty(),
            "category gate rejects the 0.5 word-order match"
        );
    }

    #[test]
    fn wildcard_characters_are_literal() {
        let matcher = TextMatcher::default();
        let percent = matcher
            .match_value(&matcher.normalize("%"), "100% Juice")
            .expect("literal '%' should match by substring");
        assert_eq!(percent.kind, MatchKind::Substring);
        assert_similarity_eq(percent.similarity.value(), 0.0);

        let candidates = vec![
            fields(1, "Zebra", None, None),
            fields(2, "100% Juice", None, None),
        ];

        assert_eq!(rank_catalog("%", candidates, 10), vec![product_id(2)]);
        assert!(rank_catalog("_", vec![fields(1, "Zebra", None, None)], 10).is_empty());
    }

    #[test]
    fn product_search_fields_new_filters_blank_optional_fields() {
        let blank = ProductSearchFields::new(
            product_id(1),
            ProductName::new("Food").unwrap(),
            Some("  ".into()),
            Some("".into()),
        );
        assert_eq!(blank.brand(), None);
        assert_eq!(blank.barcode(), None);

        let trimmed = ProductSearchFields::new(
            product_id(2),
            ProductName::new("Food").unwrap(),
            Some(" Acme ".into()),
            Some(" 12345 ".into()),
        );
        assert_eq!(trimmed.brand().unwrap().0, "Acme");
        assert_eq!(trimmed.barcode().unwrap().0, "12345");
    }

    #[test]
    fn history_search_candidate_new_filters_blank_categories() {
        let candidate = HistorySearchCandidate::new(
            fields(1, "Food", None, None),
            vec![
                Category("".into()),
                Category("   ".into()),
                Category("dairy".into()),
            ],
            recency((2026, 1, 1), 12),
        );

        assert_eq!(candidate.categories(), &[Category("dairy".into())]);
    }

    #[test]
    fn category_count_new_rejects_invalid_values() {
        assert!(CategoryCount::new(Category::new("dairy").unwrap(), -1).is_none());
        assert!(CategoryCount::new(Category("   ".into()), 1).is_none());
        assert_eq!(
            CategoryCount::new(Category::new("dairy").unwrap(), 0)
                .unwrap()
                .count(),
            0
        );
    }

    #[test]
    fn empty_query_returns_zero_similarity_prefix_for_non_empty_values() {
        let matcher = TextMatcher::default();
        let query = matcher.normalize(" \t ");

        let matched = matcher.match_value(&query, "Greek Yogurt").unwrap();
        assert_eq!(matched.kind, MatchKind::Prefix);
        assert_eq!(matched.similarity.value(), 0.0);
        assert_eq!(matcher.match_value(&query, "  "), None);
    }

    #[test]
    fn match_document_reports_each_matching_field() {
        let matcher = TextMatcher::default();
        let query = matcher.normalize("yogurt");
        let document = SearchDocument {
            name: "Yogurt",
            brand: Some("Yogurt Lab"),
            identifier: Some("12345"),
            terms: &[],
        };

        let matches = matcher.match_document(&query, &document);

        assert_eq!(matches.identifier, None);
        assert_eq!(matches.name.unwrap().kind, MatchKind::Exact);
        assert_eq!(matches.brand.unwrap().kind, MatchKind::Prefix);
        assert_eq!(matches.term, None);
        assert_eq!(matches.name_similarity.value(), 1.0);
        assert!(matches.brand_similarity.value() > 0.0);
    }

    #[test]
    fn identifier_matching_never_uses_fuzzy_similarity() {
        let matcher = TextMatcher::default();
        let query = matcher.normalize("abc124");

        assert_eq!(
            matcher.match_value(&query, "abc123").unwrap().kind,
            MatchKind::Fuzzy
        );

        let document = SearchDocument {
            name: "zzzzzz",
            brand: None,
            identifier: Some("abc123"),
            terms: &[],
        };
        let matches = matcher.match_document(&query, &document);

        assert_eq!(matches.identifier, None);
        assert!(!matches.is_match());
    }

    #[rstest]
    #[case::exact("abc123", MatchKind::Exact)]
    #[case::prefix("abc", MatchKind::Prefix)]
    #[case::substring("bc1", MatchKind::Substring)]
    fn identifier_matches_have_zero_similarity(
        #[case] query: &str,
        #[case] expected_kind: MatchKind,
    ) {
        let matcher = TextMatcher::default();
        let query = matcher.normalize(query);
        let document = SearchDocument {
            name: "Plain base",
            brand: None,
            identifier: Some("abc123"),
            terms: &[],
        };

        let matches = matcher.match_document(&query, &document);
        let identifier = matches.identifier.expect("identifier should match");
        assert_eq!(identifier.kind, expected_kind);
        assert_eq!(identifier.similarity.value(), 0.0);
    }

    #[test]
    fn term_only_matches_are_found_and_rank_as_fuzzy() {
        let matcher = TextMatcher::default();
        let query = matcher.normalize("dairy");
        let terms = [Category::new("dairy").unwrap()];
        let document = SearchDocument {
            name: "Plain base",
            brand: None,
            identifier: None,
            terms: &terms,
        };

        let matches = matcher.match_document(&query, &document);

        assert_eq!(matches.term.unwrap().kind, MatchKind::Exact);
        assert!(matches.is_match());
        assert_eq!(product_tier(&matches), Some(ProductTier::Fuzzy));
    }

    #[test]
    fn document_keeps_similarity_scores_when_threshold_rejects_matches() {
        let matcher = matcher(0.99);
        let query = matcher.normalize("yogrt");
        let terms = [Category::new("yogrt").unwrap()];
        let document = SearchDocument {
            name: "yogurt",
            brand: Some("yogurt lab"),
            identifier: None,
            terms: &terms,
        };

        let matches = matcher.match_document(&query, &document);

        assert_eq!(matches.name, None);
        assert_eq!(matches.brand, None);
        assert_eq!(matches.term.unwrap().kind, MatchKind::Exact);
        assert_similarity_eq(matches.name_similarity.value(), 0.6667);
        assert!(matches.brand_similarity.value() > 0.6);
    }

    #[test]
    fn exact_name_and_brand_map_to_prefix_tiers() {
        let matcher = TextMatcher::default();
        let query = matcher.normalize("yogurt");

        let name_document = SearchDocument {
            name: "Yogurt",
            brand: None,
            identifier: None,
            terms: &[],
        };
        assert_eq!(
            product_tier(&matcher.match_document(&query, &name_document)),
            Some(ProductTier::NamePrefix)
        );

        let brand_document = SearchDocument {
            name: "Plain base",
            brand: Some("Yogurt"),
            identifier: None,
            terms: &[],
        };
        assert_eq!(
            product_tier(&matcher.match_document(&query, &brand_document)),
            Some(ProductTier::BrandPrefix)
        );
    }

    #[test]
    fn product_tiers_are_ordered_from_barcode_exact_to_fuzzy() {
        let candidates = vec![
            fields(1, "A", None, Some("yogurt")),
            fields(2, "B", None, Some("yogurt-123")),
            fields(3, "Yogurt cup", None, None),
            fields(4, "Greek yogurt", None, None),
            fields(5, "C", Some("Yogurt Co"), None),
            fields(6, "D", Some("The Yogurt Shop"), None),
            fields(7, "Yogrt", None, None),
        ];

        let ranked = rank_catalog("yogurt", candidates, 10);

        assert_eq!(ranked, (1..=7).map(product_id).collect::<Vec<ProductId>>());
    }

    #[test]
    fn ties_break_by_similarity_then_normalized_name_then_id() {
        let exact = fields(10, "Oat", None, None);
        let prefix = fields(11, "Oatmeal", None, None);
        let exact_id = exact.id();
        let prefix_id = prefix.id();
        assert_eq!(
            rank_catalog("oat", vec![prefix, exact], 10),
            vec![exact_id, prefix_id]
        );

        let brand_exact = fields(20, "Product", Some("Acme"), None);
        let brand_prefix = fields(21, "Product", Some("Acme Foods"), None);
        let brand_exact_id = brand_exact.id();
        let brand_prefix_id = brand_prefix.id();
        assert_eq!(
            rank_catalog("acme", vec![brand_prefix, brand_exact], 10),
            vec![brand_exact_id, brand_prefix_id]
        );

        let zebra = fields(30, "Zebra", None, None);
        let apple = fields(31, "apple", None, None);
        let zebra_id = zebra.id();
        let apple_id = apple.id();
        assert_eq!(
            rank_catalog("", vec![zebra, apple], 10),
            vec![apple_id, zebra_id]
        );

        let high_id = fields(99, "Same", None, None);
        let low_id = fields(42, "Same", None, None);
        let high_id_value = high_id.id();
        let low_id_value = low_id.id();
        assert_eq!(
            rank_catalog("same", vec![high_id, low_id], 10),
            vec![low_id_value, high_id_value]
        );
    }

    #[test]
    fn empty_catalog_query_puts_barcoded_products_first() {
        let plain = fields(1, "Apple", None, None);
        let barcoded = fields(2, "Zebra", None, Some("12345"));
        let plain_id = plain.id();
        let barcoded_id = barcoded.id();

        assert_eq!(
            rank_catalog("   ", vec![plain, barcoded], 10),
            vec![barcoded_id, plain_id]
        );
    }

    #[test]
    fn history_recency_outranks_relevance() {
        let older_exact = history(1, "Zzz", None, Some("yogurt"), &[], (2026, 1, 1), 12);
        let newer_name_match = history(2, "Yogurt snack", None, None, &[], (2026, 1, 2), 12);
        assert_eq!(
            rank_history_candidates("yogurt", vec![older_exact, newer_name_match], 10),
            vec![product_id(2), product_id(1)]
        );

        let same_day_early = history(3, "Yogurt", None, None, &[], (2026, 1, 3), 8);
        let same_day_late = history(4, "Yogurt", None, None, &[], (2026, 1, 3), 20);
        assert_eq!(
            rank_history_candidates("yogurt", vec![same_day_early, same_day_late], 10),
            vec![product_id(4), product_id(3)]
        );
    }

    #[test]
    fn empty_history_query_orders_by_recency() {
        let older = history(1, "Zebra", None, None, &[], (2026, 1, 1), 12);
        let newer = history(2, "Apple", None, None, &[], (2026, 1, 2), 12);
        let same_day_early = history(3, "Mango", None, None, &[], (2026, 1, 3), 8);
        let same_day_late = history(4, "Banana", None, None, &[], (2026, 1, 3), 20);

        assert_eq!(
            rank_history_candidates("   ", vec![older, newer, same_day_early, same_day_late], 10),
            vec![product_id(4), product_id(3), product_id(2), product_id(1)]
        );
    }

    #[test]
    fn history_category_only_match_is_returned() {
        let candidate = history(1, "Plain base", None, None, &["dairy"], (2026, 1, 1), 12);

        let ranked = rank_history_candidates("dairy", vec![candidate], 10);

        assert_eq!(ranked, vec![product_id(1)]);
    }

    #[test]
    fn history_category_term_match_uses_query_first_asymmetry() {
        // Forward is `chese` -> `cheese cube` (~0.8333); reversed it would be
        // ~0.4167 and fail the fuzzy gate.
        let candidate = history(
            1,
            "Plain base",
            None,
            None,
            &["Cheese Cube"],
            (2026, 1, 1),
            12,
        );

        let ranked = rank_history_candidates("chese", vec![candidate], 10);

        assert_eq!(ranked, vec![product_id(1)]);
    }

    #[test]
    fn category_ordering_is_prefix_then_substring_then_fuzzy_with_tie_breaks() {
        let counts = vec![
            category_count("dairy bar", 5),
            category_count("dairy baz", 5),
            category_count("dairy", 2),
            category_count("dairy free", 1),
            category_count("non dairy", 100),
            category_count("daiiry", 50),
            category_count("dairi", 50),
            category_count("dary", 50),
        ];

        let ranked = rank_category_suggestions("dairy", counts, 10);

        // `dary` scores exactly 0.5, so the exclusive category gate rejects it.
        // The remaining fuzzy tier is ordered by `daiiry` (0.8333) then
        // `dairi` (0.6667).
        assert_eq!(
            ranked,
            vec![
                CategorySuggestion {
                    value: "dairy bar".into(),
                    count: 5,
                },
                CategorySuggestion {
                    value: "dairy baz".into(),
                    count: 5,
                },
                CategorySuggestion {
                    value: "dairy".into(),
                    count: 2,
                },
                CategorySuggestion {
                    value: "dairy free".into(),
                    count: 1,
                },
                CategorySuggestion {
                    value: "non dairy".into(),
                    count: 100,
                },
                CategorySuggestion {
                    value: "daiiry".into(),
                    count: 50,
                },
                CategorySuggestion {
                    value: "dairi".into(),
                    count: 50,
                },
            ]
        );
    }

    #[test]
    fn empty_category_query_orders_by_count_then_name() {
        let counts = vec![
            category_count("snacks", 2),
            category_count("zebras", 5),
            category_count("apples", 5),
        ];

        let ranked = rank_category_suggestions("", counts, 10);

        assert_eq!(
            ranked,
            vec![
                CategorySuggestion {
                    value: "apples".into(),
                    count: 5,
                },
                CategorySuggestion {
                    value: "zebras".into(),
                    count: 5,
                },
                CategorySuggestion {
                    value: "snacks".into(),
                    count: 2,
                },
            ]
        );
    }

    #[test]
    #[ignore = "manual performance check for the ~13k product catalog"]
    fn benchmark_rank_catalog_13k_candidates() {
        let candidates = (0..13_057)
            .map(|index| fields(index, &format!("Catalog product {index}"), None, None))
            .collect();

        let started = std::time::Instant::now();
        let ranked =
            rank_catalog_candidates("catalog product 9000", candidates, PRODUCT_SEARCH_LIMIT);
        let elapsed = started.elapsed();

        eprintln!("ranked 13,057 catalog candidates in {elapsed:?}");
        assert_eq!(ranked.len(), PRODUCT_SEARCH_LIMIT);
    }

    #[test]
    fn limit_is_applied_after_ranking() {
        let candidates = vec![
            fields(1, "Yogurt", None, None),
            fields(2, "Yogurt cup", None, None),
            fields(3, "Greek yogurt", None, None),
        ];
        assert_eq!(
            rank_catalog("yogurt", candidates, 2),
            vec![product_id(1), product_id(2)]
        );

        let counts = vec![
            category_count("dairy bar", 5),
            category_count("dairy", 2),
            category_count("non dairy", 100),
        ];
        assert_eq!(
            rank_category_suggestions("dairy", counts, 2),
            vec![
                CategorySuggestion {
                    value: "dairy bar".into(),
                    count: 5,
                },
                CategorySuggestion {
                    value: "dairy".into(),
                    count: 2,
                },
            ]
        );
    }
}
