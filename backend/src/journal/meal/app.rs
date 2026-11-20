use chrono::Utc;
use rust_decimal::Decimal;
use std::sync::Arc;
use uuid::Uuid;

use crate::catalog::app::CatalogReadPort;
use crate::catalog::domain::calculation::{CalculatedNutrition, Quantity};
use crate::catalog::domain::units::UnitConverter;
use crate::catalog::domain::*;
use crate::journal::error::{
    MealComponentUnavailableReason, MealQuantityUnavailableReason, UnavailableMealComponent,
    UnavailableMealComponents,
};
use crate::journal::meal::domain::*;

pub struct CreateMealInput {
    name: String,
    notes: Option<String>,
    total_quantity: Option<MealQuantity>,
    components: Vec<CreateMealComponentInput>,
}

impl CreateMealInput {
    pub fn new(
        name: String,
        notes: Option<String>,
        total_quantity: Option<MealQuantity>,
        components: Vec<CreateMealComponentInput>,
    ) -> Self {
        Self {
            name,
            notes,
            total_quantity,
            components,
        }
    }
}

pub struct CreateMealComponentInput {
    item: MealComponentItem,
    quantity: MealQuantity,
}

impl CreateMealComponentInput {
    pub fn new(item: MealComponentItem, quantity: MealQuantity) -> Self {
        Self { item, quantity }
    }
}

pub struct UpdateMealInput {
    name: Option<String>,
    notes: Option<Option<String>>,
    total_quantity: MealTotalQuantityPatch,
    components: Option<Vec<CreateMealComponentInput>>,
}

impl UpdateMealInput {
    pub fn new(
        name: Option<String>,
        notes: Option<Option<String>>,
        total_quantity: MealTotalQuantityPatch,
        components: Option<Vec<CreateMealComponentInput>>,
    ) -> Self {
        Self {
            name,
            notes,
            total_quantity,
            components,
        }
    }
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
    meal: Meal,
    products: Vec<(ProductId, Product)>,
}

impl ResolvedMeal {
    pub(crate) fn from_parts(meal: Meal, products: Vec<(ProductId, Product)>) -> Self {
        Self { meal, products }
    }

    pub fn meal(&self) -> &Meal {
        &self.meal
    }

    pub fn products(&self) -> &[(ProductId, Product)] {
        &self.products
    }

    pub fn nutrition_for(
        &self,
        quantity: &Quantity,
        unit_converter: &UnitConverter,
    ) -> Result<CalculatedNutrition, JournalError> {
        self.resolution(unit_converter)?
            .nutrition_for(&self.meal, quantity, unit_converter)
            .map_err(|error| error.into_journal(self.meal.id().0))
    }

    fn resolution(
        &self,
        unit_converter: &UnitConverter,
    ) -> Result<MealProductResolution, JournalError> {
        MealProductResolution::from_products(&self.meal, &self.products, unit_converter)
    }
}

#[derive(Debug, Clone)]
pub struct ResolvedMealComponent {
    component: MealComponent,
    availability: ResolvedMealComponentAvailability,
}

impl ResolvedMealComponent {
    pub fn component(&self) -> &MealComponent {
        &self.component
    }

    pub fn availability(&self) -> &ResolvedMealComponentAvailability {
        &self.availability
    }
}

#[derive(Debug, Clone)]
pub enum ResolvedMealComponentAvailability {
    Available {
        product: Box<Product>,
        nutrition: CalculatedNutrition,
        grams: Decimal,
    },
    Unavailable {
        reason: MealComponentUnavailableReason,
    },
}

#[derive(Debug, Clone)]
pub struct MealProductResolution {
    components: Vec<ResolvedMealComponent>,
}

impl MealProductResolution {
    pub fn components(&self) -> &[ResolvedMealComponent] {
        &self.components
    }

    pub fn unavailable_components(&self) -> Option<UnavailableMealComponents> {
        UnavailableMealComponents::new(
            self.components
                .iter()
                .filter_map(|resolved| match resolved.availability() {
                    ResolvedMealComponentAvailability::Unavailable { reason } => {
                        let MealComponentItem::Product(product_id) = resolved.component().item();
                        let quantity = resolved.component().quantity();
                        Some(UnavailableMealComponent {
                            component_id: resolved.component().id(),
                            product_id: product_id.0,
                            quantity_amount: quantity.amount(),
                            quantity_unit: quantity.unit().0.clone(),
                            reason: *reason,
                        })
                    }
                    ResolvedMealComponentAvailability::Available { .. } => None,
                })
                .collect(),
        )
    }

