use super::*;
use crate::nutrition::catalog::app::{CatalogReadPort, NutrientCatalogReadPort};
use crate::nutrition::catalog::domain::units::UnitConverter;
use crate::nutrition::catalog::domain::*;
use crate::nutrition::food_log::domain::*;
use crate::nutrition::meal::app::{MealReadPort, ResolvedMeal};
use crate::nutrition::meal::domain::*;
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
impl FoodLogRepo for MockFoodLogRepo {
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
        Ok(logs.iter().find(|l| l.id() == id).cloned())
    }

    async fn list_by_user_and_date(
        &self,
        user_id: Uuid,
        log_date: NaiveDate,
    ) -> Result<Vec<FoodLog>, NutritionError> {
        let logs = self.logs.lock().unwrap();
        Ok(logs
            .iter()
            .filter(|l| l.user_id() == user_id && l.log_date() == log_date)
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
                log.user_id() == filter.user_id
                    && matches_date_range(log.log_date(), &filter.date_range)
                    && filter
                        .meal_slot
                        .is_none_or(|slot| log.meal_slot() == Some(slot))
                    && (filter.items.is_empty()
                        || filter
                            .items
                            .iter()
                            .any(|item| log_item_matches(log.item(), item)))
            })
            .cloned()
            .collect())
    }

    async fn update(&self, log: &FoodLog) -> Result<(), NutritionError> {
        let mut logs = self.logs.lock().unwrap();
        if let Some(existing) = logs.iter_mut().find(|l| l.id() == log.id()) {
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
            .position(|l| l.id() == id)
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
        Ok(self
            .product
            .clone()
            .filter(|product| ids.contains(&product.id))
            .map(|product| vec![(product.id, product)])
            .unwrap_or_default())
    }
}

struct MockMealReadPort {
    meal_id: MealId,
    meal: Option<Meal>,
}

struct MockNutrientCatalogReadPort;

#[async_trait]
impl NutrientCatalogReadPort for MockNutrientCatalogReadPort {
    async fn nutrient_catalog(&self) -> Result<NutrientCatalog, NutritionError> {
        Ok([
            ("ENERGY_KCAL", "kcal"),
            ("PROTEIN_G", "g"),
            ("CARBS_G", "g"),
            ("FAT_G", "g"),
            ("FIBER_G", "g"),
        ]
        .into_iter()
        .map(|(code, unit)| Nutrient {
            code: NutrientCode(code.into()),
            name: code.into(),
            unit: UnitCode(unit.into()),
            category: "test".into(),
        })
        .collect())
    }
}

impl MockMealReadPort {
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
impl MealReadPort for MockMealReadPort {
    async fn resolve_loggable_meal(
        &self,
        _actor_id: Uuid,
        id: MealId,
    ) -> Result<ResolvedMeal, NutritionError> {
        if id == self.meal_id {
            let meal = self
                .meal
                .clone()
                .ok_or_else(|| NutritionError::NotFound("meal not found".into()))?;
            Ok(ResolvedMeal {
                meal,
                products: vec![(ProductId(Uuid::nil()), sample_product())],
            })
        } else {
            Err(NutritionError::NotFound("meal not found".into()))
        }
    }
}

pub(super) fn sample_product() -> Product {
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

pub(super) fn sample_product_with_serving() -> Product {
    let mut product = sample_product();
    product.servings = vec![ProductServing {
        unit: UnitCode("slice".to_string()),
        grams_per_unit: Decimal::new(30, 0),
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

pub(super) fn make_services(product: Option<Product>) -> FoodLogService {
    build_services_with_repo(product, None).0
}

pub(super) fn make_services_with_meal(product: Option<Product>, meal: Meal) -> FoodLogService {
    build_services_with_repo(product, Some(meal)).0
}

pub(super) fn make_services_and_history(
    product: Option<Product>,
) -> (FoodLogService, FoodLogHistoryService) {
    let (services, repo) = build_services_with_repo(product, None);
    (services, FoodLogHistoryService::new(repo))
}

pub(super) fn make_services_with_repo(
    product: Option<Product>,
) -> (FoodLogService, Arc<dyn FoodLogRepo>) {
    build_services_with_repo(product, None)
}

pub(super) fn empty_history_services() -> FoodLogHistoryService {
    FoodLogHistoryService::new(Arc::new(MockFoodLogRepo::new()) as Arc<dyn FoodLogRepo>)
}

fn build_services_with_repo(
    product: Option<Product>,
    meal: Option<Meal>,
) -> (FoodLogService, Arc<dyn FoodLogRepo>) {
    let food_log_repo = Arc::new(MockFoodLogRepo::new()) as Arc<dyn FoodLogRepo>;
    let product_repo = match product {
        Some(p) => Arc::new(MockCatalogReadPort::with_product(p)) as Arc<dyn CatalogReadPort>,
        None => Arc::new(MockCatalogReadPort::empty()) as Arc<dyn CatalogReadPort>,
    };
    let meal_repo = match meal {
        Some(m) => Arc::new(MockMealReadPort::with_meal(m)) as Arc<dyn MealReadPort>,
        None => Arc::new(MockMealReadPort::empty()) as Arc<dyn MealReadPort>,
    };
    (
        FoodLogService::new(
            food_log_repo.clone(),
            product_repo,
            Arc::new(MockNutrientCatalogReadPort),
            sample_unit_converter(),
            meal_repo,
        ),
        food_log_repo,
    )
}
