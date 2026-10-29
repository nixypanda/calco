use async_trait::async_trait;
use chrono::NaiveDate;
use std::sync::Arc;
use uuid::Uuid;

use crate::nutrition::catalog::app::{CatalogReadPort, NutrientCatalogReadPort};
use crate::nutrition::catalog::domain::calculation::Quantity;
use crate::nutrition::catalog::domain::units::UnitConverter;
use crate::nutrition::food_log::domain::*;
use crate::nutrition::meal::app::MealReadPort;

pub struct LogFoodInput {
    pub log_date: NaiveDate,
    pub meal_slot: Option<MealSlot>,
    pub device_timezone: Option<String>,
    pub item: FoodLogItemRef,
    pub quantity: Quantity,
    pub notes: Option<String>,
}

pub struct LogAdHocFoodInput {
    pub log_date: NaiveDate,
    pub meal_slot: Option<MealSlot>,
    pub device_timezone: Option<String>,
    pub name: String,
    pub brand: Option<String>,
    pub quantity: Quantity,
    pub nutrients: Vec<FoodLogNutrientSnapshot>,
    pub notes: Option<String>,
}

pub struct UpdateFoodInput {
    pub log_date: Option<NaiveDate>,
    pub meal_slot: Option<Option<MealSlot>>,
    pub device_timezone: Option<Option<String>>,
    pub item: Option<FoodLogItemRef>,
    pub quantity: Option<Quantity>,
    pub notes: Option<Option<String>>,
}

#[derive(Clone)]
pub struct FoodLogService {
    food_log_repo: Arc<dyn FoodLogRepo>,
    catalog: Arc<dyn CatalogReadPort>,
    nutrient_catalog: Arc<dyn NutrientCatalogReadPort>,
    unit_converter: Arc<UnitConverter>,
    meals: Arc<dyn MealReadPort>,
    policy: FoodLogPolicy,
}

impl FoodLogService {
    pub fn new(
        food_log_repo: Arc<dyn FoodLogRepo>,
        catalog: Arc<dyn CatalogReadPort>,
        nutrient_catalog: Arc<dyn NutrientCatalogReadPort>,
        unit_converter: Arc<UnitConverter>,
        meals: Arc<dyn MealReadPort>,
    ) -> Self {
        Self {
            food_log_repo,
            catalog,
            nutrient_catalog,
            unit_converter,
            meals,
            policy: FoodLogPolicy,
        }
    }

    pub async fn log_item(
        &self,
        actor_id: Uuid,
        input: LogFoodInput,
    ) -> Result<FoodLog, NutritionError> {
        let log = self.build_log(actor_id, input).await?;
        self.food_log_repo.create(&log).await?;
        Ok(log)
    }

    pub async fn log_ad_hoc_food(
        &self,
        actor_id: Uuid,
        input: LogAdHocFoodInput,
    ) -> Result<FoodLog, NutritionError> {
        let nutrient_catalog = self.nutrient_catalog.nutrient_catalog().await?;
        for snapshot in &input.nutrients {
            let nutrient = nutrient_catalog
                .get(&snapshot.nutrient_code.0)
                .ok_or_else(|| {
                    NutritionError::Validation(format!(
                        "unknown ad-hoc nutrient code: {}",
                        snapshot.nutrient_code.0
                    ))
                })?;
            if snapshot.unit != nutrient.unit {
                return Err(NutritionError::Validation(format!(
                    "{} must use unit {}",
                    snapshot.nutrient_code.0, nutrient.unit.0
                )));
            }
        }
        let log = FoodLogBuilder::new_ad_hoc(
            actor_id,
            input.log_date,
            input.name,
            input.brand,
            input.quantity,
            input.nutrients,
        )?
        .meal_slot(input.meal_slot)
        .device_timezone(input.device_timezone)
        .notes(input.notes)
        .build();
        self.food_log_repo.create(&log).await?;
        Ok(log)
    }

    pub async fn log_items(
        &self,
        actor_id: Uuid,
        inputs: Vec<LogFoodInput>,
    ) -> Result<Vec<FoodLog>, NutritionError> {
        let mut logs = Vec::with_capacity(inputs.len());
        for input in inputs {
            logs.push(self.build_log(actor_id, input).await?);
        }
        self.food_log_repo.create_many(&logs).await?;
        Ok(logs)
    }

