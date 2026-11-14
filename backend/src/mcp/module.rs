use std::sync::Arc;

use async_trait::async_trait;
use chrono::NaiveDate;
use uuid::Uuid;

use crate::catalog::app::CatalogService;
use crate::catalog::domain::{Product, ProductId, ProductSearchScope, ProductSearchSpec, UnitCode};
use crate::catalog::error::CatalogError;
use crate::config::ServerConfig;
use crate::journal::error::JournalError;
use crate::journal::food_log::app::{FoodLogDaySummary, FoodLogHistoryService};

/// Narrow, read-only catalog dependency for MCP tools.
///
/// MCP must not receive the full catalog module or service surface; write
/// dependencies stay out of this boundary until a later phase introduces them.
#[async_trait]
pub trait McpCatalogRead: Send + Sync {
    async fn search(
        &self,
        actor_id: Uuid,
        spec: ProductSearchSpec,
        scope: ProductSearchScope,
    ) -> Result<Vec<Product>, CatalogError>;

    async fn get_product(&self, actor_id: Uuid, id: ProductId) -> Result<Product, CatalogError>;

    async fn allowed_units(
        &self,
        product: &Product,
    ) -> Result<Vec<(UnitCode, String, String)>, CatalogError>;
}

#[async_trait]
impl McpCatalogRead for CatalogService {
    async fn search(
        &self,
        actor_id: Uuid,
        spec: ProductSearchSpec,
        scope: ProductSearchScope,
    ) -> Result<Vec<Product>, CatalogError> {
        CatalogService::search(self, actor_id, spec, scope).await
    }

    async fn get_product(&self, actor_id: Uuid, id: ProductId) -> Result<Product, CatalogError> {
        CatalogService::get_product(self, actor_id, id).await
    }

    async fn allowed_units(
        &self,
        product: &Product,
    ) -> Result<Vec<(UnitCode, String, String)>, CatalogError> {
        CatalogService::allowed_units(self, product).await
    }
}

/// Narrow summary dependency for MCP tools.
#[async_trait]
pub trait McpSummaryRead: Send + Sync {
    async fn summarize_by_date(
        &self,
        user_id: Uuid,
        from_date: NaiveDate,
        to_date: NaiveDate,
    ) -> Result<Vec<FoodLogDaySummary>, JournalError>;
}

#[async_trait]
impl McpSummaryRead for FoodLogHistoryService {
    async fn summarize_by_date(
        &self,
        user_id: Uuid,
        from_date: NaiveDate,
        to_date: NaiveDate,
    ) -> Result<Vec<FoodLogDaySummary>, JournalError> {
        FoodLogHistoryService::summarize_by_date(self, user_id, from_date, to_date).await
    }
}

/// HTTP-facing MCP settings, narrowed from the general server config.
#[derive(Debug, Clone)]
pub struct McpConfig {
    pub(crate) allowed_hosts: Vec<String>,
    pub(crate) allowed_origins: Vec<String>,
}

impl McpConfig {
    pub fn from_server(server: &ServerConfig) -> Self {
        let allowed_origins = server
            .cors_allowed_origins
            .iter()
            .filter_map(|origin| origin.to_str().ok())
            .map(str::to_owned)
            .collect();

        Self {
            allowed_hosts: server.effective_mcp_allowed_hosts(),
            allowed_origins,
        }
    }
}

/// Composition root for the read-only MCP surface.
#[derive(Clone)]
pub struct McpModule {
    pub(crate) catalog: Arc<dyn McpCatalogRead>,
    pub(crate) summary: Arc<dyn McpSummaryRead>,
    pub(crate) config: McpConfig,
}

impl McpModule {
    pub fn build(
        catalog: Arc<CatalogService>,
        summary: Arc<FoodLogHistoryService>,
        config: McpConfig,
    ) -> Self {
        Self {
            catalog: catalog as Arc<dyn McpCatalogRead>,
            summary: summary as Arc<dyn McpSummaryRead>,
            config,
        }
    }
}
