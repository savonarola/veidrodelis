defmodule Veidrodelis.RedisStream.Callback do
  @moduledoc """
  Behaviour for processing Redis commands as a stream.

  Implement this behaviour to process Redis commands as they are parsed from an RDB file.
  Each callback receives the current state, database number, and a command struct representing
  the Redis write operation that would have created the data.

  ## Command Structs

  The parser emits command structs from `Veidrodelis.Command`:

  - `%Command.Set{}` - String value (SET command)
  - `%Command.RPush{}` - List element (RPUSH command)
  - `%Command.SAdd{}` - Set member (SADD command)
  - `%Command.ZAdd{}` - Sorted set member with score (ZADD command)
  - `%Command.HSet{}` - Hash field and value (HSET command)
  - `%Command.PExpireAt{}` - Key expiration timestamp in milliseconds (PEXPIREAT command)

  ## Example

      defmodule MyCallback do
        @behaviour Veidrodelis.RedisStream.Callback

        alias Veidrodelis.Command

        @impl true
        def on_command(state, db, %Command.Set{key: key, value: value}) do
          IO.puts("SET \#{key} = \#{value} in DB \#{db}")
          {:ok, state}
        end

        def on_command(state, db, %Command.RPush{key: key, value: value}) do
          IO.puts("RPUSH \#{key} \#{value} in DB \#{db}")
          {:ok, state}
        end

        def on_command(state, db, %Command.SAdd{key: key, member: member}) do
          IO.puts("SADD \#{key} \#{member} in DB \#{db}")
          {:ok, state}
        end

        def on_command(state, db, %Command.ZAdd{key: key, score: score, member: member}) do
          IO.puts("ZADD \#{key} \#{score} \#{member} in DB \#{db}")
          {:ok, state}
        end

        def on_command(state, db, %Command.HSet{key: key, field: field, value: value}) do
          IO.puts("HSET \#{key} \#{field} \#{value} in DB \#{db}")
          {:ok, state}
        end

        def on_command(state, db, %Command.PExpireAt{key: key, timestamp_ms: timestamp_ms}) do
          IO.puts("PEXPIREAT \#{key} \#{timestamp_ms} in DB \#{db}")
          {:ok, state}
        end
      end

      {:ok, rdb_binary} = File.read("dump.rdb")
      {:ok, final_state} = Veidrodelis.RDB.parse(rdb_binary, MyCallback, %{})
  """

  alias Veidrodelis.Command

  @doc """
  Called when a full replication is about to start.

  This callback is invoked before the RDB transfer begins, either on the initial
  connection or after a disconnection that requires a full resync. This allows
  your application to reset its state before receiving the snapshot.

  ## Parameters

    * `state` - Current state

  ## Returns

    * `{:ok, new_state}` - Continue with replication using new state
    * `{:error, reason}` - Halt replication with error

  ## Optional

  This callback is optional. If not implemented, replication will proceed with
  the existing state.
  """
  @callback on_replication_start(state :: term()) :: {:ok, term()} | {:error, term()}

  @doc """
  Called when a Redis command is parsed from the RDB file.

  ## Parameters

    * `state` - Current state
    * `db` - Database number (0-15)
    * `command` - A command struct from `Veidrodelis.Command`

  ## Returns

    * `{:ok, new_state}` - Continue parsing with new state
    * `{:error, reason}` - Halt parsing with error
  """
  @callback on_command(
              state :: term(),
              db :: non_neg_integer(),
              command :: Command.t()
            ) ::
              {:ok, term()} | {:error, term()}

  @optional_callbacks on_replication_start: 1
end
