use std::cmp::Ordering;

use chrono::{DateTime, NaiveDate, Utc};

use super::{Barcode, Brand, Category, CategorySuggestion, ProductId, ProductName};

pub const DEFAULT_FUZZY_THRESHOLD: f64 = 0.30;
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

/// Fuzzy gates differ by call site: product matches use `>=` like pg_trgm,
/// while category suggestions preserve the old `similarity(...) > 0.30`.
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

type Trigram = [char; 3];

/// Text normalized and trigram-expanded once per candidate instead of once per
/// comparison.
#[derive(Debug, Clone, PartialEq, Eq)]
struct PreparedText {
    normalized: NormalizedText,
    trigrams: Vec<Trigram>,
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

    fn prepare(&self, text: &str) -> PreparedText {
        let normalized = self.normalize(text);
        let trigrams = trigrams(normalized.as_str());
        PreparedText {
            normalized,
            trigrams,
        }
    }

    fn prepare_optional(&self, value: Option<&str>) -> Option<PreparedText> {
        value
            .filter(|value| !value.trim().is_empty())
            .map(|value| self.prepare(value))
    }

    #[cfg(test)]
    pub(crate) fn match_value(&self, query: &NormalizedText, value: &str) -> Option<ValueMatch> {
        let query = self.prepare(query.as_str());
        let value = self.prepare(value);
        self.match_prepared_value(&query, &value, ThresholdGate::Inclusive)
    }

    #[cfg(test)]
    pub(crate) fn match_document(
        &self,
        query: &NormalizedText,
        document: &SearchDocument<'_>,
    ) -> DocumentMatches {
        let query = self.prepare(query.as_str());
        let name = self.prepare(document.name);
        let brand = self.prepare_optional(document.brand);
        let identifier = self.prepare_optional(document.identifier);
        let terms = document
            .terms
            .iter()
            .map(|term| self.prepare(term.0.as_str()))
            .collect::<Vec<_>>();

        self.match_prepared_document(&query, &name, brand.as_ref(), identifier.as_ref(), &terms)
    }

    fn match_prepared_document(
        &self,
        query: &PreparedText,
        name: &PreparedText,
        brand: Option<&PreparedText>,
        identifier: Option<&PreparedText>,
        terms: &[PreparedText],
    ) -> DocumentMatches {
        let mut matches = self.match_prepared_fields(query, name, brand, identifier);
        // Term matches can never outrank a name, brand, or identifier match.
        if !matches.is_match() {
            matches.term = self.match_prepared_terms(query, terms);
        }
        matches
    }

