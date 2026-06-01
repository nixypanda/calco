use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use std::sync::Arc;
use uuid::Uuid;

use crate::domain::catalog::*;
use crate::domain::food_log::*;
use crate::domain::meal::{Meal, MealComponentItem, MealId, MealRepository};
use crate::domain::nutrition::Quantity;
use crate::domain::units::UnitConverter;

pub struct LogFoodInput {
    pub user_id: Uuid,
    pub logged_at: DateTime<Utc>,
    pub meal_slot: Option<String>,
    pub item_type: String,
    pub item_id: Uuid,
    pub quantity_amount: Decimal,
    pub quantity_unit: String,
    pub notes: Option<String>,
}

pub struct UpdateFoodInput {
    pub logged_at: Option<DateTime<Utc>>,
    pub meal_slot: Option<Option<String>>,
    pub item_type: Option<String>,
    pub item_id: Option<Uuid>,
    pub quantity_amount: Option<Decimal>,
    pub quantity_unit: Option<String>,
    pub notes: Option<Option<String>>,
}

#[derive(Clone)]
pub struct FoodLogServices {
    pub food_log_repo: Arc<dyn FoodLogRepository>,
    pub product_repo: Arc<dyn ProductRepository>,
    pub unit_converter: Arc<UnitConverter>,
    pub meal_repo: Arc<dyn MealRepository>,
}

impl FoodLogServices {
    pub fn new(
        food_log_repo: Arc<dyn FoodLogRepository>,
        product_repo: Arc<dyn ProductRepository>,
        unit_converter: Arc<UnitConverter>,
        meal_repo: Arc<dyn MealRepository>,
    ) -> Self {
        Self {
            food_log_repo,
            product_repo,
            unit_converter,
            meal_repo,
        }
    }

    pub async fn log_food(&self, input: LogFoodInput) -> Result<FoodLog, NutritionError> {
        if input.item_type != "product" {
            return Err(NutritionError::Validation(format!(
                "unsupported item type for log_food: {}",
                input.item_type
            )));
        }

        let product_id = ProductId(input.item_id);
        let product = self
            .product_repo
            .find_by_id(product_id)
            .await?
            .ok_or_else(|| {
                NutritionError::NotFound(format!("product {} not found", input.item_id))
            })?;

        let quantity = Quantity::new(input.quantity_amount, UnitCode(input.quantity_unit.clone()));

        let meal_slot = match input.meal_slot {
            Some(ref s) => Some(s.parse::<MealSlot>().map_err(NutritionError::Validation)?),
            None => None,
        };

        let log = FoodLog::new_product_log(
            input.user_id,
            input.logged_at,
            meal_slot,
            &product,
            quantity,
            &self.unit_converter,
            input.notes,
        )?;

        self.food_log_repo.create(&log).await?;
        Ok(log)
    }

    pub async fn log_meal(&self, input: LogFoodInput) -> Result<FoodLog, NutritionError> {
        let meal_id = MealId(input.item_id);
        let meal =
            self.meal_repo.find_by_id(meal_id).await?.ok_or_else(|| {
                NutritionError::NotFound(format!("meal {} not found", input.item_id))
            })?;

        let scale_quantity =
            Quantity::new(input.quantity_amount, UnitCode(input.quantity_unit.clone()));
        let products = load_meal_products(&meal, self.product_repo.as_ref()).await?;

        let meal_slot = match input.meal_slot {
            Some(ref s) => Some(s.parse::<MealSlot>().map_err(NutritionError::Validation)?),
            None => None,
        };

        let log = FoodLog::new_meal_log(
            input.user_id,
            input.logged_at,
            meal_slot,
            &meal,
            scale_quantity,
            &products,
            &self.unit_converter,
            input.notes,
        )?;

        self.food_log_repo.create(&log).await?;
        Ok(log)
    }

