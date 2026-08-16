use std::sync::Arc;

use axum::extract::FromRef;
use sqlx::PgPool;

use crate::AppState;
use crate::BoxError;
use crate::nutrition::catalog::domain::units::UnitConverter;
use crate::nutrition::catalog::domain::{NutrientRepository, ProductRepository, UnitRepository};
use crate::nutrition::catalog::infrastructure::{
    PostgresNutrientRepository, PostgresProductRepository, PostgresUnitRepository,
};
use crate::nutrition::diary::application::DiaryPreferencesService;
use crate::nutrition::diary::domain::DiaryPreferencesRepository;
use crate::nutrition::diary::infrastructure::PostgresDiaryPreferencesRepository;
use crate::nutrition::food_log::application::{FoodLogHistoryService, FoodLogService};
use crate::nutrition::food_log::domain::FoodLogRepository;
use crate::nutrition::food_log::infrastructure::PostgresFoodLogRepository;
use crate::nutrition::goals::application::GoalTargetService;
use crate::nutrition::goals::domain::GoalTargetRepository;
use crate::nutrition::goals::infrastructure::PostgresGoalTargetRepository;
use crate::nutrition::guidance::application::NutritionDetailsService;
use crate::nutrition::guidance::domain::NutrientGuidanceRepository;
use crate::nutrition::guidance::infrastructure::StaticNutrientGuidanceRepository;
use crate::nutrition::meal::application::MealService;
use crate::nutrition::meal::domain::MealRepository;
use crate::nutrition::meal::infrastructure::PostgresMealRepository;

/// The catalog kernel: products, nutrients, units, and the unit converter.
///
/// Every other nutrition sub-module that needs product data or unit conversion
/// depends on this. Handlers that only touch the catalog extract
/// `State<CatalogModule>` instead of the whole `AppState`.
#[derive(Clone)]
pub struct CatalogModule {
    pub product_repo: Arc<dyn ProductRepository>,
    pub nutrient_repo: Arc<dyn NutrientRepository>,
    pub unit_repo: Arc<dyn UnitRepository>,
    pub unit_converter: Arc<UnitConverter>,
}

impl CatalogModule {
    pub async fn build(pool: &PgPool) -> Result<Self, BoxError> {
        let product_repo =
            Arc::new(PostgresProductRepository::new(pool.clone())) as Arc<dyn ProductRepository>;
        let nutrient_repo =
            Arc::new(PostgresNutrientRepository::new(pool.clone())) as Arc<dyn NutrientRepository>;
        let unit_repo =
            Arc::new(PostgresUnitRepository::new(pool.clone())) as Arc<dyn UnitRepository>;

        let mass_factors = unit_repo.list_mass_factors().await?;
        let unit_converter = Arc::new(UnitConverter::from_entries(mass_factors));

        Ok(Self {
            product_repo,
            nutrient_repo,
            unit_repo,
            unit_converter,
        })
    }
}

impl FromRef<AppState> for CatalogModule {
    fn from_ref(app: &AppState) -> Self {
        app.nutrition.catalog.clone()
    }
}

#[derive(Clone)]
pub struct MealModule {
    pub catalog: CatalogModule,
    pub meal_repo: Arc<dyn MealRepository>,
    pub meal_services: MealService,
}

impl MealModule {
    pub fn build(pool: &PgPool, catalog: CatalogModule) -> Self {
        let meal_repo =
            Arc::new(PostgresMealRepository::new(pool.clone())) as Arc<dyn MealRepository>;
        let meal_services = MealService::new(
            meal_repo.clone(),
            catalog.product_repo.clone(),
            catalog.unit_converter.clone(),
        );
        Self {
            catalog,
            meal_repo,
            meal_services,
        }
    }
}

impl FromRef<AppState> for MealModule {
    fn from_ref(app: &AppState) -> Self {
        app.nutrition.meal.clone()
    }
}

#[derive(Clone)]
pub struct FoodLogModule {
    pub catalog: CatalogModule,
    /// Minimal port `food_log` needs from `meal`: a `LoggedItem::Meal` resolves a
    /// saved meal into a food-log snapshot. Holds the repo, not the whole module.
    pub meal_repo: Arc<dyn MealRepository>,
    pub food_log_repo: Arc<dyn FoodLogRepository>,
    pub food_log_services: FoodLogService,
    pub food_log_history_services: FoodLogHistoryService,
}

