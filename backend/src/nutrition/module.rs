use std::sync::Arc;

use axum::extract::FromRef;
use sqlx::PgPool;

use crate::AppState;
use crate::BoxError;
use crate::nutrition::catalog::application::{CatalogReadPort, CatalogService};
use crate::nutrition::catalog::domain::units::UnitConverter;
use crate::nutrition::catalog::domain::{NutrientRepository, ProductRepository, UnitRepository};
use crate::nutrition::catalog::infrastructure::{
    PostgresNutrientRepository, PostgresProductRepository, PostgresUnitRepository,
};
use crate::nutrition::diary::application::DiaryPreferencesService;
use crate::nutrition::diary::domain::DiaryPreferencesRepository;
use crate::nutrition::diary::infrastructure::PostgresDiaryPreferencesRepository;
use crate::nutrition::food_log::application::{
    FoodLogHistoryService, FoodLogQueryPort, FoodLogService,
};
use crate::nutrition::food_log::domain::FoodLogRepository;
use crate::nutrition::food_log::infrastructure::PostgresFoodLogRepository;
use crate::nutrition::goals::application::GoalTargetService;
use crate::nutrition::goals::domain::GoalTargetRepository;
use crate::nutrition::goals::infrastructure::PostgresGoalTargetRepository;
use crate::nutrition::guidance::application::NutritionDetailsService;
use crate::nutrition::guidance::domain::NutrientGuidanceRepository;
use crate::nutrition::guidance::infrastructure::StaticNutrientGuidanceRepository;
use crate::nutrition::meal::application::{MealReadPort, MealService};
use crate::nutrition::meal::domain::MealRepository;
use crate::nutrition::meal::infrastructure::PostgresMealRepository;

/// The catalog kernel: products, nutrients, units, and the unit converter.
///
/// Every other nutrition sub-module that needs product data or unit conversion
/// depends on this. Handlers that only touch the catalog extract
/// `State<CatalogModule>` instead of the whole `AppState`.
#[derive(Clone)]
pub struct CatalogModule {
    pub services: Arc<CatalogService>,
}

impl FromRef<AppState> for CatalogModule {
    fn from_ref(app: &AppState) -> Self {
        app.nutrition.catalog.clone()
    }
}

#[derive(Clone)]
pub struct MealModule {
    pub meal_services: Arc<MealService>,
}

impl FromRef<AppState> for MealModule {
    fn from_ref(app: &AppState) -> Self {
        app.nutrition.meal.clone()
    }
}

#[derive(Clone)]
pub struct FoodLogModule {
    pub food_log_services: Arc<FoodLogService>,
    pub food_log_history_services: Arc<FoodLogHistoryService>,
}

impl FromRef<AppState> for FoodLogModule {
    fn from_ref(app: &AppState) -> Self {
        app.nutrition.food_log.clone()
    }
}

#[derive(Clone)]
pub struct GuidanceModule {
    pub nutrition_details_services: Arc<NutritionDetailsService>,
}

impl FromRef<AppState> for GuidanceModule {
    fn from_ref(app: &AppState) -> Self {
        app.nutrition.guidance.clone()
    }
}

#[derive(Clone)]
pub struct DiaryPreferencesModule {
    pub diary_preferences_services: Arc<DiaryPreferencesService>,
}

impl FromRef<AppState> for DiaryPreferencesModule {
    fn from_ref(app: &AppState) -> Self {
        app.nutrition.diary.clone()
    }
}

#[derive(Clone)]
pub struct GoalTargetModule {
    pub goal_target_services: Arc<GoalTargetService>,
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
        let product_repo =
            Arc::new(PostgresProductRepository::new(pool.clone())) as Arc<dyn ProductRepository>;
        let nutrient_repo =
            Arc::new(PostgresNutrientRepository::new(pool.clone())) as Arc<dyn NutrientRepository>;
        let unit_repo =
            Arc::new(PostgresUnitRepository::new(pool.clone())) as Arc<dyn UnitRepository>;
        let meal_repo =
            Arc::new(PostgresMealRepository::new(pool.clone())) as Arc<dyn MealRepository>;
        let food_log_repo =
            Arc::new(PostgresFoodLogRepository::new(pool.clone())) as Arc<dyn FoodLogRepository>;
        let diary_preferences_repo = Arc::new(PostgresDiaryPreferencesRepository::new(pool.clone()))
            as Arc<dyn DiaryPreferencesRepository>;
        let goal_target_repo = Arc::new(PostgresGoalTargetRepository::new(pool.clone()))
            as Arc<dyn GoalTargetRepository>;
        let nutrient_guidance_repo = Arc::new(StaticNutrientGuidanceRepository::new())
            as Arc<dyn NutrientGuidanceRepository>;

        let mass_factors = unit_repo.list_mass_factors().await?;
        let unit_converter = Arc::new(UnitConverter::from_entries(mass_factors));

        let catalog_services = Arc::new(CatalogService::new(
            product_repo,
            nutrient_repo,
            unit_repo,
            unit_converter.clone(),
        ));
        let catalog_reads: Arc<dyn CatalogReadPort> = catalog_services.clone();
        let meal_services = Arc::new(MealService::new(
            meal_repo,
            catalog_reads.clone(),
            unit_converter.clone(),
        ));
        let meal_reads: Arc<dyn MealReadPort> = meal_services.clone();
        let food_log_services = Arc::new(FoodLogService::new(
            food_log_repo.clone(),
            catalog_reads,
            unit_converter,
            meal_reads,
        ));
        let food_log_queries: Arc<dyn FoodLogQueryPort> = food_log_services.clone();

        let catalog = CatalogModule {
            services: catalog_services,
        };
        let meal = MealModule { meal_services };
        let food_log = FoodLogModule {
            food_log_services,
            food_log_history_services: Arc::new(FoodLogHistoryService::new(food_log_repo)),
        };
        let guidance = GuidanceModule {
            nutrition_details_services: Arc::new(NutritionDetailsService::new(
                food_log_queries,
                nutrient_guidance_repo,
            )),
        };
        let diary = DiaryPreferencesModule {
            diary_preferences_services: Arc::new(DiaryPreferencesService::new(
                diary_preferences_repo,
            )),
        };
        let goals = GoalTargetModule {
            goal_target_services: Arc::new(GoalTargetService::new(goal_target_repo)),
        };

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

#[cfg(test)]
mod architecture_tests {
    #[test]
    fn nutrition_http_interfaces_do_not_reference_repositories() {
        let interfaces = [
            ("catalog", include_str!("catalog/interfaces.rs")),
            ("meal", include_str!("meal/interfaces.rs")),
            ("food_log", include_str!("food_log/interfaces.rs")),
            ("guidance", include_str!("guidance/interfaces.rs")),
            ("diary", include_str!("diary/interfaces.rs")),
            ("goals", include_str!("goals/interfaces.rs")),
        ];

        for (name, source) in interfaces {
            assert!(
                !source.contains("Repository")
                    && !source.contains("_repo")
                    && !source.contains("::infrastructure"),
                "{name} HTTP interface crosses the application boundary"
            );
        }
    }
}
