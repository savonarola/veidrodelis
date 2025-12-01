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
        def on_command(state, db, %Command.Set{key: key, value: value}) do
          IO.puts("SET \#{key} = \#{value} in DB \#{db}")
          {:ok, Map.update(state, :count, 1, &(&1 + 1))}
        end

        def on_command(state, _db, _command) do
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

  alias Vdr.RDB
  alias Vdr.RedisStream.CommandParser

  @default_port 6379
  @default_timeout 5000

  # Client API

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

  # Server callbacks

  @impl true
  def init(opts) do
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
      rdb_parser: nil,
      # IOList buffer for accumulating data
      buffer: [],
      buffer_size: 0,
      state: :init,
      current_db: 0,
      # For RDB bulk string parsing
      rdb_bulk_size: nil,
      rdb_bytes_read: 0
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
    {:reply, state.state, state}
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

    # Call on_destroy callback if implemented
    if function_exported?(state.callback_module, :on_destroy, 1) do
      case state.callback_module.on_destroy(state.callback_state) do
        :ok ->
          Logger.debug("on_destroy callback succeeded")

        {:error, reason} ->
          Logger.error("on_destroy callback failed: #{inspect(reason)}")
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
        buffer: [],
        buffer_size: 0,
        state: :init,
        rdb_parser: nil,
        rdb_bulk_size: nil,
        rdb_bytes_read: 0
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
    new_buffer = [data | state.buffer]
    new_buffer_size = state.buffer_size + byte_size(data)
    new_state = %{state | buffer: new_buffer, buffer_size: new_buffer_size}

    result =
      case new_state.state do
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

        :rdb_transfer ->
          handle_rdb_data(new_state)

        :streaming ->
          handle_command_stream(new_state)
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

        # Call on_replication_start callback if implemented
        callback_state_update_result =
          if function_exported?(state.callback_module, :on_replication_start, 1) do
            case state.callback_module.on_replication_start(state.callback_state) do
              {:ok, new_callback_state} ->
                Logger.debug("on_replication_start callback succeeded")
                {:ok, new_callback_state}

              {:error, reason} ->
                Logger.error("on_replication_start callback failed: #{inspect(reason)}")
                {:error, reason}
            end
          else
            {:ok, state.callback_state}
          end

        case callback_state_update_result do
          {:ok, updated_callback_state} ->
            new_state = %{
              new_state
              | callback_state: updated_callback_state,
                replication_id: replication_id,
                replication_offset: offset,
                state: :rdb_transfer
            }

            # Create RDB parser
            rdb_parser = RDB.create(state.callback_module, new_state.callback_state)
            new_state = %{new_state | rdb_parser: rdb_parser}

            # Start parsing RDB data
            handle_rdb_data(new_state)

          {:error, reason} ->
            {:stop, {:on_replication_start_failed, reason}, new_state}
        end

      {:ok, :continue, new_state} ->
        Logger.info("PSYNC: CONTINUE - partial resync accepted")

        # Continue with saved replication state, go straight to streaming
        new_state = %{
          new_state
          | replication_id: state.saved_replication_id,
            replication_offset: state.saved_replication_offset,
            state: :streaming
        }

        # Start periodic ACK timer
        new_state = schedule_periodic_ack(new_state)

        # Process any buffered command data
        if new_state.buffer_size > 0 do
          handle_command_stream(new_state)
        else
          {:noreply, new_state}
        end

      :incomplete ->
        {:noreply, state}

      {:error, reason} ->
        {:stop, {:psync_failed, reason}, state}
    end
  end

  defp handle_rdb_data(state) do
    # RDB data comes as a bulk string: $<size>\r\n<data>
    # We parse the header once, then stream data to RDB parser
    if state.rdb_bulk_size == nil do
      # Parse bulk string header
      case parse_bulk_string_header(state) do
        {:ok, rdb_size, new_state} ->
          Logger.info("RDB transfer starting, size: #{rdb_size} bytes")
          new_state = %{new_state | rdb_bulk_size: rdb_size, rdb_bytes_read: 0}
          # Continue to stream RDB data
          stream_rdb_data(new_state)

        :incomplete ->
          {:noreply, state}

        {:error, reason} ->
          {:stop, {:rdb_transfer_failed, reason}, state}
      end
    else
      # Already parsed header, stream data
      stream_rdb_data(state)
    end
  end

  defp stream_rdb_data(state) do
    # Calculate how many bytes we still need for the RDB
    bytes_remaining = state.rdb_bulk_size - state.rdb_bytes_read

    if bytes_remaining > 0 do
      # Feed available data to RDB parser
      bytes_to_feed = min(state.buffer_size, bytes_remaining)

      if bytes_to_feed > 0 do
        # Extract bytes_to_feed from buffer
        {chunk, new_state} = consume_bytes(state, bytes_to_feed)

        # Feed to RDB parser
        case RDB.data(state.rdb_parser, chunk) do
          {:ok, rdb_parser} ->
            new_bytes_read = state.rdb_bytes_read + bytes_to_feed

            new_state = %{
              new_state
              | rdb_parser: rdb_parser,
                rdb_bytes_read: new_bytes_read
            }

            # Check if RDB transfer is complete
            if new_bytes_read >= state.rdb_bulk_size do
              # RDB transfer complete, finalize
              case RDB.finish(rdb_parser) do
                {:ok, callback_state} ->
                  Logger.info(
                    "RDB transfer complete (#{new_bytes_read} bytes), switching to streaming mode"
                  )

                  new_state = %{
                    new_state
                    | rdb_parser: nil,
                      callback_state: callback_state,
                      rdb_bulk_size: nil,
                      rdb_bytes_read: 0,
                      state: :streaming
                  }

                  # Start periodic ACK timer
                  new_state = schedule_periodic_ack(new_state)

                  # Process any command stream data that's already in the buffer
                  if new_state.buffer_size > 0 do
                    handle_command_stream(new_state)
                  else
                    {:noreply, new_state}
                  end

                {:error, :incomplete_rdb} ->
                  # This shouldn't happen if we've read all bytes
                  {:stop, {:rdb_incomplete, new_bytes_read, state.rdb_bulk_size}, new_state}
              end
            else
              # More RDB data to come
              {:noreply, new_state}
            end

          {:error, reason} ->
            {:stop, {:rdb_parse_failed, reason}, new_state}
        end
      else
        # No data available yet
        {:noreply, state}
      end
    else
      # Should not reach here
      {:noreply, state}
    end
  end

  defp handle_command_stream(state) do
    # Parse commands from the stream
    case parse_command(state) do
      {:ok, command, bytes_consumed, new_state} ->
        # Update replication offset
        new_state = %{
          new_state
          | replication_offset: new_state.replication_offset + bytes_consumed
        }

        # Process the command
        new_state = process_command(command, new_state)

        # Continue processing if there's more data
        if new_state.buffer_size > 0 do
          handle_command_stream(new_state)
        else
          {:noreply, new_state}
        end

      :incomplete ->
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Failed to parse command: #{inspect(reason)}")
        {:stop, {:command_parse_failed, reason}, state}
    end
  end

  defp process_command(["SELECT", db], state) do
    db_num = String.to_integer(db)
    Logger.debug("SELECT DB #{db_num}")
    %{state | current_db: db_num}
  end

  defp process_command(["PING"], state) do
    # PING in replication stream - send REPLCONF ACK with current offset
    Logger.debug("Received PING, sending REPLCONF ACK #{state.replication_offset}")
    send_replconf_ack(state)
    state
  end

  defp process_command(["REPLCONF", "GETACK", "*"], state) do
    # Master is requesting ACK with current offset
    Logger.debug("Received REPLCONF GETACK, sending REPLCONF ACK #{state.replication_offset}")
    send_replconf_ack(state)
    state
  end

  defp process_command(raw_command, state) do
    # Parse the command using CommandParser
    {:ok, command} = CommandParser.parse(raw_command)

    # Invoke callback with the parsed command
    case state.callback_module.on_command(state.callback_state, state.current_db, command) do
      {:ok, new_callback_state} ->
        %{state | callback_state: new_callback_state}

      {:error, reason} ->
        Logger.error("Callback error: #{inspect(reason)}")
        state
    end
  end

  # Buffer management helpers

  defp buffer_to_binary(state) do
    state.buffer |> Enum.reverse() |> :erlang.iolist_to_binary()
  end

  defp consume_bytes(state, n) when state.buffer_size >= n do
    binary = buffer_to_binary(state)
    <<chunk::binary-size(n), rest::binary>> = binary

    new_state = %{
      state
      | buffer: if(byte_size(rest) > 0, do: [rest], else: []),
        buffer_size: byte_size(rest)
    }

    {chunk, new_state}
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

  defp parse_bulk_string_header(state) do
    if state.buffer_size == 0 do
      :incomplete
    else
      case peek_bytes(state, min(state.buffer_size, 64)) do
        {:ok, peek} ->
          case peek do
            <<"$"::binary, _::binary>> ->
              binary = buffer_to_binary(state)

              case :binary.split(binary, "\r\n") do
                [<<"$"::binary, size_str::binary>>, rest] ->
                  size = String.to_integer(size_str)

                  new_state = %{
                    state
                    | buffer: if(byte_size(rest) > 0, do: [rest], else: []),
                      buffer_size: byte_size(rest)
                  }

                  {:ok, size, new_state}

                _ ->
                  :incomplete
              end

            ## Redis has a replicationCron fun running once a second.
            ## It sends a single \n to the replicas waiting for the RDB snapshot.
            ## We should handle it and ignore.
            <<"\n"::binary, _::binary>> ->
              binary = buffer_to_binary(state)
              <<"\n"::binary, rest::binary>> = binary

              new_state = %{
                state
                | buffer: if(byte_size(rest) > 0, do: [rest], else: []),
                  buffer_size: byte_size(rest)
              }

              parse_bulk_string_header(new_state)

            _ ->
              {:error, :invalid_bulk_string_header}
          end

        :incomplete ->
          :incomplete
      end
    end
  end

  defp parse_command(state) do
    original_buffer_size = state.buffer_size

    case peek_bytes(state, min(state.buffer_size, 64)) do
      {:ok, peek} ->
        case peek do
          <<"*"::binary, _::binary>> ->
            binary = buffer_to_binary(state)

            case :binary.split(binary, "\r\n") do
              [<<"*"::binary, count_str::binary>>, rest] ->
                count = String.to_integer(count_str)

                case parse_array_elements(rest, count, [], state) do
                  {:ok, command, new_state} ->
                    bytes_consumed = original_buffer_size - new_state.buffer_size
                    {:ok, command, bytes_consumed, new_state}

                  other ->
                    other
                end

              _ ->
                :incomplete
            end

          <<"\n"::binary, _::binary>> ->
            binary = buffer_to_binary(state)
            <<"\n"::binary, rest::binary>> = binary
            new_state = %{state | buffer: if(byte_size(rest) > 0, do: [rest], else: []), buffer_size: byte_size(rest)}
            parse_command(new_state)
          _ ->
            :incomplete
        end

      :incomplete ->
        :incomplete
    end
  end

  defp parse_array_elements(rest, 0, acc, state) do
    new_state = %{
      state
      | buffer: if(byte_size(rest) > 0, do: [rest], else: []),
        buffer_size: byte_size(rest)
    }

    {:ok, Enum.reverse(acc), new_state}
  end

  defp parse_array_elements(<<"$"::binary, rest::binary>>, count, acc, state) do
    case :binary.split(rest, "\r\n") do
      [size_str, rest] ->
        size = String.to_integer(size_str)

        if byte_size(rest) >= size + 2 do
          <<element::binary-size(size), "\r\n"::binary, rest::binary>> = rest
          parse_array_elements(rest, count - 1, [element | acc], state)
        else
          :incomplete
        end

      _ ->
        :incomplete
    end
  end

  defp parse_array_elements(_, _, _, _), do: :incomplete

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
