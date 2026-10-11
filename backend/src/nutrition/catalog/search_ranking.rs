use std::cmp::Ordering;
use std::collections::BTreeSet;

use chrono::{DateTime, NaiveDate, Utc};

use crate::nutrition::catalog::domain::ProductSearchScope;

const SIMILARITY_THRESHOLD: f64 = 0.30;

#[derive(Debug, Clone)]
pub struct SearchCandidate {
    pub barcode: Option<String>,
    pub name: String,
    pub brand: Option<String>,
    pub categories: Vec<String>,
    pub last_logged: Option<(NaiveDate, DateTime<Utc>)>,
}

fn trigrams(value: &str) -> BTreeSet<String> {
    let mut grams = BTreeSet::new();
    for word in value.split_whitespace() {
        let padded = format!("  {word} ");
        let chars: Vec<char> = padded.chars().collect();
        for window in chars.windows(3) {
            grams.insert(window.iter().collect());
        }
    }
    grams
}

pub fn similarity(left: &str, right: &str) -> f64 {
    let left = left.trim();
    let right = right.trim();
    if left.is_empty() || right.is_empty() {
        return 0.0;
    }
    let left = trigrams(&left.to_lowercase());
    let right = trigrams(&right.to_lowercase());
    if left.is_empty() || right.is_empty() {
        return 0.0;
    }
    let shared = left.intersection(&right).count() as f64;
    let union = left.union(&right).count() as f64;
    shared / union
}

pub fn rank(candidates: &[SearchCandidate], query: &str, scope: ProductSearchScope) -> Vec<usize> {
    let query = query.trim();
    let query_lower = query.to_lowercase();

    let mut matched: Vec<usize> = candidates
        .iter()
        .enumerate()
        .filter(|(_, candidate)| is_match(candidate, query, &query_lower, scope))
        .map(|(index, _)| index)
        .collect();

    matched.sort_by(|&left, &right| {
        compare(
            &candidates[left],
            &candidates[right],
            query,
            &query_lower,
            scope,
        )
    });
    matched
}

pub fn rank_category_suggestions(
    categories: &[(String, i64)],
    query: &str,
    limit: usize,
) -> Vec<usize> {
    let query = query.trim();
    let query_lower = query.to_lowercase();

    let mut matched: Vec<usize> = categories
        .iter()
        .enumerate()
        .filter(|(_, (value, _))| {
            if query.is_empty() {
                return true;
            }
            let value_lower = value.to_lowercase();
            value_lower.starts_with(&query_lower)
                || value_lower.contains(&query_lower)
                || similarity(&value_lower, &query_lower) > SIMILARITY_THRESHOLD
        })
        .map(|(index, _)| index)
        .collect();

    matched.sort_by(|&left, &right| {
        let (left_value, left_count) = &categories[left];
        let (right_value, right_count) = &categories[right];
        let left_tier = suggestion_tier(left_value, query, &query_lower);
        let right_tier = suggestion_tier(right_value, query, &query_lower);

        left_tier
            .cmp(&right_tier)
            .then(right_count.cmp(left_count))
            .then(
                similarity(&right_value.to_lowercase(), &query_lower)
                    .partial_cmp(&similarity(&left_value.to_lowercase(), &query_lower))
                    .unwrap_or(Ordering::Equal),
            )
            .then(left_value.cmp(right_value))
    });
    matched.truncate(limit);
    matched
}

fn is_match(
    candidate: &SearchCandidate,
    query: &str,
    query_lower: &str,
    scope: ProductSearchScope,
) -> bool {
    if query.is_empty() {
        return true;
    }

    let name = candidate.name.to_lowercase();
    let brand = candidate.brand.as_deref().unwrap_or("").to_lowercase();
    let barcode = candidate.barcode.as_deref().unwrap_or("").to_lowercase();

    if name.contains(query_lower)
        || brand.contains(query_lower)
        || barcode.contains(query_lower)
        || similarity(&name, query_lower) > SIMILARITY_THRESHOLD
        || similarity(&brand, query_lower) > SIMILARITY_THRESHOLD
    {
        return true;
    }

    scope == ProductSearchScope::History
        && candidate.categories.iter().any(|category| {
            let category = category.to_lowercase();
            category.contains(query_lower)
                || similarity(&category, query_lower) > SIMILARITY_THRESHOLD
        })
}

fn compare(
    left: &SearchCandidate,
    right: &SearchCandidate,
    query: &str,
    query_lower: &str,
    scope: ProductSearchScope,
) -> Ordering {
    if scope == ProductSearchScope::History {
        match (left.last_logged, right.last_logged) {
            (Some((left_date, left_time)), Some((right_date, right_time))) => {
                match right_date.cmp(&left_date).then(right_time.cmp(&left_time)) {
                    Ordering::Equal => {}
                    ordering => return ordering,
                }
            }
            (None, Some(_)) => return Ordering::Greater,
            (Some(_), None) => return Ordering::Less,
            (None, None) => {}
        }
    }

    let tier_ordering = tier(left, query, query_lower).cmp(&tier(right, query, query_lower));
    if tier_ordering != Ordering::Equal {
        return tier_ordering;
    }

    let score_ordering = score(right, query_lower)
        .partial_cmp(&score(left, query_lower))
        .unwrap_or(Ordering::Equal);
    if score_ordering != Ordering::Equal {
        return score_ordering;
    }

    left.name.to_lowercase().cmp(&right.name.to_lowercase())
}

