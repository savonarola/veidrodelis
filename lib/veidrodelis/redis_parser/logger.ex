defmodule Vdr.RedisParser.Logger do
  @moduledoc """
  Logging configuration for the Rust NIF parser.

  The Rust parser uses the standard `env_logger` crate for logging. Log levels
  are controlled via the `RUST_LOG` environment variable at startup.

  ## Usage

  Set the `RUST_LOG` environment variable before starting your application:

      # Enable all debug logging
      RUST_LOG=debug iex -S mix

      # Enable trace logging (very verbose)
      RUST_LOG=trace iex -S mix

      # Enable debug logging only for the vdr_nif module
      RUST_LOG=vdr_nif=debug iex -S mix

      # Disable logging (default)
      RUST_LOG=off iex -S mix

  ## Log Levels

  From least to most verbose:

  - `off` - No logging (default)
  - `error` - Only errors
  - `warn` - Warnings and errors
  - `info` - Informational messages, warnings, and errors
  - `debug` - Debug information (recommended for development)
  - `trace` - Very detailed trace information (very verbose)

  ## Examples

      # In your shell, before starting Elixir
      export RUST_LOG=debug
      iex -S mix

      # Or inline
      RUST_LOG=debug mix test

      # For production, keep logging off for maximum performance
      RUST_LOG=off mix release

  ## Performance Note

  Logging is implemented with zero runtime overhead when disabled. The logger
  checks the log level at compile/initialization time, so there's no performance
  penalty when `RUST_LOG=off` or unset.
  """

  @doc """
  Returns the current log level configuration from the environment.

  Note: This reads the `RUST_LOG` environment variable. The actual log level
  is set when the NIF is loaded and cannot be changed at runtime.
  """
  def get_env_log_level do
    System.get_env("RUST_LOG", "off")
  end

  @doc """
  Checks if debug logging is enabled.

  This is a convenience function that checks if the `RUST_LOG` environment
  variable is set to a level that includes debug messages.
  """
  def debug_enabled? do
    level = get_env_log_level()
    level in ["debug", "trace"]
  end
end
