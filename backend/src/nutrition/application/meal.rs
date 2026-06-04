use chrono::Utc;
use rust_decimal::Decimal;
use std::sync::Arc;
use uuid::Uuid;

use crate::nutrition::domain::calculation::Quantity;
use crate::nutrition::domain::catalog::*;
use crate::nutrition::domain::meal::*;
use crate::nutrition::domain::units::UnitConverter;

pub struct CreateMealInput {
    pub user_id: Uuid,
    pub name: String,
    pub notes: Option<String>,
    pub total_quantity_amount: Option<Decimal>,
    pub total_quantity_unit: Option<UnitCode>,
    pub components: Vec<CreateMealComponentInput>,
}

pub struct CreateMealComponentInput {
    pub item: MealComponentItem,
    pub quantity: Quantity,
}

pub struct UpdateMealInput {
    pub name: Option<String>,
    pub notes: Option<Option<String>>,
    pub total_quantity_amount: Option<Option<Decimal>>,
    pub total_quantity_unit: Option<Option<UnitCode>>,
    pub components: Option<Vec<CreateMealComponentInput>>,
}

pub struct MealNutritionOutput {
    pub meal_id: Uuid,
    pub quantity_amount: Decimal,
    pub quantity_unit: String,
    pub nutrients: Vec<MealNutrientEntry>,
}

pub struct MealNutrientEntry {
    pub code: String,
    pub amount: Decimal,
    pub unit: String,
}

#[derive(Clone)]
pub struct MealServices {
    pub meal_repo: Arc<dyn MealRepository>,
    pub product_repo: Arc<dyn ProductRepository>,
    pub unit_converter: Arc<UnitConverter>,
}

impl MealServices {
    pub fn new(
        meal_repo: Arc<dyn MealRepository>,
        product_repo: Arc<dyn ProductRepository>,
        unit_converter: Arc<UnitConverter>,
    ) -> Self {
        Self {
            meal_repo,
            product_repo,
            unit_converter,
        }
    }

    pub async fn create_meal(&self, input: CreateMealInput) -> Result<Meal, NutritionError> {
        let components = self.build_components(input.components).await?;

        let now = Utc::now();
        let meal = Meal::create(
            input.user_id,
            input.name,
            input.notes,
            input.total_quantity_amount,
            input.total_quantity_unit,
            components,
            now,
        )?;

        self.meal_repo.create(&meal).await?;
        Ok(meal)
    }

    pub async fn update_meal(
        &self,
        id: MealId,
        user_id: Uuid,
        input: UpdateMealInput,
    ) -> Result<Meal, NutritionError> {
        let existing = self
            .meal_repo
            .find_by_id(id)
            .await?
            .ok_or_else(|| NutritionError::NotFound("meal not found".into()))?;

        if !existing.is_owned_by(user_id) {
            return Err(NutritionError::Forbidden("not your meal".into()));
        }

        let components = match input.components {
            Some(components) => Some(self.build_components(components).await?),
            None => None,
        };

        let updated = existing.update(
            input.name,
            input.notes,
            input.total_quantity_amount,
            input.total_quantity_unit,
            components,
            Utc::now(),
        )?;

        self.meal_repo.update(&updated).await?;
        Ok(updated)
    }

    pub async fn delete_meal(&self, id: MealId, user_id: Uuid) -> Result<(), NutritionError> {
        let existing = self
            .meal_repo
            .find_by_id(id)
            .await?
            .ok_or_else(|| NutritionError::NotFound("meal not found".into()))?;

        if !existing.is_owned_by(user_id) {
            return Err(NutritionError::Forbidden("not your meal".into()));
        }

        self.meal_repo.delete(id).await
    }

    pub async fn get_meal_nutrients(
        &self,
        id: MealId,
        quantity: Quantity,
    ) -> Result<MealNutritionOutput, NutritionError> {
        let meal = self
            .meal_repo
            .find_by_id(id)
            .await?
            .ok_or_else(|| NutritionError::NotFound("meal not found".into()))?;

        let products = crate::nutrition::application::food_log::load_meal_products(
            &meal,
            self.product_repo.as_ref(),
        )
        .await?;
        let calculated = meal
            .nutrition_for(&quantity, &products, &self.unit_converter)
            .map_err(NutritionError::Validation)?;
        let nutrients: Vec<MealNutrientEntry> = calculated
            .amounts
            .into_iter()
            .map(|amount| MealNutrientEntry {
                code: amount.nutrient_code.0,
                amount: amount.amount,
                unit: amount.unit.0,
            })
            .collect();

        let (quantity_amount, quantity_unit) = quantity.into_parts();
        Ok(MealNutritionOutput {
            meal_id: id.0,
            quantity_amount,
            quantity_unit: quantity_unit.0,
            nutrients,
        })
    }

