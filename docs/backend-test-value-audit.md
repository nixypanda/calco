| Test | Location | Disposition | Reason |
|---|---|---|---|
| `fuzzy_threshold_accepts_valid_boundaries_and_default` | `backend/src/catalog/domain/search_ranking.rs:858` | Kept | Boundary/default values; proptest does not pin exact default/negative-zero. |
| `fuzzy_threshold_negative_zero_and_default_round_trip` | `backend/src/catalog/domain/search_ranking.rs:1613` | Kept | Negative-zero round trip and default constant not asserted by proptest. |
| `rust_fuzzy_search_scores_match_documented_goldens` | `backend/src/catalog/domain/search_ranking.rs:918` | Kept | Pins pinned-dependency (`=0.1.1`) behavior required for recalibration. |
| `fuzzy_similarity_uses_query_first_trigram_containment` | `backend/src/catalog/domain/search_ranking.rs:872` | Kept | Documents non-obvious query-first asymmetry. |
| `rejected_near_miss_can_be_recovered_by_lower_threshold` | `backend/src/catalog/domain/search_ranking.rs:929` | Kept | Only non-default-threshold path; low risk but retained. |
| `category_suggestions_match_known_typos` | `backend/src/catalog/domain/search_ranking.rs:967` | Kept | End-to-end suggestion guard; threshold test does not cover it. |
| `category_suggestions_admit_trigram_near_miss_but_reject_old_match` | `backend/src/catalog/domain/search_ranking.rs:980` | Kept | End-to-end suggestion guard; threshold test does not cover it. |
| `benchmark_rank_catalog_13k_candidates` | `backend/src/catalog/domain/search_ranking.rs:1394` | Kept | Ignored perf smoke test; only perf regression signal. |
| `history_lists_recent_items_through_repository` | `backend/src/journal/food_log/app/history.rs:463` | Removed | Mock wiring smoke; no app logic beyond repository echo. |
| `history_finds_last_used_items_through_repository` | `backend/src/journal/food_log/app/history.rs:520` | Removed | Mock wiring smoke; quantity asserts logged input. |
| `recent_items_use_newest_created_at_when_latest_log_dates_match` | `backend/src/journal/food_log/app/history.rs:683` | Kept | Cheap guard for subtle created-at tie-break. |
| `recent_items_rank_meals_and_break_score_ties_by_name` | `backend/src/journal/food_log/app/history.rs:737` | Kept | Distinct meal aggregation/name tie-break path. |
| `update_ad_hoc_log_recalculates_quantity` | `backend/src/journal/food_log/app/services.rs:367` | Removed | Duplicates domain scaling law; service only forwards. |
| `test_delete_food_log_not_found` | `backend/src/journal/food_log/app/services.rs:514` | Removed | Mock already returns `NotFound` for any id. |
| `test_log_meal_success` | `backend/src/journal/food_log/app/services.rs:629` | Removed | Constructor-echo happy path; meal scaling covered elsewhere. |
| `update_ad_hoc_log_scales_by_exact_multiple` | `backend/src/journal/food_log/domain.rs:1037` | Removed | Special case of ratio property. |
| `external_product_creation_normalizes_blank_barcode_to_none` | `backend/src/catalog/domain/mod.rs:1162` | Removed | Trivial normalization branch. |
| `custom_product_creation_accepts_arbitrary_default_quantity_for_serving_unit` | `backend/src/catalog/domain/mod.rs:1348` | Removed | Asserts supplied values. |
| `external_product_batch_accepts_valid_products_and_preserves_order` | `backend/src/catalog/domain/mod.rs:1756` | Kept | Only success-path coverage of `ExternalProductBatch`. |
| `catalog_policy_allows_every_view_and_only_owner_custom_mutations` | `backend/src/catalog/domain/mod.rs:1795` | Kept | Security mutation assertions retained; view assertion is no-op. |
| `test_delete_meal_not_found` | `backend/src/journal/meal/app.rs:540` | Removed | Mock already returns `NotFound`. |
| `multiple_saved_rows_resolve_latest_effective_date` | `backend/src/journal/goals/app.rs:155` | Removed | SQL/mock behavior; snapshot mapping trivial. |
| `effective_goal_lookup_does_not_cross_user_boundaries` | `backend/src/journal/goals/app.rs:187` | Kept | Security-relevant user propagation guard. |
| `save_today_does_not_overwrite_another_users_goal` | `backend/src/journal/goals/app.rs:210` | Kept | Cross-user save isolation guard. |
| `no_snapshots_report_no_data` | `backend/src/journal/guidance/app.rs:245` | Kept | Only direct guard for `NoData` arm. |
| `informational_nutrient_with_partial_items_is_partial_data` | `backend/src/journal/guidance/app.rs:255` | Kept | Distinct normal-path status guard. |
| `complete_informational_data_is_available_and_explicit_zero_is_data` | `backend/src/journal/guidance/app.rs:232` | Kept | Non-obvious zero-counts-as-data rule. |
| `guidance_enforces_reference_invariants` | `backend/src/journal/guidance/domain.rs:167` | Kept | Expand to property rather than delete. |
| `enabled_meal_slots_canonicalizes_and_deduplicates` | `backend/src/journal/diary/domain.rs:78` | Removed | Dedup guaranteed by `BTreeSet`. |
| `request_rejects_unknown_and_empty_slots` | `backend/src/journal/diary/api/http.rs:82` | Removed | Covered by pure unit tests; only `is_err()`. |
| `test_stage_nutrients_rejects_invalid` | `backend/src/import/app.rs:576` | Kept | Strengthen assertion; count guard retained. |
| `validation_failure_marks_import_failed` | `backend/src/import/app.rs:809` | Kept | Different failure trigger from integration test. |
| `import_app_uses_catalog_app_ports_for_product_writes` | `backend/src/import/module.rs:43` | Removed | Source-text guard. |
| `pg_import_repo_does_not_write_catalog_tables` | `backend/src/import/module.rs:53` | Removed | Source-text guard. |
| `nutrition_http_api_does_not_reference_repos` | `backend/src/journal/module.rs:200` | Removed | Source-text guard. |
| `draft_structure_limits_are_domain_invariants` | `backend/src/assistant/domain.rs:574` | Removed | Restates literals. |
| `draft_policy_enforces_runtime_vocabulary_and_plausibility` | `backend/src/assistant/domain.rs:609` | Removed | Restates thresholds. |
| `tracked_users_are_capped_without_consuming_existing_user_permits` | `backend/src/assistant/infra/admission.rs:119` | Removed | Internal count echo. |
| `expired_bucket_is_evicted_before_capacity_is_checked` | `backend/src/assistant/infra/admission.rs:139` | Removed | Implied by pruning test. |
| `response_contract_is_stable_for_clarification` | `backend/src/assistant/api/http.rs:673` | Removed | Golden JSON literal; clarification shape covered by integration. |
| `response_contract_maps_the_validated_draft_to_http_fields` | `backend/src/assistant/api/http.rs:690` | Kept | Wire-shape guard retained. |
| `response_contract_includes_a_suggested_logged_portion` | `backend/src/assistant/api/http.rs:737` | Removed | Golden JSON literal; ready path covered by integration. |
| `conversation_wire_rejects_unknown_photo_data` | `backend/src/assistant/api/http.rs:768` | Removed | Only `Err`, no code assertion. |
| `default_unit_must_be_grams_or_use_a_configured_serving_unit` | `backend/src/assistant/infra/food_draft/response.rs:153` | Kept | Validation branch guard. |
| `ad_hoc_draft_requires_a_suggested_log` | `backend/src/assistant/infra/food_draft/response.rs:167` | Kept | Missing-field guard. |
| `sends_custom_header_without_authorization` | `backend/src/assistant/infra/llm/openai.rs:646` | Removed | No distinct branch beyond omitting header. |
| `schema_rejection_falls_back_to_json_object` | `backend/src/assistant/infra/llm/openai.rs:678` | Removed | Partial fallback chain; full-chain test retained. |
| `falls_back_from_schema_to_json_object_to_prompt_only` | `backend/src/assistant/infra/llm/openai.rs:712` | Kept | Full fallback-chain guard. |
| `groq_request_adds_only_provider_extensions` | `backend/src/assistant/infra/llm/openai.rs:1109` | Removed | Provider-extension wiring covered by request tests. |
| `image_messages_use_openai_data_url_parts` | `backend/src/assistant/infra/llm/openai.rs:1125` | Kept | Multimodal encoding branch. |
| `credentials_and_configuration_are_redacted` | `backend/src/assistant/infra/llm/openai.rs:1147` | Kept | Security guard against credential leakage. |
| `strips_jpeg_metadata_from_small_images` | `backend/src/assistant/infra/images.rs:500` | Kept | Distinct no-downscale metadata path. |
| `translates_explicit_turn_photo_attachments` | `backend/src/assistant/infra/food_draft/mod.rs:173` | Kept | Photo attachment wiring guard. |
| `model_request_attaches_photos_to_the_latest_user_turn` | `backend/src/assistant/app/food_draft.rs:343` | Removed | Duplicates infra photo attachment test. |
| `external_product_write_validates_the_complete_batch_before_persistence` | `backend/src/catalog/app.rs:685` | Removed | Restates domain batch invariants. |
| `order_products_by_ids_preserves_rank_and_skips_missing_and_duplicate_ids` | `backend/src/catalog/app.rs:735` | Removed | Trivial helper; ordering covered by integration. |
| `category_limit_clamps_to_http_contract` | `backend/src/catalog/app.rs:755` | Removed | Restates `i64::clamp`. |
| `missing_path_empty_file_and_comment_only_file_disable_the_assistant` | `backend/src/config/source/toml.rs:184` | Trimmed | Reduced to `load(None)` assertion; renamed. |
| `absent_and_explicitly_disabled_assistant_configs_are_disabled` (`comment_only` case) | `backend/src/config/source/toml.rs:220-223` | Trimmed | Duplicate comment-only disabling coverage. |
| `unreadable_paths_do_not_leak_path_contents` | `backend/src/config/source/toml.rs:198` | Kept | Guards future path-field regression. |
| `invalid_configs_are_rejected` (serde type-mismatch cases) | `backend/src/config/source/toml.rs:463-498` | Trimmed | Retained one representative case. |
| `invalid_configs_are_rejected` (`unknown_authentication_field` case) | `backend/src/config/source/toml.rs:339-343` | Removed | Mislabelled missing-field parse failure. |
| `api_key_token_has_prefix_length_hint_and_deterministic_hash` | `backend/src/auth/domain.rs:830` | Kept | External token-format contract. |
| `session_policy_requires_a_positive_lifetime` | `backend/src/auth/domain.rs:796` | Trimmed | Removed lifetime echo assertion. |
| `create_accepts_valid_expiry_days` | `backend/src/auth/app/api_key.rs:439` | Removed | Passes through transformed value. |
| `create_rejects_when_active_key_limit_reached` | `backend/src/auth/app/api_key.rs:466` | Removed | Capacity counting covered by domain/integration. |
| `authenticate_rejects_expired_revoked_and_old_stamp_keys` | `backend/src/auth/app/api_key.rs:607` | Removed | Repeats domain usability matrix. |
| `hashes_are_salted_and_verify` | `backend/src/auth/infra/argon2_credentials.rs:42` | Removed | Exercises dependency; adapter error path retained. |
