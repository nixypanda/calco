use std::collections::HashMap;
use std::time::Duration;

use async_trait::async_trait;
use reqwest::{Client, StatusCode, Url};
use rust_decimal::Decimal;
use serde::Deserialize;
use serde_json::Value;

use crate::catalog::app::ExternalProductCatalog;
use crate::catalog::domain::{
    ExternalProductBuilder, CatalogError, ProductNutrientInput, ProductServingInput,
};

const ENDPOINT: &str = "https://world.openfoodfacts.org/api/v3/product/";
const USER_AGENT: &str = "CalCo/0.1 (homelab barcode lookup)";
const FIELDS: &str =
    "code,product_name,brands,categories_tags,nutriments,serving_size,nutrition_data_per";
const MAX_RESPONSE_BYTES: usize = 1024 * 1024;

pub struct OpenFoodFactsClient {
    client: Client,
    endpoint: Url,
}

impl OpenFoodFactsClient {
    pub fn new() -> Result<Self, reqwest::Error> {
        Ok(Self {
            client: Client::builder()
                .user_agent(USER_AGENT)
                .connect_timeout(Duration::from_secs(3))
                .timeout(Duration::from_secs(8))
                .build()?,
            endpoint: Url::parse(ENDPOINT).expect("static Open Food Facts URL is valid"),
        })
    }
}

#[async_trait]
impl ExternalProductCatalog for OpenFoodFactsClient {
    async fn find_by_barcode(
        &self,
        barcode: &str,
    ) -> Result<Option<ExternalProductBuilder>, CatalogError> {
        let response = self
            .client
            .get(
                self.endpoint
                    .join(barcode)
                    .map_err(|_| CatalogError::ExternalInvalidResponse)?,
            )
            .query(&[("fields", FIELDS)])
            .send()
            .await
            .map_err(|error| {
                tracing::warn!(error = %error, "Open Food Facts request failed");
                CatalogError::ExternalUnavailable
            })?;

        if response.status() == StatusCode::NOT_FOUND {
            return Ok(None);
        }
        if !response.status().is_success() {
            tracing::warn!(status = %response.status(), "Open Food Facts request failed");
            return Err(CatalogError::ExternalUnavailable);
        }

        let content_length = response.content_length();
        if content_length.is_some_and(|length| length > MAX_RESPONSE_BYTES as u64) {
            return Err(CatalogError::ExternalInvalidResponse);
        }
        let bytes = response
            .bytes()
            .await
            .map_err(|_| CatalogError::ExternalUnavailable)?;
        if bytes.len() > MAX_RESPONSE_BYTES {
            return Err(CatalogError::ExternalInvalidResponse);
        }

        let body: OffResponse =
            serde_json::from_slice(&bytes).map_err(|_| CatalogError::ExternalInvalidResponse)?;
        let product = body
            .product
            .ok_or(CatalogError::ExternalInvalidResponse)?;
        product.into_input(barcode).map(Some)
    }
}

#[derive(Deserialize)]
struct OffResponse {
    product: Option<OffProduct>,
}

#[derive(Deserialize)]
struct OffProduct {
    code: Option<String>,
    product_name: Option<String>,
    brands: Option<String>,
    #[serde(default)]
    categories_tags: Vec<String>,
    #[serde(default)]
    nutriments: HashMap<String, Value>,
    serving_size: Option<String>,
}

impl OffProduct {
    fn into_input(self, requested_barcode: &str) -> Result<ExternalProductBuilder, CatalogError> {
        let code = self
            .code
            .filter(|code| !code.trim().is_empty())
            .unwrap_or_else(|| requested_barcode.to_owned());
        let name = self
            .product_name
            .filter(|name| !name.trim().is_empty())
            .ok_or(CatalogError::ExternalInvalidResponse)?;
        let nutrients = map_nutrients(&self.nutriments);
        let serving_grams = self.serving_size.as_deref().and_then(parse_gram_serving);
        let (default_quantity, default_unit, servings) = match serving_grams {
            Some(grams) => (
                Some(Decimal::ONE),
                Some("serving".into()),
                vec![ProductServingInput {
                    unit: "serving".into(),
                    grams_per_unit: grams,
                }],
            ),
            None => (None, None, vec![]),
        };

        Ok(ExternalProductBuilder::new(code.clone(), name)
            .barcode(Some(code))
            .brand(self.brands)
            .categories(
                self.categories_tags
                    .into_iter()
                    .take(30)
                    .map(|tag| tag.strip_prefix("en:").unwrap_or(&tag).replace('-', " "))
                    .collect(),
            )
            .optional_default_portion(default_quantity, default_unit)?
            .nutrients(nutrients)
            .servings(servings))
    }
}

