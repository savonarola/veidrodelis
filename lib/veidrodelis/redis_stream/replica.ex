defmodule Vdr.RedisStream.Replica do
  @moduledoc """
  Redis replication client that connects to a Redis and receives
  replication stream via PSYNC.

  The replica manages a state machine for the replication protocol:
  1. Connect to Redis (TCP/SSL) or discover via Sentinel
  2. Send PING
  3. Authenticate (if password provided)
  4. Negotiate PSYNC
  5. Receive and parse RDB snapshot
  6. Receive stream of commands

  Replica is parametrized by a callback module that implements the `Vdr.RedisStream.Callback` behaviour.

  This module is a part of public API to allow users to implement their own replication handlers.
  However, be aware that the RDB snapshot parser currently skips data entries that are not
  related to string, list, set, sorted set or hash data types.

  In this project, this module is used with `Vdr.TSProj` callback module that builds an in-memory
  projection of the Redis data related to the string, list, set, sorted set or hash data types.

  ### Simple Logging Replica

  Example callback module that logs all replicated commands

  ```elixir
  defmodule LoggingCallback do
    @behaviour Vdr.RedisStream.Callback
    require Logger

    @impl Vdr.RedisStream.Callback
    def init(_opts) do
      {:ok, %{}}
    end

    @impl Vdr.RedisStream.Callback
    def handle_replication_start(state) do
      Logger.info("Replication started")
      {:ok, state}
    end

    @impl Vdr.RedisStream.Callback
    def handle_streaming_start(state) do
      Logger.info("Command streaming started")
      {:ok, state}
    end

    @impl Vdr.RedisStream.Callback
    def handle_commands(state, replica_commands) do
      # Log each command as it arrives
      Enum.each(replica_commands, fn cmd ->
        Logger.debug("Received command: db=\#{cmd.db} cmd=\#{inspect(cmd.command)}")
      end)

      {:ok, state}
    end

    @impl Vdr.RedisStream.Callback
    def handle_call(state, _message) do
      {:reply, :ok, state}
    end

    @impl Vdr.RedisStream.Callback
    def handle_info(state, _message) do
      {:noreply, state}
    end

    @impl Vdr.RedisStream.Callback
    def handle_destroy(_state) do
      Logger.info("Replica shutting down")
      :ok
    end
  end

  # Start the logging replica
  {:ok, replica} = Vdr.RedisStream.Replica.start_link(
    host: "localhost",
    port: 6379,
    callback_module: LoggingCallback,
    callback_opts: %{}
  )
  ```

  """

  use GenServer
  require Logger

  alias Vdr.RedisStream.Parser
  alias Vdr.RedisStream.CommandFilter

  @default_port 6379
  @default_timeout 5000

  @type replica_state ::
          :init
          | :ping
          | :auth
          | :replconf_listening_port
          | :replconf_capa
          | :psync
          | :rdb_transfer
          | :streaming

  # Client API

  @doc """
  Creates a child specification for the replica for running it under a supervisor.
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

  ### Connection Options (mutually exclusive)

    * `:host` - Redis host (default: "localhost"). Cannot be used with `:sentinel`.
    * `:port` - Redis port (default: 6379). Cannot be used with `:sentinel`.
    * `:sentinel` - Sentinel configuration (keyword list). Cannot be used with `:host`/`:port`.
      Requires `:redix` dependency at runtime.
      * `:sentinels` - List of sentinel nodes (required), each with `:host` and `:port`
      * `:group` - Name of the primary group in sentinel (required)
      * `:role` - Server role to discover: `:primary` or `:replica` (default: `:primary`)
      * `:connect_opts` - Redix connection options for sentinel connections (optional).
        Supports all Redix options like `:timeout`, `:ssl`, `:password`, etc.
      * `:replica_connect_opts` - Redix connection options for discovered Redis server (optional).
        Supports all Redix options like `:username`, `:password`, `:ssl`, `:socket_opts`, etc.
      * `:host_map` - Mapping for translating sentinel-returned hostnames (helpful for testing).
        Can be a map or a function that takes a hostname and returns a new hostname.

  ### Redis Server Options (apply to direct connections only)

    * `:username` - Redis username for ACL authentication (default: nil). Not used with sentinel.
    * `:password` - Redis password (default: nil). Not used with sentinel.
    * `:ssl` - Use SSL/TLS for Redis connection (default: false). Not used with sentinel.
    * `:ssl_opts` - SSL options (default: []). Not used with sentinel.

  ### Callback Options

    * `:callback_module` - Module implementing `Vdr.RedisStream.Callback` (required)
    * `:callback_opts` - Options for the callback module (required)

  ### Other Options

    * `:name` - GenServer name (optional)
    * `:reconnect` - Enable automatic reconnection (default: true)
    * `:reconnect_delay_ms` - Initial delay before reconnection in ms (default: 1000)
    * `:max_reconnect_delay_ms` - Maximum delay between reconnection attempts in ms (default: 30000)
    * `:ack_interval_ms` - Interval for sending periodic REPLCONF ACK to the primary in ms (default: 1000).
    * `:command_filter` - Command filter to apply to commands (default: none)

  ## Authentication

  For Redis 6+ ACL authentication, provide both `:username` and `:password`.
  For older Redis versions, provide only `:password`.

  ## Sentinel Support

  When using Redis Sentinel for high availability, provide the `:sentinel` option instead of
  `:host` and `:port`. The replica will:

  1. Query sentinels sequentially to discover the primary (or replica) address
  2. Connect to the discovered Redis server
  3. Verify the server role matches the expected role
  4. On reconnection, repeat the discovery process (automatically handling failovers)

  The `:role` option determines which type of server to discover:
  - `:primary` - Connect to the primary server (typical for replication)
  - `:replica` - Connect to a replica server (for read-only replication)

  ## Reconnection

  When enabled, the replica will automatically attempt to reconnect on connection failures
  or disconnects. It will use exponential backoff starting from `:reconnect_delay_ms` up to
  `:max_reconnect_delay_ms`. The replica will attempt partial resync (PSYNC) when possible
  to avoid full RDB transfer.

  When using Sentinel, the reconnection process includes rediscovery, allowing the replica
  to automatically adapt to failovers and topology changes.

  ## Examples

  ### Direct Connection

  Basic connection
  ```elixir
  opts = [
    host: "localhost",
    port: 6379,
    callback_module: MyCallback,
    callback_opts: %{}
  ]
  {:ok, replica} = Vdr.RedisStream.Replica.start_link(opts)
  ```

  With ACL authentication
  ```elixir
  opts = [
    host: "localhost",
    port: 6379,
    username: "myuser",
    password: "mypassword",
    callback_module: MyCallback,
    callback_opts: %{}
  ]
  {:ok, replica} = Vdr.RedisStream.Replica.start_link(opts)
  ```

  ### Sentinel Connection

  Connect to primary via sentinel
  ```elixir
  opts = [
    sentinel: [
      sentinels: [
        [host: "sentinel1", port: 26379],
        [host: "sentinel2", port: 26379],
        [host: "sentinel3", port: 26379]
      ],
      group: "myprimary",
      role: :primary,
      # Optional: Connection options for sentinel connections
      connect_opts: [timeout: 1000, ssl: true],
      # Optional: Connection options for replica connections
      replica_connect_opts: [password: "redis_password", ssl: true]
    ],
    callback_module: MyCallback,
    callback_opts: %{}
  ]
  {:ok, replica} = Vdr.RedisStream.Replica.start_link(opts)
  ```

  Connect to replica via sentinel
  ```elixir
  opts = [
    sentinel: [
      sentinels: [
        [host: "sentinel1", port: 26379],
        [host: "sentinel2", port: 26379],
        [host: "sentinel3", port: 26379]
      ],
      group: "myprimary",
      role: :replica,
      replica_connect_opts: [password: "redis_password"]
    ],
    callback_module: MyCallback,
    callback_opts: %{}
  ]
  {:ok, replica} = Vdr.RedisStream.Replica.start_link(opts)
  ```

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
  @spec get_replication_state(GenServer.server()) :: replica_state()
  def get_replication_state(server) do
    GenServer.call(server, :get_replication_state)
  end

  @doc """
  Get the host and port of the currently connected Redis server.

  Returns the actual host and port that the replica is connected to. For sentinel-based
  connections, this returns the discovered server address. For direct connections, this
  returns the configured host and port.

  ## Returns

    * `{:ok, {host, port}}` - The connected host (string) and port (integer)
    * `{:error, :not_connected}` - Replica is not currently connected
  """
  @spec connected_to(GenServer.server()) ::
          {:ok, {String.t(), non_neg_integer()}} | {:error, :not_connected}
  def connected_to(server) do
    GenServer.call(server, :connected_to)
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
    * `timeout` - The timeout for the call (default: 5000ms)

  ## Returns

    * `{:ok, reply}` - Success with reply from callback
    * `{:error, :not_implemented}` - Callback doesn't implement `handle_call/2`
    * `{:error, :not_connected}` - Replica not in valid state
    * `{:error, reason}` - Other error from callback
  """
  @spec call(GenServer.server(), term(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  def call(server, message, timeout \\ @default_timeout) do
    GenServer.call(server, {:callback_call, message}, timeout)
  end

  # Server callbacks

  @impl GenServer
  def init(opts) do
    Logger.debug("Initializing replica with opts: #{inspect(opts)}")
    Process.flag(:trap_exit, true)

    sentinel_opts = Keyword.get(opts, :sentinel)

    if sentinel_opts do
      unless Code.ensure_loaded?(Redix) do
        raise RuntimeError, """
        Sentinel support requires :redix dependency.
        Add to mix.exs: {:redix, "~> 1.5"}
        """
      end

      validate_sentinel_opts!(sentinel_opts)

      if Keyword.has_key?(opts, :host) or Keyword.has_key?(opts, :port) do
        raise ArgumentError, ":host or :port cannot be specified with :sentinel"
      end
    end

    callback_module = Keyword.get(opts, :callback_module)
    callback_opts = Keyword.get(opts, :callback_opts)

    case callback_module.init(callback_opts) do
      {:ok, callback_state} ->
        state = %{
          # Callback state
          callback_module: callback_module,
          callback_state: callback_state,
          # Connection mode
          sentinel: sentinel_opts,
          connection_mode: if(sentinel_opts, do: :sentinel, else: :direct),
          # For direct connections
          host: Keyword.get(opts, :host, "localhost"),
          port: Keyword.get(opts, :port, @default_port),
          # For discovered connections (filled by sentinel)
          discovered_host: nil,
          discovered_port: nil,
          # Auth and SSL
          username: Keyword.get(opts, :username),
          password: Keyword.get(opts, :password),
          ssl: Keyword.get(opts, :ssl, false),
          ssl_opts: Keyword.get(opts, :ssl_opts, []),
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
          buffer: <<>>,
          state: :init,
          command_filter: Keyword.get(opts, :command_filter, %CommandFilter{})
        }

        # Start connection process asynchronously
        {:ok, state, {:continue, :connect}}

      {:error, reason} ->
        {:stop, {:init_failed, reason}}
    end
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    case connect(state) do
      {:ok, new_state} ->
        # Reset reconnect delay on successful connection
        new_state = %{new_state | current_reconnect_delay_ms: state.reconnect_delay_ms}
        {:noreply, new_state}

      {:error, reason} ->
        schedule_reconnect({:connection_failed, reason}, state)
    end
  end

  @impl GenServer
  def handle_continue(:reconnect, state) do
    Logger.info("Attempting to reconnect...")
    handle_continue(:connect, state)
  end

  @impl GenServer
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
    {:reply, replication_state(state), state}
  end

  def handle_call(:connected_to, _from, state) do
    # Return discovered host/port if available (sentinel mode), otherwise configured host/port
    host = state.discovered_host || state.host
    port = state.discovered_port || state.port

    # Check if we have an active socket connection
    if state.socket != nil do
      {:reply, {:ok, {host, port}}, state}
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call({:callback_call, message}, _from, state) do
    # Only allow calls when replica is in a valid state (after replication start)
    # Valid state is :replication (which handles both RDB and streaming)
    if state.state == :replication do
      case state.callback_module.handle_call(state.callback_state, message) do
        {:reply, reply, new_callback_state} ->
          {:reply, reply, %{state | callback_state: new_callback_state}}

        {:noreply, new_callback_state} ->
          {:noreply, %{state | callback_state: new_callback_state}}

        {:error, _} = error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  @impl GenServer
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
    case state.callback_module.handle_info(state.callback_state, message) do
      {:noreply, new_callback_state} ->
        {:noreply, %{state | callback_state: new_callback_state}}

      {:error, _reason} ->
        Logger.warning("Callback handle_info returned error for message: #{inspect(message)}")
        {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    cancel_ack_timer(state)

    case state.callback_module.handle_destroy(state.callback_state) do
      :ok ->
        Logger.debug("handle_destroy callback succeeded")

      {:error, reason} ->
        Logger.error("handle_destroy callback failed: #{inspect(reason)}")
    end

    if state.socket do
      transport_close(state.transport, state.socket)
    end

    :ok
  end

  defp replication_state(state) do
    if state.state == :replication && state.replica_parser do
      # Query the actual replication parser's state
      case Vdr.RedisStream.Nif.replica_state(state.replica_parser) do
        :streaming -> :streaming
        :reading_rdb -> :rdb_transfer
        :waiting_rdb -> :rdb_transfer
        _ -> state.state
      end
    else
      state.state
    end
  end

  defp handle_disconnect(state, reason) do
    if state.socket do
      transport_close(state.transport, state.socket)
    end

    state = cancel_ack_timer(state)

    new_state = %{
      state
      | socket: nil,
        transport: nil,
        # Save replication state for potential partial resync
        saved_replication_id: state.replication_id || state.saved_replication_id,
        saved_replication_offset: state.replication_offset,
        # Clear current replication state
        replica_parser: nil,
        buffer: <<>>,
        state: :init
    }

    schedule_reconnect(reason, new_state)
  end

  defp schedule_reconnect(reason, state) do
    if state.socket do
      transport_close(state.transport, state.socket)
    end

    if state.reconnect_enabled do
      Logger.info(
        "Will attempt to reconnect after #{state.current_reconnect_delay_ms}ms, reason: #{inspect(reason)}"
      )

      Process.send_after(self(), :reconnect_timeout, state.current_reconnect_delay_ms)

      # Calculate next delay with exponential backoff (capped at max)
      next_delay = min(state.current_reconnect_delay_ms * 2, state.max_reconnect_delay_ms)

      new_state = %{
        state
        | current_reconnect_delay_ms: next_delay,
          buffer: <<>>,
          state: :init
      }

      {:noreply, new_state}
    else
      Logger.info("Reconnection disabled, stopping: #{inspect(reason)}")
      {:stop, reason, state}
    end
  end

  defp connect(%{connection_mode: :direct} = state) do
    connect_directly(state.host, state.port, state)
  end

  defp connect(%{connection_mode: :sentinel} = state) do
    discover_and_connect_via_sentinel(state)
  end

  defp discover_and_connect_via_sentinel(state) do
    group = state.sentinel[:group]
    Logger.info("Starting sentinel discovery for group: #{group}")

    case Vdr.RedisStream.SentinelConnector.discover_server(state.sentinel) do
      {:ok, {host, port}} ->
        Logger.info("Sentinel discovered server at #{host}:#{port}")
        state = %{state | discovered_host: host, discovered_port: port}
        connect_directly(host, port, state)

      {:error, reason} ->
        Logger.error("Sentinel discovery failed: #{inspect(reason)}")
        {:error, {:sentinel_discovery_failed, reason}}
    end
  end

  defp connect_directly(host, port, state) do
    transport = if state.ssl, do: :ssl, else: :tcp

    Logger.info("Connecting to #{host}:#{port} via #{transport}")

    case transport_connect(transport, host, port, state.ssl_opts) do
      {:ok, socket} ->
        Logger.info("Connected successfully")
        :ok = transport_setopts(transport, socket, active: :once)
        new_state = %{state | socket: socket, transport: transport}
        proceed_after_connect(new_state)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp proceed_after_connect(state) do
    # If password is provided, send AUTH first, then PING
    # Otherwise send PING directly
    if state.password do
      new_state = %{state | state: :auth}
      send_auth(new_state)
    else
      new_state = %{state | state: :ping}
      send_ping(new_state)
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
        username_len = byte_size(state.username)
        password_len = byte_size(state.password)

        "*3\r\n$4\r\nAUTH\r\n$#{username_len}\r\n#{state.username}\r\n$#{password_len}\r\n#{state.password}\r\n"
      else
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

    # Send a fake and invalid listening port
    cmd = "*3\r\n$8\r\nREPLCONF\r\n$14\r\nlistening-port\r\n$4\r\n99999\r\n"

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
        Logger.debug(
          "Sending PSYNC for partial resync (#{state.saved_replication_id} #{state.saved_replication_offset})"
        )

        {state.saved_replication_id, state.saved_replication_offset}
      else
        Logger.debug("Sending PSYNC for full sync")
        {"?", -1}
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
    if state.socket && state.transport && replication_state(state) == :streaming do
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
      Logger.debug("Skipped REPLCONF ACK - not in streaming mode")
      :ok
    end
  end

  defp schedule_periodic_ack(state) do
    state = cancel_ack_timer(state)

    # Schedule next ACK if interval is configured
    timer_ref = Process.send_after(self(), :send_periodic_ack, state.ack_interval_ms)
    %{state | ack_timer_ref: timer_ref}
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
    # Before replication starts, accumulate metadata messages in buffer for protocol parsing
    # After replication starts, feed directly to the actual replication parser
    result =
      case state.state do
        :replication ->
          # After PSYNC, all data goes to the actual replication parser
          handle_replication_data(data, state)

        other ->
          ## Connection initialization state machine
          new_state = append_to_buffer(state, data)

          case other do
            :ping ->
              handle_ping_response(new_state)

            :auth ->
              handle_auth_response(new_state)

            :replconf_listening_port ->
              handle_replconf_response(new_state, :replconf_capa)

            :replconf_capa ->
              handle_replconf_response(new_state, :send_psync)

            :psync ->
              handle_psync_response(new_state)
          end
      end

    case result do
      {:noreply, state} ->
        :ok = transport_setopts(state.transport, state.socket, active: :once)
        {:noreply, state}

      {:reconnect, reason, state} ->
        schedule_reconnect(reason, state)

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
        {:reconnect, {:ping_failed, reason}, state}
    end
  end

  defp handle_auth_response(state) do
    case parse_simple_response(state) do
      {:ok, _response, new_state} ->
        Logger.debug("AUTH successful")

        # After AUTH, send PING
        case send_ping(new_state) do
          {:ok, new_state} -> {:noreply, new_state}
          {:error, reason} -> {:reconnect, {:ping_failed, reason}, new_state}
        end

      :incomplete ->
        {:noreply, state}

      {:error, reason} ->
        {:reconnect, {:auth_failed, reason}, state}
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
        {:reconnect, {:replconf_failed, reason}, state}
    end
  end

  defp handle_psync_response(state) do
    # PSYNC response can be:
    # - +FULLRESYNC <replication_id> <offset>\r\n (full sync)
    # - +CONTINUE\r\n (partial resync accepted)
    case parse_psync_response(state) do
      :incomplete ->
        {:noreply, state}

      {:error, reason} ->
        {:reconnect, {:psync_failed, reason}, state}

      {:ok, psync_completed} ->
        case handle_psync_completed(psync_completed) do
          {:ok, new_state} ->
            new_state = schedule_periodic_ack(new_state)

            # Feed rest of the buffered data to replica parser
            buffered_data = new_state.buffer

            if byte_size(buffered_data) > 0 do
              new_state = %{new_state | buffer: <<>>}
              handle_replication_data(buffered_data, new_state)
            else
              {:noreply, new_state}
            end

          {:error, reason} ->
            Logger.error("handle_replication_start callback failed: #{inspect(reason)}")
            {:stop, {:handle_replication_start_failed, reason}, state}
        end
    end
  end

  defp handle_psync_completed({:fullresync, replication_id, offset, state}) do
    Logger.info("PSYNC: FULLRESYNC #{replication_id} #{offset}")

    case state.callback_module.handle_replication_start(state.callback_state) do
      {:ok, updated_callback_state} ->
        Logger.info("handle_replication_start callback succeeded")
        # Create replica parser (handles both RDB and command streaming)

        replica_parser = Parser.create()

        new_state = %{
          state
          | callback_state: updated_callback_state,
            replication_id: replication_id,
            replication_offset: offset,
            replica_parser: replica_parser,
            state: :replication
        }

        {:ok, new_state}

      {:error, reason} ->
        {:error, {:handle_replication_start_failed, reason}}
    end
  end

  defp handle_psync_completed({:continue, state}) do
    Logger.info("PSYNC: CONTINUE - partial resync accepted")

    # Create parser in streaming mode (no RDB expected)
    replica_parser = Parser.create(rdb: false)

    new_state = %{
      state
      | replication_id: state.saved_replication_id,
        replication_offset: state.saved_replication_offset,
        replica_parser: replica_parser,
        state: :replication
    }

    {:ok, new_state}
  end

  # Handle replication data using Rust replica parser
  defp handle_replication_data(data, state) do
    # CRITICAL: Check parser state BEFORE feeding data
    # According to Redis replication protocol, the offset in FULLRESYNC represents
    # the logical position in the command stream. The RDB is sent "out of band" and
    # should not increment the offset. Only commands after the RDB increment the offset.
    parser_state_before = Vdr.RedisStream.Nif.replica_state(state.replica_parser)

    # Feed data to replica parser (handles RDB and command stream automatically)
    case Parser.data(state.replica_parser, data) do
      {:ok, commands, new_replica_parser, flags} ->
        # If PING or REPLCONF GETACK was received, send ACK
        if flags.ping or flags.replconf_getack do
          Logger.debug(
            "Received #{if flags.ping, do: "PING", else: "REPLCONF GETACK"}, sending REPLCONF ACK #{state.replication_offset}"
          )

          send_replconf_ack(state)
        end

        # Check parser state AFTER feeding data to detect streaming transition
        parser_state_after = Vdr.RedisStream.Nif.replica_state(new_replica_parser)

        # Only increment offset if we were in streaming mode BEFORE feeding this data
        # If we were reading RDB, this data is RDB data and should not count
        new_offset =
          if parser_state_before == :streaming do
            state.replication_offset + byte_size(data)
          else
            # During RDB transfer (:waiting_rdb or :reading_rdb), don't increment offset
            state.replication_offset
          end

        # Update state with new offset BEFORE processing commands
        # This is critical because process_commands may send REPLCONF ACK
        # which must report the correct offset including the current data
        state_with_offset = %{
          state
          | replica_parser: new_replica_parser,
            replication_offset: new_offset
        }

        # If streaming just started (after RDB transfer completes), call handle_streaming_start
        # This happens in FULLRESYNC after RDB is fully received and parsed
        # This does NOT happen in PSYNC CONTINUE (parser starts directly in :streaming mode)
        state_result =
          if parser_state_before != :streaming and parser_state_after == :streaming do
            case state.callback_module.handle_streaming_start(state_with_offset.callback_state) do
              {:ok, new_callback_state} ->
                Logger.info("handle_streaming_start callback succeeded")
                {:ok, %{state_with_offset | callback_state: new_callback_state}}

              {:error, reason} ->
                Logger.error("handle_streaming_start callback failed: #{inspect(reason)}")
                {:error, {:handle_streaming_start_failed, reason}}
            end
          else
            {:ok, state_with_offset}
          end

        case state_result do
          {:ok, state_with_offset} ->
            # Process commands through callback
            case process_commands(commands, state_with_offset) do
              {:ok, new_state} ->
                {:noreply, new_state}

              {:error, reason} ->
                {:stop, {:callback_failed, reason}, state}
            end

          {:error, reason} ->
            {:stop, reason, state}
        end

      {:error, reason} ->
        Logger.error("Replica parser error: #{inspect(reason)}")
        {:stop, {:parse_failed, reason}, state}
    end
  end

  defp process_commands(commands, state) do
    replica_commands =
      for {db, command, raw_command, affected_keys} <- commands do
        %Vdr.RedisStream.ReplicaCommand{
          db: db,
          command: command,
          raw_command: raw_command,
          affected_keys: affected_keys,
          context: %{}
        }
      end

    command_filter = state.command_filter

    filtered_replica_commands = CommandFilter.apply_pre(command_filter, replica_commands)
    result = do_process_commands(filtered_replica_commands, state)

    filter_result =
      case result do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end

    :ok = CommandFilter.apply_post(command_filter, filtered_replica_commands, filter_result)
    result
  end

  # Process commands from replica parser through callback
  defp do_process_commands([], state) do
    {:ok, state}
  end

  defp do_process_commands(replica_commands, state) do
    case state.callback_module.handle_commands(state.callback_state, replica_commands) do
      {:ok, new_callback_state} ->
        {:ok, %{state | callback_state: new_callback_state}}

      {:error, reason} ->
        Logger.error("Callback error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Buffer management helpers

  defp append_to_buffer(state, data) do
    %{state | buffer: <<state.buffer::binary, data::binary>>}
  end

  # RESP protocol parsers (work with state containing iolist buffer)

  defp parse_simple_response(state) do
    case state.buffer do
      ## Redis sends "\n" as some kind of pings
      <<"\n"::binary, rest::binary>> ->
        new_state = %{state | buffer: rest}
        parse_simple_response(new_state)

      <<"+"::binary, _::binary>> ->
        case :binary.split(state.buffer, "\r\n") do
          [<<"+"::binary, response::binary>>, rest] ->
            new_state = %{state | buffer: rest}

            {:ok, response, new_state}

          _ ->
            :incomplete
        end

      <<"-"::binary, _::binary>> ->
        case :binary.split(state.buffer, "\r\n") do
          [<<"-"::binary, error::binary>>, _rest] ->
            {:error, {:redis_error, error}}

          _ ->
            :incomplete
        end

      _ ->
        :incomplete
    end
  end

  defp parse_psync_response(state) do
    case state.buffer do
      <<"\n"::binary, rest::binary>> ->
        ## Redis sends "\n" as some kind of pings
        new_state = %{state | buffer: rest}
        parse_psync_response(new_state)

      <<"+FULLRESYNC "::binary, _::binary>> ->
        case :binary.split(state.buffer, "\r\n") do
          [<<"+FULLRESYNC "::binary, params::binary>>, rest] ->
            [replication_id, offset_str] = String.split(params, " ", parts: 2)
            offset = String.to_integer(offset_str)
            new_state = %{state | buffer: rest}
            {:ok, {:fullresync, replication_id, offset, new_state}}

          _ ->
            :incomplete
        end

      <<"+CONTINUE"::binary, _::binary>> ->
        case :binary.split(state.buffer, "\r\n") do
          [<<"+CONTINUE"::binary, _::binary>>, rest] ->
            new_state = %{state | buffer: rest}

            {:ok, {:continue, new_state}}

          _ ->
            :incomplete
        end

      <<"-"::binary, _::binary>> ->
        case :binary.split(state.buffer, "\r\n") do
          [<<"-"::binary, error::binary>>, _rest] ->
            {:error, {:redis_error, error}}

          _ ->
            :incomplete
        end

      _ ->
        :incomplete
    end
  end

  # Sentinel configuration validation

  defp validate_sentinel_opts!(opts) do
    unless Keyword.has_key?(opts, :sentinels) do
      raise ArgumentError, "sentinel :sentinels list is required"
    end

    unless Keyword.has_key?(opts, :group) do
      raise ArgumentError, "sentinel :group is required"
    end

    sentinels = Keyword.get(opts, :sentinels)

    unless is_list(sentinels) and length(sentinels) > 0 do
      raise ArgumentError, "sentinel :sentinels must be a non-empty list"
    end

    # Validate each sentinel
    Enum.each(sentinels, fn sentinel ->
      unless is_list(sentinel) do
        raise ArgumentError, "each sentinel must be a keyword list"
      end

      unless Keyword.has_key?(sentinel, :host) and Keyword.has_key?(sentinel, :port) do
        raise ArgumentError, "each sentinel must have :host and :port"
      end
    end)

    # Validate role if provided
    role = Keyword.get(opts, :role, :primary)

    unless role in [:primary, :replica] do
      raise ArgumentError, "sentinel :role must be :primary or :replica"
    end

    :ok
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
