use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use std::sync::Arc;
use uuid::Uuid;

use crate::domain::catalog::*;
use crate::domain::food_log::*;
use crate::domain::nutrition::{NutritionCalculator, Quantity};

#[async_trait]
pub trait FoodLogRepository: Send + Sync {
    async fn create(&self, log: &FoodLog) -> Result<(), FoodLogError>;
    async fn find_by_id(&self, id: FoodLogId) -> Result<Option<FoodLog>, FoodLogError>;
    async fn find_by_user_and_range(
        &self,
        user_id: Uuid,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
    ) -> Result<Vec<FoodLog>, FoodLogError>;
    async fn update(&self, log: &FoodLog) -> Result<(), FoodLogError>;
    async fn delete(&self, id: FoodLogId) -> Result<(), FoodLogError>;
}

#[async_trait]
pub trait ProductLookup: Send + Sync {
    async fn find_by_id(&self, id: ProductId) -> Result<Option<Product>, FoodLogError>;
}

#[async_trait]
pub trait SummaryRepository: Send + Sync {
    async fn get_summary(
        &self,
        user_id: Uuid,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
        codes: Option<Vec<String>>,
    ) -> Result<Vec<SummaryEntry>, FoodLogError>;
}

#[derive(Debug, Clone)]
pub struct SummaryEntry {
    pub code: String,
    pub amount: Decimal,
    pub unit: String,
}

pub struct LogFoodInput {
    pub user_id: Uuid,
    pub logged_at: DateTime<Utc>,
    pub meal_slot: Option<String>,
    pub product_id: Uuid,
    pub quantity_amount: Decimal,
    pub quantity_unit: String,
    pub notes: Option<String>,
}

pub struct UpdateFoodInput {
    pub logged_at: Option<DateTime<Utc>>,
    pub meal_slot: Option<String>,
    pub product_id: Option<Uuid>,
    pub quantity_amount: Option<Decimal>,
    pub quantity_unit: Option<String>,
    pub notes: Option<String>,
}

#[derive(Clone)]
pub struct FoodLogServices {
    pub food_log_repo: Arc<dyn FoodLogRepository>,
    pub product_repo: Arc<dyn ProductLookup>,
    pub summary_repo: Arc<dyn SummaryRepository>,
}

impl FoodLogServices {
    pub fn new(
        food_log_repo: Arc<dyn FoodLogRepository>,
        product_repo: Arc<dyn ProductLookup>,
        summary_repo: Arc<dyn SummaryRepository>,
    ) -> Self {
        Self { food_log_repo, product_repo, summary_repo }
    }

    pub async fn log_food(&self, input: LogFoodInput) -> Result<FoodLog, FoodLogError> {
        let product_id = ProductId(input.product_id);
        let product = self.product_repo.find_by_id(product_id).await?
            .ok_or_else(|| FoodLogError::NotFound(format!("product {} not found", input.product_id)))?;

        let quantity = Quantity::new(input.quantity_amount, UnitCode(input.quantity_unit.clone()));
        let grams = convert_to_grams(&quantity, &product)?;

        let nutrients: Vec<(NutrientCode, AmountPer100g, UnitCode)> = product.nutrients.iter().map(|pn| {
            (pn.nutrient_code.clone(), pn.amount_per_100g.clone(), UnitCode("g".to_string()))
        }).collect();

        let calculated = NutritionCalculator::calculate(grams, &nutrients);

        let meal_slot = match input.meal_slot {
            Some(ref s) => Some(MealSlot::from_str(s).map_err(|e| FoodLogError::Validation(e))?),
            None => None,
        };

        let log = FoodLog {
            id: FoodLogId::new(),
            user_id: input.user_id,
            logged_at: input.logged_at,
            meal_slot,
            item: LoggedItem::Product(product_id),
            quantity_amount: input.quantity_amount,
            quantity_unit: UnitCode(input.quantity_unit),
            nutrient_snapshots: calculated.amounts.into_iter().map(|na| FoodLogNutrientSnapshot {
                nutrient_code: na.nutrient_code,
                amount: na.amount,
                unit: na.unit,
            }).collect(),
            notes: input.notes,
        };

        self.food_log_repo.create(&log).await?;
        Ok(log)
    }

    pub async fn get_food_log(&self, id: FoodLogId) -> Result<FoodLog, FoodLogError> {
        self.food_log_repo.find_by_id(id).await?
            .ok_or_else(|| FoodLogError::NotFound("food log not found".into()))
    }

