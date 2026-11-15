pub mod http;

use std::sync::Arc;

use axum::http::request::Parts;
use chrono::NaiveDate;
use rmcp::{
    Json, RoleServer, ServerHandler,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{
        CacheScope, CallToolResult, ContentBlock, ListToolsResult, PaginatedRequestParams,
        ProtocolVersion,
    },
    service::RequestContext,
    tool, tool_handler, tool_router,
};
use rust_decimal::Decimal;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::auth::domain::ApiKeyScope;
use crate::catalog::api::dto::{
    ProductDetailResponse, SearchListResponse, product_to_detail_response,
    products_to_search_response,
};
use crate::catalog::domain::calculation::Quantity;
use crate::catalog::domain::{ProductId, ProductSearchScope, ProductSearchSpec, UnitCode};
use crate::catalog::error::CatalogError;
use crate::journal::error::JournalError;
use crate::journal::food_log::api::dto::{
    LogListResponse, LogResponse, LogSummaryResponse, food_log_day_summaries_to_response,
    food_log_to_response, food_logs_to_list_response, normalize_device_timezone,
};
use crate::journal::food_log::app::LogFoodInput;
use crate::journal::food_log::domain::{FoodLogId, FoodLogItemRef, IdempotencyKey, MealSlot};
use crate::journal::meal::domain::MealId;
use crate::mcp::module::{McpCatalogRead, McpFoodLogRead, McpFoodLogWrite, McpSummaryRead};

const MAX_SEARCH_QUERY_CHARS: usize = 256;
const READ_WRITE_SCOPE_REQUIRED: &str = "read_write API key scope required";

/// Authentication facts made available to MCP tool handlers.
///
/// Read tools accept either key scope. Write tools require `read_write` and
/// enforce that at dispatch time, because the transport only authenticates.
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

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum MealSlotParam {
    Breakfast,
    Lunch,
    Dinner,
    Snack,
    LateNightSnack,
}

