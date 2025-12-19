# Rust NIF Logging

This document describes the logging infrastructure for the Rust NIF parser in Veidrodelis.

## Overview

The Rust parser uses the standard `env_logger` crate, which is the de facto standard for Rust logging. All `println!` statements have been converted to proper log macros (`log::debug!`, `log::trace!`, etc.).

## Configuration

Logging is controlled via the `RUST_LOG` environment variable and must be set **before** starting your Elixir application.

### Log Levels

From least to most verbose:

- `off` - No logging (default, zero overhead)
- `error` - Only errors
- `warn` - Warnings and errors
- `info` - Informational messages, warnings, and errors
- `debug` - Debug information (recommended for development)
- `trace` - Very detailed trace information (very verbose)

### Usage Examples

```bash
# Enable debug logging for all Rust code
RUST_LOG=debug iex -S mix

# Enable trace logging (very verbose)
RUST_LOG=trace iex -S mix

# Enable debug logging only for the vdr_nif crate
RUST_LOG=vdr_nif=debug iex -S mix

# Enable different levels for different modules
RUST_LOG=vdr_nif::rdb=debug,vdr_nif::replica=info iex -S mix

# Run tests with debug logging
RUST_LOG=debug mix test

# Production: keep logging off for maximum performance
RUST_LOG=off mix release
```

### Environment Variable Persistence

To make the setting persistent in your shell:

```bash
# In your .bashrc, .zshrc, or similar
export RUST_LOG=debug

# Or per-session
export RUST_LOG=debug
iex -S mix
```

## Performance

When `RUST_LOG` is unset or set to `off`, the logger has **zero runtime overhead**. The log level is checked at initialization time only, and disabled log statements compile to no-ops.

## Log Message Locations

The logging infrastructure has been implemented in:

- `native/vdr_nif/src/rdb.rs` - RDB parser logging
  - `log::debug!()` for general parsing flow
  - `log::trace!()` for very detailed buffer state info

Future modules can use the same logging infrastructure by simply using the `log` crate macros.

## Implementation Details

- **Logger**: Standard `env_logger` crate
- **Initialization**: Happens once when the NIF is loaded in `lib.rs`
- **Output**: All logs go to stderr with timestamps and source locations
- **Thread-safety**: env_logger is thread-safe by default
- **No runtime overhead**: When disabled, log statements compile to no-ops

## Advanced Configuration

The `RUST_LOG` environment variable supports advanced filtering:

```bash
# Multiple targets with different levels
RUST_LOG=warn,vdr_nif=debug iex -S mix

# Specific module paths
RUST_LOG=vdr_nif::rdb=trace iex -S mix

# Use regex patterns (requires env_logger regex feature)
RUST_LOG=vdr_nif::r.* iex -S mix
```

See the [env_logger documentation](https://docs.rs/env_logger/) for more details.