    pub fn is_complete(&self) -> bool {
        self.unavailable_components().is_none()
    }

    pub fn products(&self) -> Vec<(ProductId, Product)> {
        self.components
            .iter()
            .filter_map(|resolved| match resolved.availability() {
                ResolvedMealComponentAvailability::Available { product, .. } => {
                    let MealComponentItem::Product(product_id) = resolved.component().item();
                    Some((*product_id, (**product).clone()))
                }
                ResolvedMealComponentAvailability::Unavailable { .. } => None,
            })
            .collect()
    }

    pub fn nutrition_for(
        &self,
        meal: &Meal,
        scale_quantity: &Quantity,
        unit_converter: &UnitConverter,
    ) -> Result<CalculatedNutrition, MealNutritionResolutionError> {
        if let Some(unavailable) = self.unavailable_components() {
            return Err(MealNutritionResolutionError::UnavailableComponents(
                unavailable,
            ));
        }
        let scale_grams = meal
            .quantity_to_grams(scale_quantity, unit_converter)
            .map_err(|_| MealNutritionResolutionError::QuantityNotConvertible {
                amount: scale_quantity.amount(),
                unit: scale_quantity.unit().clone(),
            })?;
        self.scaled_nutrition(scale_grams)
    }

    pub fn declared_nutrition(
        &self,
        meal: &Meal,
        unit_converter: &UnitConverter,
    ) -> Result<CalculatedNutrition, MealNutritionResolutionError> {
        if let Some(unavailable) = self.unavailable_components() {
            return Err(MealNutritionResolutionError::UnavailableComponents(
                unavailable,
            ));
        }
        let total = meal.total_quantity().ok_or_else(|| {
            MealNutritionResolutionError::Internal("meal has no declared total quantity".into())
        })?;
        let quantity = total.to_quantity().map_err(|_| {
            MealNutritionResolutionError::QuantityNotConvertible {
                amount: total.amount(),
                unit: total.unit().clone(),
            }
        })?;
        self.nutrition_for(meal, &quantity, unit_converter)
    }

    fn scaled_nutrition(
        &self,
        scale_grams: Decimal,
    ) -> Result<CalculatedNutrition, MealNutritionResolutionError> {
        let mut total_nutrients: Vec<(NutrientCode, Decimal, UnitCode)> = Vec::new();
        let mut total_component_grams = Decimal::ZERO;

        for resolved in &self.components {
            let ResolvedMealComponentAvailability::Available {
                nutrition, grams, ..
            } = resolved.availability()
            else {
                return Err(MealNutritionResolutionError::Internal(
                    "complete resolution contained an unavailable component".into(),
                ));
            };
            total_component_grams += *grams;
            for nutrient in &nutrition.amounts {
                match total_nutrients
                    .iter_mut()
                    .find(|(code, _, _)| code == &nutrient.nutrient_code)
                {
                    Some((_, amount, _)) => *amount += nutrient.amount,
                    None => total_nutrients.push((
                        nutrient.nutrient_code.clone(),
                        nutrient.amount,
                        nutrient.unit.clone(),
                    )),
                }
            }
        }

        if total_component_grams <= Decimal::ZERO {
            return Err(MealNutritionResolutionError::Internal(
                "meal component total must be positive".into(),
            ));
        }

        let scale_factor = scale_grams / total_component_grams;
        Ok(CalculatedNutrition {
            amounts: total_nutrients
                .into_iter()
                .map(
                    |(code, amount, unit)| crate::catalog::domain::calculation::NutrientAmount {
                        nutrient_code: code,
                        amount: amount * scale_factor,
                        unit,
                    },
                )
                .collect(),
        })
    }

