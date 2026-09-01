use std::sync::Arc;

use async_trait::async_trait;

use crate::assistant::application::{
    FoodVocabulary, FoodVocabularyPort, SupportedNutrient, SupportedUnit,
};
use crate::assistant::domain::AssistantError;
use crate::nutrition::catalog::application::CatalogService;

/// Translates catalog reference data into the assistant's vocabulary model.
///
/// The adapter owns the boundary conversion. It has access only to catalog
/// application reads, never to nutrition repositories or catalog writes.
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
            .map(|nutrient| SupportedNutrient {
                code: nutrient.code.0,
                name: nutrient.name,
                unit: nutrient.unit.0,
            })
            .collect();
        let units = self
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

        Ok(FoodVocabulary {
            nutrients,
            units,
            required_nutrient_codes: self.catalog.required_custom_food_nutrient_codes(),
        })
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;
    use std::sync::Arc;

    use async_trait::async_trait;
    use rust_decimal::Decimal;
    use uuid::Uuid;

    use crate::assistant::application::FoodVocabularyPort;
    use crate::nutrition::catalog::application::CatalogService;
    use crate::nutrition::catalog::domain::units::UnitConverter;
    use crate::nutrition::catalog::domain::{
        CategorySuggestion, Nutrient, NutrientCode, NutrientRepository, NutritionError, Product,
        ProductId, ProductRepository, ProductSearchScope, ProductSearchSpec, UnitCode,
        UnitRepository,
    };

    use super::NutritionCatalogVocabularyAdapter;

    struct UnusedProductRepository;

    #[async_trait]
    impl ProductRepository for UnusedProductRepository {
        async fn search(
            &self,
            _spec: ProductSearchSpec,
            _scope: ProductSearchScope,
            _user_id: Option<Uuid>,
        ) -> Result<Vec<Product>, NutritionError> {
            unreachable!("vocabulary reads do not query products")
        }

        async fn list_categories(
            &self,
            _query: &str,
            _user_id: Option<Uuid>,
            _limit: i64,
        ) -> Result<Vec<CategorySuggestion>, NutritionError> {
            unreachable!("vocabulary reads do not query products")
        }

        async fn find_by_id(&self, _id: ProductId) -> Result<Option<Product>, NutritionError> {
            unreachable!("vocabulary reads do not query products")
        }

        async fn existing_ids(
            &self,
            _ids: &[ProductId],
        ) -> Result<HashSet<ProductId>, NutritionError> {
            unreachable!("vocabulary reads do not query products")
        }

        async fn find_by_barcode(
            &self,
            _barcode: &str,
            _user_id: Option<Uuid>,
        ) -> Result<Option<Product>, NutritionError> {
            unreachable!("vocabulary reads do not query products")
        }

        async fn list_custom_foods(&self) -> Result<Vec<Product>, NutritionError> {
            unreachable!("vocabulary reads do not query products")
        }

        async fn create(&self, _product: &Product) -> Result<(), NutritionError> {
            unreachable!("vocabulary reads do not query products")
        }

        async fn update(&self, _product: &Product) -> Result<(), NutritionError> {
            unreachable!("vocabulary reads do not query products")
        }

        async fn delete(&self, _id: ProductId) -> Result<(), NutritionError> {
            unreachable!("vocabulary reads do not query products")
        }
    }

    struct StaticNutrientRepository {
        nutrients: Vec<Nutrient>,
        fail_list: bool,
    }

    #[async_trait]
    impl NutrientRepository for StaticNutrientRepository {
        async fn list_all(&self) -> Result<Vec<Nutrient>, NutritionError> {
            if self.fail_list {
                return Err(NutritionError::Internal("catalog unavailable".into()));
            }
            Ok(self.nutrients.clone())
        }

        async fn find_by_code(&self, code: &str) -> Result<Option<Nutrient>, NutritionError> {
            Ok(self
                .nutrients
                .iter()
                .find(|nutrient| nutrient.code.0 == code)
                .cloned())
        }
    }

    struct StaticUnitRepository {
        units: Vec<(UnitCode, String, String)>,
    }

    #[async_trait]
    impl UnitRepository for StaticUnitRepository {
        async fn list_all(&self) -> Result<Vec<(UnitCode, String, String)>, NutritionError> {
            Ok(self.units.clone())
        }

        async fn list_mass_factors(&self) -> Result<Vec<(String, Decimal)>, NutritionError> {
            Ok(vec![("g".into(), Decimal::ONE)])
        }
    }

    fn adapter(fail_nutrient_list: bool) -> NutritionCatalogVocabularyAdapter {
        let catalog = CatalogService::new(
            Arc::new(UnusedProductRepository),
            Arc::new(StaticNutrientRepository {
                nutrients: vec![Nutrient {
                    code: NutrientCode("PROTEIN_G".into()),
                    name: "Protein".into(),
                    unit: UnitCode("g".into()),
                    category: "macro".into(),
                }],
                fail_list: fail_nutrient_list,
            }),
            Arc::new(StaticUnitRepository {
                units: vec![
                    (UnitCode("g".into()), "Gram".into(), "mass".into()),
                    (UnitCode("piece".into()), "Piece".into(), "count".into()),
                ],
            }),
            Arc::new(UnitConverter::from_entries([("g".into(), Decimal::ONE)])),
        );

        NutritionCatalogVocabularyAdapter::new(Arc::new(catalog))
    }

    #[tokio::test]
    async fn translates_catalog_reference_data_into_assistant_vocabulary() {
        let vocabulary = adapter(false).supported_vocabulary().await.unwrap();

        assert_eq!(
            vocabulary.nutrients,
            vec![crate::assistant::application::SupportedNutrient {
                code: "PROTEIN_G".into(),
                name: "Protein".into(),
                unit: "g".into(),
            }]
        );
        assert_eq!(
            vocabulary.units,
            vec![
                crate::assistant::application::SupportedUnit {
                    code: "g".into(),
                    name: "Gram".into(),
                    kind: "mass".into(),
                },
                crate::assistant::application::SupportedUnit {
                    code: "piece".into(),
                    name: "Piece".into(),
                    kind: "count".into(),
                },
            ]
        );
        assert_eq!(
            vocabulary.required_nutrient_codes,
            vec!["ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G"]
        );
    }

    #[tokio::test]
    async fn maps_catalog_read_failures_to_an_opaque_assistant_error() {
        assert!(matches!(
            adapter(true).supported_vocabulary().await,
            Err(crate::assistant::domain::AssistantError::Internal)
        ));
    }
}
