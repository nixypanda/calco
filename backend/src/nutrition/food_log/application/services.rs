use async_trait::async_trait;
use chrono::NaiveDate;
use std::sync::Arc;
use uuid::Uuid;

use crate::nutrition::catalog::application::CatalogReadPort;
use crate::nutrition::catalog::domain::calculation::Quantity;
use crate::nutrition::catalog::domain::units::UnitConverter;
use crate::nutrition::food_log::domain::*;
use crate::nutrition::meal::application::MealReadPort;

pub struct LogFoodInput {
    pub log_date: NaiveDate,
    pub meal_slot: Option<MealSlot>,
    pub device_timezone: Option<String>,
    pub item: FoodLogItemRef,
    pub quantity: Quantity,
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
    food_log_repo: Arc<dyn FoodLogRepository>,
    catalog: Arc<dyn CatalogReadPort>,
    unit_converter: Arc<UnitConverter>,
    meals: Arc<dyn MealReadPort>,
    policy: FoodLogPolicy,
}

impl FoodLogService {
    pub fn new(
        food_log_repo: Arc<dyn FoodLogRepository>,
        catalog: Arc<dyn CatalogReadPort>,
        unit_converter: Arc<UnitConverter>,
        meals: Arc<dyn MealReadPort>,
    ) -> Self {
        Self {
            food_log_repo,
            catalog,
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
                FoodLog::new_product_log(
                    actor_id,
                    input.log_date,
                    input.meal_slot,
                    input.device_timezone,
                    &product,
                    input.quantity,
                    &self.unit_converter,
                    input.notes,
                )?
            }
            FoodLogItemRef::Meal(meal_id) => {
                let resolved = self.meals.resolve_loggable_meal(actor_id, meal_id).await?;
                FoodLog::new_meal_log(
                    actor_id,
                    input.log_date,
                    input.meal_slot,
                    input.device_timezone,
                    &resolved.meal,
                    input.quantity,
                    &resolved.products,
                    &self.unit_converter,
                    input.notes,
                )?
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

        let item = input.item.unwrap_or_else(|| existing.item.as_ref());
        let quantity = input.quantity.unwrap_or_else(|| {
            Quantity::new(existing.quantity_amount, existing.quantity_unit.clone())
                .expect("existing food log quantity must be valid")
        });
        let log_date = input.log_date.unwrap_or(existing.log_date);
        let meal_slot = match input.meal_slot {
            Some(opt) => opt,
            None => existing.meal_slot,
        };
        let device_timezone = match input.device_timezone {
            Some(opt) => opt,
            None => existing.device_timezone.clone(),
        };
        let notes = input.notes.unwrap_or_else(|| existing.notes.clone());

        let updated = match item {
            FoodLogItemRef::Product(product_id) => {
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
            FoodLogItemRef::Meal(meal_id) => {
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
    use crate::nutrition::catalog::domain::{ProductId, UnitCode};
    use crate::nutrition::food_log::domain::{
        FoodLogId, FoodLogItemRef, FoodLogItemSnapshot, MealSlot, NutritionError,
    };
    use crate::nutrition::meal::domain::MealId;
    use rust_decimal::Decimal;
    use uuid::Uuid;

    #[tokio::test]
    async fn test_log_food_success() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let result = services
            .log_item(
                user_id,
                LogFoodInput {
                    log_date: sample_log_date(),
                    device_timezone: Some("Asia/Kolkata".to_string()),
                    meal_slot: Some(MealSlot::Lunch),
                    item: FoodLogItemRef::Product(ProductId(Uuid::nil())),
                    quantity: Quantity::new(Decimal::new(100, 0), UnitCode("g".to_string()))
                        .unwrap(),
                    notes: None,
                },
            )
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
            .log_item(
                Uuid::new_v4(),
                LogFoodInput {
                    log_date: sample_log_date(),
                    device_timezone: None,
                    meal_slot: Some(MealSlot::Lunch),
                    item: FoodLogItemRef::Product(ProductId(Uuid::new_v4())),
                    quantity: Quantity::new(Decimal::new(100, 0), UnitCode("g".to_string()))
                        .unwrap(),
                    notes: None,
                },
            )
            .await;

        assert!(result.is_err());
        match result.unwrap_err() {
            NutritionError::NotFound(_) => {}
            _ => panic!("expected NotFound"),
        }
    }

    #[tokio::test]
    async fn test_delete_food_log_success() {
        let (services, food_log_repo) = make_services_with_repo(Some(sample_product()));
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
                    notes: None,
                },
            )
            .await
            .unwrap();

        assert!(services.delete_food_log(created.id, user_id).await.is_ok());
        let still_there = food_log_repo.find_by_id(created.id).await.unwrap();
        assert!(still_there.is_none());
    }

    #[tokio::test]
    async fn test_delete_food_log_hides_another_users_log() {
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

        let result = services.delete_food_log(created.id, other).await;
        assert!(result.is_err());
        match result.unwrap_err() {
            NutritionError::NotFound(_) => {}
            _ => panic!("expected NotFound"),
        }
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
            services.get_food_log(created.id, other).await,
            Err(NutritionError::NotFound(_))
        ));
        assert!(services.get_food_log(created.id, owner).await.is_ok());
    }

