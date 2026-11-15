//! Date selector grammar and inclusive calendar ranges.
//!
//! Resolution uses one caller-supplied local date so a process never changes
//! dates at midnight. This module deliberately contains no command or output
//! rendering logic.

use chrono::{Duration, NaiveDate};

use crate::output::{self, CliError};

const MAX_RANGE_DIFFERENCE_DAYS: i64 = 366;

/// An inclusive calendar span.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DateSpan {
    pub from: NaiveDate,
    pub to: NaiveDate,
}

impl DateSpan {
    pub fn parse(raw: Option<&str>, today: NaiveDate) -> Result<Self, CliError> {
        match raw {
            None => Ok(Self {
                from: today,
                to: today,
            }),
            Some(raw) => parse_date_span(raw, today),
        }
    }

    pub fn parse_single(raw: Option<&str>, today: NaiveDate) -> Result<NaiveDate, CliError> {
        match raw {
            None => Ok(today),
            Some(raw) => {
                if raw.contains("..") {
                    return Err(date_range_not_allowed());
                }
                resolve_date_token(raw, today)
            }
        }
    }

    pub fn len(&self) -> usize {
        let difference = (self.to - self.from).num_days();
        difference.max(0) as usize + 1
    }

    pub fn is_single(&self) -> bool {
        self.from == self.to
    }

    pub fn dates(&self) -> impl Iterator<Item = NaiveDate> + '_ {
        self.from.iter_days().take(self.len())
    }

    fn checked(from: NaiveDate, to: NaiveDate) -> Result<Self, CliError> {
        if from > to {
            return Err(invalid_date_range(
                "date range start must not be after its end",
            ));
        }

        let difference = (to - from).num_days();
        if difference > MAX_RANGE_DIFFERENCE_DAYS {
            return Err(output::arguments_error(
                "date_range_too_large",
                format!(
                    "date range cannot exceed {MAX_RANGE_DIFFERENCE_DAYS} days of difference \
                     (at most 367 inclusive dates)"
                ),
            ));
        }

        Ok(Self { from, to })
    }
}

fn parse_date_span(raw: &str, today: NaiveDate) -> Result<DateSpan, CliError> {
    let Some((start, end)) = raw.split_once("..") else {
        let date = resolve_date_token(raw, today)?;
        return Ok(DateSpan {
            from: date,
            to: date,
        });
    };

    if start.is_empty() {
        return Err(invalid_date_range(
            "date range must have a start date; open-start ranges are not allowed",
        ));
    }
    if end.contains("..") {
        return Err(invalid_date_range(
            "date range must contain exactly one '..' separator",
        ));
    }

    let from = resolve_date_token(start, today)?;
    let to = if end.is_empty() {
        today
    } else {
        resolve_date_token(end, today)?
    };

    DateSpan::checked(from, to)
}

fn resolve_date_token(token: &str, today: NaiveDate) -> Result<NaiveDate, CliError> {
    if token.is_empty() {
        return Err(invalid_date("date must not be empty"));
    }
    if token.chars().any(char::is_whitespace) {
        return Err(invalid_date("dates must not contain whitespace"));
    }

    match token {
        "today" => Ok(today),
        "yesterday" => Ok(today - Duration::days(1)),
        _ => parse_iso_date(token),
    }
}

fn parse_iso_date(raw: &str) -> Result<NaiveDate, CliError> {
    let bytes = raw.as_bytes();
    let has_iso_shape = bytes.len() == 10
        && bytes[4] == b'-'
        && bytes[7] == b'-'
        && bytes
            .iter()
            .enumerate()
            .all(|(index, byte)| matches!(index, 4 | 7) || byte.is_ascii_digit());

    if !has_iso_shape {
        return Err(invalid_date("date must use YYYY-MM-DD"));
    }

    NaiveDate::parse_from_str(raw, "%Y-%m-%d")
        .map_err(|_| invalid_date("date is not a valid calendar date"))
}

fn invalid_date(message: impl Into<String>) -> CliError {
    output::arguments_error("invalid_date", message)
}

fn invalid_date_range(message: impl Into<String>) -> CliError {
    output::arguments_error("invalid_date_range", message)
}

