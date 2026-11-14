pub mod http;

use std::sync::Arc;

use axum::http::request::Parts;
use chrono::NaiveDate;
use rmcp::{
    Json, RoleServer, ServerHandler,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{CallToolResult, ContentBlock},
    service::RequestContext,
    tool, tool_handler, tool_router,
};
use schemars::JsonSchema;
use serde::Deserialize;
use uuid::Uuid;

use crate::auth::domain::ApiKeyScope;
use crate::catalog::api::dto::{
    ProductDetailResponse, SearchListResponse, product_to_detail_response,
    products_to_search_response,
};
use crate::catalog::domain::{ProductId, ProductSearchScope, ProductSearchSpec};
use crate::catalog::error::CatalogError;
use crate::journal::error::JournalError;
use crate::journal::food_log::api::dto::{LogSummaryResponse, food_log_day_summaries_to_response};
use crate::mcp::module::{McpCatalogRead, McpSummaryRead};

const MAX_SEARCH_QUERY_CHARS: usize = 256;

/// Authentication facts made available to MCP tool handlers.
///
/// The scope is retained even though the first tool set is read-only, so future
/// write tools can enforce `read_write` without changing the transport layer.
#[derive(Debug, Clone, Copy)]
pub struct McpUser {
    pub profile_id: Uuid,
    pub scope: ApiKeyScope,
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum FoodSearchScopeParam {
    All,
    Custom,
    History,
}

impl From<FoodSearchScopeParam> for ProductSearchScope {
    fn from(scope: FoodSearchScopeParam) -> Self {
        match scope {
            FoodSearchScopeParam::All => ProductSearchScope::All,
            FoodSearchScopeParam::Custom => ProductSearchScope::Custom,
            FoodSearchScopeParam::History => ProductSearchScope::History,
        }
    }
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct SearchFoodsParams {
    /// Search text interpreted like the REST food search query.
    #[schemars(length(max = MAX_SEARCH_QUERY_CHARS))]
    pub query: String,
    /// Search scope. `history` is specific to the authenticated caller.
    pub scope: Option<FoodSearchScopeParam>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetFoodParams {
    /// Food product UUID.
    pub food_id: Uuid,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetDailySummaryParams {
    /// First day in the summary range, formatted as strict `YYYY-MM-DD`.
    pub from_date: String,
    /// Last day in the summary range, formatted as strict `YYYY-MM-DD`.
    pub to_date: String,
}

#[derive(Clone)]
pub struct McpServer {
    catalog: Arc<dyn McpCatalogRead>,
    summary: Arc<dyn McpSummaryRead>,
    tool_router: ToolRouter<Self>,
}

impl McpServer {
    pub fn new(catalog: Arc<dyn McpCatalogRead>, summary: Arc<dyn McpSummaryRead>) -> Self {
        Self {
            catalog,
            summary,
            tool_router: Self::tool_router(),
        }
    }
}

#[tool_router]
impl McpServer {
    #[tool(
        description = "Search the shared food catalog with the same visibility rules as /api/foods/search. Results include per-100g nutrition. The history scope is specific to the caller.",
        annotations(read_only_hint = true)
    )]
    async fn search_foods(
        &self,
        Parameters(params): Parameters<SearchFoodsParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<Json<SearchListResponse>, CallToolResult> {
        let auth = mcp_auth(&context)?;
        if params.query.chars().count() > MAX_SEARCH_QUERY_CHARS {
            return Err(tool_error(format!(
                "query must be at most {MAX_SEARCH_QUERY_CHARS} characters"
            )));
        }
        let scope = params.scope.unwrap_or(FoodSearchScopeParam::All).into();
        let products = self
            .catalog
            .search(
                auth.profile_id,
                ProductSearchSpec::parse(&params.query),
                scope,
            )
            .await
            .map_err(catalog_error_to_tool_error)?;

        Ok(Json(products_to_search_response(products)))
    }

    #[tool(
        description = "Read a food's details from the shared catalog, including nutrients per 100 g, servings, and allowed units.",
        annotations(read_only_hint = true)
    )]
    async fn get_food(
        &self,
        Parameters(params): Parameters<GetFoodParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<Json<ProductDetailResponse>, CallToolResult> {
        let auth = mcp_auth(&context)?;
        let product = self
            .catalog
            .get_product(auth.profile_id, ProductId(params.food_id))
            .await
            .map_err(catalog_error_to_tool_error)?;
        let allowed_units = self
            .catalog
            .allowed_units(&product)
            .await
            .map_err(catalog_error_to_tool_error)?;

        Ok(Json(product_to_detail_response(&product, allowed_units)))
    }

    #[tool(
        description = "Read the caller's daily calorie and macro totals for an inclusive date range. The range is limited to a 366-day difference (up to 367 inclusive days), and only days with food logs are returned.",
        annotations(read_only_hint = true)
    )]
    async fn get_daily_summary(
        &self,
        Parameters(params): Parameters<GetDailySummaryParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<Json<LogSummaryResponse>, CallToolResult> {
        let auth = mcp_auth(&context)?;
        let from_date = parse_date("from_date", &params.from_date)?;
        let to_date = parse_date("to_date", &params.to_date)?;
        let days = self
            .summary
            .summarize_by_date(auth.profile_id, from_date, to_date)
            .await
            .map_err(journal_error_to_tool_error)?;

        Ok(Json(food_log_day_summaries_to_response(days)))
    }
}

#[tool_handler(name = "calco", router = self.tool_router)]
impl ServerHandler for McpServer {}

fn mcp_auth(context: &RequestContext<RoleServer>) -> Result<&McpUser, CallToolResult> {
    let parts = context
        .extensions
        .get::<Parts>()
        .ok_or_else(|| tool_error("missing MCP request context"))?;
    parts
        .extensions
        .get::<McpUser>()
        .ok_or_else(|| tool_error("missing MCP authentication context"))
}

fn tool_error(message: impl Into<String>) -> CallToolResult {
    CallToolResult::error(vec![ContentBlock::text(message)])
}

fn parse_date(field: &str, value: &str) -> Result<NaiveDate, CallToolResult> {
    if !has_strict_iso_date_shape(value) {
        return Err(tool_error(format!("{field} must be a YYYY-MM-DD date")));
    }

    NaiveDate::parse_from_str(value, "%Y-%m-%d")
        .map_err(|_| tool_error(format!("{field} must be a YYYY-MM-DD date")))
}

fn has_strict_iso_date_shape(value: &str) -> bool {
    let bytes = value.as_bytes();

    bytes.len() == 10
        && bytes[0..4].iter().all(|byte| byte.is_ascii_digit())
        && bytes[4] == b'-'
        && bytes[5..7].iter().all(|byte| byte.is_ascii_digit())
        && bytes[7] == b'-'
        && bytes[8..10].iter().all(|byte| byte.is_ascii_digit())
}

fn catalog_error_to_tool_error(error: CatalogError) -> CallToolResult {
    match error {
        CatalogError::Validation(message) => tool_error(message),
        CatalogError::NotFound(_) | CatalogError::Forbidden(_) => tool_error("food not found"),
        error => {
            tracing::error!(error = %error, "MCP catalog request failed");
            tool_error("internal service error")
        }
    }
}

fn journal_error_to_tool_error(error: JournalError) -> CallToolResult {
    match error {
        JournalError::Validation(message) => tool_error(message),
        JournalError::NotFound(_) | JournalError::Forbidden(_) => tool_error("resource not found"),
        error => {
            tracing::error!(error = %error, "MCP journal request failed");
            tool_error("internal service error")
        }
    }
}
