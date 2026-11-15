mod history;
mod services;

pub use history::{FoodLogDaySummary, FoodLogHistoryService, LatestSlotLogs};
pub use services::{
    FoodLogCreateOutcome, FoodLogQueryPort, FoodLogService, LogAdHocFoodInput, LogFoodInput,
    UpdateFoodInput,
};

#[cfg(test)]
mod test_support;
