defmodule Vdr.TSProj do
  @moduledoc """
  TS-based Redis replication stream processor with typed stores.

  This module provides Redis replication stream processing using TS (Rust-based storage)
  for efficient key-value storage. Currently supports string operations only.
  All keys and values are stored as raw binaries.
  """

  require Logger

  @behaviour Vdr.RedisStream.Callback

  alias Vdr.RedisStream.Command
  alias Command, as: RedisCommand

  defstruct [:ts_storage, :id, :new_ts_storage, :ready]

  @type key :: binary()
  @type value :: binary()

  @type t :: %__MODULE__{
          ts_storage: reference(),
          id: term(),
          new_ts_storage: reference() | nil,
          ready: boolean()
        }

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)

    redis_opts =
      Keyword.take(opts, [
        :host,
        :port,
        :username,
        :password,
        :ssl,
        :ssl_opts,
        :reconnect,
        :reconnect_delay_ms,
        :max_reconnect_delay_ms,
        :command_filter
      ])

    callback_opts = Keyword.get(opts, :callback_opts, [])
    callback_opts = Keyword.put(callback_opts, :id, id)

    callback_module = __MODULE__

    replica_opts =
      [
        callback_module: callback_module,
        callback_opts: callback_opts
      ] ++ redis_opts

    Vdr.RedisStream.Replica.start_link(replica_opts)
  end

  @impl Vdr.RedisStream.Callback
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    state = initialize_state(id)

    # Register with both pid and TS storage in handle_state
    :ok =
      Vdr.Registry.register(self(), id, %Vdr.Handle{
        callback_module: __MODULE__,
        handle_state: %{pid: self(), ts_storage: state.ts_storage},
        pid: self()
      })

    {:ok, state}
  end

  @impl Vdr.RedisStream.Callback
  def handle_replication_start(state) do
    reinitialize_state(state)
  end

  @impl Vdr.RedisStream.Callback
  def handle_streaming_start(state) do
    # Replace current ts_storage with new_ts_storage
    # Set ready flag to true
    # Clear new_ts_storage
    new_state = %{state | ts_storage: state.new_ts_storage, new_ts_storage: nil, ready: true}

    # Update registry with new ts_storage
    :ok =
      Vdr.Registry.register(self(), state.id, %Vdr.Handle{
        callback_module: __MODULE__,
        handle_state: %{pid: self(), ts_storage: new_state.ts_storage},
        pid: self()
      })

    {:ok, new_state}
  end

  @impl Vdr.RedisStream.Callback
  def handle_command(%__MODULE__{} = state, %Vdr.RedisStream.ReplicaCommand{
        db: db,
        command: command
      }) do
    # If new_ts_storage exists, write to it (during RDB transfer)
    # Otherwise, write to ts_storage (during streaming)
    if state.new_ts_storage do
      # Writing to new_ts_storage during RDB transfer
      do_handle_command(state.new_ts_storage, db, command)
      {:ok, state}
    else
      # Writing to ts_storage during streaming
      do_handle_command(state.ts_storage, db, command)
      {:ok, state}
    end
  end

  @impl Vdr.RedisStream.Callback
  def handle_call(%__MODULE__{} = state, message) do
    # Check if ready to serve reads
    if not state.ready do
      {:reply, {:error, :not_ready}, state}
    else
      # Serve reads from current ts_storage (not new_ts_storage)
      case message do
        {:get, db, key} ->
          result = Vdr.TS.get(state.ts_storage, db, key)
          {:reply, {:ok, result}, state}

        _ ->
          {:reply, {:error, :not_implemented}, state}
      end
    end
  end

  @impl Vdr.RedisStream.Callback
  def handle_destroy(%__MODULE__{ts_storage: ts_storage, new_ts_storage: new_ts_storage}) do
    # Clean up TS storage
    if ts_storage, do: Vdr.TS.destroy(ts_storage)
    if new_ts_storage, do: Vdr.TS.destroy(new_ts_storage)
    :ok
  end

  def handle_destroy(_state) do
    :ok
  end

  # Private functions

  defp initialize_state(id) do
    %__MODULE__{
      id: id,
      ts_storage: Vdr.TS.create(),
      new_ts_storage: nil,
      ready: false
    }
  end

  defp reinitialize_state(%__MODULE__{} = state) do
    # Create new_ts_storage for incoming RDB data
    # Keep current ts_storage for serving reads during RDB transfer
    # Keep ready flag as-is (true after first sync, false initially)
    new_state = %{state | new_ts_storage: Vdr.TS.create()}

    # Registry is already registered in init, no need to re-register
    {:ok, new_state}
  end

  # Public accessor functions
  # Uses TS storage directly instead of GenServer calls
  # Only get/3 is implemented, all others return {:error, :not_implemented}

  def get(handle_state, db, key) when is_map(handle_state) and is_binary(key) do
    # Extract TS storage from handle_state and use it directly
    ts_storage = handle_state.ts_storage
    Vdr.TS.get(ts_storage, db, key)
  end

  # All other accessors return not_implemented error
  def llen(_handle_state, _db, _key), do: {:error, :not_implemented}
  def lrange(_handle_state, _db, _key, _start, _stop), do: {:error, :not_implemented}
  def smembers(_handle_state, _db, _key), do: {:error, :not_implemented}
  def scard(_handle_state, _db, _key), do: {:error, :not_implemented}
  def hget(_handle_state, _db, _key, _field), do: {:error, :not_implemented}
  def hmget(_handle_state, _db, _key, _fields), do: {:error, :not_implemented}
  def hgetall(_handle_state, _db, _key), do: {:error, :not_implemented}
  def hkeys(_handle_state, _db, _key), do: {:error, :not_implemented}
  def hvals(_handle_state, _db, _key), do: {:error, :not_implemented}
  def hlen(_handle_state, _db, _key), do: {:error, :not_implemented}
  def zrange(_handle_state, _db, _key, _start, _stop), do: {:error, :not_implemented}
  def zcard(_handle_state, _db, _key), do: {:error, :not_implemented}
  def zscore(_handle_state, _db, _key, _member), do: {:error, :not_implemented}

  # String command handlers
  defp do_handle_command(ts_storage, db, %RedisCommand.Set{key: key, value: value}) do
    Vdr.TS.set(ts_storage, db, key, value)
  end

  defp do_handle_command(ts_storage, db, %RedisCommand.Del{keys: keys}) do
    Enum.each(keys, fn key ->
      Vdr.TS.del(ts_storage, db, key)
    end)
  end

  # Ignore all other commands
  defp do_handle_command(_ts_storage, _db, _command) do
    :ok
  end
end
