//! `calco` command-line client.
//!
//! This module owns only the top-level clap parser, raw-argument inspection for
//! JSON-aware clap errors, output-mode resolution, delegation to
//! `commands::run`, and process exit handling. Configuration/auth, dates, HTTP,
//! output, and command rendering live in their own modules.
//!
//! ```text
//! main.rs      clap parser, command delegation, process exit handling
//! auth.rs      configuration, credentials, auth commands
//! client.rs    HTTP transport, wire DTOs, request recovery
//! dates.rs     date selector grammar and ranges
//! output.rs    errors, output modes/envelopes, shared human formatting
//! commands/    command args, dispatch, category execution and human rendering
//! ```

mod auth;
mod client;
mod commands;
mod dates;
mod output;

#[cfg(test)]
mod test_support;

use std::ffi::{OsStr, OsString};
use std::io;
use std::process::ExitCode;

use clap::Parser;
use clap::error::ErrorKind;

#[derive(Debug, clap::Parser)]
#[command(name = "calco", version, about = "CalCo command-line client")]
struct Cli {
    #[command(flatten)]
    global: commands::GlobalArgs,
    #[command(subcommand)]
    command: commands::Command,
}

/// Flags that affect how an early clap error is rendered.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
struct RequestedFlags {
    json: bool,
    pretty: bool,
}

/// Inspect raw arguments for the actual `--json` and `--pretty` flags.
///
/// Only exact option tokens before a `--` separator count. Flag-like text in a
/// value, such as `--notes=--json`, is deliberately ignored. A separate token
/// such as `--notes --json` still counts as a flag because clap does not accept
/// hyphen-prefixed option values. Clap remains the authority on whether the
/// resulting argument list is valid.
fn requested_flags<I, S>(args: I) -> RequestedFlags
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let mut flags = RequestedFlags::default();
    let mut end_of_options = false;

    for arg in args {
        let arg = arg.as_ref();
        if end_of_options {
            continue;
        }
        if arg == OsStr::new("--") {
            end_of_options = true;
            continue;
        }
        if arg == OsStr::new("--json") {
            flags.json = true;
        } else if arg == OsStr::new("--pretty") {
            flags.pretty = true;
        }
    }

    flags
}

fn error_output_mode(flags: RequestedFlags) -> output::OutputMode {
    if flags.json {
        if flags.pretty {
            output::OutputMode::JsonPretty
        } else {
            output::OutputMode::JsonCompact
        }
    } else {
        output::OutputMode::Human
    }
}

fn finish_error(error: output::CliError, mode: output::OutputMode) -> ExitCode {
    let _ = output::write_error(&error, mode);
    ExitCode::from(error.exit_code())
}

fn report_clap_error(error: clap::Error, flags: RequestedFlags) -> ExitCode {
    match error.kind() {
        ErrorKind::DisplayHelp | ErrorKind::DisplayVersion => match error.print() {
            Ok(()) => ExitCode::SUCCESS,
            Err(write_error) if write_error.kind() == io::ErrorKind::BrokenPipe => {
                ExitCode::SUCCESS
            }
            Err(_) => ExitCode::from(1),
        },
        _ => {
            if flags.json {
                let cli_error = output::CliError::new(
                    output::ErrorOrigin::Arguments,
                    "invalid_arguments",
                    error.to_string().trim().to_string(),
                );
                let _ = output::write_error(&cli_error, error_output_mode(flags));
            } else {
                let _ = error.print();
            }
            ExitCode::from(2)
        }
    }
}