    async fn build_components(
        &self,
        inputs: Vec<CreateMealComponentInput>,
    ) -> Result<Vec<MealComponent>, NutritionError> {
        let product_ids: Vec<ProductId> = inputs
            .iter()
            .map(|i| match &i.item {
                MealComponentItem::Product(id) => *id,
            })
            .collect();
        let existing = self.product_repo.existing_ids(&product_ids).await?;
        for id in &product_ids {
            if !existing.contains(id) {
                return Err(NutritionError::NotFound(format!(
                    "product {} not found",
                    id.0
                )));
            }
        }

        inputs
            .into_iter()
            .map(|input| MealComponent::new(input.item, input.quantity))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use std::sync::Mutex;

    struct MockMealRepo {
        meals: Mutex<Vec<Meal>>,
    }

    impl MockMealRepo {
        fn new() -> Self {
            Self {
                meals: Mutex::new(vec![]),
            }
        }
    }

    #[async_trait]
    impl MealRepository for MockMealRepo {
        async fn create(&self, meal: &Meal) -> Result<(), NutritionError> {
            self.meals.lock().unwrap().push(meal.clone());
            Ok(())
        }

        async fn find_by_id(&self, id: MealId) -> Result<Option<Meal>, NutritionError> {
            let meals = self.meals.lock().unwrap();
            Ok(meals.iter().find(|m| m.id == id).cloned())
        }

        async fn list_by_user_id(&self, user_id: Uuid) -> Result<Vec<Meal>, NutritionError> {
            let meals = self.meals.lock().unwrap();
            Ok(meals
                .iter()
                .filter(|m| m.user_id == user_id)
                .cloned()
                .collect())
        }

        async fn update(&self, meal: &Meal) -> Result<(), NutritionError> {
            let mut meals = self.meals.lock().unwrap();
            if let Some(existing) = meals.iter_mut().find(|m| m.id == meal.id) {
                *existing = meal.clone();
                Ok(())
            } else {
                Err(NutritionError::NotFound("not found".into()))
            }
        }

        async fn delete(&self, id: MealId) -> Result<(), NutritionError> {
            let mut meals = self.meals.lock().unwrap();
            let idx = meals
                .iter()
                .position(|m| m.id == id)
                .ok_or_else(|| NutritionError::NotFound("not found".into()))?;
            meals.remove(idx);
            Ok(())
        }
    }

    struct MockProductRepo {
        product: Option<Product>,
    }

    impl MockProductRepo {
        fn with_product(product: Product) -> Self {
            Self {
                product: Some(product),
            }
        }

        fn empty() -> Self {
            Self { product: None }
        }
    }

    #[async_trait]
    impl ProductRepository for MockProductRepo {
        async fn find_by_id(&self, _id: ProductId) -> Result<Option<Product>, NutritionError> {
            Ok(self.product.clone())
        }

        async fn existing_ids(
            &self,
            ids: &[ProductId],
        ) -> Result<std::collections::HashSet<ProductId>, NutritionError> {
            if self.product.is_some() {
                Ok(ids.iter().copied().collect())
            } else {
                Ok(std::collections::HashSet::new())
            }
        }

        async fn search(
            &self,
            _query: ProductSearchSpec,
            _user_id: Option<Uuid>,
        ) -> Result<Vec<Product>, NutritionError> {
            unimplemented!("not used in test")
        }

        async fn list_categories(
            &self,
            _query: &str,
            _user_id: Option<Uuid>,
            _limit: i64,
        ) -> Result<Vec<CategorySuggestion>, NutritionError> {
            unimplemented!("not used in test")
        }

        async fn find_by_barcode(&self, _barcode: &str) -> Result<Option<Product>, NutritionError> {
            unimplemented!("not used in test")
        }

        async fn create(&self, _product: &Product) -> Result<(), NutritionError> {
            unimplemented!("not used in test")
        }

        async fn update(&self, _product: &Product) -> Result<(), NutritionError> {
            unimplemented!("not used in test")
        }

        async fn delete(&self, _id: ProductId) -> Result<(), NutritionError> {
            unimplemented!("not used in test")
        }
    }

    fn sample_product() -> Product {
        Product {
            id: ProductId(Uuid::nil()),
            source: Source::User,
            source_id: None,
            user_id: None,
            visibility: ProductVisibility::UserPrivate,
            barcode: None,
            name: ProductName("Test Food".to_string()),
            brand: None,
            categories: vec![],
            default_quantity: Some(Decimal::new(100, 0)),
            default_unit: Some(UnitCode("g".to_string())),
            serving_size_g: Some(Decimal::new(100, 0)),
            nutrients: vec![ProductNutrient {
                nutrient_code: NutrientCode("ENERGY_KCAL".to_string()),
                amount_per_100g: AmountPer100g::new(Decimal::new(100, 0)).unwrap(),
                unit: UnitCode("kcal".to_string()),
                source: None,
                confidence: None,
            }],
            servings: vec![],
            created_at: Utc::now(),
            updated_at: Utc::now(),
        }
    }

    fn make_services(product: Option<Product>) -> MealServices {
        let meal_repo = Arc::new(MockMealRepo::new()) as Arc<dyn MealRepository>;
        let product_repo = match product {
            Some(p) => Arc::new(MockProductRepo::with_product(p)) as Arc<dyn ProductRepository>,
            None => Arc::new(MockProductRepo::empty()) as Arc<dyn ProductRepository>,
        };
        let unit_converter = Arc::new(UnitConverter::from_entries([
            ("g".to_string(), Decimal::new(1, 0)),
            ("kg".to_string(), Decimal::new(1000, 0)),
        ]));
        MealServices::new(meal_repo, product_repo, unit_converter)
    }

    fn sample_component() -> CreateMealComponentInput {
        CreateMealComponentInput {
            item: MealComponentItem::Product(ProductId(Uuid::nil())),
            quantity: Quantity::new(Decimal::new(100, 0), UnitCode("g".to_string())).unwrap(),
        }
    }

    #[tokio::test]
    async fn test_create_meal_success() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let result = services
            .create_meal(CreateMealInput {
                user_id,
                name: "Test Meal".to_string(),
                notes: None,
                total_quantity_amount: None,
                total_quantity_unit: None,
                components: vec![sample_component()],
            })
            .await;

        assert!(result.is_ok());
        let meal = result.unwrap();
        assert_eq!(meal.user_id, user_id);
        assert_eq!(meal.name.0, "Test Meal");
        assert_eq!(meal.components.len(), 1);
    }

