use chrono::Utc;
use rust_decimal::Decimal;
use std::sync::Arc;
use uuid::Uuid;

use crate::nutrition::catalog::app::CatalogReadPort;
use crate::nutrition::catalog::domain::calculation::Quantity;
use crate::nutrition::catalog::domain::units::UnitConverter;
use crate::nutrition::catalog::domain::*;
use crate::nutrition::meal::domain::*;

pub struct CreateMealInput {
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

pub struct ResolvedMeal {
    pub meal: Meal,
    pub products: Vec<(ProductId, Product)>,
}

/// Application-level meal access for downstream logging workflows.
///
/// A resolved meal has already passed the meal visibility policy and its
/// products have passed catalog visibility checks for the same actor.
#[async_trait::async_trait]
pub trait MealReadPort: Send + Sync {
    async fn resolve_loggable_meal(
        &self,
        actor_id: Uuid,
        id: MealId,
    ) -> Result<ResolvedMeal, NutritionError>;
}

#[derive(Clone)]
pub struct MealService {
    meal_repo: Arc<dyn MealRepo>,
    catalog: Arc<dyn CatalogReadPort>,
    unit_converter: Arc<UnitConverter>,
    policy: MealPolicy,
}

impl MealService {
    pub fn new(
        meal_repo: Arc<dyn MealRepo>,
        catalog: Arc<dyn CatalogReadPort>,
        unit_converter: Arc<UnitConverter>,
    ) -> Self {
        Self {
            meal_repo,
            catalog,
            unit_converter,
            policy: MealPolicy,
        }
    }

    pub async fn get_meal(&self, actor_id: Uuid, id: MealId) -> Result<Meal, NutritionError> {
        let meal = self.load_meal(id).await?;
        self.policy.authorize_view(actor_id, &meal)?;
        Ok(meal)
    }

    pub async fn list_meals(&self, actor_id: Uuid) -> Result<Vec<Meal>, NutritionError> {
        let meals = self.meal_repo.list_all().await?;
        for meal in &meals {
            self.policy.authorize_view(actor_id, meal)?;
        }
        Ok(meals)
    }

    pub async fn load_products(
        &self,
        actor_id: Uuid,
        meal: &Meal,
    ) -> Result<Vec<(ProductId, Product)>, NutritionError> {
        let product_ids = meal
            .components
            .iter()
            .map(|component| match component.item {
                MealComponentItem::Product(id) => id,
            })
            .collect::<Vec<_>>();
        self.catalog.resolve_products(actor_id, &product_ids).await
    }

    pub fn unit_converter(&self) -> &UnitConverter {
        &self.unit_converter
    }

