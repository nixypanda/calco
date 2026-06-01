use async_trait::async_trait;
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

use super::catalog::{Product, ProductId, UnitCode};

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
    pub fn create(
        user_id: Uuid,
        name: String,
        notes: Option<String>,
        total_quantity_amount: Option<Decimal>,
        total_quantity_unit: Option<UnitCode>,
        components: Vec<MealComponent>,
        now: DateTime<Utc>,
    ) -> Result<Self, MealError> {
        validate_meal_name(&name)?;
        validate_meal_components(&components)?;

        Ok(Self {
            id: MealId::new(),
            user_id,
            name: MealName(name),
            notes: notes.map(MealNotes),
            total_quantity_amount,
            total_quantity_unit,
            components,
            created_at: now,
            updated_at: now,
        })
    }

    pub fn rename(&self, name: String) -> Result<MealName, MealError> {
        validate_meal_name(&name)?;
        Ok(MealName(name))
    }

    pub fn validate_components(components: &[MealComponent]) -> Result<(), MealError> {
        validate_meal_components(components)
    }

    pub fn is_owned_by(&self, user_id: Uuid) -> bool {
        self.user_id == user_id
    }
}

fn validate_meal_name(name: &str) -> Result<(), MealError> {
    if name.trim().is_empty() {
        return Err(MealError::Validation("meal name is required".into()));
    }
    Ok(())
}

fn validate_meal_components(components: &[MealComponent]) -> Result<(), MealError> {
    if components.is_empty() {
        return Err(MealError::Validation(
            "meal must have at least one component".into(),
        ));
    }
    Ok(())
}

#[derive(Debug, thiserror::Error)]
pub enum MealError {
    #[error("not_found: {0}")]
    NotFound(String),
    #[error("forbidden: {0}")]
    Forbidden(String),
    #[error("validation: {0}")]
    Validation(String),
    #[error("database: {0}")]
    Database(#[from] sqlx::Error),
    #[error("internal: {0}")]
    Internal(String),
}

#[async_trait]
pub trait MealRepository: Send + Sync {
    async fn create(&self, meal: &Meal) -> Result<(), MealError>;
    async fn find_by_id(&self, id: MealId) -> Result<Option<Meal>, MealError>;
    async fn find_by_user(&self, user_id: Uuid) -> Result<Vec<Meal>, MealError>;
    async fn update(&self, meal: &Meal) -> Result<(), MealError>;
    async fn delete(&self, id: MealId) -> Result<(), MealError>;
}

#[async_trait]
pub trait MealProductLookup: Send + Sync {
    async fn find_by_id(&self, id: ProductId) -> Result<Option<Product>, MealError>;
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
        assert_eq!(format!("{err}"), "not_found: meal not found");
        let err = MealError::Forbidden("not your meal".into());
        assert_eq!(format!("{err}"), "forbidden: not your meal");
        let err = MealError::Validation("name required".into());
        assert_eq!(format!("{err}"), "validation: name required");
        let err = MealError::Database(sqlx::Error::RowNotFound);
        assert!(format!("{err}").starts_with("database: "));
        let err = MealError::Internal("unexpected".into());
        assert_eq!(format!("{err}"), "internal: unexpected");
    }
}