    fn match_prepared_fields(
        &self,
        query: &PreparedText,
        name: &PreparedText,
        brand: Option<&PreparedText>,
        identifier: Option<&PreparedText>,
    ) -> DocumentMatches {
        let identifier_match =
            identifier.and_then(|value| self.match_prepared_identifier(query, value));
        let (name_match, name_similarity) =
            self.match_prepared_value_scored(query, name, ThresholdGate::Inclusive);
        let (brand_match, brand_similarity) = brand
            .map(|value| self.match_prepared_value_scored(query, value, ThresholdGate::Inclusive))
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

    fn match_prepared_terms(
        &self,
        query: &PreparedText,
        terms: &[PreparedText],
    ) -> Option<ValueMatch> {
        terms
            .iter()
            .filter_map(|term| self.match_prepared_value(query, term, ThresholdGate::Inclusive))
            .fold(None, best_value_match)
    }

    fn match_prepared_value(
        &self,
        query: &PreparedText,
        value: &PreparedText,
        gate: ThresholdGate,
    ) -> Option<ValueMatch> {
        self.match_prepared_value_scored(query, value, gate).0
    }

    /// Returns the accepted match (if any) together with the raw similarity.
    ///
    /// The similarity is needed for tie-breaking even when the fuzzy gate
    /// rejects the field, so the ranker never has to compute it twice.
    fn match_prepared_value_scored(
        &self,
        query: &PreparedText,
        value: &PreparedText,
        gate: ThresholdGate,
    ) -> (Option<ValueMatch>, Similarity) {
        let value_text = value.normalized.as_str();
        if value_text.is_empty() {
            return (None, Similarity::default());
        }
        if query.normalized.as_str().is_empty() {
            return (
                Some(ValueMatch {
                    kind: MatchKind::Prefix,
                    similarity: Similarity::default(),
                }),
                Similarity::default(),
            );
        }

        let similarity = prepared_similarity(query, value);
        let kind = if value_text == query.normalized.as_str() {
            MatchKind::Exact
        } else if value_text.starts_with(query.normalized.as_str()) {
            MatchKind::Prefix
        } else if value_text.contains(query.normalized.as_str()) {
            MatchKind::Substring
        } else if gate.accepts(similarity, self.threshold) {
            MatchKind::Fuzzy
        } else {
            return (None, similarity);
        };

        (Some(ValueMatch { kind, similarity }), similarity)
    }

    fn match_prepared_identifier(
        &self,
        query: &PreparedText,
        value: &PreparedText,
    ) -> Option<ValueMatch> {
        let value_text = value.normalized.as_str();
        if value_text.is_empty() {
            return None;
        }
        if query.normalized.as_str().is_empty() {
            return Some(ValueMatch {
                kind: MatchKind::Prefix,
                similarity: Similarity::default(),
            });
        }

        let similarity = prepared_similarity(query, value);
        let kind = if value_text == query.normalized.as_str() {
            MatchKind::Exact
        } else if value_text.starts_with(query.normalized.as_str()) {
            MatchKind::Prefix
        } else if value_text.contains(query.normalized.as_str()) {
            MatchKind::Substring
        } else {
            return None;
        };

        Some(ValueMatch { kind, similarity })
    }
}

impl Default for TextMatcher {
    fn default() -> Self {
        Self::new(FuzzyThreshold::default())
    }
}

/// Character trigrams with pg_trgm-style word padding.
fn trigrams(text: &str) -> Vec<Trigram> {
    let mut grams = Vec::new();

    for word in text.split(|character: char| !character.is_alphanumeric()) {
        if word.is_empty() {
            continue;
        }
        let mut padded = Vec::with_capacity(word.len() + 3);
        padded.push(' ');
        padded.push(' ');
        padded.extend(word.chars());
        padded.push(' ');
        for window in padded.windows(3) {
            grams.push([window[0], window[1], window[2]]);
        }
    }

    grams.sort_unstable();
    grams.dedup();
    grams
}

fn shared_trigrams(left: &[Trigram], right: &[Trigram]) -> usize {
    let mut left_index = 0;
    let mut right_index = 0;
    let mut shared = 0;

    while left_index < left.len() && right_index < right.len() {
        match left[left_index].cmp(&right[right_index]) {
            Ordering::Less => left_index += 1,
            Ordering::Greater => right_index += 1,
            Ordering::Equal => {
                shared += 1;
                left_index += 1;
                right_index += 1;
            }
        }
    }

    shared
}

fn prepared_similarity(left: &PreparedText, right: &PreparedText) -> Similarity {
    if left.trigrams.is_empty() || right.trigrams.is_empty() {
        return Similarity::default();
    }

    let shared = shared_trigrams(&left.trigrams, &right.trigrams);
    let union = left.trigrams.len() + right.trigrams.len() - shared;
    if union == 0 {
        Similarity::default()
    } else {
        // pg_trgm returns `real`; use f32 division so exact-boundary cases
        // such as 6/20 compare the same way PostgreSQL does.
        Similarity::new((shared as f32 / union as f32) as f64)
    }
}

#[cfg(test)]
fn trigram_similarity(left: &str, right: &str) -> f64 {
    let left = trigrams(left);
    let right = trigrams(right);
    if left.is_empty() || right.is_empty() {
        return 0.0;
    }

    let shared = shared_trigrams(&left, &right);
    let union = left.len() + right.len() - shared;
    if union == 0 {
        0.0
    } else {
        (shared as f32 / union as f32) as f64
    }
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
    let query = matcher.prepare(query);
    rank_catalog_with(&matcher, &query, candidates, limit)
}

fn rank_catalog_with(
    matcher: &TextMatcher,
    query: &PreparedText,
    candidates: Vec<ProductSearchFields>,
    limit: usize,
) -> Vec<ProductId> {
    let mut ranked = Vec::with_capacity(candidates.len());

    for fields in candidates {
        let name = matcher.prepare(fields.name().as_str());
        let brand = matcher.prepare_optional(fields.brand().map(|brand| brand.0.as_str()));
        let identifier =
            matcher.prepare_optional(fields.barcode().map(|barcode| barcode.0.as_str()));
        let matches =
            matcher.match_prepared_document(query, &name, brand.as_ref(), identifier.as_ref(), &[]);
        let Some(tier) = product_tier(&matches) else {
            continue;
        };

        ranked.push(RankedProduct {
            id: fields.id(),
            tier,
            similarity: matches.name_brand_similarity(),
            normalized_name: name.normalized,
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
    let query = matcher.prepare(query);
    rank_history_with(&matcher, &query, candidates, limit)
}

fn rank_history_with(
    matcher: &TextMatcher,
    query: &PreparedText,
    candidates: Vec<HistorySearchCandidate>,
    limit: usize,
) -> Vec<ProductId> {
    let mut ranked = Vec::with_capacity(candidates.len());

    for candidate in candidates {
        let name = matcher.prepare(candidate.fields().name().as_str());
        let brand =
            matcher.prepare_optional(candidate.fields().brand().map(|brand| brand.0.as_str()));
        let identifier = matcher.prepare_optional(
            candidate
                .fields()
                .barcode()
                .map(|barcode| barcode.0.as_str()),
        );
        let mut matches =
            matcher.match_prepared_fields(query, &name, brand.as_ref(), identifier.as_ref());
        if !matches.is_match() {
            let terms = candidate
                .categories()
                .iter()
                .map(|term| matcher.prepare(term.0.as_str()))
                .collect::<Vec<_>>();
            matches.term = matcher.match_prepared_terms(query, &terms);
        }
        let Some(tier) = product_tier(&matches) else {
            continue;
        };

        ranked.push(RankedHistoryProduct {
            id: candidate.fields().id(),
            recency: candidate.recency(),
            tier,
            similarity: matches.name_brand_similarity(),
            normalized_name: name.normalized,
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
    let query = matcher.prepare(query);
    let mut ranked = Vec::with_capacity(counts.len());

    for count in counts {
        let prepared = matcher.prepare(count.value().0.as_str());
        let Some(value_match) =
            matcher.match_prepared_value(&query, &prepared, ThresholdGate::Exclusive)
        else {
            continue;
        };

        ranked.push(RankedCategory {
            value: count.value().0.clone(),
            count: count.count(),
            tier: category_tier(value_match.kind),
            similarity: value_match.similarity,
            normalized_value: prepared.normalized,
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
    use uuid::Uuid;

    fn matcher(threshold: f64) -> TextMatcher {
        TextMatcher::new(FuzzyThreshold::new(threshold).expect("valid fuzzy threshold"))
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

    #[test]
    fn match_value_classifies_exact_prefix_substring_fuzzy_and_rejected() {
        let matcher = TextMatcher::default();

        let exact = matcher
            .match_value(&matcher.normalize("greek yogurt"), "  Greek   Yogurt ")
            .unwrap();
        assert_eq!(exact.kind, MatchKind::Exact);

        let prefix = matcher
            .match_value(&matcher.normalize("greek"), "Greek Yogurt")
            .unwrap();
        assert_eq!(prefix.kind, MatchKind::Prefix);

        let substring = matcher
            .match_value(&matcher.normalize("yog"), "Greek Yogurt")
            .unwrap();
        assert_eq!(substring.kind, MatchKind::Substring);

        let fuzzy = matcher
            .match_value(&matcher.normalize("yogrt"), "yogurt")
            .unwrap();
        assert_eq!(fuzzy.kind, MatchKind::Fuzzy);

        assert_eq!(
            matcher.match_value(&matcher.normalize("zzzz"), "Greek Yogurt"),
            None
        );
    }

    #[test]
    fn fuzzy_threshold_is_enforced_and_similarity_is_bounded() {
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

        assert_eq!(Similarity::new(-1.0).value(), 0.0);
        assert_eq!(Similarity::new(2.0).value(), 1.0);
        assert_eq!(Similarity::new(f64::NAN).value(), 0.0);
        assert_eq!(Similarity::new(0.25).value(), 0.25);
        assert_eq!(Similarity::default().value(), 0.0);
        assert_eq!(
            Similarity::new(0.25).total_cmp(&Similarity::new(0.5)),
            Ordering::Less
        );
    }

    #[test]
    fn fuzzy_threshold_rejects_invalid_values() {
        for value in [f64::NAN, -0.1, 1.1, f64::INFINITY, f64::NEG_INFINITY] {
            assert!(
                FuzzyThreshold::new(value).is_none(),
                "expected {value} to be rejected"
            );
        }

        assert_eq!(FuzzyThreshold::default().value(), DEFAULT_FUZZY_THRESHOLD);
        assert_eq!(FuzzyThreshold::new(0.0).unwrap().value(), 0.0);
        assert_eq!(FuzzyThreshold::new(1.0).unwrap().value(), 1.0);
    }

    #[test]
    fn trigram_similarity_matches_pg_trgm_examples() {
        assert_eq!(trigram_similarity("broccoli, raw", "brocolli"), 0.375);
        assert!((trigram_similarity("cheddar cheese", "chedar") - 0.461_538_46).abs() < 1e-6);
        assert!((trigram_similarity("coke", "cookies") - 0.181_818_18).abs() < 1e-6);
        assert!((trigram_similarity("rice", "rce") - 0.285_714_29).abs() < 1e-6);
        assert!(trigram_similarity("other-vegetables", "vegtable") > 0.3);
    }

    #[test]
    fn trigram_similarity_without_alphanumeric_trigrams_is_zero() {
        assert_eq!(trigram_similarity("", "abc"), 0.0);
        assert_eq!(trigram_similarity("!!!", "abc"), 0.0);
        assert_eq!(trigram_similarity("---", "___"), 0.0);
    }

    #[test]
    fn known_typos_remain_product_fuzzy_matches() {
        for (query, name) in [
            ("chedar", "Cheddar Cheese"),
            ("chese", "Cheese Cube"),
            ("brocolli", "Broccoli, raw"),
            ("avacado", "Avocado"),
            ("vegtable", "vegetables"),
        ] {
            assert_eq!(
                rank_catalog(query, vec![fields(1, name, None, None)], 10),
                vec![product_id(1)],
                "{query} should fuzzy-match {name}"
            );
        }
    }

    #[test]
    fn short_unrelated_queries_do_not_match() {
        assert!(rank_catalog("rice", vec![fields(1, "rce", None, None)], 10).is_empty());
        assert!(rank_catalog("coke", vec![fields(1, "cookies", None, None)], 10).is_empty());
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
    fn threshold_boundary_matches_pg_trgm_float4_behavior() {
        let boundary = matcher(DEFAULT_FUZZY_THRESHOLD);
        let product_match = boundary
            .match_value(&boundary.normalize("cheese"), "chess")
            .expect("0.30 similarity should pass the inclusive product gate");
        assert_eq!(product_match.kind, MatchKind::Fuzzy);
        assert!(product_match.similarity.value() > 0.3);

        // pg_trgm returns float4, so 6/20 is slightly above 0.30 and passes
        // the old `similarity(...) > 0.30` category predicate too.
        let counts = vec![category_count("chess", 1)];
        assert_eq!(
            rank_category_suggestions_with(&boundary, "cheese", counts.clone(), 10),
            vec![CategorySuggestion {
                value: "chess".into(),
                count: 1,
            }]
        );

        assert_eq!(
            rank_category_suggestions_with(
                &boundary,
                "vegtable",
                vec![category_count("other-vegetables", 1)],
                10
            ),
            vec![CategorySuggestion {
                value: "other-vegetables".into(),
                count: 1,
            }]
        );

        let strict = matcher(0.31);
        assert_eq!(
            strict.match_value(&strict.normalize("cheese"), "chess"),
            None
        );
        assert!(rank_category_suggestions_with(&strict, "cheese", counts, 10).is_empty());
    }

    #[test]
    fn wildcard_characters_are_literal() {
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
        assert!(matches.name_similarity.value() > 0.4);
        assert!(matches.name_similarity.value() < 0.5);
        assert!(matches.brand_similarity.value() > 0.0);
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
    fn history_category_only_match_is_returned() {
        let candidate = history(1, "Plain base", None, None, &["dairy"], (2026, 1, 1), 12);

        let ranked = rank_history_candidates("dairy", vec![candidate], 10);

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
            category_count("dairi", 50),
            category_count("dary", 50),
        ];

        let ranked = rank_category_suggestions("dairy", counts, 10);

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
                    value: "dairi".into(),
                    count: 50,
                },
                CategorySuggestion {
                    value: "dary".into(),
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
