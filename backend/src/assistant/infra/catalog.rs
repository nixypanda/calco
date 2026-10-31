use std::sync::Arc;

use async_trait::async_trait;

use crate::assistant::app::{
    AssistantError, FoodDraftAcceptancePort, FoodVocabulary, FoodVocabularyPort, SupportedNutrient,
    SupportedUnit,
};
use crate::assistant::domain::FoodDraft;
use crate::catalog::app::CatalogService;
use crate::catalog::domain::{CustomProductBuilder, ProductNutrientInput, ProductServingInput};
use crate::catalog::error::CatalogError;

/// Read-only anti-corruption adapter from nutrition reference data to the
/// bounded vocabulary supplied to the model.
#[derive(Clone)]
pub struct CatalogVocabularyAdapter {
    catalog: Arc<CatalogService>,
}

impl CatalogVocabularyAdapter {
    pub fn new(catalog: Arc<CatalogService>) -> Self {
        Self { catalog }
    }
}

#[async_trait]
impl FoodVocabularyPort for CatalogVocabularyAdapter {
    async fn supported_vocabulary(&self) -> Result<FoodVocabulary, AssistantError> {
        let nutrients = self
            .catalog
            .list_nutrients()
            .await
            .map_err(|_| AssistantError::Internal)?
            .into_iter()
            .map(|value| SupportedNutrient {
                code: value.code.0,
                name: value.name,
                unit: value.unit.0,
            })
            .collect();
        let serving_units: Vec<SupportedUnit> = self
            .catalog
            .list_units()
            .await
            .map_err(|_| AssistantError::Internal)?
            .into_iter()
            .map(|(code, name, kind)| SupportedUnit {
                code: code.0,
                name,
                kind,
            })
            .collect();
        let default_units = serving_units.clone();
        Ok(FoodVocabulary {
            nutrients,
            default_units,
            serving_units,
            required_nutrient_codes: self.catalog.required_custom_food_nutrient_codes(),
        })
    }
}

#[async_trait]
impl FoodDraftAcceptancePort for CatalogVocabularyAdapter {
    async fn validate_draft(&self, draft: &FoodDraft) -> Result<(), AssistantError> {
        let input = CustomProductBuilder::new(draft.name())
            .brand(draft.brand().map(str::to_owned))
            .categories(draft.categories().to_vec())
            .optional_default_portion(
                draft.default_quantity(),
                draft.default_unit().map(str::to_owned),
            )
            .map_err(|_| AssistantError::InvalidModelResponse)?
            .nutrients(
                draft
                    .nutrients()
                    .iter()
                    .map(|nutrient| ProductNutrientInput {
                        code: nutrient.code().to_owned(),
                        amount_per_100g: nutrient.amount_per_100g(),
                        source: None,
                        confidence: None,
                    })
                    .collect(),
            )
            .servings(
                draft
                    .servings()
                    .iter()
                    .map(|serving| ProductServingInput {
                        unit: serving.unit().to_owned(),
                        grams_per_unit: serving.grams_per_unit(),
                    })
                    .collect(),
            );
        self.catalog
            .validate_custom_food_draft(input)
            .await
            .map_err(|error| {
                tracing::error!(
                    draft = ?draft,
                    error = %error,
                    "assistant response failed catalog validation"
                );
                match error {
                    CatalogError::Validation(_) => AssistantError::InvalidModelResponse,
                    _ => AssistantError::Internal,
                }
            })
    }
}