    pub(crate) fn from_products(
        meal: &Meal,
        products: &[(ProductId, Product)],
        unit_converter: &UnitConverter,
    ) -> Result<Self, JournalError> {
        let components = meal
            .components()
            .iter()
            .map(|component| {
                let MealComponentItem::Product(product_id) = component.item();
                let Some((_, product)) = products.iter().find(|(id, _)| id == product_id) else {
                    return Ok(ResolvedMealComponent {
                        component: component.clone(),
                        availability: ResolvedMealComponentAvailability::Unavailable {
                            reason: MealComponentUnavailableReason::ProductUnavailable,
                        },
                    });
                };

                let quantity = match component.quantity().to_quantity() {
                    Ok(quantity) => quantity,
                    Err(_) => {
                        return Ok(ResolvedMealComponent {
                            component: component.clone(),
                            availability: ResolvedMealComponentAvailability::Unavailable {
                                reason: MealComponentUnavailableReason::QuantityNotConvertible,
                            },
                        });
                    }
                };

                let grams = match product.quantity_to_grams(&quantity, unit_converter) {
                    Ok(grams) => grams,
                    Err(_) => {
                        return Ok(ResolvedMealComponent {
                            component: component.clone(),
                            availability: ResolvedMealComponentAvailability::Unavailable {
                                reason: MealComponentUnavailableReason::QuantityNotConvertible,
                            },
                        });
                    }
                };

                // Conversion already succeeded. A later nutrition error is not an
                // expected catalog-state degradation, so propagate it instead of
                // presenting it as an unavailable quantity.
                let nutrition = product.nutrition_for(&quantity, unit_converter).map_err(
                    |error| {
                        JournalError::Internal(format!(
                            "product nutrition failed after quantity conversion succeeded: {error}"
                        ))
                    },
                )?;

                Ok(ResolvedMealComponent {
                    component: component.clone(),
                    availability: ResolvedMealComponentAvailability::Available {
                        product: Box::new(product.clone()),
                        nutrition,
                        grams,
                    },
                })
            })
            .collect::<Result<Vec<_>, JournalError>>()?;
        Ok(Self { components })
    }
}

#[derive(Debug)]
pub enum MealNutritionResolutionError {
    UnavailableComponents(UnavailableMealComponents),
    QuantityNotConvertible { amount: Decimal, unit: UnitCode },
    Internal(String),
}