    pub async fn update_food_log(
        &self,
        id: FoodLogId,
        user_id: Uuid,
        input: UpdateFoodInput,
    ) -> Result<FoodLog, NutritionError> {
        let existing = self
            .food_log_repo
            .find_by_id(id)
            .await?
            .ok_or_else(|| NutritionError::NotFound("food log not found".into()))?;

        if !existing.is_owned_by(user_id) {
            return Err(NutritionError::Forbidden("not your food log".into()));
        }

        let item_type = input
            .item_type
            .as_deref()
            .unwrap_or_else(|| log_item_type(&existing.item));
        let item_id = input.item_id.unwrap_or_else(|| existing.item_id());

        if item_type == "product" {
            let product = self
                .product_repo
                .find_by_id(ProductId(item_id))
                .await?
                .ok_or_else(|| NutritionError::NotFound("product not found".into()))?;

            let quantity_amount = input.quantity_amount.unwrap_or(existing.quantity_amount);
            let quantity_unit_str = input
                .quantity_unit
                .unwrap_or_else(|| existing.quantity_unit.0.clone());
            let quantity = Quantity::new(quantity_amount, UnitCode(quantity_unit_str.clone()));

            let logged_at = input.logged_at.unwrap_or(existing.logged_at);
            let meal_slot = match input.meal_slot {
                Some(Some(ref s)) => {
                    Some(s.parse::<MealSlot>().map_err(NutritionError::Validation)?)
                }
                Some(None) => None,
                None => existing.meal_slot,
            };
            let notes = input.notes.unwrap_or_else(|| existing.notes.clone());

            let updated = existing.update_product_log(
                logged_at,
                meal_slot,
                &product,
                quantity,
                &self.unit_converter,
                notes,
            )?;

            self.food_log_repo.update(&updated).await?;
            Ok(updated)
        } else if item_type == "meal" {
            let meal_id = MealId(item_id);
            let meal = self
                .meal_repo
                .find_by_id(meal_id)
                .await?
                .ok_or_else(|| NutritionError::NotFound("meal not found".into()))?;
            let quantity_amount = input.quantity_amount.unwrap_or(existing.quantity_amount);
            let quantity_unit_str = input
                .quantity_unit
                .unwrap_or_else(|| existing.quantity_unit.0.clone());
            let scale_quantity =
                Quantity::new(quantity_amount, UnitCode(quantity_unit_str.clone()));
            let products = load_meal_products(&meal, self.product_repo.as_ref()).await?;
            let logged_at = input.logged_at.unwrap_or(existing.logged_at);
            let meal_slot = match input.meal_slot {
                Some(Some(ref s)) => {
                    Some(s.parse::<MealSlot>().map_err(NutritionError::Validation)?)
                }
                Some(None) => None,
                None => existing.meal_slot,
            };
            let notes = input.notes.unwrap_or_else(|| existing.notes.clone());
            let updated = existing.update_meal_log(
                logged_at,
                meal_slot,
                &meal,
                scale_quantity,
                &products,
                &self.unit_converter,
                notes,
            )?;

            self.food_log_repo.update(&updated).await?;
            Ok(updated)
        } else {
            Err(NutritionError::Validation(format!(
                "unsupported item type: {}",
                item_type
            )))
        }
    }

    pub async fn delete_food_log(
        &self,
        id: FoodLogId,
        user_id: Uuid,
    ) -> Result<(), NutritionError> {
        let existing = self
            .food_log_repo
            .find_by_id(id)
            .await?
            .ok_or_else(|| NutritionError::NotFound("food log not found".into()))?;

        if !existing.is_owned_by(user_id) {
            return Err(NutritionError::Forbidden("not your food log".into()));
        }

        self.food_log_repo.delete(id).await
    }
}