fn date_range_not_allowed() -> CliError {
    output::arguments_error(
        "date_range_not_allowed",
        "this command accepts a single date, not a date range",
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn date(raw: &str) -> NaiveDate {
        NaiveDate::parse_from_str(raw, "%Y-%m-%d").expect("test date")
    }

    fn today() -> NaiveDate {
        date("2026-11-15")
    }

    fn code(result: Result<DateSpan, CliError>) -> String {
        result.expect_err("expected an error").code
    }

    #[test]
    fn dates_default_to_today_and_resolve_relative_tokens_once() {
        let span = DateSpan::parse(None, today()).unwrap();
        assert_eq!(span.from, today());
        assert_eq!(span.to, today());
        assert!(span.is_single());

        let span = DateSpan::parse(Some("yesterday..today"), today()).unwrap();
        assert_eq!(span.from, date("2026-11-14"));
        assert_eq!(span.to, today());
        assert_eq!(span.len(), 2);
        assert_eq!(
            span.dates().collect::<Vec<_>>(),
            vec![date("2026-11-14"), today()]
        );

        let span = DateSpan::parse(Some("2026-11-01.."), today()).unwrap();
        assert_eq!(span.from, date("2026-11-01"));
        assert_eq!(span.to, today());

        let span = DateSpan::parse(Some("today..today"), today()).unwrap();
        assert!(span.is_single());
        assert_eq!(span.len(), 1);
    }

    #[test]
    fn dates_accept_iso_relative_and_inclusive_ranges() {
        let span = DateSpan::parse(Some("2026-01-01..2026-01-03"), today()).unwrap();
        assert_eq!(span.len(), 3);
        assert_eq!(
            span.dates().collect::<Vec<_>>(),
            vec![date("2026-01-01"), date("2026-01-02"), date("2026-01-03")]
        );

        let span = DateSpan::parse(Some("yesterday.."), today()).unwrap();
        assert_eq!(span.from, date("2026-11-14"));
        assert_eq!(span.to, today());

        assert_eq!(
            DateSpan::parse_single(Some("today"), today()).unwrap(),
            today()
        );
        assert_eq!(
            DateSpan::parse_single(Some("yesterday"), today()).unwrap(),
            date("2026-11-14")
        );
    }

    #[test]
    fn dates_reject_open_start_reversed_whitespace_and_malformed_values() {
        assert_eq!(
            code(DateSpan::parse(Some("..2026-11-15"), today())),
            "invalid_date_range"
        );
        assert_eq!(
            code(DateSpan::parse(Some(".."), today())),
            "invalid_date_range"
        );
        assert_eq!(
            code(DateSpan::parse(Some("2026-11-16..2026-11-15"), today())),
            "invalid_date_range"
        );
        assert_eq!(
            code(DateSpan::parse(
                Some("2026-11-15..2026-11-16..2026-11-17"),
                today()
            )),
            "invalid_date_range"
        );
        assert_eq!(
            code(DateSpan::parse(Some("2026-11-16.."), today())),
            "invalid_date_range"
        );
        assert_eq!(
            code(DateSpan::parse(Some(" 2026-11-15"), today())),
            "invalid_date"
        );
        assert_eq!(
            code(DateSpan::parse(Some("2026-11-15 "), today())),
            "invalid_date"
        );
        assert_eq!(
            code(DateSpan::parse(Some("2026-1-1"), today())),
            "invalid_date"
        );
        assert_eq!(
            code(DateSpan::parse(Some("2026-02-30"), today())),
            "invalid_date"
        );
        assert_eq!(
            code(DateSpan::parse(Some("2026-11-15T00:00:00"), today())),
            "invalid_date"
        );
        assert_eq!(
            code(DateSpan::parse(Some("Today"), today())),
            "invalid_date"
        );
    }

    #[test]
    fn dates_reject_ranges_where_a_single_date_is_required() {
        for raw in [
            "2026-11-14..2026-11-15",
            "today..",
            "..today",
            "today..today",
        ] {
            let error = DateSpan::parse_single(Some(raw), today()).unwrap_err();
            assert_eq!(error.code, "date_range_not_allowed");
        }
    }

    #[test]
    fn dates_enforce_the_366_day_difference_limit() {
        let allowed = DateSpan::parse(Some("2026-01-01..2027-01-02"), today()).unwrap();
        assert_eq!(allowed.len(), 367);
        assert_eq!((allowed.to - allowed.from).num_days(), 366);

        let error = DateSpan::parse(Some("2026-01-01..2027-01-03"), today()).unwrap_err();
        assert_eq!(error.code, "date_range_too_large");
    }
}