    pub async fn get_logs_for_range(
        &self,
        user_id: Uuid,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
    ) -> Result<Vec<FoodLog>, FoodLogError> {
        self.food_log_repo.find_by_user_and_range(user_id, from, to).await
    }

    pub async fn update_food_log(
        &self,
        id: FoodLogId,
        user_id: Uuid,
        input: UpdateFoodInput,
    ) -> Result<FoodLog, FoodLogError> {
        let existing = self.food_log_repo.find_by_id(id).await?
            .ok_or_else(|| FoodLogError::NotFound("food log not found".into()))?;

        if !existing.is_owned_by(user_id) {
            return Err(FoodLogError::Forbidden("not your food log".into()));
        }

        let product_id = input.product_id.unwrap_or_else(|| existing.item_product_id());
        let product = self.product_repo.find_by_id(ProductId(product_id)).await?
            .ok_or_else(|| FoodLogError::NotFound("product not found".into()))?;

        let quantity_amount = input.quantity_amount.unwrap_or(existing.quantity_amount);
        let quantity_unit_str = input.quantity_unit.unwrap_or_else(|| existing.quantity_unit.0.clone());
        let quantity = Quantity::new(quantity_amount, UnitCode(quantity_unit_str.clone()));
        let grams = convert_to_grams(&quantity, &product)?;

        let nutrients: Vec<(NutrientCode, AmountPer100g, UnitCode)> = product.nutrients.iter().map(|pn| {
            (pn.nutrient_code.clone(), pn.amount_per_100g.clone(), UnitCode("g".to_string()))
        }).collect();

        let calculated = NutritionCalculator::calculate(grams, &nutrients);

        let logged_at = input.logged_at.unwrap_or(existing.logged_at);
        let meal_slot = match input.meal_slot {
            Some(ref s) => Some(MealSlot::from_str(s).map_err(|e| FoodLogError::Validation(e))?),
            None => existing.meal_slot,
        };
        let notes = input.notes.or(existing.notes);

        let updated = FoodLog {
            id,
            user_id,
            logged_at,
            meal_slot,
            item: LoggedItem::Product(ProductId(product_id)),
            quantity_amount,
            quantity_unit: UnitCode(quantity_unit_str),
            nutrient_snapshots: calculated.amounts.into_iter().map(|na| FoodLogNutrientSnapshot {
                nutrient_code: na.nutrient_code,
                amount: na.amount,
                unit: na.unit,
            }).collect(),
            notes,
        };

        self.food_log_repo.update(&updated).await?;
        Ok(updated)
    }

    pub async fn delete_food_log(&self, id: FoodLogId, user_id: Uuid) -> Result<(), FoodLogError> {
        let existing = self.food_log_repo.find_by_id(id).await?
            .ok_or_else(|| FoodLogError::NotFound("food log not found".into()))?;

        if !existing.is_owned_by(user_id) {
            return Err(FoodLogError::Forbidden("not your food log".into()));
        }

        self.food_log_repo.delete(id).await
    }

    pub async fn get_summary(
        &self,
        user_id: Uuid,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
        codes: Option<Vec<String>>,
    ) -> Result<Vec<SummaryEntry>, FoodLogError> {
        self.summary_repo.get_summary(user_id, from, to, codes).await
    }
}

fn convert_to_grams(quantity: &Quantity, product: &Product) -> Result<Decimal, FoodLogError> {
    if quantity.unit.0 == "g" {
        return Ok(quantity.amount);
    }
    if quantity.unit.0 == "kg" {
        return Ok(quantity.amount * Decimal::new(1000, 0));
    }
    for serving in &product.servings {
        if serving.unit.0 == quantity.unit.0 && serving.quantity == quantity.amount {
            return Ok(serving.grams * (quantity.amount / serving.quantity));
        }
    }
    if let Some(size_g) = product.serving_size_g {
        let default_unit = product.default_unit.as_ref().map(|u| u.0.as_str()).unwrap_or("serving");
        if quantity.unit.0 == default_unit {
            return Ok(size_g * quantity.amount);
        }
    }
    Err(FoodLogError::Validation(format!("cannot convert {} {} to grams", quantity.amount, quantity.unit.0)))
}

impl FoodLog {
    fn item_product_id(&self) -> Uuid {
        match &self.item {
            LoggedItem::Product(id) => id.0,
        }
    }
}

