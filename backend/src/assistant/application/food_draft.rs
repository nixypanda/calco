use std::collections::HashSet;
use std::sync::Arc;

use async_trait::async_trait;
use rust_decimal::Decimal;
use serde::Deserialize;
use serde_json::Value;

use crate::assistant::domain::{
    AssistantError, Conversation, DraftNutrient, DraftServing, DraftStatus, FoodDraft,
    FoodDraftTurn, MAX_ASSISTANT_MESSAGE_CHARS,
};

use super::{build_system_prompt, food_draft_response_schema};

const REQUIRED_NUTRIENT_CODES: [&str; 4] = ["ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G"];
const MAX_CATEGORIES: usize = 20;
const MAX_CATEGORY_CHARS: usize = 200;
const MAX_NUTRIENTS: usize = 100;
const MAX_SERVINGS: usize = 20;
const MAX_WARNINGS: usize = 20;
const MAX_WARNING_CHARS: usize = 500;
const MAX_NUTRIENT_AMOUNT_FALLBACK: Decimal = Decimal::from_parts(100_000, 0, 0, false, 0);
const MAX_NUTRIENT_AMOUNT_G: Decimal = Decimal::from_parts(100, 0, 0, false, 0);
const MAX_NUTRIENT_AMOUNT_MG: Decimal = Decimal::from_parts(100_000, 0, 0, false, 0);
const MAX_NUTRIENT_AMOUNT_UG: Decimal = Decimal::from_parts(100_000_000, 0, 0, false, 0);
const MAX_NUTRIENT_AMOUNT_KCAL: Decimal = Decimal::from_parts(1_000, 0, 0, false, 0);
const MAX_SERVING_GRAMS: Decimal = Decimal::from_parts(100_000, 0, 0, false, 0);
const MAX_SERVING_QUANTITY: Decimal = Decimal::from_parts(10_000, 0, 0, false, 0);
const CALORIE_CONSISTENCY_WARNING: &str = "Energy differs substantially from the 4/4/9 estimate based on protein, carbohydrates, and fat; review the nutrition values.";

/// The user-supplied data for a single text-only custom-food drafting request.
/// Photo input will be added as a distinct transport-safe value in a later
/// slice, rather than making the model port depend on HTTP multipart types.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FoodDraftRequest {
    pub conversation: Conversation,
}

/// The provider-neutral request sent by the application service to a model.
/// Prompt and response-schema text are code-owned and never supplied by HTTP.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelDraftRequest {
    pub conversation: Conversation,
    pub system_prompt: String,
    pub response_schema: String,
}

/// Provider-neutral response content. Provider adapters own wire parsing;
/// this application layer decodes the contained structured draft once.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelDraftResponse {
    pub content: String,
    pub usage: Option<ModelUsage>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ModelUsage {
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
}

