defmodule Vdr.TSProj do
  @moduledoc """
  Redis replication stream processor storing data in TS (Rust-based storage).

  This module provides Redis replication stream processing using TS (Rust-based storage)
  for efficient key-value storage. Currently supports sets, sorted sets, lists, hashes and strings.
  """

  require Logger

  @behaviour Vdr.RedisStream.Callback

  @tx_key "__vdr_tx"

  defstruct [
    :ts_storage,
    :id,
    :new_ts_storage,
    :ready,
    :tx_buffer,
    :in_transaction,
    :watch,
    :monitors
  ]

  @type key :: binary()
  @type value :: binary()

  @type t :: %__MODULE__{
          ts_storage: reference(),
          id: term(),
          new_ts_storage: reference() | nil,
          ready: boolean(),
          tx_buffer: list(),
          in_transaction: boolean(),
          watch: Vdr.TS.Watch.t(),
          monitors: %{pid() => reference()}
        }

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)

    redis_opts =
      Keyword.take(opts, [
        :host,
        :port,
        :sentinel,
        :username,
        :password,
        :ssl,
        :ssl_opts,
        :reconnect,
        :reconnect_delay_ms,
        :max_reconnect_delay_ms,
        :command_filter
      ])

    callback_opts = [id: id]
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

    # Register instance immediately so it can accept watch requests
    # before streaming starts (ts_storage will be empty until first sync)
    :ok =
      Vdr.Registry.register(self(), state.id, %Vdr.Handle{
        callback_module: __MODULE__,
        handle_state: %{pid: self(), ts_storage: state.ts_storage, ready: false},
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

    # Send Init messages to all watchers
    new_state.watch
    |> Vdr.TS.Watch.all_watchers()
    |> Enum.each(fn {pid, ref} ->
      send(pid, {ref, %Vdr.WatchEvent.Init{}})
    end)

    # Update registry with new ts_storage and set ready flag
    :ok =
      Vdr.Registry.register(self(), state.id, %Vdr.Handle{
        callback_module: __MODULE__,
        handle_state: %{pid: self(), ts_storage: new_state.ts_storage, ready: true},
        pid: self()
      })

    {:ok, new_state}
  end

  @impl Vdr.RedisStream.Callback
  def handle_commands(%__MODULE__{} = state, commands) when is_list(commands) do
    new_state = Enum.reduce(commands, state, &process_single_command/2)
    # Flush any remaining buffered commands at the end (only if not in transaction)
    flushed_state =
      if new_state.in_transaction, do: new_state, else: flush_tx_buffer(new_state)

    {:ok, flushed_state}
  end

  # Transaction start: SET __vdr_tx
  defp process_single_command(
         %Vdr.RedisStream.ReplicaCommand{db: db, command: {:set, @tx_key, _value} = cmd},
         %__MODULE__{} = state
       ) do
    # Flush any buffered commands before starting the transaction
    flushed_state = flush_tx_buffer(state)
    # Start transaction and buffer this SET command
    %{flushed_state | in_transaction: true, tx_buffer: [{db, cmd}]}
  end

  # Transaction end: DEL __vdr_tx
  defp process_single_command(
         %Vdr.RedisStream.ReplicaCommand{db: db, command: {:del, keys} = cmd},
         %__MODULE__{} = state
       ) do
    if @tx_key in keys do
      # Buffer the DEL command, then flush all buffered commands
      state_with_del = %{state | tx_buffer: [{db, cmd} | state.tx_buffer]}
      flushed_state = flush_tx_buffer(state_with_del)
      %{flushed_state | in_transaction: false}
    else
      # Normal DEL command, buffer it
      %{state | tx_buffer: [{db, cmd} | state.tx_buffer]}
    end
  end

  # Buffer the command (prepend for O(1) performance)
  # Commands are flushed at end of handle_commands or when transaction ends
  defp process_single_command(
         %Vdr.RedisStream.ReplicaCommand{db: db, command: command},
         %__MODULE__{} = state
       ) do
    %{state | tx_buffer: [{db, command} | state.tx_buffer]}
  end

  @impl Vdr.RedisStream.Callback
  def handle_call(%__MODULE__{} = state, {:watch, pid, db, key, ref}) do
    case Vdr.TS.Watch.add(state.watch, pid, db, key, ref) do
      {:ok, new_watch} ->
        # Monitor the process if not already monitored
        new_monitors =
          if Map.has_key?(state.monitors, pid) do
            state.monitors
          else
            monitor_ref = Process.monitor(pid)
            Map.put(state.monitors, pid, monitor_ref)
          end

        new_state = %{state | watch: new_watch, monitors: new_monitors}
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(%__MODULE__{} = state, {:unwatch, pid, db, key}) do
    case Vdr.TS.Watch.delete(state.watch, pid, db, key) do
      {:ok, new_watch, 0} ->
        # Last watch for this pid - demonitor
        case Map.get(state.monitors, pid) do
          nil -> :ok
          monitor_ref -> Process.demonitor(monitor_ref, [:flush])
        end

        new_monitors = Map.delete(state.monitors, pid)
        new_state = %{state | watch: new_watch, monitors: new_monitors}
        {:reply, :ok, new_state}

      {:ok, new_watch, _remaining} ->
        # Pid still has other watches - keep monitoring
        new_state = %{state | watch: new_watch}
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(%__MODULE__{} = state, _message) do
    {:reply, {:error, :not_implemented}, state}
  end

  @impl Vdr.RedisStream.Callback
  def handle_info(%__MODULE__{} = state, {:DOWN, _ref, :process, pid, _reason}) do
    # Remove all watches for the crashed process
    new_watch = Vdr.TS.Watch.delete_all(state.watch, pid)
    new_monitors = Map.delete(state.monitors, pid)
    new_state = %{state | watch: new_watch, monitors: new_monitors}
    {:noreply, new_state}
  end

  def handle_info(%__MODULE__{} = state, _message) do
    # Ignore other messages
    {:noreply, state}
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
      ready: false,
      tx_buffer: [],
      in_transaction: false,
      watch: Vdr.TS.Watch.create(),
      monitors: %{}
    }
  end

  defp reinitialize_state(%__MODULE__{} = state) do
    # Create new_ts_storage for incoming RDB data
    # Keep current ts_storage for serving reads during RDB transfer
    # Keep ready flag as-is (true after first sync, false initially)
    # Clear any ongoing transaction on reconnection
    new_state = %{state | new_ts_storage: Vdr.TS.create(), tx_buffer: [], in_transaction: false}

    # Registry is already registered in init, no need to re-register
    {:ok, new_state}
  end

  @spec read_tx(
          %{ts_storage: reference(), ready: boolean()},
          non_neg_integer(),
          [tuple()] | binary()
        ) ::
          {:ok, [term()]} | {:error, term()}
  def read_tx(%{ready: ready, ts_storage: ts_storage}, db, commands_or_script)
      when is_list(commands_or_script) or is_binary(commands_or_script) do
    if ready do
      Vdr.TS.read_tx(ts_storage, db, commands_or_script)
    else
      {:error, :not_ready}
    end
  end

  @spec lua_load(%{ts_storage: reference()}, binary()) :: {:ok, binary()} | {:error, term()}
  def lua_load(%{ts_storage: ts_storage}, script) when is_binary(script) do
    Vdr.TS.lua_load(ts_storage, script)
  end

  # Convert command tuple to final format for NIF
  # Commands are already in tuple format from CommandParser, just wrap with db
  defp convert_command(_db, {:flushall}), do: {0, {:flushall}}
  defp convert_command(_db, {:swapdb, db1, db2}), do: {0, {:swapdb, db1, db2}}
  defp convert_command(_db, {:generic, _args}), do: nil
  defp convert_command(db, command) when is_tuple(command), do: {db, command}
  defp convert_command(_db, _command), do: nil

  # Transaction helper functions

  # Flush buffered commands: execute all in single tx, notify watchers, clear buffer
  defp flush_tx_buffer(%__MODULE__{tx_buffer: []} = state), do: state

  defp flush_tx_buffer(%__MODULE__{tx_buffer: buffer} = state) do
    # Reverse the buffer since we prepended commands
    commands = Enum.reverse(buffer)

    # Determine which storage to write to
    ts_storage =
      if state.new_ts_storage do
        state.new_ts_storage
      else
        state.ts_storage
      end

    # Convert all commands to tuple format, filtering out unsupported ones
    cmd_tuples =
      commands
      |> Enum.map(fn {db, command} -> convert_command(db, command) end)
      |> Enum.reject(&is_nil/1)

    # Execute all commands in a single tx call
    if cmd_tuples != [] do
      Vdr.TS.tx(ts_storage, cmd_tuples)
    end

    # Notify watchers for each command (in order)
    # Note: commands here are {db, command} tuples from tx_buffer
    # We need to get affected_keys for notification
    Enum.each(commands, fn {db, cmd} ->
      # Extract affected keys for notification (commands in buffer don't have affected_keys)
      affected_keys = extract_affected_keys_for_notification(cmd)
      notify_watchers(state, db, cmd, affected_keys)
    end)

    %{state | tx_buffer: []}
  end

  # Extract affected keys for watch notifications (for commands from tx_buffer)
  defp extract_affected_keys_for_notification(command) do
    case command do
      # Multiple keys
      {:del, keys} -> keys
      {:mset, pairs} -> Enum.map(pairs, fn {k, _v} -> k end)
      {:msetnx, pairs} -> Enum.map(pairs, fn {k, _v} -> k end)
      # Source/destination commands
      {:rpoplpush, src, dest} -> [src, dest]
      {:lmove, src, dest, _wherefrom, _whereto} -> [src, dest]
      {:rename, old_key, new_key} -> [old_key, new_key]
      {:renamenx, old_key, new_key} -> [old_key, new_key]
      {:smove, src, dest, _member} -> [src, dest]
      {:copy, src, dest, _replace} -> [src, dest]
      # Store commands (affect destination + sources)
      {:sunionstore, dest, keys} -> [dest | keys]
      {:sinterstore, dest, keys} -> [dest | keys]
      {:sdiffstore, dest, keys} -> [dest | keys]
      {:zunionstore, dest, keys, _weights, _aggregate} -> [dest | keys]
      {:zinterstore, dest, keys, _weights, _aggregate} -> [dest | keys]
      {:zdiffstore, dest, keys} -> [dest | keys]
      {:zrangestore, dest, src, _min, _max, _opts} -> [dest, src]
      # Single key commands - extract first element as key
      {_cmd, key} when is_binary(key) -> [key]
      {_cmd, key, _} when is_binary(key) -> [key]
      {_cmd, key, _, _} when is_binary(key) -> [key]
      {_cmd, key, _, _, _} when is_binary(key) -> [key]
      # Catch-all for commands we don't track
      _ -> []
    end
  end

  # Notify all watchers of a command
  defp notify_watchers(state, db, command, affected_keys) do
    # Only notify in streaming mode (not during RDB transfer)
    if state.ready do
      case command do
        # FLUSHALL affects all databases - notify all watchers
        {:flushall} ->
          state.watch
          |> Vdr.TS.Watch.all_watchers()
          |> Enum.each(fn {pid, ref} ->
            send(pid, {ref, %Vdr.WatchEvent.Update{command: command, db: db}})
          end)

        # FLUSHDB affects a specific database - notify all watchers in that db
        {:flushdb} ->
          state.watch
          |> Vdr.TS.Watch.lookup_by_db(db)
          |> Enum.each(fn {ref, pid} ->
            send(pid, {ref, %Vdr.WatchEvent.Update{command: command, db: db}})
          end)

        # SWAPDB affects two databases - notify watchers in both
        {:swapdb, db1, db2} ->
          db1_watchers = Vdr.TS.Watch.lookup_by_db(state.watch, db1)
          db2_watchers = Vdr.TS.Watch.lookup_by_db(state.watch, db2)

          # Combine and deduplicate watchers
          all_watchers = Enum.uniq(db1_watchers ++ db2_watchers)

          Enum.each(all_watchers, fn {ref, pid} ->
            send(pid, {ref, %Vdr.WatchEvent.Update{command: command, db: db}})
          end)

        # Regular key-based commands
        _ ->
          Enum.each(affected_keys, fn key ->
            state.watch
            |> Vdr.TS.Watch.lookup(db, key)
            |> Enum.each(fn {ref, pid} ->
              send(pid, {ref, %Vdr.WatchEvent.Update{command: command, db: db}})
            end)
          end)
      end
    end

    :ok
  end
end
