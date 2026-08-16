use super::*;
use crate::nutrition::domain::catalog::*;
use crate::nutrition::domain::food_log::*;
use crate::nutrition::domain::meal::*;
use crate::nutrition::domain::units::UnitConverter;
use async_trait::async_trait;
use chrono::{NaiveDate, Utc};
use rust_decimal::Decimal;
use std::ops::Bound;
use std::sync::Arc;
use std::sync::Mutex;
use uuid::Uuid;

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

    async fn create_many(&self, logs: &[FoodLog]) -> Result<(), NutritionError> {
        self.logs.lock().unwrap().extend_from_slice(logs);
        Ok(())
    }

    async fn find_by_id(&self, id: FoodLogId) -> Result<Option<FoodLog>, NutritionError> {
        let logs = self.logs.lock().unwrap();
        Ok(logs.iter().find(|l| l.id == id).cloned())
    }

    async fn list_by_user_and_date(
        &self,
        user_id: Uuid,
        log_date: NaiveDate,
    ) -> Result<Vec<FoodLog>, NutritionError> {
        let logs = self.logs.lock().unwrap();
        Ok(logs
            .iter()
            .filter(|l| l.user_id == user_id && l.log_date == log_date)
            .cloned()
            .collect())
    }

    async fn list_by_filter(
        &self,
        filter: FoodLogListFilter,
    ) -> Result<Vec<FoodLog>, NutritionError> {
        let logs = self.logs.lock().unwrap();
        Ok(logs
            .iter()
            .filter(|log| {
                log.user_id == filter.user_id
                    && matches_date_range(log.log_date, &filter.date_range)
                    && filter
                        .meal_slot
                        .is_none_or(|slot| log.meal_slot == Some(slot))
                    && (filter.items.is_empty()
                        || filter
                            .items
                            .iter()
                            .any(|item| log_item_matches(&log.item, item)))
            })
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

fn matches_date_range(date: NaiveDate, range: &DateRange) -> bool {
    matches_lower_bound(date, &range.start) && matches_upper_bound(date, &range.end)
}

fn matches_lower_bound(date: NaiveDate, bound: &Bound<NaiveDate>) -> bool {
    match bound {
        Bound::Included(start) => date >= *start,
        Bound::Excluded(start) => date > *start,
        Bound::Unbounded => true,
    }
}

fn matches_upper_bound(date: NaiveDate, bound: &Bound<NaiveDate>) -> bool {
    match bound {
        Bound::Included(end) => date <= *end,
        Bound::Excluded(end) => date < *end,
        Bound::Unbounded => true,
    }
}

fn log_item_matches(snapshot: &FoodLogItemSnapshot, item: &FoodLogItemRef) -> bool {
    match (snapshot, item) {
        (FoodLogItemSnapshot::Product { id: left_id, .. }, FoodLogItemRef::Product(right_id)) => {
            left_id == right_id
        }
        (FoodLogItemSnapshot::Meal { id: left_id, .. }, FoodLogItemRef::Meal(right_id)) => {
            left_id == right_id
        }
        _ => false,
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
        _scope: ProductSearchScope,
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

    async fn find_by_barcode(
        &self,
        _barcode: &str,
        _user_id: Option<Uuid>,
    ) -> Result<Option<Product>, NutritionError> {
        unimplemented!("not used in test")
    }

    async fn list_by_user_id(&self, _user_id: Uuid) -> Result<Vec<Product>, NutritionError> {
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

pub(super) fn sample_product() -> Product {
    Product {
        id: ProductId(Uuid::nil()),
        source: Source::User,
        source_id: None,
        user_id: None,
        visibility: ProductVisibility::UserPrivate,
        barcode: None,
        name: ProductName::new("Test Food").unwrap(),
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

pub(super) fn sample_product_with_serving() -> Product {
    let mut product = sample_product();
    product.servings = vec![ProductServing {
        label: ServingLabel("slice".to_string()),
        quantity: Decimal::new(1, 0),
        unit: UnitCode("slice".to_string()),
        grams: Decimal::new(30, 0),
    }];
    product
}

pub(super) fn sample_meal() -> Meal {
    Meal {
        id: MealId(Uuid::nil()),
        user_id: Uuid::nil(),
        name: MealName::new("Test Meal").unwrap(),
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

pub(super) fn sample_log_date() -> NaiveDate {
    NaiveDate::from_ymd_opt(2026, 6, 1).unwrap()
}

pub(super) fn make_services(product: Option<Product>) -> FoodLogServices {
    build_services(product, None)
}

pub(super) fn make_services_with_meal(product: Option<Product>, meal: Meal) -> FoodLogServices {
    build_services(product, Some(meal))
}

pub(super) fn history_services_for(services: &FoodLogServices) -> FoodLogHistoryServices {
    FoodLogHistoryServices::new(services.food_log_repo.clone())
}

pub(super) fn empty_history_services() -> FoodLogHistoryServices {
    FoodLogHistoryServices::new(Arc::new(MockFoodLogRepo::new()) as Arc<dyn FoodLogRepository>)
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