#[derive(Debug)]
pub enum FoodLogError {
    NotFound(String),
    Forbidden(String),
    Validation(String),
    Database(String),
    Internal(String),
}

impl std::fmt::Display for FoodLogError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FoodLogError::NotFound(msg) => write!(f, "not found: {msg}"),
            FoodLogError::Forbidden(msg) => write!(f, "forbidden: {msg}"),
            FoodLogError::Validation(msg) => write!(f, "validation: {msg}"),
            FoodLogError::Database(msg) => write!(f, "database: {msg}"),
            FoodLogError::Internal(msg) => write!(f, "internal: {msg}"),
        }
    }
}

impl std::error::Error for FoodLogError {}

impl From<crate::application::catalog::CatalogError> for FoodLogError {
    fn from(e: crate::application::catalog::CatalogError) -> Self {
        match e {
            crate::application::catalog::CatalogError::NotFound(msg) => FoodLogError::NotFound(msg),
            crate::application::catalog::CatalogError::Forbidden(msg) => FoodLogError::Forbidden(msg),
            crate::application::catalog::CatalogError::Database(msg) => FoodLogError::Database(msg),
            crate::application::catalog::CatalogError::Internal(msg) => FoodLogError::Internal(msg),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    struct MockFoodLogRepo {
        logs: Mutex<Vec<FoodLog>>,
    }

    impl MockFoodLogRepo {
        fn new() -> Self {
            Self { logs: Mutex::new(vec![]) }
        }
    }

    #[async_trait]
    impl FoodLogRepository for MockFoodLogRepo {
        async fn create(&self, log: &FoodLog) -> Result<(), FoodLogError> {
            self.logs.lock().unwrap().push(log.clone());
            Ok(())
        }

        async fn find_by_id(&self, id: FoodLogId) -> Result<Option<FoodLog>, FoodLogError> {
            let logs = self.logs.lock().unwrap();
            Ok(logs.iter().find(|l| l.id == id).cloned())
        }

        async fn find_by_user_and_range(
            &self,
            user_id: Uuid,
            from: DateTime<Utc>,
            to: DateTime<Utc>,
        ) -> Result<Vec<FoodLog>, FoodLogError> {
            let logs = self.logs.lock().unwrap();
            Ok(logs.iter().filter(|l| l.user_id == user_id && l.logged_at >= from && l.logged_at <= to).cloned().collect())
        }

        async fn update(&self, log: &FoodLog) -> Result<(), FoodLogError> {
            let mut logs = self.logs.lock().unwrap();
            if let Some(existing) = logs.iter_mut().find(|l| l.id == log.id) {
                *existing = log.clone();
                Ok(())
            } else {
                Err(FoodLogError::NotFound("not found".into()))
            }
        }

        async fn delete(&self, id: FoodLogId) -> Result<(), FoodLogError> {
            let mut logs = self.logs.lock().unwrap();
            let idx = logs.iter().position(|l| l.id == id).ok_or_else(|| FoodLogError::NotFound("not found".into()))?;
            logs.remove(idx);
            Ok(())
        }
    }

    struct MockProductLookup {
        product: Option<Product>,
    }

    impl MockProductLookup {
        fn with_product(product: Product) -> Self {
            Self { product: Some(product) }
        }

        fn empty() -> Self {
            Self { product: None }
        }
    }

    #[async_trait]
    impl ProductLookup for MockProductLookup {
        async fn find_by_id(&self, _id: ProductId) -> Result<Option<Product>, FoodLogError> {
            Ok(self.product.clone())
        }
    }

    struct MockSummaryRepo;

    #[async_trait]
    impl SummaryRepository for MockSummaryRepo {
        async fn get_summary(
            &self,
            _user_id: Uuid,
            _from: DateTime<Utc>,
            _to: DateTime<Utc>,
            _codes: Option<Vec<String>>,
        ) -> Result<Vec<SummaryEntry>, FoodLogError> {
            Ok(vec![])
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
            category: None,
            default_quantity: Some(Decimal::new(100, 0)),
            default_unit: Some(UnitCode("g".to_string())),
            serving_size_g: Some(Decimal::new(100, 0)),
            nutrients: vec![
                ProductNutrient {
                    nutrient_code: NutrientCode("ENERGY_KCAL".to_string()),
                    amount_per_100g: AmountPer100g(Decimal::new(100, 0)),
                    source: None,
                    confidence: None,
                },
            ],
            servings: vec![],
            deleted_at: None,
        }
    }

    fn make_services(product: Option<Product>) -> FoodLogServices {
        let food_log_repo = Arc::new(MockFoodLogRepo::new()) as Arc<dyn FoodLogRepository>;
        let product_repo = match product {
            Some(p) => Arc::new(MockProductLookup::with_product(p)) as Arc<dyn ProductLookup>,
            None => Arc::new(MockProductLookup::empty()) as Arc<dyn ProductLookup>,
        };
        let summary_repo = Arc::new(MockSummaryRepo) as Arc<dyn SummaryRepository>;
        FoodLogServices::new(food_log_repo, product_repo, summary_repo)
    }

    #[tokio::test]
    async fn test_log_food_success() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let result = services.log_food(LogFoodInput {
            user_id,
            logged_at: Utc::now(),
            meal_slot: Some("lunch".to_string()),
            product_id: Uuid::nil(),
            quantity_amount: Decimal::new(100, 0),
            quantity_unit: "g".to_string(),
            notes: None,
        }).await;

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

        let result = services.log_food(LogFoodInput {
            user_id: Uuid::new_v4(),
            logged_at: Utc::now(),
            meal_slot: Some("lunch".to_string()),
            product_id: Uuid::new_v4(),
            quantity_amount: Decimal::new(100, 0),
            quantity_unit: "g".to_string(),
            notes: None,
        }).await;

        assert!(result.is_err());
        match result.unwrap_err() {
            FoodLogError::NotFound(msg) => assert!(msg.contains("product")),
            _ => panic!("expected NotFound"),
        }
    }

    #[tokio::test]
    async fn test_log_food_invalid_meal_slot() {
        let services = make_services(Some(sample_product()));

        let result = services.log_food(LogFoodInput {
            user_id: Uuid::new_v4(),
            logged_at: Utc::now(),
            meal_slot: Some("brunch".to_string()),
            product_id: Uuid::nil(),
            quantity_amount: Decimal::new(100, 0),
            quantity_unit: "g".to_string(),
            notes: None,
        }).await;

        assert!(result.is_err());
        match result.unwrap_err() {
            FoodLogError::Validation(msg) => assert!(msg.contains("brunch")),
            _ => panic!("expected Validation"),
        }
    }

    #[tokio::test]
    async fn test_get_food_log_success() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let created = services.log_food(LogFoodInput {
            user_id,
            logged_at: Utc::now(),
            meal_slot: None,
            product_id: Uuid::nil(),
            quantity_amount: Decimal::new(50, 0),
            quantity_unit: "g".to_string(),
            notes: Some("test note".to_string()),
        }).await.unwrap();

        let fetched = services.get_food_log(created.id).await.unwrap();
        assert_eq!(fetched.id, created.id);
        assert_eq!(fetched.notes, Some("test note".to_string()));
        assert_eq!(fetched.quantity_amount, Decimal::new(50, 0));
    }