    async fn build_log(
        &self,
        actor_id: Uuid,
        input: LogFoodInput,
    ) -> Result<FoodLog, NutritionError> {
        let log = match input.item {
            FoodLogItemRef::Product(product_id) => {
                let product = self
                    .catalog
                    .resolve_products(actor_id, &[product_id])
                    .await?
                    .into_iter()
                    .find_map(|(id, product)| (id == product_id).then_some(product))
                    .ok_or_else(|| NutritionError::NotFound("product not found".into()))?;
                let nutrition = product
                    .nutrition_for(&input.quantity, &self.unit_converter)
                    .map_err(NutritionError::Validation)?;
                FoodLogBuilder::new(
                    actor_id,
                    input.log_date,
                    FoodLogItemSnapshot::from_product(&product),
                    input.quantity,
                    nutrition,
                )
                .meal_slot(input.meal_slot)
                .device_timezone(input.device_timezone)
                .notes(input.notes)
                .build()
            }
            FoodLogItemRef::Meal(meal_id) => {
                let resolved = self.meals.resolve_loggable_meal(actor_id, meal_id).await?;
                let nutrition = resolved
                    .meal
                    .nutrition_for(&input.quantity, &resolved.products, &self.unit_converter)
                    .map_err(NutritionError::Validation)?;
                FoodLogBuilder::new(
                    actor_id,
                    input.log_date,
                    FoodLogItemSnapshot::from_meal(&resolved.meal),
                    input.quantity,
                    nutrition,
                )
                .meal_slot(input.meal_slot)
                .device_timezone(input.device_timezone)
                .notes(input.notes)
                .build()
            }
        };
        Ok(log)
    }

    pub async fn update_food_log(
        &self,
        id: FoodLogId,
        actor_id: Uuid,
        input: UpdateFoodInput,
    ) -> Result<FoodLog, NutritionError> {
        let existing = self.get_food_log(id, actor_id).await?;

        let item = input.item;
        let quantity = input.quantity.unwrap_or_else(|| {
            Quantity::new(existing.quantity_amount(), existing.quantity_unit().clone())
                .expect("existing food log quantity must be valid")
        });
        let log_date = input.log_date.unwrap_or(existing.log_date());
        let meal_slot = match input.meal_slot {
            Some(opt) => opt,
            None => existing.meal_slot(),
        };
        let device_timezone = match input.device_timezone {
            Some(opt) => opt,
            None => existing.device_timezone().map(str::to_owned),
        };
        let notes = input
            .notes
            .unwrap_or_else(|| existing.notes().map(str::to_owned));

        let updated = match existing.item() {
            FoodLogItemSnapshot::AdHoc { .. } => {
                if item.is_some() {
                    return Err(NutritionError::Validation(
                        "the item of an ad-hoc food log cannot be changed".into(),
                    ));
                }
                existing.update_ad_hoc_log(log_date, meal_slot, device_timezone, quantity, notes)?
            }
            _ => match item.or_else(|| existing.item().as_ref()) {
                Some(FoodLogItemRef::Product(product_id)) => {
                    let product = self
                        .catalog
                        .resolve_products(actor_id, &[product_id])
                        .await?
                        .into_iter()
                        .find_map(|(id, product)| (id == product_id).then_some(product))
                        .ok_or_else(|| NutritionError::NotFound("product not found".into()))?;
                    existing.update_product_log(
                        log_date,
                        meal_slot,
                        device_timezone,
                        &product,
                        quantity,
                        &self.unit_converter,
                        notes,
                    )?
                }
                Some(FoodLogItemRef::Meal(meal_id)) => {
                    let resolved = self.meals.resolve_loggable_meal(actor_id, meal_id).await?;
                    existing.update_meal_log(
                        log_date,
                        meal_slot,
                        device_timezone,
                        &resolved.meal,
                        quantity,
                        &resolved.products,
                        &self.unit_converter,
                        notes,
                    )?
                }
                None => unreachable!("product and meal snapshots always have references"),
            },
        };

        self.food_log_repo.update(&updated).await?;
        Ok(updated)
    }

    pub async fn delete_food_log(
        &self,
        id: FoodLogId,
        actor_id: Uuid,
    ) -> Result<(), NutritionError> {
        self.get_food_log(id, actor_id).await?;
        self.food_log_repo.delete(id).await
    }

    pub async fn get_food_log(
        &self,
        id: FoodLogId,
        actor_id: Uuid,
    ) -> Result<FoodLog, NutritionError> {
        let log = self
            .food_log_repo
            .find_by_id(id)
            .await?
            .ok_or_else(|| NutritionError::NotFound("food log not found".into()))?;
        self.policy.authorize_access(actor_id, &log)?;
        Ok(log)
    }

    pub async fn list_food_logs(
        &self,
        actor_id: Uuid,
        log_date: NaiveDate,
    ) -> Result<Vec<FoodLog>, NutritionError> {
        self.food_log_repo
            .list_by_user_and_date(actor_id, log_date)
            .await
    }
}

