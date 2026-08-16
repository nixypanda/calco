use std::sync::Arc;

use axum::extract::FromRef;
use sqlx::PgPool;

use crate::AppState;
use crate::BoxError;
use crate::nutrition::application::diary_preferences::DiaryPreferencesService;
use crate::nutrition::application::food_log::{FoodLogHistoryService, FoodLogService};
use crate::nutrition::application::goal_target::GoalTargetService;
use crate::nutrition::application::meal::MealService;
use crate::nutrition::application::nutrition_details::NutritionDetailsService;
use crate::nutrition::domain::catalog::{NutrientRepository, ProductRepository, UnitRepository};
use crate::nutrition::domain::diary_preferences::DiaryPreferencesRepository;
use crate::nutrition::domain::food_log::FoodLogRepository;
use crate::nutrition::domain::goal_target::GoalTargetRepository;
use crate::nutrition::domain::meal::MealRepository;
use crate::nutrition::domain::nutrient_guidance::NutrientGuidanceRepository;
use crate::nutrition::domain::units::UnitConverter;
use crate::nutrition::infrastructure::nutrient_guidance::StaticNutrientGuidanceRepository;
use crate::nutrition::infrastructure::postgres::catalog::{
    PostgresNutrientRepository, PostgresProductRepository, PostgresUnitRepository,
};
use crate::nutrition::infrastructure::postgres::diary_preferences::PostgresDiaryPreferencesRepository;
use crate::nutrition::infrastructure::postgres::food_log::PostgresFoodLogRepository;
use crate::nutrition::infrastructure::postgres::goal_target::PostgresGoalTargetRepository;
use crate::nutrition::infrastructure::postgres::meal::PostgresMealRepository;

#[derive(Clone)]
pub struct NutritionModule {
    pub product_repo: Arc<dyn ProductRepository>,
    pub nutrient_repo: Arc<dyn NutrientRepository>,
    pub unit_repo: Arc<dyn UnitRepository>,
    pub unit_converter: Arc<UnitConverter>,
    pub food_log_repo: Arc<dyn FoodLogRepository>,
    pub diary_preferences_repo: Arc<dyn DiaryPreferencesRepository>,
    pub nutrient_guidance_repo: Arc<dyn NutrientGuidanceRepository>,
    pub meal_repo: Arc<dyn MealRepository>,
    pub goal_target_repo: Arc<dyn GoalTargetRepository>,
    pub food_log_services: FoodLogService,
    pub diary_preferences_services: DiaryPreferencesService,
    pub nutrition_details_services: NutritionDetailsService,
    pub food_log_history_services: FoodLogHistoryService,
    pub meal_services: MealService,
    pub goal_target_services: GoalTargetService,
}

impl NutritionModule {
    pub async fn build(pool: &PgPool) -> Result<Self, BoxError> {
        let product_repo =
            Arc::new(PostgresProductRepository::new(pool.clone())) as Arc<dyn ProductRepository>;
        let nutrient_repo =
            Arc::new(PostgresNutrientRepository::new(pool.clone())) as Arc<dyn NutrientRepository>;
        let unit_repo =
            Arc::new(PostgresUnitRepository::new(pool.clone())) as Arc<dyn UnitRepository>;

        let mass_factors = unit_repo.list_mass_factors().await?;
        let unit_converter = Arc::new(UnitConverter::from_entries(mass_factors));

        let food_log_repo =
            Arc::new(PostgresFoodLogRepository::new(pool.clone())) as Arc<dyn FoodLogRepository>;
        let diary_preferences_repo = Arc::new(PostgresDiaryPreferencesRepository::new(pool.clone()))
            as Arc<dyn DiaryPreferencesRepository>;
        let nutrient_guidance_repo = Arc::new(StaticNutrientGuidanceRepository::new())
            as Arc<dyn NutrientGuidanceRepository>;
        let meal_repo =
            Arc::new(PostgresMealRepository::new(pool.clone())) as Arc<dyn MealRepository>;
        let goal_target_repo = Arc::new(PostgresGoalTargetRepository::new(pool.clone()))
            as Arc<dyn GoalTargetRepository>;

        let food_log_services = FoodLogService::new(
            food_log_repo.clone(),
            product_repo.clone(),
            unit_converter.clone(),
            meal_repo.clone(),
        );
        let food_log_history_services = FoodLogHistoryService::new(food_log_repo.clone());
        let diary_preferences_services =
            DiaryPreferencesService::new(diary_preferences_repo.clone());
        let nutrition_details_services =
            NutritionDetailsService::new(food_log_repo.clone(), nutrient_guidance_repo.clone());
        let meal_services = MealService::new(
            meal_repo.clone(),
            product_repo.clone(),
            unit_converter.clone(),
        );
        let goal_target_services = GoalTargetService::new(goal_target_repo.clone());

        Ok(Self {
            product_repo,
            nutrient_repo,
            unit_repo,
            unit_converter,
            food_log_repo,
            diary_preferences_repo,
            nutrient_guidance_repo,
            meal_repo,
            goal_target_repo,
            food_log_services,
            diary_preferences_services,
            nutrition_details_services,
            food_log_history_services,
            meal_services,
            goal_target_services,
        })
    }
}

impl FromRef<AppState> for NutritionModule {
    fn from_ref(app: &AppState) -> Self {
        app.nutrition.clone()
    }
}