fn tier(candidate: &SearchCandidate, query: &str, query_lower: &str) -> i64 {
    if let Some(barcode) = &candidate.barcode {
        if barcode == query {
            return 0;
        }
        if barcode.to_lowercase().starts_with(query_lower) {
            return 1;
        }
    }

    let name = candidate.name.to_lowercase();
    if name.starts_with(query_lower) {
        return 2;
    }
    if name.contains(query_lower) {
        return 3;
    }

    if let Some(brand) = &candidate.brand {
        let brand = brand.to_lowercase();
        if brand.starts_with(query_lower) {
            return 4;
        }
        if brand.contains(query_lower) {
            return 5;
        }
    }

    6
}

fn score(candidate: &SearchCandidate, query_lower: &str) -> f64 {
    let name = similarity(&candidate.name.to_lowercase(), query_lower);
    let brand = similarity(
        &candidate.brand.as_deref().unwrap_or("").to_lowercase(),
        query_lower,
    );
    name.max(brand)
}

fn suggestion_tier(value: &str, query: &str, query_lower: &str) -> i64 {
    if query.is_empty() {
        return 0;
    }
    let value_lower = value.to_lowercase();
    if value_lower.starts_with(query_lower) {
        0
    } else if value_lower.contains(query_lower) {
        1
    } else {
        2
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate(name: &str, brand: Option<&str>, barcode: Option<&str>) -> SearchCandidate {
        SearchCandidate {
            barcode: barcode.map(str::to_owned),
            name: name.to_owned(),
            brand: brand.map(str::to_owned),
            categories: Vec::new(),
            last_logged: None,
        }
    }

    #[test]
    fn similarity_is_zero_for_empty_inputs() {
        assert_eq!(similarity("", "granola"), 0.0);
        assert_eq!(similarity("granola", ""), 0.0);
    }

    #[test]
    fn similarity_uses_trigram_overlap() {
        assert_eq!(similarity("grain", "dairy"), 0.0);
        assert_eq!(similarity("fresh", "fresh"), 1.0);
        assert!(similarity("fresh", "freshly") > 0.3);
    }

    #[test]
    fn rank_orders_barcode_exact_before_prefix_and_name_matches() {
        let candidates = vec![
            candidate("Granola Bar", Some("BrandCo"), None),
            candidate("Other", Some("Other"), Some("12345")),
            candidate("Granola Crunch", Some("Granola"), Some("123456")),
        ];

        let ranked = rank(&candidates, "12345", ProductSearchScope::All);

        assert_eq!(ranked, vec![1, 2]);
    }

    #[test]
    fn rank_orders_name_prefix_before_name_substring() {
        let candidates = vec![
            candidate("Crunchy Granola", None, None),
            candidate("Granola", None, None),
        ];

        let ranked = rank(&candidates, "granola", ProductSearchScope::All);

        assert_eq!(ranked, vec![1, 0]);
    }

    #[test]
    fn rank_returns_everything_for_empty_query_in_name_order() {
        let candidates = vec![
            candidate("Zebra", None, None),
            candidate("Apple", None, None),
        ];

        let ranked = rank(&candidates, "", ProductSearchScope::All);

        assert_eq!(ranked, vec![1, 0]);
    }

    #[test]
    fn rank_orders_history_by_most_recent_log() {
        let mut older = candidate("Scope Oats", None, None);
        older.last_logged = Some((
            NaiveDate::from_ymd_opt(2026, 6, 2).unwrap(),
            "2026-06-02T10:00:00Z".parse().unwrap(),
        ));
        let mut newer = candidate("Scope Yogurt", None, None);
        newer.last_logged = Some((
            NaiveDate::from_ymd_opt(2026, 6, 3).unwrap(),
            "2026-06-03T10:00:00Z".parse().unwrap(),
        ));
        let candidates = vec![older, newer];

        let ranked = rank(&candidates, "scope", ProductSearchScope::History);

        assert_eq!(ranked, vec![1, 0]);
    }

    #[test]
    fn rank_matches_categories_only_in_history_scope() {
        let mut with_category = candidate("Cola", None, None);
        with_category.categories = vec!["fermented".to_owned()];

        let all = rank(
            std::slice::from_ref(&with_category),
            "fermented",
            ProductSearchScope::All,
        );
        let history = rank(
            std::slice::from_ref(&with_category),
            "fermented",
            ProductSearchScope::History,
        );

        assert!(all.is_empty());
        assert_eq!(history, vec![0]);
    }

    #[test]
    fn rank_drops_candidates_below_the_similarity_threshold() {
        let candidates = vec![candidate("Chocolate Cake", None, None)];

        let ranked = rank(&candidates, "zzzzzzzzzz", ProductSearchScope::All);

        assert!(ranked.is_empty());
    }

    #[test]
    fn category_suggestions_prefer_prefix_then_count() {
        let categories = vec![
            ("fresh".to_owned(), 1),
            ("freshest".to_owned(), 9),
            ("organic fresh".to_owned(), 5),
        ];

        let ranked = rank_category_suggestions(&categories, "fresh", 10);

        assert_eq!(ranked, vec![1, 0, 2]);
    }

    #[test]
    fn category_suggestions_limit_results() {
        let categories = vec![
            ("fresh".to_owned(), 2),
            ("freshly".to_owned(), 1),
            ("freshest".to_owned(), 1),
        ];

        let ranked = rank_category_suggestions(&categories, "fresh", 2);

        assert_eq!(ranked.len(), 2);
    }
}
