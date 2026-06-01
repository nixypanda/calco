use chrono::Utc;
use rust_decimal::Decimal;
use std::sync::Arc;
use uuid::Uuid;

use crate::domain::catalog::*;
use crate::domain::meal::*;
use crate::domain::nutrition::Quantity;
use crate::domain::units::UnitConverter;

pub struct CreateMealInput {
    pub user_id: Uuid,
    pub name: String,
    pub notes: Option<String>,
    pub total_quantity_amount: Option<Decimal>,
    pub total_quantity_unit: Option<String>,
    pub components: Vec<CreateMealComponentInput>,
}

pub struct CreateMealComponentInput {
    pub item_type: String,
    pub item_id: Uuid,
    pub quantity_amount: Decimal,
    pub quantity_unit: String,
}

pub struct UpdateMealInput {
    pub name: Option<String>,
    pub notes: Option<Option<String>>,
    pub total_quantity_amount: Option<Option<Decimal>>,
    pub total_quantity_unit: Option<Option<String>>,
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
    pub product_lookup: Arc<dyn MealProductLookup>,
    pub unit_converter: Arc<UnitConverter>,
}

impl MealServices {
    pub fn new(
        meal_repo: Arc<dyn MealRepository>,
        product_lookup: Arc<dyn MealProductLookup>,
        unit_converter: Arc<UnitConverter>,
    ) -> Self {
        Self {
            meal_repo,
            product_lookup,
            unit_converter,
        }
    }

    pub async fn create_meal(&self, input: CreateMealInput) -> Result<Meal, MealError> {
        let components = self.build_components(input.components).await?;

        let now = Utc::now();
        let meal = Meal::create(
            input.user_id,
            input.name,
            input.notes,
            input.total_quantity_amount,
            input.total_quantity_unit.map(UnitCode),
            components,
            now,
        )?;

        self.meal_repo.create(&meal).await?;
        Ok(meal)
    }

    pub async fn get_meal(&self, id: MealId) -> Result<Meal, MealError> {
        self.meal_repo
            .find_by_id(id)
            .await?
            .ok_or_else(|| MealError::NotFound("meal not found".into()))
    }

    pub async fn list_meals(&self, user_id: Uuid) -> Result<Vec<Meal>, MealError> {
        self.meal_repo.find_by_user(user_id).await
    }

    pub async fn update_meal(
        &self,
        id: MealId,
        user_id: Uuid,
        input: UpdateMealInput,
    ) -> Result<Meal, MealError> {
        let existing = self
            .meal_repo
            .find_by_id(id)
            .await?
            .ok_or_else(|| MealError::NotFound("meal not found".into()))?;

        if !existing.is_owned_by(user_id) {
            return Err(MealError::Forbidden("not your meal".into()));
        }

        let components = match input.components {
            Some(components) => Some(self.build_components(components).await?),
            None => None,
        };

        let updated = existing.update(
            input.name,
            input.notes,
            input.total_quantity_amount,
            input.total_quantity_unit.map(|opt| opt.map(UnitCode)),
            components,
            Utc::now(),
        )?;

        self.meal_repo.update(&updated).await?;
        Ok(updated)
    }

    pub async fn delete_meal(&self, id: MealId, user_id: Uuid) -> Result<(), MealError> {
        let existing = self
            .meal_repo
            .find_by_id(id)
            .await?
            .ok_or_else(|| MealError::NotFound("meal not found".into()))?;

        if !existing.is_owned_by(user_id) {
            return Err(MealError::Forbidden("not your meal".into()));
        }

        self.meal_repo.delete(id).await
    }