impl FoodLogModule {
    pub fn build(
        pool: &PgPool,
        catalog: CatalogModule,
        meal_repo: Arc<dyn MealRepository>,
    ) -> Self {
        let food_log_repo =
            Arc::new(PostgresFoodLogRepository::new(pool.clone())) as Arc<dyn FoodLogRepository>;
        let food_log_services = FoodLogService::new(
            food_log_repo.clone(),
            catalog.product_repo.clone(),
            catalog.unit_converter.clone(),
            meal_repo.clone(),
        );
        let food_log_history_services = FoodLogHistoryService::new(food_log_repo.clone());
        Self {
            catalog,
            meal_repo,
            food_log_repo,
            food_log_services,
            food_log_history_services,
        }
    }
}

impl FromRef<AppState> for FoodLogModule {
    fn from_ref(app: &AppState) -> Self {
        app.nutrition.food_log.clone()
    }
}

#[derive(Clone)]
pub struct GuidanceModule {
    pub food_log_repo: Arc<dyn FoodLogRepository>,
    pub nutrient_guidance_repo: Arc<dyn NutrientGuidanceRepository>,
    pub nutrition_details_services: NutritionDetailsService,
}

impl GuidanceModule {
    pub fn build(food_log_repo: Arc<dyn FoodLogRepository>) -> Self {
        let nutrient_guidance_repo = Arc::new(StaticNutrientGuidanceRepository::new())
            as Arc<dyn NutrientGuidanceRepository>;
        let nutrition_details_services =
            NutritionDetailsService::new(food_log_repo.clone(), nutrient_guidance_repo.clone());
        Self {
            food_log_repo,
            nutrient_guidance_repo,
            nutrition_details_services,
        }
    }
}

impl FromRef<AppState> for GuidanceModule {
    fn from_ref(app: &AppState) -> Self {
        app.nutrition.guidance.clone()
    }
}

#[derive(Clone)]
pub struct DiaryPreferencesModule {
    pub diary_preferences_repo: Arc<dyn DiaryPreferencesRepository>,
    pub diary_preferences_services: DiaryPreferencesService,
}

impl DiaryPreferencesModule {
    pub fn build(pool: &PgPool) -> Self {
        let diary_preferences_repo = Arc::new(PostgresDiaryPreferencesRepository::new(pool.clone()))
            as Arc<dyn DiaryPreferencesRepository>;
        let diary_preferences_services =
            DiaryPreferencesService::new(diary_preferences_repo.clone());
        Self {
            diary_preferences_repo,
            diary_preferences_services,
        }
    }
}

impl FromRef<AppState> for DiaryPreferencesModule {
    fn from_ref(app: &AppState) -> Self {
        app.nutrition.diary.clone()
    }
}

#[derive(Clone)]
pub struct GoalTargetModule {
    pub goal_target_repo: Arc<dyn GoalTargetRepository>,
    pub goal_target_services: GoalTargetService,
}

impl GoalTargetModule {
    pub fn build(pool: &PgPool) -> Self {
        let goal_target_repo = Arc::new(PostgresGoalTargetRepository::new(pool.clone()))
            as Arc<dyn GoalTargetRepository>;
        let goal_target_services = GoalTargetService::new(goal_target_repo.clone());
        Self {
            goal_target_repo,
            goal_target_services,
        }
    }
}

impl FromRef<AppState> for GoalTargetModule {
    fn from_ref(app: &AppState) -> Self {
        app.nutrition.goals.clone()
    }
}

/// Composition root for the nutrition context. Wires the sub-modules along the
/// catalog-rooted DAG: catalog first, then meal, then food_log, then guidance;
/// diary and goals are standalone islands.
#[derive(Clone)]
pub struct NutritionModule {
    pub catalog: CatalogModule,
    pub meal: MealModule,
    pub food_log: FoodLogModule,
    pub guidance: GuidanceModule,
    pub diary: DiaryPreferencesModule,
    pub goals: GoalTargetModule,
}

impl NutritionModule {
    pub async fn build(pool: &PgPool) -> Result<Self, BoxError> {
        let catalog = CatalogModule::build(pool).await?;
        let meal = MealModule::build(pool, catalog.clone());
        let food_log = FoodLogModule::build(pool, catalog.clone(), meal.meal_repo.clone());
        let guidance = GuidanceModule::build(food_log.food_log_repo.clone());
        let diary = DiaryPreferencesModule::build(pool);
        let goals = GoalTargetModule::build(pool);

        Ok(Self {
            catalog,
            meal,
            food_log,
            guidance,
            diary,
            goals,
        })
    }
}

impl FromRef<AppState> for NutritionModule {
    fn from_ref(app: &AppState) -> Self {
        app.nutrition.clone()
    }
}