impl From<MealSlotParam> for MealSlot {
    fn from(slot: MealSlotParam) -> Self {
        match slot {
            MealSlotParam::Breakfast => MealSlot::Breakfast,
            MealSlotParam::Lunch => MealSlot::Lunch,
            MealSlotParam::Dinner => MealSlot::Dinner,
            MealSlotParam::Snack => MealSlot::Snack,
            MealSlotParam::LateNightSnack => MealSlot::LateNightSnack,
        }
    }
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum LogItemParam {
    Product { id: Uuid },
    Meal { id: Uuid },
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct LogQuantityParam {
    /// Positive decimal amount.
    pub amount: Decimal,
    /// Unit code accepted by the logged item, for example `g`, `kg`, or a configured serving unit.
    pub unit: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct CreateLogParams {
    /// Day to log the food on, formatted as strict `YYYY-MM-DD`.
    pub log_date: String,
    /// Optional meal slot for the log.
    pub meal_slot: Option<MealSlotParam>,
    /// Optional IANA-style device timezone label, for example `Asia/Kolkata`.
    pub device_timezone: Option<String>,
    /// Catalog item to log.
    pub item: LogItemParam,
    /// Logged quantity and its unit.
    pub quantity: LogQuantityParam,
    /// Optional free-form notes.
    pub notes: Option<String>,
    /// Optional idempotency key. Repeating the same key for the same user returns the existing log.
    #[schemars(length(max = IdempotencyKey::MAX_LEN))]
    pub idempotency_key: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ListLogsParams {
    /// Day to list, formatted as strict `YYYY-MM-DD`.
    pub log_date: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct DeleteLogParams {
    /// Food log UUID to delete.
    pub log_id: Uuid,
}

#[derive(Serialize, JsonSchema)]
pub struct DeleteLogResponse {
    pub deleted: bool,
}

#[derive(Clone)]
pub struct McpServer {
    catalog: Arc<dyn McpCatalogRead>,
    summary: Arc<dyn McpSummaryRead>,
    food_log_read: Arc<dyn McpFoodLogRead>,
    food_log_write: Arc<dyn McpFoodLogWrite>,
    tool_router: ToolRouter<Self>,
}

impl McpServer {
    pub fn new(
        catalog: Arc<dyn McpCatalogRead>,
        summary: Arc<dyn McpSummaryRead>,
        food_log_read: Arc<dyn McpFoodLogRead>,
        food_log_write: Arc<dyn McpFoodLogWrite>,
    ) -> Self {
        Self {
            catalog,
            summary,
            food_log_read,
            food_log_write,
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

    #[tool(
        description = "Create one food log for the authenticated profile from a catalog product or meal. Provide idempotency_key to make retries safe: the same key for the same user returns the existing log instead of creating a duplicate.",
        annotations(read_only_hint = false, destructive_hint = false)
    )]
    async fn create_log(
        &self,
        Parameters(params): Parameters<CreateLogParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<Json<LogResponse>, CallToolResult> {
        let auth = mcp_auth(&context)?;
        require_write_scope(auth)?;
        let input = create_log_params_to_input(params)?;
        let log = self
            .food_log_write
            .log_item(auth.profile_id, input)
            .await
            .map_err(journal_error_to_tool_error)?;

        Ok(Json(food_log_to_response(&log)))
    }

    #[tool(
        description = "List the caller's food logs for one day, ordered like GET /api/logs. Both read and read_write API keys may call this tool.",
        annotations(read_only_hint = true)
    )]
    async fn list_logs(
        &self,
        Parameters(params): Parameters<ListLogsParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<Json<LogListResponse>, CallToolResult> {
        let auth = mcp_auth(&context)?;
        let log_date = parse_date("log_date", &params.log_date)?;
        let logs = self
            .food_log_read
            .list_food_logs(auth.profile_id, log_date)
            .await
            .map_err(journal_error_to_tool_error)?;

        Ok(Json(food_logs_to_list_response(log_date, logs)))
    }

    #[tool(
        description = "Delete one of the caller's food logs. This is destructive and cannot be undone.",
        annotations(read_only_hint = false, destructive_hint = true)
    )]
    async fn delete_log(
        &self,
        Parameters(params): Parameters<DeleteLogParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<Json<DeleteLogResponse>, CallToolResult> {
        let auth = mcp_auth(&context)?;
        require_write_scope(auth)?;
        self.food_log_write
            .delete_food_log(FoodLogId(params.log_id), auth.profile_id)
            .await
            .map_err(journal_error_to_tool_error)?;

        Ok(Json(DeleteLogResponse { deleted: true }))
    }
}

#[tool_handler(name = "calco", router = self.tool_router)]
impl ServerHandler for McpServer {
    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, rmcp::ErrorData> {
        let auth = mcp_user(&context).ok_or_else(|| {
            rmcp::ErrorData::internal_error("missing MCP authentication context", None)
        })?;
        let mut tools = self.tool_router.list_all();
        if auth.scope != ApiKeyScope::ReadWrite {
            tools.retain(|tool| !is_write_tool(&tool.name));
        }

        let supports_cache_hints = context
            .protocol_version()
            .is_some_and(|version| version >= ProtocolVersion::V_2026_07_28);
        let mut result = ListToolsResult::with_all_items(tools);
        if supports_cache_hints {
            result.ttl_ms = Some(0);
            result.cache_scope = Some(CacheScope::Private);
        }

        Ok(result)
    }
}

/// Write tools are hidden from `read` keys. Read tools, including `list_logs`,
/// stay visible because both key scopes may call them.
fn is_write_tool(name: &str) -> bool {
    matches!(name, "create_log" | "delete_log")
}

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

fn mcp_user(context: &RequestContext<RoleServer>) -> Option<&McpUser> {
    context
        .extensions
        .get::<Parts>()
        .and_then(|parts| parts.extensions.get::<McpUser>())
}

fn require_write_scope(auth: &McpUser) -> Result<(), CallToolResult> {
    if auth.scope == ApiKeyScope::ReadWrite {
        Ok(())
    } else {
        Err(tool_error(READ_WRITE_SCOPE_REQUIRED))
    }
}

fn create_log_params_to_input(params: CreateLogParams) -> Result<LogFoodInput, CallToolResult> {
    let log_date = parse_date("log_date", &params.log_date)?;
    let item = match params.item {
        LogItemParam::Product { id } => FoodLogItemRef::Product(ProductId(id)),
        LogItemParam::Meal { id } => FoodLogItemRef::Meal(MealId(id)),
    };
    let quantity = Quantity::new(params.quantity.amount, UnitCode(params.quantity.unit))
        .map_err(catalog_error_to_tool_error)?;
    let device_timezone =
        normalize_device_timezone(params.device_timezone).map_err(journal_error_to_tool_error)?;
    let idempotency_key = params
        .idempotency_key
        .map(IdempotencyKey::new)
        .transpose()
        .map_err(journal_error_to_tool_error)?;

    Ok(LogFoodInput {
        log_date,
        meal_slot: params.meal_slot.map(Into::into),
        device_timezone,
        item,
        quantity,
        notes: params.notes,
        idempotency_key,
    })
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