impl MealNutritionResolutionError {
    fn into_journal(self, meal_id: Uuid) -> JournalError {
        match self {
            Self::UnavailableComponents(unavailable) => JournalError::UnavailableMealComponents {
                meal_id,
                unavailable,
            },
            Self::QuantityNotConvertible { amount, unit } => {
                JournalError::MealQuantityNotConvertible {
                    meal_id,
                    amount,
                    unit: unit.0,
                    reason: MealQuantityUnavailableReason::QuantityNotConvertible,
                }
            }
            Self::Internal(message) => JournalError::Internal(message),
        }
    }
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
    ) -> Result<ResolvedMeal, JournalError>;
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

    pub async fn get_meal(&self, actor_id: Uuid, id: MealId) -> Result<Meal, JournalError> {
        let meal = self.load_meal(id).await?;
        self.policy.authorize_view(actor_id, &meal)?;
        Ok(meal)
    }

    pub async fn list_meals(&self, actor_id: Uuid) -> Result<Vec<Meal>, JournalError> {
        let meals = self.meal_repo.list_all().await?;
        for meal in &meals {
            self.policy.authorize_view(actor_id, meal)?;
        }
        Ok(meals)
    }

    pub async fn resolve_meal_products(
        &self,
        actor_id: Uuid,
        meal: &Meal,
    ) -> Result<MealProductResolution, JournalError> {
        let product_ids = meal
            .components()
            .iter()
            .map(|component| match component.item() {
                MealComponentItem::Product(id) => *id,
            })
            .collect::<Vec<_>>();
        let products = self
            .catalog
            .resolve_products_available(actor_id, &product_ids)
            .await
            .map_err(JournalError::from)?;
        MealProductResolution::from_products(meal, &products, &self.unit_converter)
    }

    pub fn unit_converter(&self) -> &UnitConverter {
        &self.unit_converter
    }

    pub async fn create_meal(
        &self,
        actor_id: Uuid,
        input: CreateMealInput,
    ) -> Result<Meal, JournalError> {
        let CreateMealInput {
            name,
            notes,
            total_quantity,
            components,
        } = input;
        if let Some(total) = &total_quantity {
            self.validate_supported_total(total)?;
        }
        let components = self.build_components(actor_id, components).await?;
        let now = Utc::now();
        let meal = Meal::create(actor_id, name, notes, total_quantity, components, now)?;

        self.meal_repo.create(&meal).await?;
        Ok(meal)
    }

    pub async fn update_meal(
        &self,
        id: MealId,
        user_id: Uuid,
        input: UpdateMealInput,
    ) -> Result<Meal, JournalError> {
        let existing = self.load_meal(id).await?;
        self.policy.authorize_mutation(user_id, &existing)?;

        let UpdateMealInput {
            name,
            notes,
            total_quantity,
            components,
        } = input;
        if let MealTotalQuantityPatch::Set(total) = &total_quantity {
            self.validate_supported_total(total)?;
        }
        let components = match components {
            Some(components) => Some(self.build_components(user_id, components).await?),
            None => None,
        };

        let updated = existing.update(name, notes, total_quantity, components, Utc::now())?;
        self.meal_repo.update(&updated).await?;
        Ok(updated)
    }

    pub async fn delete_meal(&self, id: MealId, user_id: Uuid) -> Result<(), JournalError> {
        let existing = self.load_meal(id).await?;
        self.policy.authorize_mutation(user_id, &existing)?;

        self.meal_repo.delete(id).await
    }

    pub async fn get_meal_nutrients(
        &self,
        actor_id: Uuid,
        id: MealId,
        quantity: Quantity,
    ) -> Result<MealNutritionOutput, JournalError> {
        let resolved = self.resolve_loggable_meal(actor_id, id).await?;
        let calculated = resolved.nutrition_for(&quantity, &self.unit_converter)?;
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

    async fn load_meal(&self, id: MealId) -> Result<Meal, JournalError> {
        self.meal_repo
            .find_by_id(id)
            .await?
            .ok_or_else(|| JournalError::NotFound("meal not found".into()))
    }

    fn validate_supported_total(&self, total: &MealQuantity) -> Result<(), JournalError> {
        self.unit_converter
            .mass_to_grams(total.amount(), total.unit())
            .filter(|grams| *grams > Decimal::ZERO)
            .map(|_| ())
            .ok_or_else(|| {
                JournalError::Validation(
                    "meal total quantity must use a supported mass unit".into(),
                )
            })
    }

    async fn build_components(
        &self,
        actor_id: Uuid,
        inputs: Vec<CreateMealComponentInput>,
    ) -> Result<Vec<MealComponent>, JournalError> {
        if inputs.is_empty() {
            return Ok(Vec::new());
        }
        let product_ids: Vec<ProductId> = inputs
            .iter()
            .map(|input| match input.item {
                MealComponentItem::Product(id) => id,
            })
            .collect();
        let products = self
            .catalog
            .resolve_products(actor_id, &product_ids)
            .await?;

        inputs
            .into_iter()
            .map(|input| {
                let CreateMealComponentInput { item, quantity } = input;
                let MealComponentItem::Product(product_id) = item;
                let product = products
                    .iter()
                    .find(|(id, _)| id == &product_id)
                    .map(|(_, product)| product)
                    .ok_or_else(|| JournalError::NotFound("product not found".into()))?;
                let quantity_in_grams = quantity.to_quantity().map_err(|error| {
                    JournalError::Validation(format!(
                        "meal component quantity is invalid: {error}"
                    ))
                })?;
                product
                    .quantity_to_grams(&quantity_in_grams, &self.unit_converter)
                    .map_err(|error| {
                        JournalError::Validation(format!(
                            "meal component quantity {} {} cannot be converted for product {}: {error}",
                            quantity_in_grams.amount(),
                            quantity_in_grams.unit().0,
                            product_id.0
                        ))
                    })?;
                Ok(MealComponent::new(item, quantity))
            })
            .collect()
    }
}

#[async_trait::async_trait]
impl MealReadPort for MealService {
    async fn resolve_loggable_meal(
        &self,
        actor_id: Uuid,
        id: MealId,
    ) -> Result<ResolvedMeal, JournalError> {
        let meal = self.get_meal(actor_id, id).await?;
        let resolution = self.resolve_meal_products(actor_id, &meal).await?;
        if let Some(unavailable) = resolution.unavailable_components() {
            return Err(JournalError::UnavailableMealComponents {
                meal_id: meal.id().0,
                unavailable,
            });
        }
        Ok(ResolvedMeal::from_parts(meal, resolution.products()))
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

        fn len(&self) -> usize {
            self.meals.lock().unwrap().len()
        }
    }

