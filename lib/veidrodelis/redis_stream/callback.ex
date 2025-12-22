defmodule Vdr.RedisStream.Callback do
  @moduledoc """
  Behaviour for processing Redis commands as a stream.

  Implement this behaviour to process Redis commands as they are parsed from an RDB file
  or received from a replication stream. Each callback receives the current state and a
  `ReplicaCommand` struct containing the database number, parsed command, raw command,
  and a context map.

  ## Command Structs

  The parser emits command structs from `Veidrodelis.RedisCommand`:

  - `%RedisCommand.Set{}` - String value (SET command)
  - `%RedisCommand.RPush{}` - List element (RPUSH command)
  - `%RedisCommand.SAdd{}` - Set member (SADD command)
  - `%RedisCommand.ZAdd{}` - Sorted set member with score (ZADD command)
  - `%RedisCommand.HSet{}` - Hash field and value (HSET command)
  - `%RedisCommand.PExpireAt{}` - Key expiration timestamp in milliseconds (PEXPIREAT command)

  ## Example

      defmodule MyCallback do
        @behaviour Vdr.RedisStream.Callback

        alias Vdr.RedisStream.Command, as: RedisCommand
        alias Vdr.RedisStream.ReplicaCommand

        @impl true
        def handle_command(state, %ReplicaCommand{db: db, command: %RedisCommand.Set{key: key, value: value}}) do
          IO.puts("SET \#{key} = \#{value} in DB \#{db}")
          {:ok, state}
        end

        def handle_command(state, %ReplicaCommand{db: db, command: %RedisCommand.RPush{key: key, value: value}}) do
          IO.puts("RPUSH \#{key} \#{value} in DB \#{db}")
          {:ok, state}
        end

        def handle_command(state, %ReplicaCommand{db: db, command: %RedisCommand.SAdd{key: key, member: member}}) do
          IO.puts("SADD \#{key} \#{member} in DB \#{db}")
          {:ok, state}
        end

        def handle_command(state, %ReplicaCommand{db: db, command: %RedisCommand.ZAdd{key: key, score: score, member: member}}) do
          IO.puts("ZADD \#{key} \#{score} \#{member} in DB \#{db}")
          {:ok, state}
        end

        def handle_command(state, %ReplicaCommand{db: db, command: %RedisCommand.HSet{key: key, field: field, value: value}}) do
          IO.puts("HSET \#{key} \#{field} \#{value} in DB \#{db}")
          {:ok, state}
        end

        def handle_command(state, %ReplicaCommand{db: db, command: %RedisCommand.PExpireAt{key: key, timestamp_ms: timestamp_ms}}) do
          IO.puts("PEXPIREAT \#{key} \#{timestamp_ms} in DB \#{db}")
          {:ok, state}
        end
      end

      {:ok, rdb_binary} = File.read("dump.rdb")
      {:ok, final_state} = Vdr.RedisStream.RDB.parse(rdb_binary, MyCallback, %{})
  """

  alias Vdr.RedisStream.ReplicaCommand

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
  @callback handle_replication_start(state :: term()) :: {:ok, term()} | {:error, term()}

  @doc """
  Called when a Redis command is parsed from the RDB file or received from replication.

  ## Parameters

    * `state` - Current state
    * `replica_command` - A `ReplicaCommand` struct containing:
      * `db` - Database number
      * `command` - Parsed command struct from `Veidrodelis.RedisCommand`
      * `raw_command` - Raw generic command representation
      * `context` - Map for storing metadata (can be modified by filters)

  ## Returns

    * `{:ok, new_state}` - Continue parsing with new state
    * `{:error, reason}` - Halt parsing with error
  """
  @callback handle_command(
              state :: term(),
              replica_command :: ReplicaCommand.t()
            ) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Called when a synchronous call is made to the replica via `Replica.call/2`.

  This callback allows your application to respond to custom synchronous queries
  or commands. It is invoked in the replica's GenServer context, only when the
  replica is in a valid state (after replication start and before destroy).

  ## Parameters

    * `state` - Current state
    * `message` - The message passed to `Replica.call/2`

  ## Returns

    * `{:reply, reply, new_state}` - Reply to the caller with `reply` and update state
    * `{:noreply, new_state}` - Don't reply (caller will timeout)
    * `{:error, reason}` - Return error to caller

  ## Optional

  This callback is optional. If not implemented, calls will return `{:error, :not_implemented}`.
  """
  @callback handle_call(state :: term(), message :: term()) ::
              {:reply, term(), term()} | {:noreply, term()} | {:error, term()}

  @doc """
  Called when the replication connection is being terminated.

  This callback is invoked in the `terminate/2` callback of the replica GenServer,
  allowing your application to clean up resources before shutdown.

  ## Parameters

    * `state` - Current state

  ## Returns

    * `:ok` - Cleanup successful
    * `{:error, reason}` - Cleanup failed (error is logged but doesn't prevent termination)

  ## Optional

  This callback is optional. If not implemented, termination will proceed without
  additional cleanup.
  """
  @callback handle_destroy(state :: term()) :: :ok | {:error, term()}

  @optional_callbacks handle_destroy: 1, handle_call: 2
end