    pub async fn create_meal(
        &self,
        actor_id: Uuid,
        input: CreateMealInput,
    ) -> Result<Meal, NutritionError> {
        let components = self.build_components(actor_id, input.components).await?;

        let now = Utc::now();
        let meal = Meal::create(
            actor_id,
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
        let existing = self.load_meal(id).await?;
        self.policy.authorize_mutation(user_id, &existing)?;

        let components = match input.components {
            Some(components) => Some(self.build_components(user_id, components).await?),
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
        let existing = self.load_meal(id).await?;
        self.policy.authorize_mutation(user_id, &existing)?;

        self.meal_repo.delete(id).await
    }

    pub async fn get_meal_nutrients(
        &self,
        actor_id: Uuid,
        id: MealId,
        quantity: Quantity,
    ) -> Result<MealNutritionOutput, NutritionError> {
        let meal = self.get_meal(actor_id, id).await?;

        let products = self.load_products(actor_id, &meal).await?;
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

    async fn load_meal(&self, id: MealId) -> Result<Meal, NutritionError> {
        self.meal_repo
            .find_by_id(id)
            .await?
            .ok_or_else(|| NutritionError::NotFound("meal not found".into()))
    }

    async fn build_components(
        &self,
        actor_id: Uuid,
        inputs: Vec<CreateMealComponentInput>,
    ) -> Result<Vec<MealComponent>, NutritionError> {
        let product_ids: Vec<ProductId> = inputs
            .iter()
            .map(|i| match &i.item {
                MealComponentItem::Product(id) => *id,
            })
            .collect();
        self.catalog
            .resolve_products(actor_id, &product_ids)
            .await?;

        Ok(inputs
            .into_iter()
            .map(|input| MealComponent::new(input.item, input.quantity))
            .collect())
    }
}

#[async_trait::async_trait]
impl MealReadPort for MealService {
    async fn resolve_loggable_meal(
        &self,
        actor_id: Uuid,
        id: MealId,
    ) -> Result<ResolvedMeal, NutritionError> {
        let meal = self.get_meal(actor_id, id).await?;
        let products = self.load_products(actor_id, &meal).await?;
        Ok(ResolvedMeal { meal, products })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use rstest::rstest;
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
    impl MealRepo for MockMealRepo {
        async fn create(&self, meal: &Meal) -> Result<(), NutritionError> {
            self.meals.lock().unwrap().push(meal.clone());
            Ok(())
        }

        async fn find_by_id(&self, id: MealId) -> Result<Option<Meal>, NutritionError> {
            let meals = self.meals.lock().unwrap();
            Ok(meals.iter().find(|m| m.id == id).cloned())
        }

        async fn list_all(&self) -> Result<Vec<Meal>, NutritionError> {
            let meals = self.meals.lock().unwrap();
            Ok(meals.clone())
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

    struct MockCatalogReadPort {
        product: Option<Product>,
    }

    impl MockCatalogReadPort {
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
    impl CatalogReadPort for MockCatalogReadPort {
        async fn resolve_products(
            &self,
            _actor_id: Uuid,
            ids: &[ProductId],
        ) -> Result<Vec<(ProductId, Product)>, NutritionError> {
            match &self.product {
                Some(product) => Ok(ids.iter().map(|id| (*id, product.clone())).collect()),
                None => Err(NutritionError::NotFound("product not found".into())),
            }
        }
    }

    fn sample_product() -> Product {
        Product {
            id: ProductId(Uuid::nil()),
            origin: ProductOrigin::Custom {
                user_id: Uuid::nil(),
            },
            visibility: ProductVisibility::Global,
            name: ProductName::new("Test Food").unwrap(),
            brand: None,
            categories: vec![],
            default_quantity: Some(Decimal::new(100, 0)),
            default_unit: Some(UnitCode("g".to_string())),
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

    fn make_services_with_repo(product: Option<Product>) -> (MealService, Arc<MockMealRepo>) {
        let meal_repo = Arc::new(MockMealRepo::new());
        let catalog = match product {
            Some(p) => Arc::new(MockCatalogReadPort::with_product(p)) as Arc<dyn CatalogReadPort>,
            None => Arc::new(MockCatalogReadPort::empty()) as Arc<dyn CatalogReadPort>,
        };
        let unit_converter = Arc::new(UnitConverter::from_entries([
            ("g".to_string(), Decimal::new(1, 0)),
            ("kg".to_string(), Decimal::new(1000, 0)),
        ]));
        (
            MealService::new(meal_repo.clone(), catalog, unit_converter),
            meal_repo,
        )
    }

    fn make_services(product: Option<Product>) -> MealService {
        make_services_with_repo(product).0
    }

    fn sample_component() -> CreateMealComponentInput {
        CreateMealComponentInput {
            item: MealComponentItem::Product(ProductId(Uuid::nil())),
            quantity: Quantity::new(Decimal::new(100, 0), UnitCode("g".to_string())).unwrap(),
        }
    }

    #[derive(Clone, Copy, Debug)]
    enum ExpectedCreateMealError {
        Validation,
        NotFound,
    }

    #[track_caller]
    fn assert_create_meal_error(expected: ExpectedCreateMealError, error: NutritionError) {
        match (expected, error) {
            (ExpectedCreateMealError::Validation, NutritionError::Validation(_)) => {}
            (ExpectedCreateMealError::NotFound, NutritionError::NotFound(_)) => {}
            (expected, error) => panic!("expected {expected:?}, got {error}"),
        }
    }

    #[rstest]
    #[case::empty_name(
        Some(sample_product()),
        "",
        vec![sample_component()],
        ExpectedCreateMealError::Validation
    )]
    #[case::no_components(
        Some(sample_product()),
        "Empty Meal",
        vec![],
        ExpectedCreateMealError::Validation
    )]
    #[case::product_not_found(
        None,
        "Test Meal",
        vec![sample_component()],
        ExpectedCreateMealError::NotFound
    )]
    #[tokio::test]
    async fn create_meal_rejects_invalid_request(
        #[case] product: Option<Product>,
        #[case] name: &str,
        #[case] components: Vec<CreateMealComponentInput>,
        #[case] expected: ExpectedCreateMealError,
    ) {
        let services = make_services(product);

        let result = services
            .create_meal(
                Uuid::new_v4(),
                CreateMealInput {
                    name: name.to_string(),
                    notes: None,
                    total_quantity_amount: None,
                    total_quantity_unit: None,
                    components,
                },
            )
            .await;

        let error = result.expect_err("create_meal should reject invalid input");
        assert_create_meal_error(expected, error);
    }

    #[tokio::test]
    async fn test_update_meal_can_clear_optional_fields() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let created = services
            .create_meal(
                user_id,
                CreateMealInput {
                    name: "Original".to_string(),
                    notes: Some("clear me".to_string()),
                    total_quantity_amount: Some(Decimal::new(100, 0)),
                    total_quantity_unit: Some(UnitCode("g".to_string())),
                    components: vec![sample_component()],
                },
            )
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

    #[derive(Clone, Copy, Debug)]
    enum MealMutation {
        Update,
        Delete,
    }

    #[rstest]
    #[case::update(MealMutation::Update)]
    #[case::delete(MealMutation::Delete)]
    #[tokio::test]
    async fn non_owner_cannot_mutate_meal(#[case] mutation: MealMutation) {
        let services = make_services(Some(sample_product()));
        let owner = Uuid::new_v4();
        let other = Uuid::new_v4();

        let created = services
            .create_meal(
                owner,
                CreateMealInput {
                    name: "My Meal".to_string(),
                    notes: None,
                    total_quantity_amount: None,
                    total_quantity_unit: None,
                    components: vec![sample_component()],
                },
            )
            .await
            .unwrap();

        let result = match mutation {
            MealMutation::Update => services
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
                .await
                .map(|_| ()),
            MealMutation::Delete => services.delete_meal(created.id, other).await,
        };

        assert!(
            matches!(&result, Err(NutritionError::Forbidden(_))),
            "expected Forbidden, got {result:?}"
        );
    }

    #[tokio::test]
    async fn test_delete_meal_not_found() {
        let services = make_services(Some(sample_product()));
        let result = services.delete_meal(MealId::new(), Uuid::new_v4()).await;
        assert!(matches!(&result, Err(NutritionError::NotFound(_))));
    }

    #[tokio::test]
    async fn test_get_meal_nutrients_calculates_sum() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let meal = services
            .create_meal(
                user_id,
                CreateMealInput {
                    name: "Double Food".to_string(),
                    notes: None,
                    total_quantity_amount: None,
                    total_quantity_unit: None,
                    components: vec![
                        sample_component(),
                        CreateMealComponentInput {
                            item: MealComponentItem::Product(ProductId(Uuid::nil())),
                            quantity: Quantity::new(
                                Decimal::new(200, 0),
                                UnitCode("g".to_string()),
                            )
                            .unwrap(),
                        },
                    ],
                },
            )
            .await
            .unwrap();

        let nutrition = services
            .get_meal_nutrients(
                user_id,
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