#[tokio::main]
async fn main() -> ExitCode {
    let args: Vec<OsString> = std::env::args_os().collect();
    let flags = requested_flags(args.iter().skip(1));

    let cli = match Cli::try_parse_from(args) {
        Ok(cli) => cli,
        Err(error) => return report_clap_error(error, flags),
    };

    let mode = match output::OutputMode::resolve(cli.global.json, cli.global.pretty) {
        Ok(mode) => mode,
        Err(error) => return finish_error(error, error_output_mode(flags)),
    };

    let runtime = match commands::Runtime::system() {
        Ok(runtime) => runtime,
        Err(error) => return finish_error(error, mode),
    };

    match commands::run(cli.command, &cli.global, &runtime).await {
        Ok(output) => match output::write_success(&output, mode) {
            Ok(()) => ExitCode::SUCCESS,
            Err(write_error) if write_error.kind() == io::ErrorKind::BrokenPipe => {
                ExitCode::SUCCESS
            }
            Err(_) => finish_error(
                output::CliError::new(
                    output::ErrorOrigin::Internal,
                    "internal_error",
                    "could not write command output",
                ),
                mode,
            ),
        },
        Err(error) => finish_error(error, mode),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[test]
    fn requested_flags_only_match_literal_options_before_the_separator() {
        let flags = requested_flags(["--json", "--pretty"]);
        assert_eq!(
            flags,
            RequestedFlags {
                json: true,
                pretty: true
            }
        );

        assert!(requested_flags(["logs", "list", "today", "--json"]).json);
        assert!(requested_flags(["--pretty", "--json"]).pretty);

        for args in [
            vec!["--notes=--json"],
            vec!["--base-url=--json"],
            vec!["--notes", "--json=1"],
            vec!["--json=true"],
            vec!["logs", "list", "today", "--", "--json"],
            vec!["--", "--json", "--pretty"],
        ] {
            assert_eq!(
                requested_flags(args),
                RequestedFlags::default(),
                "unexpected flag detection"
            );
        }
    }

    #[test]
    fn requested_flags_ignore_attached_values_and_invalid_flag_forms() {
        for args in [
            vec!["--notes=--json"],
            vec!["--base-url=--json"],
            vec!["--json=true"],
            vec!["--json=false"],
            vec!["--json="],
            vec!["--pretty=true"],
            vec!["--pretty=false"],
            vec!["--pretty="],
        ] {
            assert_eq!(
                requested_flags(args),
                RequestedFlags::default(),
                "invalid or attached flag-like values must not select an output mode"
            );
        }

        // A separate flag-like token is a clap option, not an option value.
        assert_eq!(
            requested_flags(["--notes", "--json"]),
            RequestedFlags {
                json: true,
                pretty: false
            }
        );
        assert_eq!(
            requested_flags(["--base-url", "--pretty", "--json"]),
            RequestedFlags {
                json: true,
                pretty: true
            }
        );

        // Once the option terminator is seen, later flag-like tokens are values.
        assert_eq!(
            requested_flags(["--notes", "--", "--json", "--pretty"]),
            RequestedFlags::default()
        );
        assert_eq!(
            requested_flags(["--json", "--", "--pretty"]),
            RequestedFlags {
                json: true,
                pretty: false
            }
        );
    }

    #[test]
    fn clap_treats_a_separate_flag_like_token_as_an_option_not_an_option_value() {
        let error = Cli::try_parse_from([
            "calco",
            "logs",
            "add",
            "--food",
            "123e4567-e89b-12d3-a456-426614174000",
            "--amount",
            "1",
            "--unit",
            "g",
            "--idempotency-key",
            "key",
            "--notes",
            "--json",
        ])
        .expect_err("--json is a flag, so --notes has no value");
        assert_eq!(error.kind(), ErrorKind::InvalidValue);
    }

    #[test]
    fn invalid_pretty_forms_only_select_pretty_when_json_is_also_exact() {
        assert_eq!(
            error_output_mode(requested_flags(["--pretty"])),
            output::OutputMode::Human
        );
        assert_eq!(
            error_output_mode(requested_flags(["--pretty=false", "--json"])),
            output::OutputMode::JsonCompact
        );
        assert_eq!(
            error_output_mode(requested_flags(["--pretty=true", "--json"])),
            output::OutputMode::JsonCompact
        );
        assert_eq!(
            error_output_mode(requested_flags(["--pretty", "--json=false"])),
            output::OutputMode::Human
        );
        assert_eq!(
            error_output_mode(requested_flags(["--pretty", "--json=true"])),
            output::OutputMode::Human
        );
        assert_eq!(
            error_output_mode(requested_flags(["--pretty", "--json"])),
            output::OutputMode::JsonPretty
        );
    }

    #[test]
    fn pretty_without_json_is_an_arguments_error_after_parsing() {
        let cli = Cli::try_parse_from(["calco", "--pretty", "logs", "list", "today"])
            .expect("pretty parses as a global flag");
        assert!(cli.global.pretty);
        assert!(!cli.global.json);

        let error = output::OutputMode::resolve(cli.global.json, cli.global.pretty)
            .expect_err("pretty requires json");
        assert_eq!(error.code, "invalid_arguments");
        assert_eq!(error.exit_code(), 2);
        assert!(error.message.contains("--pretty requires --json"));
    }

    #[test]
    fn parser_accepts_global_flags_before_and_after_the_command() {
        let before = Cli::try_parse_from(["calco", "--json", "logs", "list", "today"])
            .expect("global flag before command");
        assert!(before.global.json);
        assert!(matches!(
            before.command,
            commands::Command::Logs(commands::LogsArgs {
                command: commands::LogsCommand::List { .. }
            })
        ));

        let after = Cli::try_parse_from(["calco", "logs", "list", "today", "--json"])
            .expect("global flag after command");
        assert!(after.global.json);
    }

    #[test]
    fn help_and_version_are_normal_clap_messages() {
        let help = Cli::try_parse_from(["calco", "--help"]).expect_err("help exits clap");
        assert_eq!(help.kind(), ErrorKind::DisplayHelp);
        assert!(!help.use_stderr());
        assert!(help.to_string().contains("Usage:"));
        assert!(help.to_string().contains("--json"));

        let version = Cli::try_parse_from(["calco", "--version"]).expect_err("version exits clap");
        assert_eq!(version.kind(), ErrorKind::DisplayVersion);
        assert!(!version.use_stderr());
        assert!(version.to_string().contains(env!("CARGO_PKG_VERSION")));
    }

    #[test]
    fn parser_rejects_invalid_commands_and_missing_values() {
        let invalid = Cli::try_parse_from(["calco", "logs", "delete"]).expect_err("missing id");
        assert_eq!(invalid.kind(), ErrorKind::MissingRequiredArgument);

        let missing_value = Cli::try_parse_from(["calco", "logs", "add", "--notes"])
            .expect_err("missing notes value");
        assert_eq!(missing_value.kind(), ErrorKind::InvalidValue);
    }
}
