//! Test-only command-helper tests.

use super::*;

#[test]
fn uuid_parser_requires_full_lowercase_canonical_form() {
    let canonical = "123e4567-e89b-12d3-a456-426614174000";
    assert_eq!(parse_full_uuid(canonical).unwrap().to_string(), canonical);
    assert_eq!(
        parse_full_uuid("00000000-0000-0000-0000-000000000000")
            .unwrap()
            .to_string(),
        "00000000-0000-0000-0000-000000000000"
    );

    for raw in [
        "123E4567-E89B-12D3-A456-426614174000",
        "123e4567e89b12d3a456426614174000",
        "{123e4567-e89b-12d3-a456-426614174000}",
        "123e4567-e89b",
        "not-a-uuid",
    ] {
        let error = parse_full_uuid(raw).unwrap_err();
        assert_eq!(error.code, "invalid_arguments");
    }
}