async fn load_meal_products(
    meal: &Meal,
    product_repo: &dyn ProductRepository,
) -> Result<Vec<(ProductId, Product)>, NutritionError> {
    let mut products = Vec::new();
    for component in &meal.components {
        match &component.item {
            MealComponentItem::Product(product_id) => {
                let product = product_repo.find_by_id(*product_id).await?.ok_or_else(|| {
                    NutritionError::NotFound(format!(
                        "product {} in meal {} not found",
                        product_id.0, meal.id.0
                    ))
                })?;
                products.push((*product_id, product));
            }
        }
    }
    Ok(products)
}

pub fn log_item_id(item: &LoggedItem) -> Uuid {
    match item {
        LoggedItem::Product(id) => id.0,
        LoggedItem::Meal(id) => id.0,
    }
}

pub fn log_item_type(item: &LoggedItem) -> &'static str {
    match item {
        LoggedItem::Product(_) => "product",
        LoggedItem::Meal(_) => "meal",
    }
}

impl FoodLog {
    fn item_id(&self) -> Uuid {
        log_item_id(&self.item)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::meal::*;
    use async_trait::async_trait;
    use std::sync::Mutex;

    struct MockFoodLogRepo {
        logs: Mutex<Vec<FoodLog>>,
    }

    impl MockFoodLogRepo {
        fn new() -> Self {
            Self {
                logs: Mutex::new(vec![]),
            }
        }
    }

    #[async_trait]
    impl FoodLogRepository for MockFoodLogRepo {
        async fn create(&self, log: &FoodLog) -> Result<(), NutritionError> {
            self.logs.lock().unwrap().push(log.clone());
            Ok(())
        }

        async fn find_by_id(&self, id: FoodLogId) -> Result<Option<FoodLog>, NutritionError> {
            let logs = self.logs.lock().unwrap();
            Ok(logs.iter().find(|l| l.id == id).cloned())
        }

        async fn list_by_user_and_range(
            &self,
            user_id: Uuid,
            from: DateTime<Utc>,
            to: DateTime<Utc>,
        ) -> Result<Vec<FoodLog>, NutritionError> {
            let logs = self.logs.lock().unwrap();
            Ok(logs
                .iter()
                .filter(|l| l.user_id == user_id && l.logged_at >= from && l.logged_at <= to)
                .cloned()
                .collect())
        }

        async fn update(&self, log: &FoodLog) -> Result<(), NutritionError> {
            let mut logs = self.logs.lock().unwrap();
            if let Some(existing) = logs.iter_mut().find(|l| l.id == log.id) {
                *existing = log.clone();
                Ok(())
            } else {
                Err(NutritionError::NotFound("not found".into()))
            }
        }

        async fn sum_nutrients_by_user_and_range(
            &self,
            _user_id: Uuid,
            _from: DateTime<Utc>,
            _to: DateTime<Utc>,
            _codes: Option<Vec<String>>,
        ) -> Result<Vec<SummaryEntry>, NutritionError> {
            Ok(vec![])
        }

        async fn delete(&self, id: FoodLogId) -> Result<(), NutritionError> {
            let mut logs = self.logs.lock().unwrap();
            let idx = logs
                .iter()
                .position(|l| l.id == id)
                .ok_or_else(|| NutritionError::NotFound("not found".into()))?;
            logs.remove(idx);
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

        async fn search(
            &self,
            _query: ProductSearchQuery,
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

    struct MockMealRepo {
        meal_id: MealId,
        meal: Option<Meal>,
    }

    impl MockMealRepo {
        fn with_meal(meal: Meal) -> Self {
            Self {
                meal_id: meal.id,
                meal: Some(meal),
            }
        }

        fn empty() -> Self {
            Self {
                meal_id: MealId::new(),
                meal: None,
            }
        }
    }

    #[async_trait]
    impl MealRepository for MockMealRepo {
        async fn find_by_id(&self, id: MealId) -> Result<Option<Meal>, NutritionError> {
            if id == self.meal_id {
                Ok(self.meal.clone())
            } else {
                Ok(None)
            }
        }

        async fn create(&self, _meal: &Meal) -> Result<(), NutritionError> {
            unimplemented!("not used in test")
        }

        async fn list_by_user_id(&self, _user_id: Uuid) -> Result<Vec<Meal>, NutritionError> {
            unimplemented!("not used in test")
        }

        async fn update(&self, _meal: &Meal) -> Result<(), NutritionError> {
            unimplemented!("not used in test")
        }

        async fn delete(&self, _id: MealId) -> Result<(), NutritionError> {
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
                amount_per_100g: AmountPer100g(Decimal::new(100, 0)),
                unit: UnitCode("kcal".to_string()),
                source: None,
                confidence: None,
            }],
            servings: vec![],
        }
    }

    fn sample_product_with_serving() -> Product {
        let mut product = sample_product();
        product.servings = vec![ProductServing {
            label: ServingLabel("slice".to_string()),
            quantity: Decimal::new(1, 0),
            unit: UnitCode("slice".to_string()),
            grams: Decimal::new(30, 0),
        }];
        product
    }

    fn sample_meal() -> Meal {
        Meal {
            id: MealId(Uuid::nil()),
            user_id: Uuid::nil(),
            name: MealName("Test Meal".to_string()),
            notes: None,
            total_quantity_amount: None,
            total_quantity_unit: None,
            components: vec![MealComponent {
                id: Uuid::new_v4(),
                item: MealComponentItem::Product(ProductId(Uuid::nil())),
                quantity_amount: Decimal::new(100, 0),
                quantity_unit: UnitCode("g".to_string()),
            }],
            created_at: Utc::now(),
            updated_at: Utc::now(),
        }
    }

    fn sample_unit_converter() -> Arc<UnitConverter> {
        use std::str::FromStr;
        Arc::new(UnitConverter::from_entries([
            ("g".to_string(), Decimal::from(1)),
            ("kg".to_string(), Decimal::from(1000)),
            ("mg".to_string(), Decimal::from_str("0.001").unwrap()),
            ("ug".to_string(), Decimal::from_str("0.000001").unwrap()),
        ]))
    }

    fn make_services(product: Option<Product>) -> FoodLogServices {
        build_services(product, None)
    }

    fn make_services_with_meal(product: Option<Product>, meal: Meal) -> FoodLogServices {
        build_services(product, Some(meal))
    }

    fn build_services(product: Option<Product>, meal: Option<Meal>) -> FoodLogServices {
        let food_log_repo = Arc::new(MockFoodLogRepo::new()) as Arc<dyn FoodLogRepository>;
        let product_repo = match product {
            Some(p) => Arc::new(MockProductRepo::with_product(p)) as Arc<dyn ProductRepository>,
            None => Arc::new(MockProductRepo::empty()) as Arc<dyn ProductRepository>,
        };
        let meal_repo = match meal {
            Some(m) => Arc::new(MockMealRepo::with_meal(m)) as Arc<dyn MealRepository>,
            None => Arc::new(MockMealRepo::empty()) as Arc<dyn MealRepository>,
        };
        FoodLogServices::new(
            food_log_repo,
            product_repo,
            sample_unit_converter(),
            meal_repo,
        )
    }

    #[tokio::test]
    async fn test_log_food_success() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let result = services
            .log_food(LogFoodInput {
                user_id,
                logged_at: Utc::now(),
                meal_slot: Some("lunch".to_string()),
                item_type: "product".to_string(),
                item_id: Uuid::nil(),
                quantity_amount: Decimal::new(100, 0),
                quantity_unit: "g".to_string(),
                notes: None,
            })
            .await;

        assert!(result.is_ok());
        let log = result.unwrap();
        assert_eq!(log.user_id, user_id);
        assert_eq!(log.meal_slot, Some(MealSlot::Lunch));
        assert_eq!(log.quantity_amount, Decimal::new(100, 0));
        assert_eq!(log.nutrient_snapshots.len(), 1);
        assert_eq!(log.nutrient_snapshots[0].nutrient_code.0, "ENERGY_KCAL");
    }

    #[tokio::test]
    async fn test_log_food_product_not_found() {
        let services = make_services(None);

        let result = services
            .log_food(LogFoodInput {
                user_id: Uuid::new_v4(),
                logged_at: Utc::now(),
                meal_slot: Some("lunch".to_string()),
                item_type: "product".to_string(),
                item_id: Uuid::new_v4(),
                quantity_amount: Decimal::new(100, 0),
                quantity_unit: "g".to_string(),
                notes: None,
            })
            .await;

        assert!(result.is_err());
        match result.unwrap_err() {
            NutritionError::NotFound(_) => {}
            _ => panic!("expected NotFound"),
        }
    }

    #[tokio::test]
    async fn test_log_food_invalid_meal_slot() {
        let services = make_services(Some(sample_product()));

        let result = services
            .log_food(LogFoodInput {
                user_id: Uuid::new_v4(),
                logged_at: Utc::now(),
                meal_slot: Some("brunch".to_string()),
                item_type: "product".to_string(),
                item_id: Uuid::nil(),
                quantity_amount: Decimal::new(100, 0),
                quantity_unit: "g".to_string(),
                notes: None,
            })
            .await;

        assert!(result.is_err());
        match result.unwrap_err() {
            NutritionError::Validation(_) => {}
            _ => panic!("expected Validation"),
        }
    }

    #[tokio::test]
    async fn test_log_food_wrong_item_type() {
        let services = make_services(Some(sample_product()));

        let result = services
            .log_food(LogFoodInput {
                user_id: Uuid::new_v4(),
                logged_at: Utc::now(),
                meal_slot: Some("lunch".to_string()),
                item_type: "meal".to_string(),
                item_id: Uuid::nil(),
                quantity_amount: Decimal::new(100, 0),
                quantity_unit: "g".to_string(),
                notes: None,
            })
            .await;

        assert!(result.is_err());
        match result.unwrap_err() {
            NutritionError::Validation(_) => {}
            _ => panic!("expected Validation"),
        }
    }

    #[tokio::test]
    async fn test_delete_food_log_success() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let created = services
            .log_food(LogFoodInput {
                user_id,
                logged_at: Utc::now(),
                meal_slot: Some("lunch".to_string()),
                item_type: "product".to_string(),
                item_id: Uuid::nil(),
                quantity_amount: Decimal::new(100, 0),
                quantity_unit: "g".to_string(),
                notes: None,
            })
            .await
            .unwrap();

        assert!(services.delete_food_log(created.id, user_id).await.is_ok());
        let still_there = services.food_log_repo.find_by_id(created.id).await.unwrap();
        assert!(still_there.is_none());
    }