const NUTRIENT_MAPPINGS: [(&str, &str, &str); 25] = [
    ("energy-kcal", "ENERGY_KCAL", "kcal"),
    ("proteins", "PROTEIN_G", "g"),
    ("carbohydrates", "CARBS_G", "g"),
    ("fat", "FAT_G", "g"),
    ("fiber", "FIBER_G", "g"),
    ("sugars", "SUGAR_G", "g"),
    ("saturated-fat", "SATURATED_FAT_G", "g"),
    ("trans-fat", "TRANS_FAT_G", "g"),
    ("sodium", "SODIUM_MG", "mg"),
    ("cholesterol", "CHOLESTEROL_MG", "mg"),
    ("potassium", "POTASSIUM_MG", "mg"),
    ("calcium", "CALCIUM_MG", "mg"),
    ("iron", "IRON_MG", "mg"),
    ("magnesium", "MAGNESIUM_MG", "mg"),
    ("zinc", "ZINC_MG", "mg"),
    ("phosphorus", "PHOSPHORUS_MG", "mg"),
    ("vitamin-a", "VITAMIN_A_UG", "ug"),
    ("vitamin-c", "VITAMIN_C_MG", "mg"),
    ("vitamin-d", "VITAMIN_D_UG", "ug"),
    ("vitamin-e", "VITAMIN_E_MG", "mg"),
    ("vitamin-b6", "VITAMIN_B6_MG", "mg"),
    ("vitamin-b12", "VITAMIN_B12_UG", "ug"),
    ("folates", "FOLATE_UG", "ug"),
    ("monounsaturated-fat", "MONOUNSATURATED_FAT_G", "g"),
    ("polyunsaturated-fat", "POLYUNSATURATED_FAT_G", "g"),
];

fn map_nutrients(nutriments: &HashMap<String, Value>) -> Vec<ProductNutrientInput> {
    NUTRIENT_MAPPINGS
        .iter()
        .filter_map(|(off_key, code, target_unit)| {
            let value = decimal_value(nutriments.get(&format!("{off_key}_100g"))?)?;
            let source_unit = nutriments
                .get(&format!("{off_key}_unit"))
                .and_then(Value::as_str)?;
            let amount = convert_unit(value, source_unit, target_unit)?;
            (amount >= Decimal::ZERO).then(|| ProductNutrientInput {
                code: (*code).into(),
                amount_per_100g: amount,
                source: Some("open_food_facts".into()),
                confidence: Some("unknown".into()),
            })
        })
        .collect()
}

fn decimal_value(value: &Value) -> Option<Decimal> {
    match value {
        Value::Number(number) => number.to_string().parse().ok(),
        Value::String(value) => value.parse().ok(),
        _ => None,
    }
}

fn convert_unit(value: Decimal, source: &str, target: &str) -> Option<Decimal> {
    let source_grams = match source.trim().to_ascii_lowercase().as_str() {
        "g" => value,
        "mg" => value / Decimal::from(1_000),
        "µg" | "μg" | "ug" => value / Decimal::from(1_000_000),
        "kcal" if target == "kcal" => return Some(value),
        _ => return None,
    };
    match target {
        "g" => Some(source_grams),
        "mg" => Some(source_grams * Decimal::from(1_000)),
        "ug" => Some(source_grams * Decimal::from(1_000_000)),
        _ => None,
    }
}

fn parse_gram_serving(value: &str) -> Option<Decimal> {
    let normalized = value.trim().to_ascii_lowercase();
    let amount = normalized
        .strip_suffix('g')?
        .trim()
        .parse::<Decimal>()
        .ok()?;
    (amount > Decimal::ZERO).then_some(amount)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::domain::{ExternalSource, NutrientCatalog, Product};
    use serde_json::json;

    #[test]
    fn maps_supported_nutrients_and_converts_units() {
        let nutriments = serde_json::from_value(json!({
            "energy-kcal_100g": 539,
            "energy-kcal_unit": "kcal",
            "proteins_100g": 6.3,
            "proteins_unit": "g",
            "sodium_100g": 0.0428,
            "sodium_unit": "g",
            "vitamin-b12_100g": 0.00000025,
            "vitamin-b12_unit": "g"
        }))
        .unwrap();

        let mapped = map_nutrients(&nutriments);
        let amount = |code: &str| {
            mapped
                .iter()
                .find(|item| item.code == code)
                .unwrap()
                .amount_per_100g
        };

        assert_eq!(amount("ENERGY_KCAL"), Decimal::from(539));
        assert_eq!(amount("PROTEIN_G"), Decimal::new(63, 1));
        assert_eq!(amount("SODIUM_MG"), Decimal::new(428, 1));
        assert_eq!(amount("VITAMIN_B12_UG"), Decimal::new(25, 2));
    }

    #[test]
    fn builds_a_conservative_serving_and_normalizes_categories() {
        let input = OffProduct {
            code: Some("3017620422003".into()),
            product_name: Some("Nutella".into()),
            brands: Some("Ferrero".into()),
            categories_tags: vec!["en:sweet-spreads".into()],
            nutriments: HashMap::new(),
            serving_size: Some("15 g".into()),
        }
        .into_input("ignored")
        .unwrap();
        let product =
            Product::new_external(ExternalSource::Off, input, &NutrientCatalog::default()).unwrap();

        assert_eq!(product.categories[0].0, "sweet spreads");
        assert_eq!(
            product.default_unit.as_ref().map(|unit| unit.0.as_str()),
            Some("serving")
        );
        assert_eq!(product.servings[0].grams_per_unit, Decimal::from(15));
    }
}