    #[async_trait]
    impl MealRepo for MockMealRepo {
        async fn create(&self, meal: &Meal) -> Result<(), JournalError> {
            self.meals.lock().unwrap().push(meal.clone());
            Ok(())
        }

        async fn find_by_id(&self, id: MealId) -> Result<Option<Meal>, JournalError> {
            let meals = self.meals.lock().unwrap();
            Ok(meals.iter().find(|m| m.id() == id).cloned())
        }

        async fn list_all(&self) -> Result<Vec<Meal>, JournalError> {
            let meals = self.meals.lock().unwrap();
            Ok(meals.clone())
        }

        async fn update(&self, meal: &Meal) -> Result<(), JournalError> {
            let mut meals = self.meals.lock().unwrap();
            if let Some(existing) = meals.iter_mut().find(|m| m.id() == meal.id()) {
                *existing = meal.clone();
                Ok(())
            } else {
                Err(JournalError::NotFound("not found".into()))
            }
        }

        async fn delete(&self, id: MealId) -> Result<(), JournalError> {
            let mut meals = self.meals.lock().unwrap();
            let idx = meals
                .iter()
                .position(|m| m.id() == id)
                .ok_or_else(|| JournalError::NotFound("not found".into()))?;
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
        ) -> Result<Vec<(ProductId, Product)>, CatalogError> {
            match &self.product {
                Some(product) => Ok(ids.iter().map(|id| (*id, product.clone())).collect()),
                None => Err(CatalogError::NotFound("product not found".into())),
            }
        }

        async fn resolve_products_available(
            &self,
            _actor_id: Uuid,
            ids: &[ProductId],
        ) -> Result<Vec<(ProductId, Product)>, CatalogError> {
            Ok(self
                .product
                .as_ref()
                .map(|product| ids.iter().map(|id| (*id, product.clone())).collect())
                .unwrap_or_default())
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
        CreateMealComponentInput::new(
            MealComponentItem::Product(ProductId(Uuid::nil())),
            MealQuantity::new(Decimal::new(100, 0), UnitCode("g".to_string())).unwrap(),
        )
    }

    #[derive(Clone, Copy, Debug)]
    enum ExpectedCreateMealError {
        Validation,
        NotFound,
    }

    #[track_caller]
    fn assert_create_meal_error(expected: ExpectedCreateMealError, error: JournalError) {
        match (expected, error) {
            (ExpectedCreateMealError::Validation, JournalError::Validation(_)) => {}
            (ExpectedCreateMealError::NotFound, JournalError::NotFound(_)) => {}
            (expected, error) => panic!("expected {expected:?}, got {error}"),
        }
    }