    #[tokio::test]
    async fn test_create_meal_empty_name() {
        let services = make_services(Some(sample_product()));

        let result = services
            .create_meal(CreateMealInput {
                user_id: Uuid::new_v4(),
                name: "".to_string(),
                notes: None,
                total_quantity_amount: None,
                total_quantity_unit: None,
                components: vec![sample_component()],
            })
            .await;

        assert!(result.is_err());
        match result.unwrap_err() {
            NutritionError::Validation(_) => {}
            _ => panic!("expected Validation"),
        }
    }

    #[tokio::test]
    async fn test_create_meal_no_components() {
        let services = make_services(Some(sample_product()));

        let result = services
            .create_meal(CreateMealInput {
                user_id: Uuid::new_v4(),
                name: "Empty Meal".to_string(),
                notes: None,
                total_quantity_amount: None,
                total_quantity_unit: None,
                components: vec![],
            })
            .await;

        assert!(result.is_err());
        match result.unwrap_err() {
            NutritionError::Validation(_) => {}
            _ => panic!("expected Validation"),
        }
    }

    #[tokio::test]
    async fn test_create_meal_product_not_found() {
        let services = make_services(None);

        let result = services
            .create_meal(CreateMealInput {
                user_id: Uuid::new_v4(),
                name: "Test Meal".to_string(),
                notes: None,
                total_quantity_amount: None,
                total_quantity_unit: None,
                components: vec![sample_component()],
            })
            .await;

        assert!(result.is_err());
        match result.unwrap_err() {
            NutritionError::NotFound(_) => {}
            _ => panic!("expected NotFound"),
        }
    }

    #[tokio::test]
    async fn test_update_meal_success() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let created = services
            .create_meal(CreateMealInput {
                user_id,
                name: "Original".to_string(),
                notes: None,
                total_quantity_amount: None,
                total_quantity_unit: None,
                components: vec![sample_component()],
            })
            .await
            .unwrap();

        let updated = services
            .update_meal(
                created.id,
                user_id,
                UpdateMealInput {
                    name: Some("Updated".to_string()),
                    notes: Some(Some("new notes".to_string())),
                    total_quantity_amount: None,
                    total_quantity_unit: None,
                    components: None,
                },
            )
            .await
            .unwrap();

