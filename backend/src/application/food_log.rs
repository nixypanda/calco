use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use std::sync::Arc;
use uuid::Uuid;

use crate::domain::catalog::*;
use crate::domain::food_log::*;
use crate::domain::meal::{Meal, MealId, MealComponentItem};
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
pub trait MealLookup: Send + Sync {
    async fn find_by_id(&self, id: MealId) -> Result<Option<Meal>, FoodLogError>;
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
    pub product_repo: Arc<dyn ProductLookup>,
    pub summary_repo: Arc<dyn SummaryRepository>,
    pub meal_lookup: Option<Arc<dyn MealLookup>>,
    pub meal_product_lookup: Option<Arc<dyn ProductLookup>>,
}

impl FoodLogServices {
    pub fn new(
        food_log_repo: Arc<dyn FoodLogRepository>,
        product_repo: Arc<dyn ProductLookup>,
        summary_repo: Arc<dyn SummaryRepository>,
    ) -> Self {
        Self {
            food_log_repo,
            product_repo,
            summary_repo,
            meal_lookup: None,
            meal_product_lookup: None,
        }
    }

    pub fn with_meal_support(
        mut self,
        meal_lookup: Arc<dyn MealLookup>,
        meal_product_lookup: Arc<dyn ProductLookup>,
    ) -> Self {
        self.meal_lookup = Some(meal_lookup);
        self.meal_product_lookup = Some(meal_product_lookup);
        self
    }

