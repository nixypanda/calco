//! Infrastructure adapters for the food-assistance context.
//!
//! Provider protocol adapters arrive in later slices. The nutrition adapter
//! deliberately consumes only catalog application reads and translates their
//! values into assistant-owned vocabulary terms.

pub mod images;
pub mod nutrition_catalog;
pub mod openai_compatible;

pub use images::SafeFoodImageSanitizer;
pub use nutrition_catalog::NutritionCatalogVocabularyAdapter;
pub use openai_compatible::OpenAiCompatibleFoodDraftModel;