    pub async fn get_meal_nutrients(
        &self,
        id: MealId,
        quantity_amount: Decimal,
        quantity_unit: String,
    ) -> Result<MealNutritionOutput, MealError> {
        let meal = self
            .meal_repo
            .find_by_id(id)
            .await?
            .ok_or_else(|| MealError::NotFound("meal not found".into()))?;

        let products = self.load_meal_products(&meal).await?;
        let requested_quantity = Quantity::new(quantity_amount, UnitCode(quantity_unit.clone()));
        let calculated = meal
            .nutrition_for(&requested_quantity, &products, &self.unit_converter)
            .map_err(MealError::Validation)?;
        let nutrients: Vec<MealNutrientEntry> = calculated
            .amounts
            .into_iter()
            .map(|amount| MealNutrientEntry {
                code: amount.nutrient_code.0,
                amount: amount.amount,
                unit: amount.unit.0,
            })
            .collect();

        Ok(MealNutritionOutput {
            meal_id: id.0,
            quantity_amount,
            quantity_unit,
            nutrients,
        })
    }

    async fn build_components(
        &self,
        inputs: Vec<CreateMealComponentInput>,
    ) -> Result<Vec<MealComponent>, MealError> {
        let mut components = Vec::with_capacity(inputs.len());
        for input in inputs {
            let item = MealComponentItem::parse(&input.item_type, input.item_id)?;
            match &item {
                MealComponentItem::Product(product_id) => {
                    self.product_lookup
                        .find_by_id(*product_id)
                        .await?
                        .ok_or_else(|| {
                            MealError::NotFound(format!("product {} not found", input.item_id))
                        })?;
                }
            }
            components.push(MealComponent::new(
                item,
                input.quantity_amount,
                UnitCode(input.quantity_unit),
            )?);
        }
        Ok(components)
    }

    async fn load_meal_products(
        &self,
        meal: &Meal,
    ) -> Result<Vec<(ProductId, Product)>, MealError> {
        let mut products = Vec::new();
        for component in &meal.components {
            match &component.item {
                MealComponentItem::Product(product_id) => {
                    let product = self
                        .product_lookup
                        .find_by_id(*product_id)
                        .await?
                        .ok_or_else(|| {
                            MealError::NotFound(format!("product {} not found", product_id.0))
                        })?;
                    products.push((*product_id, product));
                }
            }
        }
        Ok(products)
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
        async fn create(&self, meal: &Meal) -> Result<(), MealError> {
            self.meals.lock().unwrap().push(meal.clone());
            Ok(())
        }

        async fn find_by_id(&self, id: MealId) -> Result<Option<Meal>, MealError> {
            let meals = self.meals.lock().unwrap();
            Ok(meals.iter().find(|m| m.id == id).cloned())
        }

        async fn find_by_user(&self, user_id: Uuid) -> Result<Vec<Meal>, MealError> {
            let meals = self.meals.lock().unwrap();
            Ok(meals
                .iter()
                .filter(|m| m.user_id == user_id)
                .cloned()
                .collect())
        }

        async fn update(&self, meal: &Meal) -> Result<(), MealError> {
            let mut meals = self.meals.lock().unwrap();
            if let Some(existing) = meals.iter_mut().find(|m| m.id == meal.id) {
                *existing = meal.clone();
                Ok(())
            } else {
                Err(MealError::NotFound("not found".into()))
            }
        }

        async fn delete(&self, id: MealId) -> Result<(), MealError> {
            let mut meals = self.meals.lock().unwrap();
            let idx = meals
                .iter()
                .position(|m| m.id == id)
                .ok_or_else(|| MealError::NotFound("not found".into()))?;
            meals.remove(idx);
            Ok(())
        }
    }

    struct MockMealProductLookup {
        product: Option<Product>,
    }

