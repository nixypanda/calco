use std::sync::Arc;

use axum::extract::FromRef;
use sqlx::PgPool;

use crate::AppState;
use crate::BoxError;
use crate::catalog::app::{CatalogReadPort, NutrientCatalogReadPort};
use crate::catalog::module::CatalogModule;
use crate::journal::diary_prefs::app::DiaryPrefsService;
use crate::journal::diary_prefs::domain::DiaryPrefsRepo;
use crate::journal::diary_prefs::infra::PgDiaryPrefsRepo;
use crate::journal::food_log::app::{FoodLogHistoryService, FoodLogQueryPort, FoodLogService};
use crate::journal::food_log::domain::FoodLogRepo;
use crate::journal::food_log::infra::PgFoodLogRepo;
use crate::journal::goals::app::GoalTargetService;
use crate::journal::goals::domain::GoalTargetRepo;
use crate::journal::goals::infra::PgGoalTargetRepo;
use crate::journal::guidance::app::NutritionDetailsService;
use crate::journal::guidance::domain::NutrientGuidanceRepo;
use crate::journal::guidance::infra::StaticGuidanceRepo;
use crate::journal::meal::app::{MealReadPort, MealService};
use crate::journal::meal::domain::MealRepo;
use crate::journal::meal::infra::PgMealRepo;

/// The catalog kernel: products, nutrients, units, and the unit converter.
///
/// Every other nutrition sub-module that needs product data or unit conversion

#[derive(Clone)]
pub struct MealModule {
    pub meal_services: Arc<MealService>,
}

impl FromRef<AppState> for MealModule {
    fn from_ref(app: &AppState) -> Self {
        app.journal.meal.clone()
    }
}

#[derive(Clone)]
pub struct FoodLogModule {
    pub food_log_services: Arc<FoodLogService>,
    pub food_log_history_services: Arc<FoodLogHistoryService>,
}

impl FromRef<AppState> for FoodLogModule {
    fn from_ref(app: &AppState) -> Self {
        app.journal.food_log.clone()
    }
}

#[derive(Clone)]
pub struct GuidanceModule {
    pub nutrition_details_services: Arc<NutritionDetailsService>,
}

impl FromRef<AppState> for GuidanceModule {
    fn from_ref(app: &AppState) -> Self {
        app.journal.guidance.clone()
    }
}

#[derive(Clone)]
pub struct DiaryPrefsModule {
    pub diary_prefs_services: Arc<DiaryPrefsService>,
}

impl FromRef<AppState> for DiaryPrefsModule {
    fn from_ref(app: &AppState) -> Self {
        app.journal.diary_prefs.clone()
    }
}

#[derive(Clone)]
pub struct GoalTargetModule {
    pub goal_target_services: Arc<GoalTargetService>,
}

impl FromRef<AppState> for GoalTargetModule {
    fn from_ref(app: &AppState) -> Self {
        app.journal.goals.clone()
    }
}

/// Composition root for the nutrition context. Wires the sub-modules along the
/// catalog-rooted DAG: catalog first, then meal, then food_log, then guidance;
/// diary and goals are standalone islands.
#[derive(Clone)]
pub struct JournalModule {
    pub catalog: CatalogModule,
    pub meal: MealModule,
    pub food_log: FoodLogModule,
    pub guidance: GuidanceModule,
    pub diary_prefs: DiaryPrefsModule,
    pub goals: GoalTargetModule,
}

impl JournalModule {
    pub async fn build(pool: &PgPool, catalog: &CatalogModule) -> Result<Self, BoxError> {
        let meal_repo = Arc::new(PgMealRepo::new(pool.clone())) as Arc<dyn MealRepo>;
        let food_log_repo = Arc::new(PgFoodLogRepo::new(pool.clone())) as Arc<dyn FoodLogRepo>;
        let diary_prefs_repo =
            Arc::new(PgDiaryPrefsRepo::new(pool.clone())) as Arc<dyn DiaryPrefsRepo>;
        let goal_target_repo =
            Arc::new(PgGoalTargetRepo::new(pool.clone())) as Arc<dyn GoalTargetRepo>;
        let nutrient_guidance_repo =
            Arc::new(StaticGuidanceRepo::new()) as Arc<dyn NutrientGuidanceRepo>;

        let catalog_services = catalog.services.clone();
        let unit_converter = catalog.unit_converter.clone();
        let catalog_reads: Arc<dyn CatalogReadPort> = catalog_services.clone();
        let nutrient_catalog_reads: Arc<dyn NutrientCatalogReadPort> = catalog_services.clone();
        let meal_services = Arc::new(MealService::new(
            meal_repo,
            catalog_reads.clone(),
            unit_converter.clone(),
        ));
        let meal_reads: Arc<dyn MealReadPort> = meal_services.clone();
        let food_log_services = Arc::new(FoodLogService::new(
            food_log_repo.clone(),
            catalog_reads,
            nutrient_catalog_reads,
            unit_converter,
            meal_reads,
        ));
        let food_log_queries: Arc<dyn FoodLogQueryPort> = food_log_services.clone();

        let catalog = catalog.clone();
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
        let diary_prefs = DiaryPrefsModule {
            diary_prefs_services: Arc::new(DiaryPrefsService::new(diary_prefs_repo)),
        };
        let goals = GoalTargetModule {
            goal_target_services: Arc::new(GoalTargetService::new(goal_target_repo)),
        };

        Ok(Self {
            catalog,
            meal,
            food_log,
            guidance,
            diary_prefs,
            goals,
        })
    }
}

impl FromRef<AppState> for JournalModule {
    fn from_ref(app: &AppState) -> Self {
        app.journal.clone()
    }
}

#[cfg(test)]
mod architecture_tests {}
