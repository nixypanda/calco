//! Global command arguments, runtime dispatch, and shared command helpers.
//!
//! Each category module owns its arguments, execution, validation, human
//! rendering, and tests. This parent keeps only the state shared by every
//! category: global flags, the command tree, the injected runtime, connection
//! creation, canonical UUID parsing, and dispatch.
//!
//! The backend remains the authority for catalog resolution, unit conversion,
//! ownership, and write validation. Local checks only cover the stable CLI
//! contract: canonical UUIDs, the single-write request shape, confirmation
//! before a delete, and atomic range output.

mod foods;
mod logs;
mod meals;
mod summary;

use std::io::IsTerminal;
use std::sync::Arc;

use chrono::NaiveDate;
use uuid::Uuid;

use crate::auth::{self, AuthArgs};
use crate::client;
use crate::output::{CliError, CommandOutput, arguments_error};

use logs::TtyDeleteConfirmation;

pub(crate) use logs::DeleteConfirmation;
pub use logs::LogsArgs;
#[cfg(test)]
pub(crate) use logs::LogsCommand;
pub use summary::SummaryArgs;

#[derive(Debug, Clone, clap::Args)]
pub struct GlobalArgs {
    #[arg(long, global = true)]
    pub json: bool,
    #[arg(long, global = true)]
    pub pretty: bool,
    #[arg(long, global = true, value_name = "URL")]
    pub base_url: Option<String>,
}

#[derive(Debug, clap::Subcommand)]
pub enum Command {
    Auth(AuthArgs),
    Foods(foods::FoodsArgs),
    Meals(meals::MealsArgs),
    Logs(LogsArgs),
    Summary(SummaryArgs),
}

/// Injected process dependencies and the single resolved local date.
pub struct Runtime {
    pub env: Arc<dyn auth::Environment>,
    pub stores: Arc<dyn auth::LocalStores>,
    pub http: reqwest::Client,
    pub prompt: Arc<dyn auth::SecretPrompt>,
    pub confirm: Arc<dyn DeleteConfirmation>,
    pub stdin_is_tty: bool,
    pub today: NaiveDate,
}

impl Runtime {
    pub fn system() -> Result<Self, CliError> {
        Ok(Self {
            env: Arc::new(auth::ProcessEnvironment),
            stores: Arc::new(auth::OsLocalStores),
            http: client::build_http_client()?,
            prompt: Arc::new(auth::TtyPrompt),
            confirm: Arc::new(TtyDeleteConfirmation),
            stdin_is_tty: std::io::stdin().is_terminal(),
            today: chrono::Local::now().date_naive(),
        })
    }
}

pub fn parse_full_uuid(raw: &str) -> Result<Uuid, CliError> {
    let parsed = Uuid::parse_str(raw)
        .map_err(|_| arguments_error("invalid_arguments", "ID must be a full canonical UUID"))?;

    if parsed.to_string() != raw {
        return Err(arguments_error(
            "invalid_arguments",
            "ID must be a full lowercase canonical 8-4-4-4-12 UUID",
        ));
    }

    Ok(parsed)
}

pub async fn run(
    command: Command,
    global: &GlobalArgs,
    runtime: &Runtime,
) -> Result<CommandOutput, CliError> {
    match command {
        Command::Auth(args) => auth::run(args.command, global, runtime).await,
        Command::Foods(args) => foods::run(args.command, global, runtime).await,
        Command::Meals(args) => meals::run(args.command, global, runtime).await,
        Command::Logs(args) => logs::run(args.command, global, runtime).await,
        Command::Summary(args) => summary::run(args, global, runtime).await,
    }
}

fn api_client(global: &GlobalArgs, runtime: &Runtime) -> Result<client::ApiClient, CliError> {
    let auth::ResolvedConnection {
        base_url, token, ..
    } = auth::resolve_connection(
        global.base_url.as_deref(),
        runtime.env.as_ref(),
        runtime.stores.as_ref(),
    )?;

    Ok(client::ApiClient::with_http(
        base_url,
        token,
        runtime.http.clone(),
    ))
}

#[cfg(test)]
mod tests;
