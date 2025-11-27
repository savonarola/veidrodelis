defmodule Veidrodelis do
  @moduledoc """
  Veidrodelis - A Redis RDB file parser for Elixir.

  This library provides a streaming parser for Redis RDB (Redis Database) files
  with a callback-based interface for processing data as it's parsed.

  ## Features

    * Supports RDB format versions 1-12
    * Memory-efficient streaming parser
    * All Redis data types: strings, lists, sets, sorted sets, hashes
    * Multiple encoding formats: ziplist, listpack, intset, quicklist
    * LZF compression/decompression via NIF
    * Callback-based architecture for flexible data processing

  ## Quick Start

      # Define a callback module
      defmodule MyCallback do
        @behaviour Veidrodelis.RDB.Callback

        def on_string(state, _db, key, value) do
          new_state = Map.put(state, key, value)
          {:ok, new_state}
        end

        # Implement other callbacks...
        def on_list_entry(state, _db, _key, _idx, _val), do: {:ok, state}
        def on_set_entry(state, _db, _key, _member), do: {:ok, state}
        def on_zset_entry(state, _db, _key, _member, _score), do: {:ok, state}
        def on_hash_entry(state, _db, _key, _field, _val), do: {:ok, state}
      end

      # Parse an RDB file
      {:ok, rdb_binary} = File.read("dump.rdb")
      {:ok, result} = Veidrodelis.RDB.parse(rdb_binary, MyCallback, %{})

  ## Modules

    * `Veidrodelis.RDB` - Main RDB parser
    * `Veidrodelis.RDB.Callback` - Callback behaviour definition
    * `Veidrodelis.LZF` - LZF compression utilities

  ## Core Erlang Modules

  The parsing logic is implemented in Erlang for performance:

    * `:vdr_rdb` - RDB parser implementation
    * `:vdr_lzf` - LZF NIF implementation
    * `:vdr_rdb_callback` - Erlang callback behaviour
  """

  @doc """
  Returns the version of Veidrodelis.
  """
  @spec version() :: String.t()
  def version do
    "0.1.0"
  end
end