    #[rstest]
    #[case::empty_name(
        Some(sample_product()),
        "",
        vec![sample_component()],
        None,
        ExpectedCreateMealError::Validation
    )]
    #[case::no_components(
        Some(sample_product()),
        "Empty Meal",
        vec![],
        None,
        ExpectedCreateMealError::Validation
    )]
    #[case::product_not_found(
        None,
        "Test Meal",
        vec![sample_component()],
        None,
        ExpectedCreateMealError::NotFound
    )]
    #[case::unconvertible_component(
        Some(sample_product()),
        "Bad Component",
        vec![CreateMealComponentInput::new(
            MealComponentItem::Product(ProductId(Uuid::nil())),
            MealQuantity::new(Decimal::ONE, UnitCode("banana".to_string())).unwrap(),
        )],
        None,
        ExpectedCreateMealError::Validation
    )]
    #[case::non_mass_total(
        Some(sample_product()),
        "Bad Total",
        vec![sample_component()],
        Some(MealQuantity::new(Decimal::ONE, UnitCode("cup".to_string())).unwrap()),
        ExpectedCreateMealError::Validation
    )]
    #[tokio::test]
    async fn create_meal_rejects_invalid_request(
        #[case] product: Option<Product>,
        #[case] name: &str,
        #[case] components: Vec<CreateMealComponentInput>,
        #[case] total_quantity: Option<MealQuantity>,
        #[case] expected: ExpectedCreateMealError,
    ) {
        let (services, repo) = make_services_with_repo(product);

        let result = services
            .create_meal(
                Uuid::new_v4(),
                CreateMealInput::new(name.to_string(), None, total_quantity, components),
            )
            .await;

        let error = result.expect_err("create_meal should reject invalid input");
        assert_create_meal_error(expected, error);
        assert_eq!(repo.len(), 0, "invalid meals must not be persisted");
    }

    #[tokio::test]
    async fn test_update_meal_can_clear_optional_fields() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let created = services
            .create_meal(
                user_id,
                CreateMealInput::new(
                    "Original".to_string(),
                    Some("clear me".to_string()),
                    Some(
                        MealQuantity::new(Decimal::new(100, 0), UnitCode("g".to_string())).unwrap(),
                    ),
                    vec![sample_component()],
                ),
            )
            .await
            .unwrap();

        let updated = services
            .update_meal(
                created.id(),
                user_id,
                UpdateMealInput::new(None, Some(None), MealTotalQuantityPatch::Clear, None),
            )
            .await
            .unwrap();

        assert_eq!(updated.notes(), None);
        assert_eq!(updated.total_quantity(), None);
    }

    #[tokio::test]
    async fn update_meal_rejects_invalid_changes_without_writing() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let created = services
            .create_meal(
                user_id,
                CreateMealInput::new(
                    "Original".to_string(),
                    None,
                    Some(
                        MealQuantity::new(Decimal::new(100, 0), UnitCode("g".to_string())).unwrap(),
                    ),
                    vec![sample_component()],
                ),
            )
            .await
            .unwrap();

        let invalid_total = services
            .update_meal(
                created.id(),
                user_id,
                UpdateMealInput::new(
                    Some("Changed".to_string()),
                    None,
                    MealTotalQuantityPatch::Set(
                        MealQuantity::new(Decimal::ONE, UnitCode("cup".to_string())).unwrap(),
                    ),
                    None,
                ),
            )
            .await;
        assert!(matches!(invalid_total, Err(JournalError::Validation(_))));

        let invalid_component = services
            .update_meal(
                created.id(),
                user_id,
                UpdateMealInput::new(
                    Some("Changed".to_string()),
                    None,
                    MealTotalQuantityPatch::Unchanged,
                    Some(vec![CreateMealComponentInput::new(
                        MealComponentItem::Product(ProductId(Uuid::nil())),
                        MealQuantity::new(Decimal::ONE, UnitCode("banana".to_string())).unwrap(),
                    )]),
                ),
            )
            .await;
        assert!(matches!(
            invalid_component,
            Err(JournalError::Validation(_))
        ));

        let reloaded = services.get_meal(user_id, created.id()).await.unwrap();
        assert_eq!(reloaded.name().as_str(), "Original");
        assert_eq!(
            reloaded.total_quantity().map(MealQuantity::amount),
            Some(Decimal::new(100, 0))
        );
        assert_eq!(reloaded.components().len(), 1);
        assert_eq!(
            reloaded.components()[0].quantity().unit().0,
            "g".to_string()
        );
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
                CreateMealInput::new("My Meal".to_string(), None, None, vec![sample_component()]),
            )
            .await
            .unwrap();

        let result = match mutation {
            MealMutation::Update => services
                .update_meal(
                    created.id(),
                    other,
                    UpdateMealInput::new(None, None, MealTotalQuantityPatch::Unchanged, None),
                )
                .await
                .map(|_| ()),
            MealMutation::Delete => services.delete_meal(created.id(), other).await,
        };

        assert!(
            matches!(&result, Err(JournalError::Forbidden(_))),
            "expected Forbidden, got {result:?}"
        );
    }

    #[tokio::test]
    async fn test_get_meal_nutrients_calculates_sum() {
        let services = make_services(Some(sample_product()));
        let user_id = Uuid::new_v4();

        let meal = services
            .create_meal(
                user_id,
                CreateMealInput::new(
                    "Double Food".to_string(),
                    None,
                    None,
                    vec![
                        sample_component(),
                        CreateMealComponentInput::new(
                            MealComponentItem::Product(ProductId(Uuid::nil())),
                            MealQuantity::new(Decimal::new(200, 0), UnitCode("g".to_string()))
                                .unwrap(),
                        ),
                    ],
                ),
            )
            .await
            .unwrap();

        let nutrition = services
            .get_meal_nutrients(
                user_id,
                meal.id(),
                Quantity::new(Decimal::new(150, 0), UnitCode("g".to_string())).unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(nutrition.meal_id, meal.id().0);
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