    pub async fn log_food(&self, input: LogFoodInput) -> Result<FoodLog, FoodLogError> {
        if input.item_type != "product" {
            return Err(FoodLogError::Validation(format!(
                "unsupported item type for log_food: {}",
                input.item_type
            )));
        }

        let product_id = ProductId(input.item_id);
        let product = self.product_repo.find_by_id(product_id).await?
            .ok_or_else(|| FoodLogError::NotFound(format!("product {} not found", input.item_id)))?;

        let quantity = Quantity::new(input.quantity_amount, UnitCode(input.quantity_unit.clone()));
        let grams = convert_to_grams(&quantity, &product)?;

        let nutrients: Vec<(NutrientCode, AmountPer100g, UnitCode)> = product.nutrients.iter().map(|pn| {
            (pn.nutrient_code.clone(), pn.amount_per_100g.clone(), pn.unit.clone())
        }).collect();

        let calculated = NutritionCalculator::calculate(grams, &nutrients);

        let meal_slot = match input.meal_slot {
            Some(ref s) => Some(MealSlot::from_str(s).map_err(FoodLogError::Validation)?),
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

    pub async fn log_meal(&self, input: LogFoodInput) -> Result<FoodLog, FoodLogError> {
        let meal_lookup = self.meal_lookup.as_ref()
            .ok_or_else(|| FoodLogError::Internal("meal support not configured".into()))?;
        let meal_product_lookup = self.meal_product_lookup.as_ref()
            .ok_or_else(|| FoodLogError::Internal("meal support not configured".into()))?;

        let meal_id = MealId(input.item_id);
        let meal = meal_lookup.find_by_id(meal_id).await?
            .ok_or_else(|| FoodLogError::NotFound(format!("meal {} not found", input.item_id)))?;

        let scale_quantity = Quantity::new(input.quantity_amount, UnitCode(input.quantity_unit.clone()));
        let scale_grams = meal_quantity_to_grams(&scale_quantity, &meal)?;

        let mut total_nutrients: Vec<(NutrientCode, Decimal, UnitCode)> = Vec::new();
        let mut total_component_grams = Decimal::ZERO;

        for component in &meal.components {
            match &component.item {
                MealComponentItem::Product(product_id) => {
                    let product = meal_product_lookup.find_by_id(*product_id).await?
                        .ok_or_else(|| FoodLogError::NotFound(format!(
                            "product {} in meal {} not found",
                            product_id.0, meal.id.0
                        )))?;

                    let component_qty = Quantity::new(component.quantity_amount, component.quantity_unit.clone());
                    let component_grams = convert_to_grams(&component_qty, &product)?;
                    total_component_grams += component_grams;

                    let contribution_ratio = component_grams / Decimal::new(100, 0);
                    for pn in &product.nutrients {
                        let existing = total_nutrients.iter_mut().find(|(code, _, _)| code == &pn.nutrient_code);
                        let contributed_amount = pn.amount_per_100g.0 * contribution_ratio;
                        match existing {
                            Some((_, existing_amount, _)) => {
                                *existing_amount += contributed_amount;
                            }
                            None => {
                                total_nutrients.push((
                                    pn.nutrient_code.clone(),
                                    contributed_amount,
                                    pn.unit.clone(),
                                ));
                            }
                        }
                    }
                }
            }
        }

        if total_component_grams <= Decimal::ZERO {
            return Err(FoodLogError::Validation("meal total quantity must be positive".into()));
        }
        let scale_factor = scale_grams / total_component_grams;
        let snapshots: Vec<FoodLogNutrientSnapshot> = total_nutrients.into_iter().map(|(code, amount, unit)| {
            FoodLogNutrientSnapshot {
                nutrient_code: code,
                amount: amount * scale_factor,
                unit,
            }
        }).collect();

        let meal_slot = match input.meal_slot {
            Some(ref s) => Some(MealSlot::from_str(s).map_err(FoodLogError::Validation)?),
            None => None,
        };

        let log = FoodLog {
            id: FoodLogId::new(),
            user_id: input.user_id,
            logged_at: input.logged_at,
            meal_slot,
            item: LoggedItem::Meal(meal_id),
            quantity_amount: input.quantity_amount,
            quantity_unit: UnitCode(input.quantity_unit),
            nutrient_snapshots: snapshots,
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

        let item_type = input.item_type.as_deref().unwrap_or_else(|| log_item_type(&existing.item));
        let item_id = input.item_id.unwrap_or_else(|| existing.item_id());

        if item_type == "product" {
            let product = self.product_repo.find_by_id(ProductId(item_id)).await?
                .ok_or_else(|| FoodLogError::NotFound("product not found".into()))?;

            let quantity_amount = input.quantity_amount.unwrap_or(existing.quantity_amount);
            let quantity_unit_str = input.quantity_unit.unwrap_or_else(|| existing.quantity_unit.0.clone());
            let quantity = Quantity::new(quantity_amount, UnitCode(quantity_unit_str.clone()));
            let grams = convert_to_grams(&quantity, &product)?;

            let nutrients: Vec<(NutrientCode, AmountPer100g, UnitCode)> = product.nutrients.iter().map(|pn| {
                (pn.nutrient_code.clone(), pn.amount_per_100g.clone(), pn.unit.clone())
            }).collect();

            let calculated = NutritionCalculator::calculate(grams, &nutrients);

            let logged_at = input.logged_at.unwrap_or(existing.logged_at);
            let meal_slot = match input.meal_slot {
                Some(Some(ref s)) => Some(MealSlot::from_str(s).map_err(FoodLogError::Validation)?),
                Some(None) => None,
                None => existing.meal_slot,
            };
            let notes = input.notes.unwrap_or(existing.notes);

            let updated = FoodLog {
                id,
                user_id,
                logged_at,
                meal_slot,
                item: LoggedItem::Product(ProductId(item_id)),
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
        } else if item_type == "meal" {
            let meal_lookup = self.meal_lookup.as_ref()
                .ok_or_else(|| FoodLogError::Internal("meal support not configured".into()))?;
            let meal_product_lookup = self.meal_product_lookup.as_ref()
                .ok_or_else(|| FoodLogError::Internal("meal support not configured".into()))?;
            let meal_id = MealId(item_id);
            let meal = meal_lookup.find_by_id(meal_id).await?
                .ok_or_else(|| FoodLogError::NotFound("meal not found".into()))?;
            let quantity_amount = input.quantity_amount.unwrap_or(existing.quantity_amount);
            let quantity_unit_str = input.quantity_unit.unwrap_or_else(|| existing.quantity_unit.0.clone());
            let scale_quantity = Quantity::new(quantity_amount, UnitCode(quantity_unit_str.clone()));
            let scale_grams = meal_quantity_to_grams(&scale_quantity, &meal)?;
            let mut total_nutrients: Vec<(NutrientCode, Decimal, UnitCode)> = Vec::new();
            let mut total_component_grams = Decimal::ZERO;

            for component in &meal.components {
                match &component.item {
                    MealComponentItem::Product(product_id) => {
                        let product = meal_product_lookup.find_by_id(*product_id).await?
                            .ok_or_else(|| FoodLogError::NotFound("product in meal not found".into()))?;
                        let component_qty = Quantity::new(component.quantity_amount, component.quantity_unit.clone());
                        let component_grams = convert_to_grams(&component_qty, &product)?;
                        total_component_grams += component_grams;
                        let contribution_ratio = component_grams / Decimal::new(100, 0);
                        for pn in &product.nutrients {
                            let contributed_amount = pn.amount_per_100g.0 * contribution_ratio;
                            match total_nutrients.iter_mut().find(|(code, _, _)| code == &pn.nutrient_code) {
                                Some((_, existing_amount, _)) => *existing_amount += contributed_amount,
                                None => total_nutrients.push((
                                    pn.nutrient_code.clone(),
                                    contributed_amount,
                                    pn.unit.clone(),
                                )),
                            }
                        }
                    }
                }
            }

            if total_component_grams <= Decimal::ZERO {
                return Err(FoodLogError::Validation("meal total quantity must be positive".into()));
            }
            let scale_factor = scale_grams / total_component_grams;
            let logged_at = input.logged_at.unwrap_or(existing.logged_at);
            let meal_slot = match input.meal_slot {
                Some(Some(ref s)) => Some(MealSlot::from_str(s).map_err(FoodLogError::Validation)?),
                Some(None) => None,
                None => existing.meal_slot,
            };
            let notes = input.notes.unwrap_or(existing.notes);
            let updated = FoodLog {
                id,
                user_id,
                logged_at,
                meal_slot,
                item: LoggedItem::Meal(meal_id),
                quantity_amount,
                quantity_unit: UnitCode(quantity_unit_str),
                nutrient_snapshots: total_nutrients.into_iter().map(|(code, amount, unit)| FoodLogNutrientSnapshot {
                    nutrient_code: code,
                    amount: amount * scale_factor,
                    unit,
                }).collect(),
                notes,
            };

            self.food_log_repo.update(&updated).await?;
            Ok(updated)
        } else {
            Err(FoodLogError::Validation(format!("unsupported item type: {}", item_type)))
        }
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
    if quantity.amount <= Decimal::ZERO {
        return Err(FoodLogError::Validation("quantity amount must be positive".into()));
    }
    if quantity.unit.0 == "g" {
        return Ok(quantity.amount);
    }
    if quantity.unit.0 == "kg" {
        return Ok(quantity.amount * Decimal::new(1000, 0));
    }
    for serving in &product.servings {
        if serving.unit.0 == quantity.unit.0 && serving.quantity > Decimal::ZERO {
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

fn meal_quantity_to_grams(quantity: &Quantity, meal: &Meal) -> Result<Decimal, FoodLogError> {
    if quantity.amount <= Decimal::ZERO {
        return Err(FoodLogError::Validation("quantity amount must be positive".into()));
    }
    if quantity.unit.0 == "g" {
        return Ok(quantity.amount);
    }
    match (&meal.total_quantity_amount, &meal.total_quantity_unit) {
        (Some(total_amount), Some(total_unit))
            if total_unit.0 == quantity.unit.0 && *total_amount > Decimal::ZERO =>
        {
            Ok(quantity.amount / *total_amount * total_meal_declared_grams(meal)?)
        }
        _ => Err(FoodLogError::Validation(format!(
            "cannot convert {} {} to grams for meal logging",
            quantity.amount, quantity.unit.0
        ))),
    }
}

fn total_meal_declared_grams(meal: &Meal) -> Result<Decimal, FoodLogError> {
    match (&meal.total_quantity_amount, &meal.total_quantity_unit) {
        (Some(amount), Some(unit)) if unit.0 == "g" && *amount > Decimal::ZERO => Ok(*amount),
        _ => Err(FoodLogError::Validation(
            "meal total quantity must be defined in grams for non-gram logging".into(),
        )),
    }
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
            crate::application::catalog::CatalogError::Validation(msg) => FoodLogError::Validation(msg),
            crate::application::catalog::CatalogError::Database(msg) => FoodLogError::Database(msg),
            crate::application::catalog::CatalogError::Internal(msg) => FoodLogError::Internal(msg),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::meal::*;
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

    struct MockMealLookup {
        meal_id: MealId,
        meal: Option<Meal>,
    }

    impl MockMealLookup {
        fn with_meal(meal: Meal) -> Self {
            Self {
                meal_id: meal.id,
                meal: Some(meal),
            }
        }
    }

    #[async_trait]
    impl MealLookup for MockMealLookup {
        async fn find_by_id(&self, id: MealId) -> Result<Option<Meal>, FoodLogError> {
            if id == self.meal_id {
                Ok(self.meal.clone())
            } else {
                Ok(None)
            }
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
                    unit: UnitCode("kcal".to_string()),
                    source: None,
                    confidence: None,
                },
            ],
            servings: vec![],
            deleted_at: None,
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
            components: vec![
                MealComponent {
                    id: Uuid::new_v4(),
                    item: MealComponentItem::Product(ProductId(Uuid::nil())),
                    quantity_amount: Decimal::new(100, 0),
                    quantity_unit: UnitCode("g".to_string()),
                },
            ],
            created_at: Utc::now(),
            updated_at: Utc::now(),
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

    fn make_services_with_meal(product: Option<Product>, meal: Meal) -> FoodLogServices {
        let food_log_repo = Arc::new(MockFoodLogRepo::new()) as Arc<dyn FoodLogRepository>;
        let product_repo = match product {
            Some(p) => Arc::new(MockProductLookup::with_product(p)) as Arc<dyn ProductLookup>,
            None => Arc::new(MockProductLookup::empty()) as Arc<dyn ProductLookup>,
        };
        let summary_repo = Arc::new(MockSummaryRepo) as Arc<dyn SummaryRepository>;
        let meal_lookup = Arc::new(MockMealLookup::with_meal(meal)) as Arc<dyn MealLookup>;
        let meal_product_lookup = product_repo.clone();
        FoodLogServices::new(food_log_repo, product_repo, summary_repo)
            .with_meal_support(meal_lookup, meal_product_lookup)
    }

    #[tokio::test]
    async fn test_log_food_success() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let result = services.log_food(LogFoodInput {
            user_id,
            logged_at: Utc::now(),
            meal_slot: Some("lunch".to_string()),
            item_type: "product".to_string(),
            item_id: Uuid::nil(),
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
            item_type: "product".to_string(),
            item_id: Uuid::new_v4(),
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
            item_type: "product".to_string(),
            item_id: Uuid::nil(),
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
    async fn test_log_food_wrong_item_type() {
        let services = make_services(Some(sample_product()));

        let result = services.log_food(LogFoodInput {
            user_id: Uuid::new_v4(),
            logged_at: Utc::now(),
            meal_slot: Some("lunch".to_string()),
            item_type: "meal".to_string(),
            item_id: Uuid::nil(),
            quantity_amount: Decimal::new(100, 0),
            quantity_unit: "g".to_string(),
            notes: None,
        }).await;

        assert!(result.is_err());
        match result.unwrap_err() {
            FoodLogError::Validation(msg) => assert!(msg.contains("unsupported item type")),
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
            item_type: "product".to_string(),
            item_id: Uuid::nil(),
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
            item_type: "product".to_string(),
            item_id: Uuid::nil(),
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
            item_type: "product".to_string(),
            item_id: Uuid::nil(),
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
            item_type: "product".to_string(),
            item_id: Uuid::nil(),
            quantity_amount: Decimal::new(100, 0),
            quantity_unit: "g".to_string(),
            notes: None,
        }).await.unwrap();

        let updated = services.update_food_log(created.id, user_id, UpdateFoodInput {
            logged_at: Some(Utc::now()),
            meal_slot: Some(Some("dinner".to_string())),
            item_type: None,
            item_id: None,
            quantity_amount: Some(Decimal::new(200, 0)),
            quantity_unit: Some("g".to_string()),
            notes: Some(Some("updated notes".to_string())),
        }).await.unwrap();

        assert_eq!(updated.meal_slot, Some(MealSlot::Dinner));
        assert_eq!(updated.quantity_amount, Decimal::new(200, 0));
        assert_eq!(updated.notes, Some("updated notes".to_string()));
    }

    #[tokio::test]
    async fn test_update_food_log_can_clear_optional_fields() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let created = services.log_food(LogFoodInput {
            user_id,
            logged_at: Utc::now(),
            meal_slot: Some("lunch".to_string()),
            item_type: "product".to_string(),
            item_id: Uuid::nil(),
            quantity_amount: Decimal::new(100, 0),
            quantity_unit: "g".to_string(),
            notes: Some("clear me".to_string()),
        }).await.unwrap();

        let updated = services.update_food_log(created.id, user_id, UpdateFoodInput {
            logged_at: None,
            meal_slot: Some(None),
            item_type: None,
            item_id: None,
            quantity_amount: None,
            quantity_unit: None,
            notes: Some(None),
        }).await.unwrap();

        assert_eq!(updated.meal_slot, None);
        assert_eq!(updated.notes, None);
    }

    #[tokio::test]
    async fn test_log_food_accepts_serving_multiples() {
        let services = make_services(Some(sample_product_with_serving()));

        let log = services.log_food(LogFoodInput {
            user_id: Uuid::new_v4(),
            logged_at: Utc::now(),
            meal_slot: None,
            item_type: "product".to_string(),
            item_id: Uuid::nil(),
            quantity_amount: Decimal::new(2, 0),
            quantity_unit: "slice".to_string(),
            notes: None,
        }).await.unwrap();

        assert_eq!(log.nutrient_snapshots[0].amount, Decimal::new(60, 0));
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
            item_type: "product".to_string(),
            item_id: Uuid::nil(),
            quantity_amount: Decimal::new(100, 0),
            quantity_unit: "g".to_string(),
            notes: None,
        }).await.unwrap();

        let result = services.update_food_log(created.id, other, UpdateFoodInput {
            logged_at: None,
            meal_slot: None,
            item_type: None,
            item_id: None,
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
            item_type: "product".to_string(),
            item_id: Uuid::nil(),
            quantity_amount: Decimal::new(100, 0),
            quantity_unit: "g".to_string(),
            notes: None,
        }).await.unwrap();

        services.log_food(LogFoodInput {
            user_id,
            logged_at: now,
            meal_slot: Some("dinner".to_string()),
            item_type: "product".to_string(),
            item_id: Uuid::nil(),
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

    #[tokio::test]
    async fn test_log_meal_success() {
        let services = make_services_with_meal(Some(sample_product()), sample_meal());
        let user_id = Uuid::new_v4();

        let result = services.log_meal(LogFoodInput {
            user_id,
            logged_at: Utc::now(),
            meal_slot: Some("dinner".to_string()),
            item_type: "meal".to_string(),
            item_id: Uuid::nil(),
            quantity_amount: Decimal::new(150, 0),
            quantity_unit: "g".to_string(),
            notes: Some("meal note".to_string()),
        }).await;

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

        let created = services.log_meal(LogFoodInput {
            user_id,
            logged_at: Utc::now(),
            meal_slot: Some("dinner".to_string()),
            item_type: "meal".to_string(),
            item_id: Uuid::nil(),
            quantity_amount: Decimal::new(100, 0),
            quantity_unit: "g".to_string(),
            notes: None,
        }).await.unwrap();

        let updated = services.update_food_log(created.id, user_id, UpdateFoodInput {
            logged_at: None,
            meal_slot: None,
            item_type: None,
            item_id: None,
            quantity_amount: Some(Decimal::new(200, 0)),
            quantity_unit: None,
            notes: None,
        }).await.unwrap();

        assert!(matches!(updated.item, LoggedItem::Meal(_)));
        assert_eq!(updated.quantity_amount, Decimal::new(200, 0));
        assert_eq!(updated.nutrient_snapshots[0].amount, Decimal::new(200, 0));
    }

    #[tokio::test]
    async fn test_log_meal_not_found() {
        let services = make_services_with_meal(Some(sample_product()), sample_meal());

        let result = services.log_meal(LogFoodInput {
            user_id: Uuid::new_v4(),
            logged_at: Utc::now(),
            meal_slot: Some("lunch".to_string()),
            item_type: "meal".to_string(),
            item_id: MealId::new().0,
            quantity_amount: Decimal::new(100, 0),
            quantity_unit: "g".to_string(),
            notes: None,
        }).await;

        assert!(result.is_err());
        match result.unwrap_err() {
            FoodLogError::NotFound(msg) => assert!(msg.contains("meal")),
            _ => panic!("expected NotFound"),
        }
    }

    #[tokio::test]
    async fn test_log_meal_no_meal_support() {
        let services = make_services(Some(sample_product()));

        let result = services.log_meal(LogFoodInput {
            user_id: Uuid::new_v4(),
            logged_at: Utc::now(),
            meal_slot: Some("lunch".to_string()),
            item_type: "meal".to_string(),
            item_id: Uuid::nil(),
            quantity_amount: Decimal::new(100, 0),
            quantity_unit: "g".to_string(),
            notes: None,
        }).await;

        assert!(result.is_err());
        match result.unwrap_err() {
            FoodLogError::Internal(msg) => assert!(msg.contains("not configured")),
            _ => panic!("expected Internal"),
        }
    }
}