    #[tokio::test]
    async fn test_delete_food_log_forbidden() {
        let services = make_services(Some(sample_product()));
        let owner = Uuid::new_v4();
        let other = Uuid::new_v4();

        let created = services
            .log_food(LogFoodInput {
                user_id: owner,
                logged_at: Utc::now(),
                meal_slot: Some("breakfast".to_string()),
                item_type: "product".to_string(),
                item_id: Uuid::nil(),
                quantity_amount: Decimal::new(100, 0),
                quantity_unit: "g".to_string(),
                notes: None,
            })
            .await
            .unwrap();

        let result = services.delete_food_log(created.id, other).await;
        assert!(result.is_err());
        match result.unwrap_err() {
            NutritionError::Forbidden(_) => {}
            _ => panic!("expected Forbidden"),
        }
    }

    #[tokio::test]
    async fn test_delete_food_log_not_found() {
        let services = make_services(Some(sample_product()));
        let result = services
            .delete_food_log(FoodLogId::new(), Uuid::new_v4())
            .await;
        assert!(result.is_err());
        match result.unwrap_err() {
            NutritionError::NotFound(_) => {}
            _ => panic!("expected NotFound"),
        }
    }

    #[tokio::test]
    async fn test_update_food_log_success() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let created = services
            .log_food(LogFoodInput {
                user_id,
                logged_at: Utc::now(),
                meal_slot: Some("lunch".to_string()),
                item_type: "product".to_string(),
                item_id: Uuid::nil(),
                quantity_amount: Decimal::new(100, 0),
                quantity_unit: "g".to_string(),
                notes: None,
            })
            .await
            .unwrap();

