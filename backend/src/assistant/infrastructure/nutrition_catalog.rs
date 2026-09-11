use std::sync::Arc;

use async_trait::async_trait;

use crate::assistant::application::{
    AssistantError, FoodDraftAcceptancePort, FoodVocabulary, FoodVocabularyPort, SupportedNutrient,
    SupportedUnit,
};
use crate::assistant::domain::FoodDraft;
use crate::nutrition::catalog::application::{CatalogService, CustomFoodInput};
use crate::nutrition::catalog::domain::{ProductNutrientInput, ProductServingInput};
use crate::nutrition::error::NutritionError;

/// Read-only anti-corruption adapter from nutrition reference data to the
/// bounded vocabulary supplied to the model.
#[derive(Clone)]
pub struct NutritionCatalogVocabularyAdapter {
    catalog: Arc<CatalogService>,
}

impl NutritionCatalogVocabularyAdapter {
    pub fn new(catalog: Arc<CatalogService>) -> Self {
        Self { catalog }
    }
}

#[async_trait]
impl FoodVocabularyPort for NutritionCatalogVocabularyAdapter {
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
impl FoodDraftAcceptancePort for NutritionCatalogVocabularyAdapter {
    async fn validate_draft(&self, draft: &FoodDraft) -> Result<(), AssistantError> {
        self.catalog
            .validate_custom_food_draft(CustomFoodInput {
                name: draft.name().to_owned(),
                brand: draft.brand().map(str::to_owned),
                categories: draft.categories().to_vec(),
                default_quantity: draft.default_quantity(),
                default_unit: draft.default_unit().map(str::to_owned),
                nutrients: draft
                    .nutrients()
                    .iter()
                    .map(|nutrient| ProductNutrientInput {
                        code: nutrient.code().to_owned(),
                        amount_per_100g: nutrient.amount_per_100g(),
                        source: None,
                        confidence: None,
                    })
                    .collect(),
                servings: draft
                    .servings()
                    .iter()
                    .map(|serving| ProductServingInput {
                        unit: serving.unit().to_owned(),
                        grams_per_unit: serving.grams_per_unit(),
                    })
                    .collect(),
            })
            .await
            .map_err(|error| match error {
                NutritionError::Validation(_) => AssistantError::InvalidModelResponse,
                _ => AssistantError::Internal,
            })
    }
}