#[async_trait]
pub trait FoodLogQueryPort: Send + Sync {
    async fn list_logs_for_date(
        &self,
        actor_id: Uuid,
        date: NaiveDate,
    ) -> Result<Vec<FoodLog>, NutritionError>;
}

#[async_trait]
impl FoodLogQueryPort for FoodLogService {
    async fn list_logs_for_date(
        &self,
        actor_id: Uuid,
        date: NaiveDate,
    ) -> Result<Vec<FoodLog>, NutritionError> {
        self.list_food_logs(actor_id, date).await
    }
}

#[cfg(test)]
mod tests {
    use super::super::test_support::*;
    use super::*;
    use crate::nutrition::catalog::domain::calculation::Quantity;
    use crate::nutrition::catalog::domain::{NutrientCode, Product, ProductId, UnitCode};
    use crate::nutrition::food_log::domain::{
        FoodLogItemRef, FoodLogItemSnapshot, FoodLogNutrientSnapshot, MealSlot, NutritionError,
    };
    use crate::nutrition::meal::domain::MealId;
    use rstest::rstest;
    use rust_decimal::Decimal;
    use uuid::Uuid;

    #[tokio::test]
    async fn log_ad_hoc_rejects_unknown_nutrient_code() {
        let services = make_services(None);
        let snapshot = |code: &str, amount: i64, unit: &str| FoodLogNutrientSnapshot {
            nutrient_code: NutrientCode(code.into()),
            amount: Decimal::from(amount),
            unit: UnitCode(unit.into()),
        };

        let result = services
            .log_ad_hoc_food(
                Uuid::new_v4(),
                LogAdHocFoodInput {
                    log_date: sample_log_date(),
                    meal_slot: None,
                    device_timezone: None,
                    name: "Mystery food".into(),
                    brand: None,
                    quantity: Quantity::new(Decimal::ONE, UnitCode("serving".into())).unwrap(),
                    nutrients: vec![
                        snapshot("ENERGY_KCAL", 100, "kcal"),
                        snapshot("PROTEIN_G", 1, "g"),
                        snapshot("CARBS_G", 1, "g"),
                        snapshot("FAT_G", 1, "g"),
                        snapshot("NOT_A_NUTRIENT", 1, "g"),
                    ],
                    notes: None,
                },
            )
            .await;

        match result {
            Err(NutritionError::Validation(message)) => assert!(
                message.contains("unknown ad-hoc nutrient code: NOT_A_NUTRIENT"),
                "unexpected message: {message}"
            ),
            Ok(_) => panic!("unknown nutrient must be rejected"),
            Err(other) => panic!("unexpected error: {other}"),
        }
    }

    #[derive(Clone, Copy, Debug)]
    enum MissingLoggableItem {
        Product,
        Meal,
    }

    #[rstest]
    #[case::product_not_found(MissingLoggableItem::Product)]
    #[case::meal_not_found(MissingLoggableItem::Meal)]
    #[tokio::test]
    async fn log_food_rejects_missing_item(#[case] missing: MissingLoggableItem) {
        let (services, item) = match missing {
            MissingLoggableItem::Product => (
                make_services(None),
                FoodLogItemRef::Product(ProductId(Uuid::new_v4())),
            ),
            MissingLoggableItem::Meal => (
                make_services_with_meal(Some(sample_product()), sample_meal()),
                FoodLogItemRef::Meal(MealId::new()),
            ),
        };

        let result = services
            .log_item(
                Uuid::new_v4(),
                LogFoodInput {
                    log_date: sample_log_date(),
                    device_timezone: None,
                    meal_slot: Some(MealSlot::Lunch),
                    item,
                    quantity: Quantity::new(Decimal::new(100, 0), UnitCode("g".to_string()))
                        .unwrap(),
                    notes: None,
                },
            )
            .await;

        assert!(
            matches!(&result, Err(NutritionError::NotFound(_))),
            "expected NotFound, got {result:?}"
        );
    }

    #[tokio::test]
    async fn test_get_food_log_hides_another_users_log() {
        let services = make_services(Some(sample_product()));
        let owner = Uuid::new_v4();
        let other = Uuid::new_v4();

        let created = services
            .log_item(
                owner,
                LogFoodInput {
                    log_date: sample_log_date(),
                    device_timezone: None,
                    meal_slot: Some(MealSlot::Breakfast),
                    item: FoodLogItemRef::Product(ProductId(Uuid::nil())),
                    quantity: Quantity::new(Decimal::new(100, 0), UnitCode("g".to_string()))
                        .unwrap(),
                    notes: None,
                },
            )
            .await
            .unwrap();

        assert!(matches!(
            services.get_food_log(created.id(), other).await,
            Err(NutritionError::NotFound(_))
        ));
        assert!(services.get_food_log(created.id(), owner).await.is_ok());
    }