    #[tokio::test]
    async fn test_get_food_log_not_found() {
        let services = make_services(Some(sample_product()));

        let result = services.get_food_log(FoodLogId::new()).await;
        assert!(result.is_err());
        match result.unwrap_err() {
            FoodLogError::NotFound(msg) => assert!(msg.contains("food log")),
            _ => panic!("expected NotFound"),
        }
    }

    #[tokio::test]
    async fn test_delete_food_log_success() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let created = services.log_food(LogFoodInput {
            user_id,
            logged_at: Utc::now(),
            meal_slot: Some("lunch".to_string()),
            product_id: Uuid::nil(),
            quantity_amount: Decimal::new(100, 0),
            quantity_unit: "g".to_string(),
            notes: None,
        }).await.unwrap();

        assert!(services.delete_food_log(created.id, user_id).await.is_ok());
        let fetch_result = services.get_food_log(created.id).await;
        assert!(fetch_result.is_err());
    }

    #[tokio::test]
    async fn test_delete_food_log_forbidden() {
        let services = make_services(Some(sample_product()));
        let owner = Uuid::new_v4();
        let other = Uuid::new_v4();

        let created = services.log_food(LogFoodInput {
            user_id: owner,
            logged_at: Utc::now(),
            meal_slot: Some("breakfast".to_string()),
            product_id: Uuid::nil(),
            quantity_amount: Decimal::new(100, 0),
            quantity_unit: "g".to_string(),
            notes: None,
        }).await.unwrap();

        let result = services.delete_food_log(created.id, other).await;
        assert!(result.is_err());
        match result.unwrap_err() {
            FoodLogError::Forbidden(msg) => assert!(msg.contains("not your")),
            _ => panic!("expected Forbidden"),
        }
    }

    #[tokio::test]
    async fn test_delete_food_log_not_found() {
        let services = make_services(Some(sample_product()));
        let result = services.delete_food_log(FoodLogId::new(), Uuid::new_v4()).await;
        assert!(result.is_err());
        match result.unwrap_err() {
            FoodLogError::NotFound(msg) => assert!(msg.contains("food log")),
            _ => panic!("expected NotFound"),
        }
    }

    #[tokio::test]
    async fn test_update_food_log_success() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let created = services.log_food(LogFoodInput {
            user_id,
            logged_at: Utc::now(),
            meal_slot: Some("lunch".to_string()),
            product_id: Uuid::nil(),
            quantity_amount: Decimal::new(100, 0),
            quantity_unit: "g".to_string(),
            notes: None,
        }).await.unwrap();

        let updated = services.update_food_log(created.id, user_id, UpdateFoodInput {
            logged_at: Some(Utc::now()),
            meal_slot: Some("dinner".to_string()),
            product_id: None,
            quantity_amount: Some(Decimal::new(200, 0)),
            quantity_unit: Some("g".to_string()),
            notes: Some("updated notes".to_string()),
        }).await.unwrap();

        assert_eq!(updated.meal_slot, Some(MealSlot::Dinner));
        assert_eq!(updated.quantity_amount, Decimal::new(200, 0));
        assert_eq!(updated.notes, Some("updated notes".to_string()));
    }

    #[tokio::test]
    async fn test_update_food_log_forbidden() {
        let services = make_services(Some(sample_product()));
        let owner = Uuid::new_v4();
        let other = Uuid::new_v4();

        let created = services.log_food(LogFoodInput {
            user_id: owner,
            logged_at: Utc::now(),
            meal_slot: Some("lunch".to_string()),
            product_id: Uuid::nil(),
            quantity_amount: Decimal::new(100, 0),
            quantity_unit: "g".to_string(),
            notes: None,
        }).await.unwrap();

        let result = services.update_food_log(created.id, other, UpdateFoodInput {
            logged_at: None,
            meal_slot: None,
            product_id: None,
            quantity_amount: None,
            quantity_unit: None,
            notes: None,
        }).await;

        assert!(result.is_err());
        match result.unwrap_err() {
            FoodLogError::Forbidden(msg) => assert!(msg.contains("not your")),
            _ => panic!("expected Forbidden"),
        }
    }

    #[tokio::test]
    async fn test_get_logs_for_range() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();
        let now = Utc::now();

        services.log_food(LogFoodInput {
            user_id,
            logged_at: now,
            meal_slot: Some("lunch".to_string()),
            product_id: Uuid::nil(),
            quantity_amount: Decimal::new(100, 0),
            quantity_unit: "g".to_string(),
            notes: None,
        }).await.unwrap();

        services.log_food(LogFoodInput {
            user_id,
            logged_at: now,
            meal_slot: Some("dinner".to_string()),
            product_id: Uuid::nil(),
            quantity_amount: Decimal::new(200, 0),
            quantity_unit: "g".to_string(),
            notes: None,
        }).await.unwrap();

        let from = now - chrono::Duration::hours(1);
        let to = now + chrono::Duration::hours(1);
        let logs = services.get_logs_for_range(user_id, from, to).await.unwrap();
        assert_eq!(logs.len(), 2);
    }

    #[tokio::test]
    async fn test_summary_delegates_to_repo() {
        let food_log_repo = Arc::new(MockFoodLogRepo::new()) as Arc<dyn FoodLogRepository>;
        let product_repo = Arc::new(MockProductLookup::empty()) as Arc<dyn ProductLookup>;
        let summary_repo = Arc::new(MockSummaryRepo) as Arc<dyn SummaryRepository>;
        let services = FoodLogServices::new(food_log_repo, product_repo, summary_repo);

        let result = services.get_summary(
            Uuid::new_v4(),
            Utc::now() - chrono::Duration::days(1),
            Utc::now(),
            Some(vec!["ENERGY_KCAL".to_string()]),
        ).await;

        assert!(result.is_ok());
        assert!(result.unwrap().is_empty());
    }
}