        let updated = services
            .update_food_log(
                created.id,
                user_id,
                UpdateFoodInput {
                    logged_at: Some(Utc::now()),
                    meal_slot: Some(Some("dinner".to_string())),
                    item_type: None,
                    item_id: None,
                    quantity_amount: Some(Decimal::new(200, 0)),
                    quantity_unit: Some("g".to_string()),
                    notes: Some(Some("updated notes".to_string())),
                },
            )
            .await
            .unwrap();

        assert_eq!(updated.meal_slot, Some(MealSlot::Dinner));
        assert_eq!(updated.quantity_amount, Decimal::new(200, 0));
        assert_eq!(updated.notes, Some("updated notes".to_string()));
    }

    #[tokio::test]
    async fn test_update_food_log_can_clear_optional_fields() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let created = services
            .log_food(LogFoodInput {
                user_id,
                logged_at: Utc::now(),
                meal_slot: Some("lunch".to_string()),
                item_type: "product".to_string(),
                item_id: Uuid::nil(),
                quantity_amount: Decimal::new(100, 0),
                quantity_unit: "g".to_string(),
                notes: Some("clear me".to_string()),
            })
            .await
            .unwrap();

        let updated = services
            .update_food_log(
                created.id,
                user_id,
                UpdateFoodInput {
                    logged_at: None,
                    meal_slot: Some(None),
                    item_type: None,
                    item_id: None,
                    quantity_amount: None,
                    quantity_unit: None,
                    notes: Some(None),
                },
            )
            .await
            .unwrap();

        assert_eq!(updated.meal_slot, None);
        assert_eq!(updated.notes, None);
    }

    #[tokio::test]
    async fn test_log_food_uses_unit_converter_for_kg() {
        let services = make_services(Some(sample_product()));

        let log = services
            .log_food(LogFoodInput {
                user_id: Uuid::new_v4(),
                logged_at: Utc::now(),
                meal_slot: None,
                item_type: "product".to_string(),
                item_id: Uuid::nil(),
                quantity_amount: Decimal::new(2, 0),
                quantity_unit: "kg".to_string(),
                notes: None,
            })
            .await
            .unwrap();

        // sample product has 100 kcal per 100g → 2 kg = 2000 g → 2000 kcal
        assert_eq!(log.nutrient_snapshots[0].amount, Decimal::new(2000, 0));
    }

    #[tokio::test]
    async fn test_log_food_rejects_unknown_unit() {
        let services = make_services(Some(sample_product()));

        let result = services
            .log_food(LogFoodInput {
                user_id: Uuid::new_v4(),
                logged_at: Utc::now(),
                meal_slot: None,
                item_type: "product".to_string(),
                item_id: Uuid::nil(),
                quantity_amount: Decimal::new(1, 0),
                quantity_unit: "cup".to_string(),
                notes: None,
            })
            .await;

        assert!(matches!(result, Err(NutritionError::Validation(_))));
    }

    #[tokio::test]
    async fn test_log_food_accepts_serving_multiples() {
        let services = make_services(Some(sample_product_with_serving()));

        let log = services
            .log_food(LogFoodInput {
                user_id: Uuid::new_v4(),
                logged_at: Utc::now(),
                meal_slot: None,
                item_type: "product".to_string(),
                item_id: Uuid::nil(),
                quantity_amount: Decimal::new(2, 0),
                quantity_unit: "slice".to_string(),
                notes: None,
            })
            .await
            .unwrap();

        assert_eq!(log.nutrient_snapshots[0].amount, Decimal::new(60, 0));
    }

    #[tokio::test]
    async fn test_update_food_log_forbidden() {
        let services = make_services(Some(sample_product()));
        let owner = Uuid::new_v4();
        let other = Uuid::new_v4();

        let created = services
            .log_food(LogFoodInput {
                user_id: owner,
                logged_at: Utc::now(),
                meal_slot: Some("lunch".to_string()),
                item_type: "product".to_string(),
                item_id: Uuid::nil(),
                quantity_amount: Decimal::new(100, 0),
                quantity_unit: "g".to_string(),
                notes: None,
            })
            .await
            .unwrap();

        let result = services
            .update_food_log(
                created.id,
                other,
                UpdateFoodInput {
                    logged_at: None,
                    meal_slot: None,
                    item_type: None,
                    item_id: None,
                    quantity_amount: None,
                    quantity_unit: None,
                    notes: None,
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
    async fn test_log_meal_success() {
        let services = make_services_with_meal(Some(sample_product()), sample_meal());
        let user_id = Uuid::new_v4();

        let result = services
            .log_meal(LogFoodInput {
                user_id,
                logged_at: Utc::now(),
                meal_slot: Some("dinner".to_string()),
                item_type: "meal".to_string(),
                item_id: Uuid::nil(),
                quantity_amount: Decimal::new(150, 0),
                quantity_unit: "g".to_string(),
                notes: Some("meal note".to_string()),
            })
            .await;

        assert!(result.is_ok());
        let log = result.unwrap();
        assert_eq!(log.user_id, user_id);
        assert_eq!(log.meal_slot, Some(MealSlot::Dinner));
        assert!(matches!(log.item, LoggedItem::Meal(_)));
        assert_eq!(log.nutrient_snapshots.len(), 1);
        assert_eq!(log.nutrient_snapshots[0].nutrient_code.0, "ENERGY_KCAL");
        assert_eq!(log.nutrient_snapshots[0].amount, Decimal::new(150, 0));
    }

    #[tokio::test]
    async fn test_update_existing_meal_log_recalculates_without_item_payload() {
        let services = make_services_with_meal(Some(sample_product()), sample_meal());
        let user_id = Uuid::new_v4();

        let created = services
            .log_meal(LogFoodInput {
                user_id,
                logged_at: Utc::now(),
                meal_slot: Some("dinner".to_string()),
                item_type: "meal".to_string(),
                item_id: Uuid::nil(),
                quantity_amount: Decimal::new(100, 0),
                quantity_unit: "g".to_string(),
                notes: None,
            })
            .await
            .unwrap();

        let updated = services
            .update_food_log(
                created.id,
                user_id,
                UpdateFoodInput {
                    logged_at: None,
                    meal_slot: None,
                    item_type: None,
                    item_id: None,
                    quantity_amount: Some(Decimal::new(200, 0)),
                    quantity_unit: None,
                    notes: None,
                },
            )
            .await
            .unwrap();

        assert!(matches!(updated.item, LoggedItem::Meal(_)));
        assert_eq!(updated.quantity_amount, Decimal::new(200, 0));
        assert_eq!(updated.nutrient_snapshots[0].amount, Decimal::new(200, 0));
    }

    #[tokio::test]
    async fn test_log_meal_not_found() {
        let services = make_services_with_meal(Some(sample_product()), sample_meal());

        let result = services
            .log_meal(LogFoodInput {
                user_id: Uuid::new_v4(),
                logged_at: Utc::now(),
                meal_slot: Some("lunch".to_string()),
                item_type: "meal".to_string(),
                item_id: MealId::new().0,
                quantity_amount: Decimal::new(100, 0),
                quantity_unit: "g".to_string(),
                notes: None,
            })
            .await;

        assert!(result.is_err());
        match result.unwrap_err() {
            NutritionError::NotFound(_) => {}
            _ => panic!("expected NotFound"),
        }
    }
}
