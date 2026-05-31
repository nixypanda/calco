use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

use super::catalog::{ProductId, UnitCode};

use crate::application::food_log::FoodLogError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct MealId(pub Uuid);

impl MealId {
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }
}

impl From<Uuid> for MealId {
    fn from(id: Uuid) -> Self {
        Self(id)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MealName(pub String);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MealNotes(pub String);

#[derive(Debug, Clone)]
pub enum MealComponentItem {
    Product(ProductId),
}

#[derive(Debug, Clone)]
pub struct MealComponent {
    pub id: Uuid,
    pub item: MealComponentItem,
    pub quantity_amount: Decimal,
    pub quantity_unit: UnitCode,
}

#[derive(Debug, Clone)]
pub struct Meal {
    pub id: MealId,
    pub user_id: Uuid,
    pub name: MealName,
    pub notes: Option<MealNotes>,
    pub total_quantity_amount: Option<Decimal>,
    pub total_quantity_unit: Option<UnitCode>,
    pub components: Vec<MealComponent>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl Meal {
    pub fn is_owned_by(&self, user_id: Uuid) -> bool {
        self.user_id == user_id
    }
}

#[derive(Debug)]
pub enum MealError {
    NotFound(String),
    Forbidden(String),
    Validation(String),
    Database(String),
    Internal(String),
}

impl std::fmt::Display for MealError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MealError::NotFound(msg) => write!(f, "not found: {msg}"),
            MealError::Forbidden(msg) => write!(f, "forbidden: {msg}"),
            MealError::Validation(msg) => write!(f, "validation: {msg}"),
            MealError::Database(msg) => write!(f, "database: {msg}"),
            MealError::Internal(msg) => write!(f, "internal: {msg}"),
        }
    }
}

impl std::error::Error for MealError {}

impl From<MealError> for FoodLogError {
    fn from(e: MealError) -> Self {
        match e {
            MealError::NotFound(msg) => FoodLogError::NotFound(msg),
            MealError::Forbidden(msg) => FoodLogError::Forbidden(msg),
            MealError::Validation(msg) => FoodLogError::Validation(msg),
            MealError::Database(msg) => FoodLogError::Database(msg),
            MealError::Internal(msg) => FoodLogError::Internal(msg),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_meal_id_generates_unique_ids() {
        let id1 = MealId::new();
        let id2 = MealId::new();
        assert_ne!(id1, id2);
    }

    #[test]
    fn test_meal_id_from_uuid() {
        let uuid = Uuid::new_v4();
        let id = MealId::from(uuid);
        assert_eq!(id.0, uuid);
    }

    #[test]
    fn test_meal_is_owned_by() {
        let user_a = Uuid::new_v4();
        let user_b = Uuid::new_v4();
        let meal = Meal {
            id: MealId::new(),
            user_id: user_a,
            name: MealName("Test Meal".to_string()),
            notes: None,
            total_quantity_amount: None,
            total_quantity_unit: None,
            components: vec![],
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        assert!(meal.is_owned_by(user_a));
        assert!(!meal.is_owned_by(user_b));
    }

    #[test]
    fn test_meal_has_at_least_one_component() {
        fn has_at_least_one_component(meal: &Meal) -> bool {
            !meal.components.is_empty()
        }

        let user_id = Uuid::new_v4();
        let meal_empty = Meal {
            id: MealId::new(),
            user_id,
            name: MealName("Empty Meal".to_string()),
            notes: None,
            total_quantity_amount: None,
            total_quantity_unit: None,
            components: vec![],
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        assert!(!has_at_least_one_component(&meal_empty));

        let meal_with_component = Meal {
            components: vec![MealComponent {
                id: Uuid::new_v4(),
                item: MealComponentItem::Product(ProductId(Uuid::new_v4())),
                quantity_amount: Decimal::new(100, 0),
                quantity_unit: UnitCode("g".to_string()),
            }],
            ..meal_empty
        };
        assert!(has_at_least_one_component(&meal_with_component));
    }

    #[test]
    fn test_meal_component_item_product() {
        let product_id = ProductId(Uuid::new_v4());
        let component = MealComponent {
            id: Uuid::new_v4(),
            item: MealComponentItem::Product(product_id),
            quantity_amount: Decimal::new(150, 0),
            quantity_unit: UnitCode("g".to_string()),
        };
        match component.item {
            MealComponentItem::Product(pid) => assert_eq!(pid, product_id),
        }
    }

    #[test]
    fn test_meal_error_display() {
        let err = MealError::NotFound("meal not found".into());
        assert_eq!(format!("{err}"), "not found: meal not found");
        let err = MealError::Forbidden("not your meal".into());
        assert_eq!(format!("{err}"), "forbidden: not your meal");
        let err = MealError::Validation("name required".into());
        assert_eq!(format!("{err}"), "validation: name required");
        let err = MealError::Database("connection failed".into());
        assert_eq!(format!("{err}"), "database: connection failed");
        let err = MealError::Internal("unexpected".into());
        assert_eq!(format!("{err}"), "internal: unexpected");
    }

    #[test]
    fn test_meal_error_conversion_to_food_log_error() {
        let meal_err = MealError::NotFound("test".into());
        let fl_err: FoodLogError = meal_err.into();
        match fl_err {
            FoodLogError::NotFound(msg) => assert_eq!(msg, "test"),
            _ => panic!("expected NotFound"),
        }
    }
}