        assert_eq!(updated.name.0, "Updated");
        assert_eq!(
            updated.notes.as_ref().map(|n| n.0.as_str()),
            Some("new notes")
        );
    }

    #[tokio::test]
    async fn test_update_meal_can_clear_optional_fields() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let created = services
            .create_meal(CreateMealInput {
                user_id,
                name: "Original".to_string(),
                notes: Some("clear me".to_string()),
                total_quantity_amount: Some(Decimal::new(100, 0)),
                total_quantity_unit: Some(UnitCode("g".to_string())),
                components: vec![sample_component()],
            })
            .await
            .unwrap();

        let updated = services
            .update_meal(
                created.id,
                user_id,
                UpdateMealInput {
                    name: None,
                    notes: Some(None),
                    total_quantity_amount: Some(None),
                    total_quantity_unit: Some(None),
                    components: None,
                },
            )
            .await
            .unwrap();

        assert_eq!(updated.notes, None);
        assert_eq!(updated.total_quantity_amount, None);
        assert_eq!(updated.total_quantity_unit, None);
    }

    #[tokio::test]
    async fn test_update_meal_forbidden() {
        let services = make_services(Some(sample_product()));
        let owner = Uuid::new_v4();
        let other = Uuid::new_v4();

        let created = services
            .create_meal(CreateMealInput {
                user_id: owner,
                name: "My Meal".to_string(),
                notes: None,
                total_quantity_amount: None,
                total_quantity_unit: None,
                components: vec![sample_component()],
            })
            .await
            .unwrap();

        let result = services
            .update_meal(
                created.id,
                other,
                UpdateMealInput {
                    name: None,
                    notes: None,
                    total_quantity_amount: None,
                    total_quantity_unit: None,
                    components: None,
                },
            )
            .await;

        assert!(result.is_err());
        match result.unwrap_err() {
            NutritionError::Forbidden(_) => {}
            _ => panic!("expected Forbidden"),
        }
    }

    #[tokio::test]
    async fn test_delete_meal_success() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let created = services
            .create_meal(CreateMealInput {
                user_id,
                name: "To Delete".to_string(),
                notes: None,
                total_quantity_amount: None,
                total_quantity_unit: None,
                components: vec![sample_component()],
            })
            .await
            .unwrap();

        assert!(services.delete_meal(created.id, user_id).await.is_ok());
        let still_there = services.meal_repo.find_by_id(created.id).await.unwrap();
        assert!(still_there.is_none());
    }

    #[tokio::test]
    async fn test_delete_meal_forbidden() {
        let services = make_services(Some(sample_product()));
        let owner = Uuid::new_v4();
        let other = Uuid::new_v4();

        let created = services
            .create_meal(CreateMealInput {
                user_id: owner,
                name: "My Meal".to_string(),
                notes: None,
                total_quantity_amount: None,
                total_quantity_unit: None,
                components: vec![sample_component()],
            })
            .await
            .unwrap();

        let result = services.delete_meal(created.id, other).await;
        assert!(result.is_err());
        match result.unwrap_err() {
            NutritionError::Forbidden(_) => {}
            _ => panic!("expected Forbidden"),
        }
    }

    #[tokio::test]
    async fn test_delete_meal_not_found() {
        let services = make_services(Some(sample_product()));
        let result = services.delete_meal(MealId::new(), Uuid::new_v4()).await;
        assert!(result.is_err());
        match result.unwrap_err() {
            NutritionError::NotFound(_) => {}
            _ => panic!("expected NotFound"),
        }
    }

    #[tokio::test]
    async fn test_get_meal_nutrients_calculates_sum() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let meal = services
            .create_meal(CreateMealInput {
                user_id,
                name: "Double Food".to_string(),
                notes: None,
                total_quantity_amount: None,
                total_quantity_unit: None,
                components: vec![
                    sample_component(),
                    CreateMealComponentInput {
                        item: MealComponentItem::Product(ProductId(Uuid::nil())),
                        quantity: Quantity::new(Decimal::new(200, 0), UnitCode("g".to_string()))
                            .unwrap(),
                    },
                ],
            })
            .await
            .unwrap();

        let nutrition = services
            .get_meal_nutrients(
                meal.id,
                Quantity::new(Decimal::new(150, 0), UnitCode("g".to_string())).unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(nutrition.meal_id, meal.id.0);
        assert_eq!(nutrition.nutrients.len(), 1);
        assert_eq!(nutrition.nutrients[0].code, "ENERGY_KCAL");

        let product_energy_100g = Decimal::new(100, 0);
        let component1_energy = product_energy_100g * Decimal::new(100, 0) / Decimal::new(100, 0);
        let component2_energy = product_energy_100g * Decimal::new(200, 0) / Decimal::new(100, 0);
        let total_energy = component1_energy + component2_energy;
        let total_grams = Decimal::new(300, 0);
        let scaled = total_energy * Decimal::new(150, 0) / total_grams;
        assert_eq!(nutrition.nutrients[0].amount, scaled);
    }
}