    #[tokio::test]
    async fn food_log_query_port_is_scoped_to_actor() {
        let services = make_services(Some(sample_product()));
        let owner = Uuid::new_v4();
        let other = Uuid::new_v4();

        services
            .log_item(
                owner,
                LogFoodInput {
                    log_date: sample_log_date(),
                    device_timezone: None,
                    meal_slot: None,
                    item: FoodLogItemRef::Product(ProductId(Uuid::nil())),
                    quantity: Quantity::new(Decimal::new(100, 0), UnitCode("g".to_string()))
                        .unwrap(),
                    notes: None,
                },
            )
            .await
            .unwrap();

        assert_eq!(
            FoodLogQueryPort::list_logs_for_date(&services, owner, sample_log_date())
                .await
                .unwrap()
                .len(),
            1
        );
        assert!(
            FoodLogQueryPort::list_logs_for_date(&services, other, sample_log_date())
                .await
                .unwrap()
                .is_empty()
        );
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
            .log_item(
                user_id,
                LogFoodInput {
                    log_date: sample_log_date(),
                    device_timezone: None,
                    meal_slot: Some(MealSlot::Lunch),
                    item: FoodLogItemRef::Product(ProductId(Uuid::nil())),
                    quantity: Quantity::new(Decimal::new(100, 0), UnitCode("g".to_string()))
                        .unwrap(),
                    notes: None,
                },
            )
            .await
            .unwrap();

        let updated = services
            .update_food_log(
                created.id,
                user_id,
                UpdateFoodInput {
                    log_date: Some(sample_log_date()),
                    device_timezone: None,
                    meal_slot: Some(Some(MealSlot::Dinner)),
                    item: None,
                    quantity: Some(
                        Quantity::new(Decimal::new(200, 0), UnitCode("g".to_string())).unwrap(),
                    ),
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
                created.id,
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

        assert_eq!(updated.meal_slot, None);
        assert_eq!(updated.device_timezone, None);
        assert_eq!(updated.notes, None);
    }

    #[tokio::test]
    async fn test_log_food_uses_unit_converter_for_kg() {
        let services = make_services(Some(sample_product()));

        let log = services
            .log_item(
                Uuid::new_v4(),
                LogFoodInput {
                    log_date: sample_log_date(),
                    device_timezone: None,
                    meal_slot: None,
                    item: FoodLogItemRef::Product(ProductId(Uuid::nil())),
                    quantity: Quantity::new(Decimal::new(2, 0), UnitCode("kg".to_string()))
                        .unwrap(),
                    notes: None,
                },
            )
            .await
            .unwrap();

        // sample product has 100 kcal per 100g → 2 kg = 2000 g → 2000 kcal
        assert_eq!(log.nutrient_snapshots[0].amount, Decimal::new(2000, 0));
    }

    #[tokio::test]
    async fn test_log_food_rejects_unknown_unit() {
        let services = make_services(Some(sample_product()));

        let result = services
            .log_item(
                Uuid::new_v4(),
                LogFoodInput {
                    log_date: sample_log_date(),
                    device_timezone: None,
                    meal_slot: None,
                    item: FoodLogItemRef::Product(ProductId(Uuid::nil())),
                    quantity: Quantity::new(Decimal::new(1, 0), UnitCode("cup".to_string()))
                        .unwrap(),
                    notes: None,
                },
            )
            .await;

        assert!(matches!(result, Err(NutritionError::Validation(_))));
    }

    #[tokio::test]
    async fn test_log_food_accepts_serving_multiples() {
        let services = make_services(Some(sample_product_with_serving()));

        let log = services
            .log_item(
                Uuid::new_v4(),
                LogFoodInput {
                    log_date: sample_log_date(),
                    device_timezone: None,
                    meal_slot: None,
                    item: FoodLogItemRef::Product(ProductId(Uuid::nil())),
                    quantity: Quantity::new(Decimal::new(2, 0), UnitCode("slice".to_string()))
                        .unwrap(),
                    notes: None,
                },
            )
            .await
            .unwrap();

        assert_eq!(log.nutrient_snapshots[0].amount, Decimal::new(60, 0));
    }

    #[tokio::test]
    async fn test_update_food_log_hides_another_users_log() {
        let services = make_services(Some(sample_product()));
        let owner = Uuid::new_v4();
        let other = Uuid::new_v4();

        let created = services
            .log_item(
                owner,
                LogFoodInput {
                    log_date: sample_log_date(),
                    device_timezone: None,
                    meal_slot: Some(MealSlot::Lunch),
                    item: FoodLogItemRef::Product(ProductId(Uuid::nil())),
                    quantity: Quantity::new(Decimal::new(100, 0), UnitCode("g".to_string()))
                        .unwrap(),
                    notes: None,
                },
            )
            .await
            .unwrap();

        let result = services
            .update_food_log(
                created.id,
                other,
                UpdateFoodInput {
                    log_date: None,
                    device_timezone: None,
                    meal_slot: None,
                    item: None,
                    quantity: None,
                    notes: None,
                },
            )
            .await;

        assert!(result.is_err());
        match result.unwrap_err() {
            NutritionError::NotFound(_) => {}
            _ => panic!("expected NotFound"),
        }
    }

    #[tokio::test]
    async fn test_log_meal_success() {
        let services = make_services_with_meal(Some(sample_product()), sample_meal());
        let user_id = Uuid::new_v4();

        let result = services
            .log_item(
                user_id,
                LogFoodInput {
                    log_date: sample_log_date(),
                    device_timezone: None,
                    meal_slot: Some(MealSlot::Dinner),
                    item: FoodLogItemRef::Meal(MealId(Uuid::nil())),
                    quantity: Quantity::new(Decimal::new(150, 0), UnitCode("g".to_string()))
                        .unwrap(),
                    notes: Some("meal note".to_string()),
                },
            )
            .await;

        assert!(result.is_ok());
        let log = result.unwrap();
        assert_eq!(log.user_id, user_id);
        assert_eq!(log.meal_slot, Some(MealSlot::Dinner));
        assert!(matches!(log.item, FoodLogItemSnapshot::Meal { .. }));
        assert_eq!(log.nutrient_snapshots.len(), 1);
        assert_eq!(log.nutrient_snapshots[0].nutrient_code.0, "ENERGY_KCAL");
        assert_eq!(log.nutrient_snapshots[0].amount, Decimal::new(150, 0));
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
                created.id,
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

        assert!(matches!(updated.item, FoodLogItemSnapshot::Meal { .. }));
        assert_eq!(updated.quantity_amount, Decimal::new(200, 0));
        assert_eq!(updated.nutrient_snapshots[0].amount, Decimal::new(200, 0));
    }

    #[tokio::test]
    async fn test_log_meal_not_found() {
        let services = make_services_with_meal(Some(sample_product()), sample_meal());

        let result = services
            .log_item(
                Uuid::new_v4(),
                LogFoodInput {
                    log_date: sample_log_date(),
                    device_timezone: None,
                    meal_slot: Some(MealSlot::Lunch),
                    item: FoodLogItemRef::Meal(MealId::new()),
                    quantity: Quantity::new(Decimal::new(100, 0), UnitCode("g".to_string()))
                        .unwrap(),
                    notes: None,
                },
            )
            .await;

        assert!(result.is_err());
        match result.unwrap_err() {
            NutritionError::NotFound(_) => {}
            _ => panic!("expected NotFound"),
        }
    }
}