/// Reference data translated from nutrition into assistant-owned terms.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct FoodVocabulary {
    pub nutrients: Vec<SupportedNutrient>,
    pub units: Vec<SupportedUnit>,
    pub required_nutrient_codes: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SupportedNutrient {
    pub code: String,
    pub name: String,
    pub unit: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SupportedUnit {
    pub code: String,
    pub name: String,
    pub kind: String,
}

/// Provider seam. Implementations own all remote-protocol and credential
/// details; callers only receive neutral assistant content.
#[async_trait]
pub trait FoodDraftModelPort: Send + Sync {
    async fn generate(
        &self,
        request: ModelDraftRequest,
    ) -> Result<ModelDraftResponse, AssistantError>;
}

/// Nutrition anti-corruption seam. It supplies vocabulary only and exposes no
/// catalog write operation to the assistant context.
#[async_trait]
pub trait FoodVocabularyPort: Send + Sync {
    async fn supported_vocabulary(&self) -> Result<FoodVocabulary, AssistantError>;
}

/// Application use-case seam used by HTTP and the module.
#[async_trait]
pub trait FoodDraftPort: Send + Sync {
    async fn draft(&self, request: FoodDraftRequest) -> Result<FoodDraftTurn, AssistantError>;
}

/// Validates an untrusted model turn and returns a transient form draft.
///
/// This type intentionally owns only a generation port and a vocabulary-read
/// port. It has no catalog service, repository, actor, or product-write input,
/// so this use case cannot create or update a food.
pub struct FoodDraftService {
    model: Arc<dyn FoodDraftModelPort>,
    vocabulary: Arc<dyn FoodVocabularyPort>,
}

impl FoodDraftService {
    pub fn new(
        model: Arc<dyn FoodDraftModelPort>,
        vocabulary: Arc<dyn FoodVocabularyPort>,
    ) -> Self {
        Self { model, vocabulary }
    }
}

#[async_trait]
impl FoodDraftPort for FoodDraftService {
    async fn draft(&self, request: FoodDraftRequest) -> Result<FoodDraftTurn, AssistantError> {
        let vocabulary = self.vocabulary.supported_vocabulary().await?;
        validate_vocabulary(&vocabulary)?;

        // This is deliberately the sole model call. Invalid structured content
        // is rejected locally rather than retried as another paid request.
        let response = self
            .model
            .generate(ModelDraftRequest {
                conversation: request.conversation,
                system_prompt: build_system_prompt(&vocabulary),
                response_schema: food_draft_response_schema(),
            })
            .await?;

        decode_and_validate(&response.content, &vocabulary)
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ModelTurnDto {
    assistant_message: String,
    status: ModelDraftStatus,
    draft: Option<ModelFoodDraftDto>,
    warnings: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ModelDraftStatus {
    NeedsClarification,
    DraftReady,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ModelFoodDraftDto {
    name: String,
    brand: Option<String>,
    categories: Vec<String>,
    serving_size_g: Option<Decimal>,
    default_quantity: Option<Decimal>,
    default_unit: Option<String>,
    nutrients: Vec<ModelNutrientDto>,
    servings: Vec<ModelServingDto>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ModelNutrientDto {
    code: String,
    amount_per_100g: Decimal,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ModelServingDto {
    label: String,
    quantity: Decimal,
    unit: String,
    grams: Decimal,
}

fn decode_and_validate(
    content: &str,
    vocabulary: &FoodVocabulary,
) -> Result<FoodDraftTurn, AssistantError> {
    let value: Value =
        serde_json::from_str(content).map_err(|_| AssistantError::InvalidModelResponse)?;
    validate_response_shape(&value)?;
    let output: ModelTurnDto =
        serde_json::from_value(value).map_err(|_| AssistantError::InvalidModelResponse)?;

    if output.assistant_message.chars().count() > MAX_ASSISTANT_MESSAGE_CHARS
        || output.warnings.len() > MAX_WARNINGS
        || output
            .warnings
            .iter()
            .any(|warning| warning.chars().count() > MAX_WARNING_CHARS)
    {
        return Err(AssistantError::InvalidModelResponse);
    }

    let status = match output.status {
        ModelDraftStatus::NeedsClarification => DraftStatus::NeedsClarification,
        ModelDraftStatus::DraftReady => DraftStatus::DraftReady,
    };
    let (draft, calorie_warning) = match output.draft {
        Some(draft) => {
            let draft = validate_draft(draft, vocabulary)?;
            let warning = calorie_consistency_warning(&draft);
            (Some(draft), warning)
        }
        None => (None, None),
    };

    let mut warnings = output.warnings;
    if let Some(warning) = calorie_warning
        && warnings.len() < MAX_WARNINGS
        && !warnings.iter().any(|existing| existing == &warning)
    {
        warnings.push(warning);
    }

    FoodDraftTurn::new(output.assistant_message, status, draft, warnings)
        .map_err(|_| AssistantError::InvalidModelResponse)
}

fn validate_vocabulary(vocabulary: &FoodVocabulary) -> Result<(), AssistantError> {
    let nutrient_codes: HashSet<&str> = vocabulary
        .nutrients
        .iter()
        .map(|nutrient| nutrient.code.as_str())
        .collect();
    let unit_codes: HashSet<&str> = vocabulary
        .units
        .iter()
        .map(|unit| unit.code.as_str())
        .collect();
    let required_codes: HashSet<&str> = vocabulary
        .required_nutrient_codes
        .iter()
        .map(String::as_str)
        .collect();

    if nutrient_codes.len() != vocabulary.nutrients.len()
        || unit_codes.len() != vocabulary.units.len()
        || required_codes.len() != vocabulary.required_nutrient_codes.len()
        || nutrient_codes.iter().any(|code| code.trim().is_empty())
        || unit_codes.iter().any(|code| code.trim().is_empty())
        || REQUIRED_NUTRIENT_CODES
            .iter()
            .any(|code| !nutrient_codes.contains(code) || !required_codes.contains(code))
        || required_codes
            .iter()
            .any(|code| !nutrient_codes.contains(code))
    {
        return Err(AssistantError::Internal);
    }

    Ok(())
}

fn validate_draft(
    source: ModelFoodDraftDto,
    vocabulary: &FoodVocabulary,
) -> Result<FoodDraft, AssistantError> {
    if source.categories.len() > MAX_CATEGORIES
        || source
            .categories
            .iter()
            .any(|category| category.chars().count() > MAX_CATEGORY_CHARS)
        || source.nutrients.len() > MAX_NUTRIENTS
        || source.servings.len() > MAX_SERVINGS
    {
        return Err(AssistantError::InvalidModelResponse);
    }

    let known_nutrients: HashSet<&str> = vocabulary
        .nutrients
        .iter()
        .map(|nutrient| nutrient.code.as_str())
        .collect();
    let known_units: HashSet<&str> = vocabulary
        .units
        .iter()
        .map(|unit| unit.code.as_str())
        .collect();

    if source
        .default_unit
        .as_deref()
        .is_some_and(|unit| !known_units.contains(unit))
        || source
            .serving_size_g
            .is_some_and(|grams| !is_positive_and_at_most(grams, MAX_SERVING_GRAMS))
        || source
            .default_quantity
            .is_some_and(|quantity| !is_positive_and_at_most(quantity, MAX_SERVING_QUANTITY))
    {
        return Err(AssistantError::InvalidModelResponse);
    }

    let mut seen_nutrients = HashSet::with_capacity(source.nutrients.len());
    let mut nutrients = Vec::with_capacity(source.nutrients.len());
    for nutrient in source.nutrients {
        let maximum = vocabulary
            .nutrients
            .iter()
            .find(|supported| supported.code == nutrient.code)
            .map(|supported| maximum_nutrient_amount(supported.unit.as_str()));
        if !known_nutrients.contains(nutrient.code.as_str())
            || !seen_nutrients.insert(nutrient.code.clone())
            || nutrient.amount_per_100g < Decimal::ZERO
            || maximum.is_none_or(|maximum| nutrient.amount_per_100g > maximum)
        {
            return Err(AssistantError::InvalidModelResponse);
        }
        // `AmountPer100g` in the catalog stores six fractional places.
        nutrients.push(
            DraftNutrient::new(nutrient.code, nutrient.amount_per_100g.round_dp(6))
                .map_err(|_| AssistantError::InvalidModelResponse)?,
        );
    }

    if vocabulary
        .required_nutrient_codes
        .iter()
        .any(|code| !seen_nutrients.contains(code))
    {
        return Err(AssistantError::InvalidModelResponse);
    }

    let mut servings = Vec::with_capacity(source.servings.len());
    for serving in source.servings {
        if !known_units.contains(serving.unit.as_str())
            || !is_positive_and_at_most(serving.quantity, MAX_SERVING_QUANTITY)
            || !is_positive_and_at_most(serving.grams, MAX_SERVING_GRAMS)
        {
            return Err(AssistantError::InvalidModelResponse);
        }
        servings.push(
            DraftServing::new(serving.label, serving.quantity, serving.unit, serving.grams)
                .map_err(|_| AssistantError::InvalidModelResponse)?,
        );
    }

    FoodDraft::new(
        source.name,
        source.brand,
        source.categories,
        source.serving_size_g,
        source.default_quantity,
        source.default_unit,
        nutrients,
        servings,
    )
    .map_err(|_| AssistantError::InvalidModelResponse)
}

fn is_positive_and_at_most(value: Decimal, maximum: Decimal) -> bool {
    value > Decimal::ZERO && value <= maximum
}

/// A nutrient cannot weigh more than the 100 g reference amount. The other
/// units express that same physical bound at their conventional scales. An
/// unfamiliar catalog unit gets a conservative finite ceiling rather than an
/// unbounded model-controlled value.
fn maximum_nutrient_amount(unit: &str) -> Decimal {
    match unit.to_ascii_lowercase().as_str() {
        "g" => MAX_NUTRIENT_AMOUNT_G,
        "mg" => MAX_NUTRIENT_AMOUNT_MG,
        "ug" | "µg" => MAX_NUTRIENT_AMOUNT_UG,
        "kcal" => MAX_NUTRIENT_AMOUNT_KCAL,
        _ => MAX_NUTRIENT_AMOUNT_FALLBACK,
    }
}

fn calorie_consistency_warning(draft: &FoodDraft) -> Option<String> {
    let amount = |code| {
        draft
            .nutrients
            .iter()
            .find(|nutrient| nutrient.code == code)
            .map(|nutrient| nutrient.amount_per_100g)
    };
    let energy = amount("ENERGY_KCAL")?;
    let protein = amount("PROTEIN_G")?;
    let carbs = amount("CARBS_G")?;
    let fat = amount("FAT_G")?;
    let macro_energy =
        protein * Decimal::from(4) + carbs * Decimal::from(4) + fat * Decimal::from(9);
    let difference = (energy - macro_energy).abs();
    let tolerance = Decimal::from(20).max(macro_energy * Decimal::new(20, 2));

    (difference > tolerance).then(|| CALORIE_CONSISTENCY_WARNING.into())
}

fn validate_response_shape(value: &Value) -> Result<(), AssistantError> {
    exact_object(value, &["assistant_message", "status", "draft", "warnings"])?;
    let draft = &value["draft"];
    if draft.is_null() {
        return Ok(());
    }
    exact_object(
        draft,
        &[
            "name",
            "brand",
            "categories",
            "serving_size_g",
            "default_quantity",
            "default_unit",
            "nutrients",
            "servings",
        ],
    )?;
    for nutrient in draft["nutrients"]
        .as_array()
        .ok_or(AssistantError::InvalidModelResponse)?
    {
        exact_object(nutrient, &["code", "amount_per_100g"])?;
    }
    for serving in draft["servings"]
        .as_array()
        .ok_or(AssistantError::InvalidModelResponse)?
    {
        exact_object(serving, &["label", "quantity", "unit", "grams"])?;
    }
    Ok(())
}

fn exact_object(value: &Value, fields: &[&str]) -> Result<(), AssistantError> {
    let object = value
        .as_object()
        .ok_or(AssistantError::InvalidModelResponse)?;
    if object.len() != fields.len()
        || fields.iter().any(|field| !object.contains_key(*field))
        || object.keys().any(|field| !fields.contains(&field.as_str()))
    {
        return Err(AssistantError::InvalidModelResponse);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use async_trait::async_trait;
    use tokio::sync::Mutex;

    use super::*;
    use crate::assistant::domain::{ConversationRole, ConversationTurn};

    #[derive(Clone)]
    struct StaticVocabulary;

    #[async_trait]
    impl FoodVocabularyPort for StaticVocabulary {
        async fn supported_vocabulary(&self) -> Result<FoodVocabulary, AssistantError> {
            Ok(vocabulary())
        }
    }

    struct RecordingModel {
        content: String,
        requests: Mutex<Vec<ModelDraftRequest>>,
    }

    #[async_trait]
    impl FoodDraftModelPort for RecordingModel {
        async fn generate(
            &self,
            request: ModelDraftRequest,
        ) -> Result<ModelDraftResponse, AssistantError> {
            self.requests.lock().await.push(request);
            Ok(ModelDraftResponse {
                content: self.content.clone(),
                usage: None,
            })
        }
    }

    fn vocabulary() -> FoodVocabulary {
        FoodVocabulary {
            nutrients: [
                ("ENERGY_KCAL", "Energy", "kcal"),
                ("PROTEIN_G", "Protein", "g"),
                ("CARBS_G", "Carbohydrates", "g"),
                ("FAT_G", "Fat", "g"),
                ("SODIUM_MG", "Sodium", "mg"),
                ("VITAMIN_B12_UG", "Vitamin B12", "ug"),
            ]
            .into_iter()
            .map(|(code, name, unit)| SupportedNutrient {
                code: code.into(),
                name: name.into(),
                unit: unit.into(),
            })
            .collect(),
            units: [
                ("g", "Gram", "mass"),
                ("serving", "Serving", "serving"),
                ("piece", "Piece", "count"),
            ]
            .into_iter()
            .map(|(code, name, kind)| SupportedUnit {
                code: code.into(),
                name: name.into(),
                kind: kind.into(),
            })
            .collect(),
            required_nutrient_codes: REQUIRED_NUTRIENT_CODES
                .into_iter()
                .map(str::to_owned)
                .collect(),
        }
    }

    fn request() -> FoodDraftRequest {
        FoodDraftRequest {
            conversation: Conversation::new(vec![
                ConversationTurn::new(ConversationRole::User, "A bowl of dal rice").unwrap(),
            ])
            .unwrap(),
        }
    }

    fn ready_json() -> String {
        r#"{
          "assistant_message":"Here is an estimated draft.",
          "status":"draft_ready",
          "draft":{
            "name":"Dal rice", "brand":null, "categories":[" Indian ","indian"],
            "serving_size_g":250, "default_quantity":1, "default_unit":"serving",
            "nutrients":[
              {"code":"ENERGY_KCAL","amount_per_100g":120},
              {"code":"PROTEIN_G","amount_per_100g":5.1256789},
              {"code":"CARBS_G","amount_per_100g":20},
              {"code":"FAT_G","amount_per_100g":2}
            ],
            "servings":[{"label":"1 bowl","quantity":1,"unit":"serving","grams":250}]
          },
          "warnings":["Nutrition is estimated."]
        }"#
        .into()
    }

    async fn service(content: String) -> (FoodDraftService, Arc<RecordingModel>) {
        let model = Arc::new(RecordingModel {
            content,
            requests: Mutex::new(Vec::new()),
        });
        (
            FoodDraftService::new(model.clone(), Arc::new(StaticVocabulary)),
            model,
        )
    }

    #[tokio::test]
    async fn loads_vocabulary_builds_code_owned_request_and_calls_model_once() {
        let (service, model) = service(ready_json()).await;
        let turn = service.draft(request()).await.unwrap();

        assert_eq!(turn.status, DraftStatus::DraftReady);
        let draft = turn.draft.unwrap();
        assert_eq!(draft.categories, vec!["indian"]);
        assert_eq!(
            draft.nutrients[1].amount_per_100g,
            Decimal::new(5_125_679, 6)
        );
        let requests = model.requests.lock().await;
        assert_eq!(requests.len(), 1);
        assert!(
            requests[0]
                .system_prompt
                .contains("SODIUM_MG | Sodium | mg")
        );
        assert!(requests[0].response_schema.contains("additionalProperties"));
    }

    #[tokio::test]
    async fn ready_and_clarification_statuses_must_match_draft_presence() {
        for content in [
            ready_json().replace("\"draft_ready\"", "\"needs_clarification\""),
            r#"{"assistant_message":"How much?","status":"draft_ready","draft":null,"warnings":[]}"#.into(),
        ] {
            let (service, _) = service(content).await;
            assert!(matches!(service.draft(request()).await, Err(AssistantError::InvalidModelResponse)));
        }
    }

    #[tokio::test]
    async fn accepts_a_complete_clarification_without_a_draft() {
        let (service, _) = service(
            r#"{"assistant_message":"How many grams was the bowl?","status":"needs_clarification","draft":null,"warnings":[]}"#.into(),
        )
        .await;

        let turn = service.draft(request()).await.unwrap();
        assert_eq!(turn.status, DraftStatus::NeedsClarification);
        assert!(turn.draft.is_none());
    }

    #[tokio::test]
    async fn rejects_unknown_duplicate_and_missing_required_nutrients() {
        for content in [
            ready_json().replace("\"FAT_G\"", "\"UNKNOWN\""),
            ready_json().replace("\"FAT_G\"", "\"PROTEIN_G\""),
            ready_json().replace(
                ",\n              {\"code\":\"FAT_G\",\"amount_per_100g\":2}",
                "",
            ),
        ] {
            let (service, _) = service(content).await;
            assert!(matches!(
                service.draft(request()).await,
                Err(AssistantError::InvalidModelResponse)
            ));
        }
    }

    #[tokio::test]
    async fn rejects_unknown_units_non_positive_amounts_and_incomplete_defaults() {
        for content in [
            ready_json().replace("\"serving\"", "\"unknown\""),
            ready_json().replace("\"amount_per_100g\":2", "\"amount_per_100g\":-2"),
            ready_json().replace("\"quantity\":1", "\"quantity\":0"),
            ready_json().replace("\"grams\":250", "\"grams\":0"),
            ready_json().replace("\"default_unit\":\"serving\"", "\"default_unit\":null"),
        ] {
            let (service, _) = service(content).await;
            assert!(matches!(
                service.draft(request()).await,
                Err(AssistantError::InvalidModelResponse)
            ));
        }
    }

    #[tokio::test]
    async fn rejects_extra_or_missing_fields_instead_of_accepting_provider_extensions() {
        for content in [
            ready_json().replace("\"warnings\":[", "\"ingredients\":[],\"warnings\":["),
            ready_json().replace("\"brand\":null, ", ""),
            ready_json().replace("\"grams\":250", "\"grams\":250,\"per_serving\":true"),
        ] {
            let (service, _) = service(content).await;
            assert!(matches!(
                service.draft(request()).await,
                Err(AssistantError::InvalidModelResponse)
            ));
        }
    }

    #[tokio::test]
    async fn warns_for_inconsistent_calories_without_mutating_nutrients() {
        let (service, _) =
            service(ready_json().replace("\"amount_per_100g\":120", "\"amount_per_100g\":400"))
                .await;
        let turn = service.draft(request()).await.unwrap();
        let draft = turn.draft.unwrap();
        assert_eq!(draft.nutrients[0].amount_per_100g, Decimal::from(400));
        assert!(
            turn.warnings
                .iter()
                .any(|warning| warning.contains("4/4/9"))
        );
    }

    #[tokio::test]
    async fn rejects_values_beyond_reasonable_product_limits() {
        for content in [
            ready_json().replace("\"amount_per_100g\":120", "\"amount_per_100g\":100001"),
            ready_json().replace("\"grams\":250", "\"grams\":100001"),
            ready_json().replace("\"quantity\":1", "\"quantity\":10001"),
        ] {
            let (service, _) = service(content).await;
            assert!(matches!(
                service.draft(request()).await,
                Err(AssistantError::InvalidModelResponse)
            ));
        }
    }

    #[tokio::test]
    async fn rejects_nutrients_that_exceed_their_live_unit_physical_limit() {
        for content in [
            ready_json().replace("\"amount_per_100g\":5.1256789", "\"amount_per_100g\":101"),
            ready_json().replace("\"amount_per_100g\":120", "\"amount_per_100g\":1001"),
            ready_json().replace(
                "{\"code\":\"FAT_G\",\"amount_per_100g\":2}",
                "{\"code\":\"FAT_G\",\"amount_per_100g\":2},{\"code\":\"SODIUM_MG\",\"amount_per_100g\":100001}",
            ),
            ready_json().replace(
                "{\"code\":\"FAT_G\",\"amount_per_100g\":2}",
                "{\"code\":\"FAT_G\",\"amount_per_100g\":2},{\"code\":\"VITAMIN_B12_UG\",\"amount_per_100g\":100000001}",
            ),
        ] {
            let (service, _) = service(content).await;
            assert!(matches!(
                service.draft(request()).await,
                Err(AssistantError::InvalidModelResponse)
            ));
        }
    }

    #[tokio::test]
    async fn calorie_warning_never_exceeds_the_warning_bound_or_duplicates_provider_text() {
        let mut at_capacity: serde_json::Value = serde_json::from_str(&ready_json()).unwrap();
        at_capacity["draft"]["nutrients"][0]["amount_per_100g"] = serde_json::json!(400);
        at_capacity["warnings"] = serde_json::json!(
            (0..MAX_WARNINGS)
                .map(|index| format!("Provider warning {index}"))
                .collect::<Vec<_>>()
        );
        let (capacity_service, _) = service(serde_json::to_string(&at_capacity).unwrap()).await;
        assert_eq!(
            capacity_service
                .draft(request())
                .await
                .unwrap()
                .warnings
                .len(),
            MAX_WARNINGS
        );

        let duplicate = ready_json()
            .replace("\"amount_per_100g\":120", "\"amount_per_100g\":400")
            .replace(
                "\"warnings\":[\"Nutrition is estimated.\"]",
                &format!("\"warnings\":[\"{CALORIE_CONSISTENCY_WARNING}\"]"),
            );
        let (service, _) = service(duplicate).await;
        let warnings = service.draft(request()).await.unwrap().warnings;
        assert_eq!(warnings, vec![CALORIE_CONSISTENCY_WARNING]);
    }

    #[tokio::test]
    async fn rejects_categories_beyond_the_form_limit() {
        let too_long_category = "a".repeat(MAX_CATEGORY_CHARS + 1);
        let (service, _) =
            service(ready_json().replace("\" Indian \"", &format!("\"{too_long_category}\"")))
                .await;

        assert!(matches!(
            service.draft(request()).await,
            Err(AssistantError::InvalidModelResponse)
        ));
    }
}
