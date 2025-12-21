defmodule Vdr.RedisStream.Replica do
  @moduledoc """
  Redis replication client that connects to a Redis master and receives
  replication stream via PSYNC.

  The replica manages a state machine for the replication protocol:
  1. Connect to Redis (TCP/SSL)
  2. Send PING
  3. Authenticate (if password provided)
  4. Negotiate PSYNC
  5. Receive and parse RDB snapshot
  6. Stream commands and invoke callbacks

  ## Example

      defmodule MyCallback do
        @behaviour Veidrodelis.RedisStream.Callback

        alias Vdr.Command

        @impl true
        def handle_command(state, db, %Command.Set{key: key, value: value}) do
          IO.puts("SET \#{key} = \#{value} in DB \#{db}")
          {:ok, Map.update(state, :count, 1, &(&1 + 1))}
        end

        def handle_command(state, _db, _command) do
          {:ok, Map.update(state, :count, 1, &(&1 + 1))}
        end
      end

      # Without authentication
      opts = [
        host: "localhost",
        port: 6379,
        callback_module: MyCallback,
        callback_state: %{count: 0}
      ]

      # With legacy password authentication (Redis < 6)
      opts = [
        host: "localhost",
        port: 6379,
        password: "mypassword",
        callback_module: MyCallback,
        callback_state: %{count: 0}
      ]

      # With ACL authentication (Redis 6+)
      opts = [
        host: "localhost",
        port: 6379,
        username: "myuser",
        password: "mypassword",
        callback_module: MyCallback,
        callback_state: %{count: 0}
      ]

      {:ok, replica} = Vdr.RedisStream.Replica.start_link(opts)

      # Get current replication offset
      offset = Vdr.RedisStream.Replica.get_offset(replica)

      # Get callback state
      state = Vdr.RedisStream.Replica.get_callback_state(replica)
  """

  use GenServer
  require Logger

  alias Vdr.ReplicaParser

  @default_port 6379
  @default_timeout 5000

  # Client API

  @doc """
  Creates a child specification for the replica.
  """
  @spec child_spec(keyword()) :: Supervisor.Spec.spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  @doc """
  Start a Redis replica client.

  ## Options

    * `:host` - Redis host (default: "localhost")
    * `:port` - Redis port (default: 6379)
    * `:username` - Redis username for ACL authentication (default: nil)
    * `:password` - Redis password (default: nil)
    * `:ssl` - Use SSL/TLS (default: false)
    * `:ssl_opts` - SSL options (default: [])
    * `:callback_module` - Module implementing `Vdr.RedisStream.Callback`
    * `:callback_state` - Initial state for callbacks
    * `:name` - GenServer name (optional)
    * `:reconnect` - Enable automatic reconnection (default: true)
    * `:reconnect_delay_ms` - Initial delay before reconnection in ms (default: 1000)
    * `:max_reconnect_delay_ms` - Maximum delay between reconnection attempts in ms (default: 30000)
    * `:ack_interval_ms` - Interval for sending periodic REPLCONF ACK to master in ms (default: 1000). Set to nil to disable periodic ACKs.

  ## Authentication

  For Redis 6+ ACL authentication, provide both `:username` and `:password`.
  For older Redis versions, provide only `:password`.

  ## Reconnection

  When enabled, the replica will automatically attempt to reconnect on connection failures
  or disconnects. It will use exponential backoff starting from `:reconnect_delay_ms` up to
  `:max_reconnect_delay_ms`. The replica will attempt partial resync (PSYNC) when possible
  to avoid full RDB transfer.

  ## Returns

    * `{:ok, pid}` - Successfully started
    * `{:error, reason}` - Failed to start
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Stop the replica client.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server)
  end

  @doc """
  Get the current replication offset.
  """
  @spec get_offset(GenServer.server()) :: integer()
  def get_offset(server) do
    GenServer.call(server, :get_offset)
  end

  @doc """
  Get the current replication ID.
  """
  @spec get_replication_id(GenServer.server()) :: binary() | nil
  def get_replication_id(server) do
    GenServer.call(server, :get_replication_id)
  end

  @doc """
  Get the current callback state.
  """
  @spec get_callback_state(GenServer.server()) :: term()
  def get_callback_state(server) do
    GenServer.call(server, :get_callback_state)
  end

  @doc """
  Get the current replication state.
  """
  @spec get_replication_state(GenServer.server()) :: term()
  def get_replication_state(server) do
    GenServer.call(server, :get_replication_state)
  end

  @doc """
  Make a synchronous call to the replica's callback module.

  This will invoke the callback module's `handle_call/2` function with the provided
  message, allowing you to query or interact with the callback state.

  The call will only succeed if the replica is in a valid state (after replication
  has started but before termination). If called during initialization or after
  disconnection, it will return `{:error, :not_connected}`.

  ## Parameters

    * `server` - The replica GenServer PID or name
    * `message` - The message to pass to the callback's `handle_call/2`

  ## Returns

    * `{:ok, reply}` - Success with reply from callback
    * `{:error, :not_implemented}` - Callback doesn't implement `handle_call/2`
    * `{:error, :not_connected}` - Replica not in valid state
    * `{:error, reason}` - Other error from callback
  """
  @spec call(GenServer.server(), term()) :: {:ok, term()} | {:error, term()}
  def call(server, message) do
    GenServer.call(server, {:callback_call, message})
  end

  # Server callbacks

  @impl true
  def init(opts) do
    Logger.debug("Initializing replica with opts: #{inspect(opts)}")
    Process.flag(:trap_exit, true)

    state = %{
      host: Keyword.get(opts, :host, "localhost"),
      port: Keyword.get(opts, :port, @default_port),
      username: Keyword.get(opts, :username),
      password: Keyword.get(opts, :password),
      ssl: Keyword.get(opts, :ssl, false),
      ssl_opts: Keyword.get(opts, :ssl_opts, []),
      callback_module: Keyword.fetch!(opts, :callback_module),
      callback_state: Keyword.fetch!(opts, :callback_state),
      # Reconnection options
      reconnect_enabled: Keyword.get(opts, :reconnect, true),
      reconnect_delay_ms: Keyword.get(opts, :reconnect_delay_ms, 1000),
      max_reconnect_delay_ms: Keyword.get(opts, :max_reconnect_delay_ms, 30_000),
      current_reconnect_delay_ms: Keyword.get(opts, :reconnect_delay_ms, 1000),
      # ACK options
      ack_interval_ms: Keyword.get(opts, :ack_interval_ms, 1000),
      ack_timer_ref: nil,
      # Connection state
      socket: nil,
      transport: nil,
      # Replication state (preserved across reconnections)
      saved_replication_id: nil,
      saved_replication_offset: 0,
      replication_id: nil,
      replication_offset: 0,
      # Rust replica parser handles all parsing (RDB + commands)
      replica_parser: nil,
      # Buffer for protocol messages before replication starts
      buffer: [],
      buffer_size: 0,
      state: :init
    }

    # Start connection process asynchronously
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect(state) do
      {:ok, new_state} ->
        # Reset reconnect delay on successful connection
        new_state = %{new_state | current_reconnect_delay_ms: state.reconnect_delay_ms}
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Failed to connect: #{inspect(reason)}")

        if state.reconnect_enabled do
          schedule_reconnect(state)
        else
          {:stop, {:connection_failed, reason}, state}
        end
    end
  end

  @impl true
  def handle_continue(:reconnect, state) do
    Logger.info("Attempting to reconnect...")
    handle_continue(:connect, state)
  end

  @impl true
  def handle_call(:get_offset, _from, state) do
    {:reply, state.replication_offset, state}
  end

  def handle_call(:get_replication_id, _from, state) do
    {:reply, state.replication_id, state}
  end

  def handle_call(:get_callback_state, _from, state) do
    {:reply, state.callback_state, state}
  end

  def handle_call(:get_replication_state, _from, state) do
    # If we're in :replication mode, check the parser state
    reply_state =
      if state.state == :replication && state.replica_parser do
        # Query the Rust parser's actual state
        case Vdr.RedisNif.replica_state(state.replica_parser) do
          :streaming -> :streaming
          :reading_rdb -> :rdb_transfer
          :waiting_rdb -> :rdb_transfer
          _ -> state.state
        end
      else
        state.state
      end

    {:reply, reply_state, state}
  end

  def handle_call({:callback_call, message}, _from, state) do
    # Only allow calls when replica is in a valid state (after replication start)
    # Valid state is :replication (which handles both RDB and streaming)
    if state.state == :replication do
      # Check if callback implements handle_call
      if function_exported?(state.callback_module, :handle_call, 2) do
        case state.callback_module.handle_call(state.callback_state, message) do
          {:reply, reply, new_callback_state} ->
            {:reply, {:ok, reply}, %{state | callback_state: new_callback_state}}

          {:noreply, new_callback_state} ->
            {:noreply, %{state | callback_state: new_callback_state}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
      else
        {:reply, {:error, :not_implemented}, state}
      end
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    handle_data(data, state)
  end

  def handle_info({:ssl, socket, data}, %{socket: socket} = state) do
    handle_data(data, state)
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    Logger.warning("Connection closed")
    handle_disconnect(state, :connection_closed)
  end

  def handle_info({:tcp_closed, _socket}, state) do
    Logger.warning("Connection closed (stale socket)")
    {:noreply, state}
  end

  def handle_info({:ssl_closed, socket}, %{socket: socket} = state) do
    Logger.warning("SSL connection closed")
    handle_disconnect(state, :ssl_connection_closed)
  end

  def handle_info({:ssl_closed, _socket}, state) do
    Logger.warning("SSL connection closed (stale socket)")
    {:noreply, state}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.error("TCP error: #{inspect(reason)}")
    handle_disconnect(state, {:tcp_error, reason})
  end

  def handle_info({:ssl_error, socket, reason}, %{socket: socket} = state) do
    Logger.error("SSL error: #{inspect(reason)}")
    handle_disconnect(state, {:ssl_error, reason})
  end

  def handle_info(:reconnect_timeout, state) do
    {:noreply, state, {:continue, :reconnect}}
  end

  def handle_info(:send_periodic_ack, state) do
    # Send REPLCONF ACK with current offset
    send_replconf_ack(state)

    # Schedule next ACK if still in streaming mode
    new_state = schedule_periodic_ack(state)
    {:noreply, new_state}
  end

  def handle_info(message, state) do
    Logger.warning("Unhandled message: #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Cancel ACK timer
    cancel_ack_timer(state)

    # Call handle_destroy callback if implemented
    if function_exported?(state.callback_module, :handle_destroy, 1) do
      case state.callback_module.handle_destroy(state.callback_state) do
        :ok ->
          Logger.debug("handle_destroy callback succeeded")

        {:error, reason} ->
          Logger.error("handle_destroy callback failed: #{inspect(reason)}")
      end
    end

    if state.socket do
      transport_close(state.transport, state.socket)
    end

    :ok
  end

  # Private functions

  defp handle_disconnect(state, reason) do
    # Close existing socket if any
    if state.socket do
      transport_close(state.transport, state.socket)
    end

    # Cancel ACK timer
    state = cancel_ack_timer(state)

    # Save replication state for potential partial resync
    new_state = %{
      state
      | socket: nil,
        transport: nil,
        saved_replication_id: state.replication_id || state.saved_replication_id,
        saved_replication_offset: state.replication_offset,
        # Clear current replication state but keep saved values
        replica_parser: nil,
        buffer: [],
        buffer_size: 0,
        state: :init
    }

    if new_state.reconnect_enabled do
      Logger.info("Will attempt to reconnect after #{new_state.current_reconnect_delay_ms}ms")
      schedule_reconnect(new_state)
    else
      {:stop, reason, new_state}
    end
  end

  defp schedule_reconnect(state) do
    # Schedule reconnection with current delay
    Process.send_after(self(), :reconnect_timeout, state.current_reconnect_delay_ms)

    # Calculate next delay with exponential backoff (capped at max)
    next_delay = min(state.current_reconnect_delay_ms * 2, state.max_reconnect_delay_ms)
    new_state = %{state | current_reconnect_delay_ms: next_delay}

    {:noreply, new_state}
  end

  defp connect(state) do
    transport = if state.ssl, do: :ssl, else: :tcp

    Logger.info("Connecting to #{state.host}:#{state.port} via #{transport}")

    case transport_connect(transport, state.host, state.port, state.ssl_opts) do
      {:ok, socket} ->
        Logger.info("Connected successfully")

        # Set socket to active: once for backpressure
        :ok = transport_setopts(transport, socket, active: :once)

        # If password is provided, send AUTH first, then PING
        # Otherwise send PING directly
        if state.password do
          new_state = %{state | socket: socket, transport: transport, state: :auth}
          send_auth(new_state)
        else
          new_state = %{state | socket: socket, transport: transport, state: :ping}
          send_ping(new_state)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_ping(state) do
    Logger.debug("Sending PING")

    case transport_send(state.transport, state.socket, "*1\r\n$4\r\nPING\r\n") do
      :ok ->
        {:ok, %{state | state: :ping}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_auth(state) do
    Logger.debug("Sending AUTH")

    # Support both ACL (username + password) and legacy (password only) authentication
    cmd =
      if state.username do
        # Redis 6+ ACL authentication: AUTH <username> <password>
        username_len = byte_size(state.username)
        password_len = byte_size(state.password)

        "*3\r\n$4\r\nAUTH\r\n$#{username_len}\r\n#{state.username}\r\n$#{password_len}\r\n#{state.password}\r\n"
      else
        # Legacy authentication: AUTH <password>
        password_len = byte_size(state.password)
        "*2\r\n$4\r\nAUTH\r\n$#{password_len}\r\n#{state.password}\r\n"
      end

    case transport_send(state.transport, state.socket, cmd) do
      :ok ->
        {:ok, %{state | state: :auth}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_replconf_listening_port(state) do
    Logger.debug("Sending REPLCONF listening-port")

    # Send a fake listening port (we're not actually listening)
    cmd = "*3\r\n$8\r\nREPLCONF\r\n$14\r\nlistening-port\r\n$4\r\n6380\r\n"

    case transport_send(state.transport, state.socket, cmd) do
      :ok ->
        {:ok, %{state | state: :replconf_listening_port}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_replconf_capa(state) do
    Logger.debug("Sending REPLCONF capa")

    # Announce capabilities: psync2
    cmd = "*3\r\n$8\r\nREPLCONF\r\n$4\r\ncapa\r\n$6\r\npsync2\r\n"

    case transport_send(state.transport, state.socket, cmd) do
      :ok ->
        {:ok, %{state | state: :replconf_capa}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_psync(state) do
    # Try partial resync if we have saved replication state
    {repl_id, repl_offset} =
      if state.saved_replication_id do
        {state.saved_replication_id, state.saved_replication_offset}
      else
        {"?", -1}
      end

    if repl_id == "?" do
      Logger.debug("Sending PSYNC for full sync")
    else
      Logger.debug("Sending PSYNC for partial resync (#{repl_id} #{repl_offset})")
    end

    # Build PSYNC command
    repl_id_len = byte_size(repl_id)
    offset_str = Integer.to_string(repl_offset)
    offset_len = byte_size(offset_str)

    cmd =
      "*3\r\n$5\r\nPSYNC\r\n$#{repl_id_len}\r\n#{repl_id}\r\n$#{offset_len}\r\n#{offset_str}\r\n"

    case transport_send(state.transport, state.socket, cmd) do
      :ok ->
        {:ok, %{state | state: :psync}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_replconf_ack(state) do
    if state.socket && state.transport do
      offset = state.replication_offset
      offset_str = Integer.to_string(offset)
      offset_len = byte_size(offset_str)

      cmd = "*3\r\n$8\r\nREPLCONF\r\n$3\r\nACK\r\n$#{offset_len}\r\n#{offset_str}\r\n"

      case transport_send(state.transport, state.socket, cmd) do
        :ok ->
          Logger.debug("Sent periodic REPLCONF ACK #{offset}")
          :ok

        {:error, reason} ->
          Logger.warning("Failed to send REPLCONF ACK: #{inspect(reason)}")
          :error
      end
    else
      :ok
    end
  end

  defp schedule_periodic_ack(state) do
    # Cancel existing timer if any
    state = cancel_ack_timer(state)

    # Schedule next ACK if interval is configured and we're in streaming mode
    if state.ack_interval_ms && state.state == :streaming do
      timer_ref = Process.send_after(self(), :send_periodic_ack, state.ack_interval_ms)
      %{state | ack_timer_ref: timer_ref}
    else
      state
    end
  end

  defp cancel_ack_timer(state) do
    if state.ack_timer_ref do
      Process.cancel_timer(state.ack_timer_ref)
      %{state | ack_timer_ref: nil}
    else
      state
    end
  end

  defp handle_data(data, state) do
    # Before replication starts, accumulate in buffer for protocol parsing
    # After replication starts, feed directly to replica parser
    result =
      case state.state do
        :ping ->
          new_buffer = [data | state.buffer]
          new_buffer_size = state.buffer_size + byte_size(data)
          new_state = %{state | buffer: new_buffer, buffer_size: new_buffer_size}
          handle_ping_response(new_state)

        :auth ->
          new_buffer = [data | state.buffer]
          new_buffer_size = state.buffer_size + byte_size(data)
          new_state = %{state | buffer: new_buffer, buffer_size: new_buffer_size}
          handle_auth_response(new_state)

        :replconf_listening_port ->
          new_buffer = [data | state.buffer]
          new_buffer_size = state.buffer_size + byte_size(data)
          new_state = %{state | buffer: new_buffer, buffer_size: new_buffer_size}
          handle_replconf_response(new_state, :replconf_capa)

        :replconf_capa ->
          new_buffer = [data | state.buffer]
          new_buffer_size = state.buffer_size + byte_size(data)
          new_state = %{state | buffer: new_buffer, buffer_size: new_buffer_size}
          handle_replconf_response(new_state, :send_psync)

        :psync ->
          new_buffer = [data | state.buffer]
          new_buffer_size = state.buffer_size + byte_size(data)
          new_state = %{state | buffer: new_buffer, buffer_size: new_buffer_size}
          handle_psync_response(new_state)

        :replication ->
          # After PSYNC, all data goes to the replica parser (no buffering)
          handle_replication_data(data, state)
      end

    # Re-enable socket for next packet (backpressure)
    case result do
      {:noreply, state} ->
        :ok = transport_setopts(state.transport, state.socket, active: :once)
        {:noreply, state}

      other ->
        other
    end
  end

  defp handle_ping_response(state) do
    case parse_simple_response(state) do
      {:ok, _response, new_state} ->
        Logger.debug("PING successful")

        # After PING, send REPLCONF
        case send_replconf_listening_port(new_state) do
          {:ok, new_state} -> {:noreply, new_state}
          {:error, reason} -> {:stop, {:replconf_failed, reason}, new_state}
        end

      :incomplete ->
        {:noreply, state}

      {:error, reason} ->
        {:stop, {:ping_failed, reason}, state}
    end
  end

  defp handle_auth_response(state) do
    case parse_simple_response(state) do
      {:ok, _response, new_state} ->
        Logger.debug("AUTH successful")

        # After AUTH, send PING
        case send_ping(new_state) do
          {:ok, new_state} -> {:noreply, new_state}
          {:error, reason} -> {:stop, {:ping_failed, reason}, new_state}
        end

      :incomplete ->
        {:noreply, state}

      {:error, reason} ->
        {:stop, {:auth_failed, reason}, state}
    end
  end

  defp handle_replconf_response(state, next_action) do
    case parse_simple_response(state) do
      {:ok, _response, new_state} ->
        Logger.debug("REPLCONF successful")

        case next_action do
          :replconf_capa ->
            case send_replconf_capa(new_state) do
              {:ok, new_state} -> {:noreply, new_state}
              {:error, reason} -> {:stop, {:replconf_failed, reason}, new_state}
            end

          :send_psync ->
            case send_psync(new_state) do
              {:ok, new_state} -> {:noreply, new_state}
              {:error, reason} -> {:stop, {:psync_failed, reason}, new_state}
            end
        end

      :incomplete ->
        {:noreply, state}

      {:error, reason} ->
        {:stop, {:replconf_failed, reason}, state}
    end
  end

  defp handle_psync_response(state) do
    # PSYNC response can be:
    # - +FULLRESYNC <replication_id> <offset>\r\n (full sync)
    # - +CONTINUE\r\n (partial resync accepted)
    case parse_psync_response(state) do
      {:ok, :fullresync, replication_id, offset, new_state} ->
        Logger.info("PSYNC: FULLRESYNC #{replication_id} #{offset}")

        # Call handle_replication_start callback if implemented
        callback_state_update_result =
          if function_exported?(state.callback_module, :handle_replication_start, 1) do
            case state.callback_module.handle_replication_start(state.callback_state) do
              {:ok, new_callback_state} ->
                Logger.debug("handle_replication_start callback succeeded")
                {:ok, new_callback_state}

              {:error, reason} ->
                Logger.error("handle_replication_start callback failed: #{inspect(reason)}")
                {:error, reason}
            end
          else
            {:ok, state.callback_state}
          end

        case callback_state_update_result do
          {:ok, updated_callback_state} ->
            # Create replica parser (handles both RDB and command streaming)
            replica_parser = ReplicaParser.create()

            new_state = %{
              new_state
              | callback_state: updated_callback_state,
                replication_id: replication_id,
                replication_offset: offset,
                replica_parser: replica_parser,
                state: :replication
            }

            # Start periodic ACK timer
            new_state = schedule_periodic_ack(new_state)

            # Feed any buffered data to replica parser
            if new_state.buffer_size > 0 do
              buffered_data = buffer_to_binary(new_state)
              new_state = %{new_state | buffer: [], buffer_size: 0}
              handle_replication_data(buffered_data, new_state)
            else
              {:noreply, new_state}
            end

          {:error, reason} ->
            {:stop, {:handle_replication_start_failed, reason}, new_state}
        end

      {:ok, :continue, new_state} ->
        Logger.info("PSYNC: CONTINUE - partial resync accepted")

        # For partial resync, feed a fake empty RDB to trigger streaming mode
        # The replica parser starts in WaitingRdb state, so we need to transition it
        replica_parser = ReplicaParser.create()

        # Feed minimal RDB header to transition parser to streaming mode
        # $0\r\n means zero-length RDB (no data)
        case ReplicaParser.data(replica_parser, "$0\r\n") do
          {:ok, [], replica_parser} ->
            # Parser now in streaming mode
            new_state = %{
              new_state
              | replication_id: state.saved_replication_id,
                replication_offset: state.saved_replication_offset,
                replica_parser: replica_parser,
                state: :replication
            }

            # Start periodic ACK timer
            new_state = schedule_periodic_ack(new_state)

            # Feed any buffered data
            if new_state.buffer_size > 0 do
              buffered_data = buffer_to_binary(new_state)
              new_state = %{new_state | buffer: [], buffer_size: 0}
              handle_replication_data(buffered_data, new_state)
            else
              {:noreply, new_state}
            end

          {:error, reason} ->
            {:stop, {:partial_resync_init_failed, reason}, new_state}
        end

      :incomplete ->
        {:noreply, state}

      {:error, reason} ->
        {:stop, {:psync_failed, reason}, state}
    end
  end

  # Handle replication data using Rust replica parser
  defp handle_replication_data(data, state) do
    # Feed data to replica parser (handles RDB and command stream automatically)
    case ReplicaParser.data(state.replica_parser, data) do
      {:ok, commands, new_replica_parser} ->
        # Parser returned commands and wants more data
        # Update replication offset by data size
        new_offset = state.replication_offset + byte_size(data)

        # Process commands through callback
        case process_commands(commands, state) do
          {:ok, new_state_with_commands} ->
            new_state = %{
              new_state_with_commands
              | replica_parser: new_replica_parser,
                replication_offset: new_offset
            }

            {:noreply, new_state}

          {:error, reason} ->
            {:stop, {:callback_failed, reason}, state}
        end

      {:ok, commands} ->
        # Parser finished (should not happen in normal replication)
        # Update replication offset by data size
        new_offset = state.replication_offset + byte_size(data)

        # Process final commands
        case process_commands(commands, state) do
          {:ok, new_state_with_commands} ->
            new_state = %{new_state_with_commands | replication_offset: new_offset}
            Logger.warning("Replica parser finished unexpectedly")
            {:noreply, new_state}

          {:error, reason} ->
            {:stop, {:callback_failed, reason}, state}
        end

      {:error, reason} ->
        Logger.error("Replica parser error: #{inspect(reason)}")
        {:stop, {:parse_failed, reason}, state}
    end
  end

  # Process commands from replica parser through callback
  defp process_commands([], state) do
    {:ok, state}
  end

  defp process_commands([{db, command} | rest], state) do
    # Handle special commands
    result =
      case command do
        # PING - send ACK
        %Vdr.Command.Set{key: "PING", value: ""} when db == 0 ->
          Logger.debug("Received PING, sending REPLCONF ACK #{state.replication_offset}")
          send_replconf_ack(state)
          {:ok, state}

        # Regular commands - invoke callback
        _ ->
          result = state.callback_module.handle_command(state.callback_state, db, command)

          case result do
            {:ok, new_callback_state} ->
              {:ok, %{state | callback_state: new_callback_state}}

            {:error, reason} ->
              Logger.error("Callback error: #{inspect(reason)}")
              {:error, reason}
          end
      end

    case result do
      {:ok, new_state} ->
        process_commands(rest, new_state)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Buffer management helpers

  defp buffer_to_binary(state) do
    state.buffer |> Enum.reverse() |> :erlang.iolist_to_binary()
  end

  defp peek_bytes(state, n) when state.buffer_size >= n do
    binary = buffer_to_binary(state)
    {:ok, :binary.part(binary, 0, n)}
  end

  defp peek_bytes(_state, _n), do: :incomplete

  # RESP protocol parsers (work with state containing iolist buffer)

  defp parse_simple_response(state) do
    case peek_bytes(state, min(state.buffer_size, 1024)) do
      {:ok, peek} ->
        case peek do
          <<"+"::binary, _::binary>> ->
            binary = buffer_to_binary(state)

            case :binary.split(binary, "\r\n") do
              [<<"+"::binary, response::binary>>, rest] ->
                new_state = %{
                  state
                  | buffer: if(byte_size(rest) > 0, do: [rest], else: []),
                    buffer_size: byte_size(rest)
                }

                {:ok, response, new_state}

              _ ->
                :incomplete
            end

          <<"-"::binary, _::binary>> ->
            binary = buffer_to_binary(state)

            case :binary.split(binary, "\r\n") do
              [<<"-"::binary, error::binary>>, _rest] ->
                {:error, {:redis_error, error}}

              _ ->
                :incomplete
            end

          _ ->
            :incomplete
        end

      :incomplete ->
        :incomplete
    end
  end

  defp parse_psync_response(state) do
    case peek_bytes(state, min(state.buffer_size, 1024)) do
      {:ok, peek} ->
        case peek do
          <<"+FULLRESYNC "::binary, _::binary>> ->
            binary = buffer_to_binary(state)

            case :binary.split(binary, "\r\n") do
              [<<"+FULLRESYNC "::binary, params::binary>>, rest] ->
                [replication_id, offset_str] = String.split(params, " ", parts: 2)
                offset = String.to_integer(offset_str)

                new_state = %{
                  state
                  | buffer: if(byte_size(rest) > 0, do: [rest], else: []),
                    buffer_size: byte_size(rest)
                }

                {:ok, :fullresync, replication_id, offset, new_state}

              _ ->
                :incomplete
            end

          <<"+CONTINUE"::binary, _::binary>> ->
            binary = buffer_to_binary(state)

            case :binary.split(binary, "\r\n") do
              [<<"+CONTINUE"::binary, _::binary>>, rest] ->
                new_state = %{
                  state
                  | buffer: if(byte_size(rest) > 0, do: [rest], else: []),
                    buffer_size: byte_size(rest)
                }

                {:ok, :continue, new_state}

              _ ->
                :incomplete
            end

          <<"-"::binary, _::binary>> ->
            binary = buffer_to_binary(state)

            case :binary.split(binary, "\r\n") do
              [<<"-"::binary, error::binary>>, _rest] ->
                {:error, {:redis_error, error}}

              _ ->
                :incomplete
            end

          _ ->
            :incomplete
        end

      :incomplete ->
        :incomplete
    end
  end

  # Transport abstraction

  defp transport_connect(:tcp, host, port, _opts) do
    host_charlist = String.to_charlist(host)
    :gen_tcp.connect(host_charlist, port, [:binary, active: false], @default_timeout)
  end

  defp transport_connect(:ssl, host, port, ssl_opts) do
    host_charlist = String.to_charlist(host)

    default_opts = [
      :binary,
      active: false,
      verify: :verify_none
    ]

    opts = Keyword.merge(default_opts, ssl_opts)
    :ssl.connect(host_charlist, port, opts, @default_timeout)
  end

  defp transport_send(:tcp, socket, data), do: :gen_tcp.send(socket, data)
  defp transport_send(:ssl, socket, data), do: :ssl.send(socket, data)

  defp transport_close(:tcp, socket), do: :gen_tcp.close(socket)
  defp transport_close(:ssl, socket), do: :ssl.close(socket)

  defp transport_setopts(:tcp, socket, opts), do: :inet.setopts(socket, opts)
  defp transport_setopts(:ssl, socket, opts), do: :ssl.setopts(socket, opts)
end