    impl MockMealProductLookup {
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
    impl MealProductLookup for MockMealProductLookup {
        async fn find_by_id(&self, _id: ProductId) -> Result<Option<Product>, MealError> {
            Ok(self.product.clone())
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
                amount_per_100g: AmountPer100g(Decimal::new(100, 0)),
                unit: UnitCode("kcal".to_string()),
                source: None,
                confidence: None,
            }],
            servings: vec![],
        }
    }

    fn make_services(product: Option<Product>) -> MealServices {
        let meal_repo = Arc::new(MockMealRepo::new()) as Arc<dyn MealRepository>;
        let product_lookup = match product {
            Some(p) => {
                Arc::new(MockMealProductLookup::with_product(p)) as Arc<dyn MealProductLookup>
            }
            None => Arc::new(MockMealProductLookup::empty()) as Arc<dyn MealProductLookup>,
        };
        let unit_converter = Arc::new(UnitConverter::from_entries([
            ("g".to_string(), Decimal::new(1, 0)),
            ("kg".to_string(), Decimal::new(1000, 0)),
        ]));
        MealServices::new(meal_repo, product_lookup, unit_converter)
    }

    fn sample_component() -> CreateMealComponentInput {
        CreateMealComponentInput {
            item_type: "product".to_string(),
            item_id: Uuid::nil(),
            quantity_amount: Decimal::new(100, 0),
            quantity_unit: "g".to_string(),
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
            MealError::Validation(_) => {}
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
            MealError::Validation(_) => {}
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
            MealError::NotFound(_) => {}
            _ => panic!("expected NotFound"),
        }
    }

    #[tokio::test]
    async fn test_get_meal_success() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let created = services
            .create_meal(CreateMealInput {
                user_id,
                name: "Test Meal".to_string(),
                notes: Some("test notes".to_string()),
                total_quantity_amount: None,
                total_quantity_unit: None,
                components: vec![sample_component()],
            })
            .await
            .unwrap();

        let fetched = services.get_meal(created.id).await.unwrap();
        assert_eq!(fetched.id, created.id);
        assert_eq!(fetched.name.0, "Test Meal");
    }

    #[tokio::test]
    async fn test_get_meal_not_found() {
        let services = make_services(Some(sample_product()));
        let result = services.get_meal(MealId::new()).await;
        assert!(result.is_err());
        match result.unwrap_err() {
            MealError::NotFound(_) => {}
            _ => panic!("expected NotFound"),
        }
    }

    #[tokio::test]
    async fn test_list_meals() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();
        let other_id = Uuid::new_v4();

        services
            .create_meal(CreateMealInput {
                user_id,
                name: "Meal 1".to_string(),
                notes: None,
                total_quantity_amount: None,
                total_quantity_unit: None,
                components: vec![sample_component()],
            })
            .await
            .unwrap();

        services
            .create_meal(CreateMealInput {
                user_id,
                name: "Meal 2".to_string(),
                notes: None,
                total_quantity_amount: None,
                total_quantity_unit: None,
                components: vec![sample_component()],
            })
            .await
            .unwrap();

        let meals = services.list_meals(user_id).await.unwrap();
        assert_eq!(meals.len(), 2);

        let other_meals = services.list_meals(other_id).await.unwrap();
        assert_eq!(other_meals.len(), 0);
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
                total_quantity_unit: Some("g".to_string()),
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
            MealError::Forbidden(_) => {}
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
        let fetch_result = services.get_meal(created.id).await;
        assert!(fetch_result.is_err());
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
            MealError::Forbidden(_) => {}
            _ => panic!("expected Forbidden"),
        }
    }

    #[tokio::test]
    async fn test_delete_meal_not_found() {
        let services = make_services(Some(sample_product()));
        let result = services.delete_meal(MealId::new(), Uuid::new_v4()).await;
        assert!(result.is_err());
        match result.unwrap_err() {
            MealError::NotFound(_) => {}
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
                        item_type: "product".to_string(),
                        item_id: Uuid::nil(),
                        quantity_amount: Decimal::new(200, 0),
                        quantity_unit: "g".to_string(),
                    },
                ],
            })
            .await
            .unwrap();

        let nutrition = services
            .get_meal_nutrients(meal.id, Decimal::new(150, 0), "g".to_string())
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