    #[tokio::test]
    async fn test_update_food_log_can_clear_optional_fields() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let created = services
            .log_item(
                user_id,
                LogFoodInput {
                    log_date: sample_log_date(),
                    device_timezone: Some("Asia/Kolkata".to_string()),
                    meal_slot: Some(MealSlot::Lunch),
                    item: FoodLogItemRef::Product(ProductId(Uuid::nil())),
                    quantity: Quantity::new(Decimal::new(100, 0), UnitCode("g".to_string()))
                        .unwrap(),
                    notes: Some("clear me".to_string()),
                },
            )
            .await
            .unwrap();

        let updated = services
            .update_food_log(
                created.id(),
                user_id,
                UpdateFoodInput {
                    log_date: None,
                    device_timezone: Some(None),
                    meal_slot: Some(None),
                    item: None,
                    quantity: None,
                    notes: Some(None),
                },
            )
            .await
            .unwrap();

        assert_eq!(updated.meal_slot(), None);
        assert_eq!(updated.device_timezone(), None);
        assert_eq!(updated.notes(), None);
    }

    #[derive(Clone, Copy, Debug)]
    enum ExpectedLogOutcome {
        Energy(i64),
        Validation,
    }

    // Sample product: 100 kcal per 100 g. 2 kg = 2000 g -> 2000 kcal.
    // Serving: 30 g per slice; 2 slices = 60 g -> 60 kcal.
    #[rstest]
    #[case::kg_is_converted_to_grams(sample_product(), 2, "kg", ExpectedLogOutcome::Energy(2000))]
    #[case::serving_multiples_are_expanded(
        sample_product_with_serving(),
        2,
        "slice",
        ExpectedLogOutcome::Energy(60)
    )]
    #[case::unknown_unit_is_rejected(sample_product(), 1, "cup", ExpectedLogOutcome::Validation)]
    #[tokio::test]
    async fn log_product_converts_quantity_units(
        #[case] product: Product,
        #[case] amount: i64,
        #[case] unit: &str,
        #[case] expected: ExpectedLogOutcome,
    ) {
        let services = make_services(Some(product));

        let result = services
            .log_item(
                Uuid::new_v4(),
                LogFoodInput {
                    log_date: sample_log_date(),
                    device_timezone: None,
                    meal_slot: None,
                    item: FoodLogItemRef::Product(ProductId(Uuid::nil())),
                    quantity: Quantity::new(Decimal::from(amount), UnitCode(unit.to_string()))
                        .unwrap(),
                    notes: None,
                },
            )
            .await;

        match expected {
            ExpectedLogOutcome::Energy(expected_energy) => {
                let log = result.expect("quantity with a known unit should be logged");
                assert_eq!(log.nutrient_snapshots().len(), 1);
                assert_eq!(log.nutrient_snapshots()[0].nutrient_code.0, "ENERGY_KCAL");
                assert_eq!(
                    log.nutrient_snapshots()[0].amount,
                    Decimal::from(expected_energy)
                );
            }
            ExpectedLogOutcome::Validation => {
                assert!(
                    matches!(&result, Err(NutritionError::Validation(_))),
                    "expected Validation, got {result:?}"
                );
            }
        }
    }

    #[tokio::test]
    async fn test_update_existing_meal_log_recalculates_without_item_payload() {
        let services = make_services_with_meal(Some(sample_product()), sample_meal());
        let user_id = Uuid::new_v4();

        let created = services
            .log_item(
                user_id,
                LogFoodInput {
                    log_date: sample_log_date(),
                    device_timezone: None,
                    meal_slot: Some(MealSlot::Dinner),
                    item: FoodLogItemRef::Meal(MealId(Uuid::nil())),
                    quantity: Quantity::new(Decimal::new(100, 0), UnitCode("g".to_string()))
                        .unwrap(),
                    notes: None,
                },
            )
            .await
            .unwrap();

        let updated = services
            .update_food_log(
                created.id(),
                user_id,
                UpdateFoodInput {
                    log_date: None,
                    device_timezone: None,
                    meal_slot: None,
                    item: None,
                    quantity: Some(
                        Quantity::new(Decimal::new(200, 0), UnitCode("g".to_string())).unwrap(),
                    ),
                    notes: None,
                },
            )
            .await
            .unwrap();

        assert!(matches!(updated.item(), FoodLogItemSnapshot::Meal { .. }));
        assert_eq!(updated.quantity_amount(), Decimal::new(200, 0));
        assert_eq!(updated.nutrient_snapshots()[0].amount, Decimal::new(200, 0));
    }
}
