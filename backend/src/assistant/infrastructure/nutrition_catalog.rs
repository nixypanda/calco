use std::sync::Arc;

use async_trait::async_trait;

use crate::assistant::application::{
    FoodVocabulary, FoodVocabularyPort, SupportedNutrient, SupportedUnit,
};
use crate::assistant::domain::AssistantError;
use crate::nutrition::catalog::application::CatalogService;

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
        let default_codes = self.catalog.custom_food_default_unit_codes();
        let default_units = serving_units
            .iter()
            .filter(|unit| default_codes.contains(&unit.code))
            .cloned()
            .collect();
        Ok(FoodVocabulary {
            nutrients,
            default_units,
            serving_units,
            required_nutrient_codes: self.catalog.required_custom_food_nutrient_codes(),
        })
    }
}
