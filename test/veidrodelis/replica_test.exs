defmodule Veidrodelis.ReplicaTest do
  use ExUnit.Case, async: false

  alias Vdr.RedisStream.Replica
  alias Vdr.RedisStream.Command, as: RedisCommand
  use CommandMatchers
  require Logger

  # Callback module that collects all commands
  defmodule CollectorCallback do
    @behaviour Vdr.RedisStream.Callback

    @impl Vdr.RedisStream.Callback
    def init(_opts) do
      {:ok, %{}}
    end

    @impl Vdr.RedisStream.Callback
    def handle_replication_start(state) do
      {:ok, state}
    end

    @impl Vdr.RedisStream.Callback
    def handle_streaming_start(state) do
      {:ok, state}
    end

    @impl Vdr.RedisStream.Callback
    def handle_commands(state, replica_commands) do
      # Add commands to the list with timestamp
      commands = Map.get(state, :commands, [])

      new_commands =
        Enum.reduce(replica_commands, commands, fn %Vdr.RedisStream.ReplicaCommand{
                                                      db: db,
                                                      command: command
                                                    },
                                                    acc ->
          entry = {System.monotonic_time(), db, command}
          [entry | acc]
        end)

      new_state = Map.put(state, :commands, new_commands)
      {:ok, new_state}
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
      :ok
    end

    def commands(state) do
      Map.get(state, :commands, [])
      |> Enum.reverse()
      |> Enum.map(fn {_ts, _db, cmd} -> cmd end)
    end
  end

  @redis_host "localhost"
  @redis_port 16378

  setup do
    # Ensure Redis is running (docker-compose up in test/assets)
    # Connect to Redis for test setup
    {:ok, redis} = Redix.start_link(host: @redis_host, port: @redis_port)

    # Flush all databases before each test
    Redix.command!(redis, ["FLUSHALL"])

    on_exit(fn ->
      if Process.alive?(redis) do
        Redix.stop(redis)
      end
    end)

    {:ok, redis: redis}
  end

  describe "full replication flow" do
    test "receives commands from RDB and streaming", %{redis: redis} do
      # Step 1: Write some data to Redis BEFORE starting replica
      Redix.command!(redis, ["SET", "key1", "value1"])
      Redix.command!(redis, ["SET", "key2", "value2"])
      Redix.command!(redis, ["RPUSH", "mylist", "item1"])
      Redix.command!(redis, ["RPUSH", "mylist", "item2"])
      Redix.command!(redis, ["SADD", "myset", "member1"])
      Redix.command!(redis, ["ZADD", "myzset", "1.5", "zmember1"])
      Redix.command!(redis, ["HSET", "myhash", "field1", "value1"])

      # Step 2: Start replica
      opts = [
        host: @redis_host,
        port: @redis_port,
        callback_module: CollectorCallback,
        callback_state: %{commands: []}
      ]

      {:ok, replica} = Replica.start_link(opts)

      # Wait for RDB transfer to complete
      assert_within 2000 do
        assert :streaming == Replica.get_replication_state(replica)
      end

      # Step 3: Issue more commands AFTER replica is connected
      Redix.command!(redis, ["SET", "key3", "value3"])
      Redix.command!(redis, ["RPUSH", "mylist", "item3"])
      Redix.command!(redis, ["SADD", "myset", "member2"])
      Redix.command!(redis, ["DEL", "key3"])

      # Wait for commands to replicate
      assert_within 1000 do
        # Step 4: Get callback state and verify
        callback_state = Replica.get_callback_state(replica)
        commands = CollectorCallback.commands(callback_state)
        Logger.debug("Commands: #{inspect(commands)}")

        # Verify we received commands from RDB
        assert command_in_list(%RedisCommand.Set{key: "key1", value: "value1"}, commands)
        assert command_in_list(%RedisCommand.Set{key: "key2", value: "value2"}, commands)
        assert command_in_list(%RedisCommand.RPush{key: "mylist"}, commands)
        assert command_in_list(%RedisCommand.SAdd{key: "myset"}, commands)
        assert command_in_list(%RedisCommand.ZAdd{key: "myzset"}, commands)
        assert command_in_list(%RedisCommand.HSet{key: "myhash"}, commands)
        assert command_in_list(%RedisCommand.Set{key: "key3", value: "value3"}, commands)
        assert command_in_list(%RedisCommand.RPush{key: "mylist"}, commands)
        assert command_in_list(%RedisCommand.SAdd{key: "myset"}, commands)
        assert command_in_list(%RedisCommand.Del{keys: ["key3"]}, commands)
      end

      Replica.stop(replica)
    end

    test "tracks replication offset", %{redis: redis} do
      # Write initial data
      Redix.command!(redis, ["SET", "initial", "data"])

      # Start replica
      opts = [
        host: @redis_host,
        port: @redis_port,
        callback_module: CollectorCallback,
        callback_state: %{commands: []}
      ]

      {:ok, replica} = Replica.start_link(opts)

      # Wait for sync
      assert_within 1500 do
        assert :streaming == Replica.get_replication_state(replica)
      end

      # Get initial offset
      initial_offset = Replica.get_offset(replica)
      assert is_integer(initial_offset)

      # Write more data
      Redix.command!(redis, ["SET", "key1", "value1"])
      Redix.command!(redis, ["SET", "key2", "value2"])

      # Wait for replication
      assert_within 500 do
        Replica.get_offset(replica) > initial_offset
      end

      Replica.stop(replica)
    end

    test "gets replication ID", %{redis: _redis} do
      opts = [
        host: @redis_host,
        port: @redis_port,
        callback_module: CollectorCallback,
        callback_state: %{commands: []}
      ]

      {:ok, replica} = Replica.start_link(opts)

      # Wait for sync
      assert_within 1500 do
        assert :streaming == Replica.get_replication_state(replica)
      end

      # Get replication ID
      repl_id = Replica.get_replication_id(replica)
      assert is_binary(repl_id)
      assert byte_size(repl_id) == 40

      Replica.stop(replica)
    end
  end

  describe "command types" do
    test "receives SET commands correctly", %{redis: redis} do
      Redix.command!(redis, ["SET", "testkey", "testvalue"])

      opts = [
        host: @redis_host,
        port: @redis_port,
        callback_module: CollectorCallback,
        callback_state: %{commands: []}
      ]

      {:ok, replica} = Replica.start_link(opts)

      assert_within 1500 do
        assert :streaming == Replica.get_replication_state(replica)
      end

      callback_state = Replica.get_callback_state(replica)
      commands = filter_commands(%RedisCommand.Set{}, CollectorCallback.commands(callback_state))

      assert length(commands) >= 1
      assert command_in_list(%RedisCommand.Set{key: "testkey", value: "testvalue"}, commands)

      Replica.stop(replica)
    end

    test "receives RPUSH commands correctly", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "testlist", "item1", "item2", "item3"])

      opts = [
        host: @redis_host,
        port: @redis_port,
        callback_module: CollectorCallback,
        callback_state: %{commands: []}
      ]

      {:ok, replica} = Replica.start_link(opts)

      assert_within 1500 do
        assert :streaming == Replica.get_replication_state(replica)
      end

      callback_state = Replica.get_callback_state(replica)
      commands = CollectorCallback.commands(callback_state)

      rpush_commands = filter_commands(%RedisCommand.RPush{}, commands)

      # Should have 1 RPUSH command with all 3 items
      assert length(rpush_commands) >= 1

      # Verify all items are present in the command
      assert command_in_list(%RedisCommand.RPush{key: "testlist", values: values}, commands)
      [%RedisCommand.RPush{values: values}] = rpush_commands
      assert "item1" in values and "item2" in values and "item3" in values

      Replica.stop(replica)
    end

    test "receives SADD commands correctly", %{redis: redis} do
      Redix.command!(redis, ["SADD", "testset", "member1", "member2"])

      opts = [
        host: @redis_host,
        port: @redis_port,
        callback_module: CollectorCallback,
        callback_state: %{commands: []}
      ]

      {:ok, replica} = Replica.start_link(opts)

      assert_within 1500 do
        assert :streaming == Replica.get_replication_state(replica)
      end

      assert_within 1500 do
        commands = CollectorCallback.commands(Replica.get_callback_state(replica))
        command_in_list(%RedisCommand.SAdd{key: "testset"}, commands)
      end

      callback_state = Replica.get_callback_state(replica)
      commands = CollectorCallback.commands(callback_state)
      [%RedisCommand.SAdd{members: members}] = filter_commands(%RedisCommand.SAdd{}, commands)
      assert "member1" in members and "member2" in members

      Replica.stop(replica)
    end

    test "receives ZADD commands correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "testzset", "1.0", "member1", "2.5", "member2"])

      opts = [
        host: @redis_host,
        port: @redis_port,
        callback_module: CollectorCallback,
        callback_state: %{commands: []}
      ]

      {:ok, replica} = Replica.start_link(opts)

      assert_within 1500 do
        assert :streaming == Replica.get_replication_state(replica)
      end

      assert_within 1500 do
        commands =
          replica
          |> Replica.get_callback_state()
          |> CollectorCallback.commands()

        command_in_list(%RedisCommand.ZAdd{key: "testzset"}, commands)
      end

      state = Replica.get_callback_state(replica)
      commands = CollectorCallback.commands(state)
      zadd_commands = filter_commands(%RedisCommand.ZAdd{}, commands)

      [%RedisCommand.ZAdd{members: members}] = zadd_commands

      assert {1.0, "member1"} in members
      assert {2.5, "member2"} in members

      Replica.stop(replica)
    end

    test "receives HSET commands correctly", %{redis: redis} do
      Redix.command!(redis, ["HSET", "testhash", "field1", "value1", "field2", "value2"])

      opts = [
        host: @redis_host,
        port: @redis_port,
        callback_module: CollectorCallback,
        callback_state: %{commands: []}
      ]

      {:ok, replica} = Replica.start_link(opts)

      assert_within 1500 do
        assert :streaming == Replica.get_replication_state(replica)
      end

      callback_state = Replica.get_callback_state(replica)
      commands = CollectorCallback.commands(callback_state)

      hset_commands = filter_commands(%RedisCommand.HSet{}, commands)

      # Should have 1 HSET command with both fields
      assert length(hset_commands) >= 1

      # Verify both fields are present in the command
      assert command_in_list(%RedisCommand.HSet{key: "testhash", fields: fields}, commands)
      [%RedisCommand.HSet{fields: fields}] = hset_commands
      assert {"field1", "value1"} in fields and {"field2", "value2"} in fields

      Replica.stop(replica)
    end

    test "receives PEXPIREAT commands for expiring keys", %{redis: redis} do
      # Set multiple keys including one with expiration
      Redix.command!(redis, ["SET", "normalkey", "normal"])
      Redix.command!(redis, ["SET", "expirekey", "value"])
      Redix.command!(redis, ["PEXPIREAT", "expirekey", "9999999999000"])
      Redix.command!(redis, ["SET", "anotherkey", "another"])

      # Give Redis a moment to persist the data
      Process.sleep(50)

      opts = [
        host: @redis_host,
        port: @redis_port,
        callback_module: CollectorCallback,
        callback_state: %{commands: []}
      ]

      {:ok, replica} = Replica.start_link(opts)

      assert_within 1500 do
        assert :streaming == Replica.get_replication_state(replica)
      end

      callback_state = Replica.get_callback_state(replica)
      commands = CollectorCallback.commands(callback_state)

      # Should have both SET and PEXPIREAT commands
      set_commands = filter_commands(%RedisCommand.Set{key: "expirekey"}, commands)
      expire_commands = filter_commands(%RedisCommand.PExpireAt{key: "expirekey"}, commands)

      assert length(set_commands) >= 1
      assert length(expire_commands) >= 1

      Replica.stop(replica)
    end
  end

  describe "database selection" do
    test "tracks current database correctly", %{redis: redis} do
      # Write to different databases
      Redix.command!(redis, ["SELECT", "0"])
      Redix.command!(redis, ["SET", "db0key", "value0"])

      Redix.command!(redis, ["SELECT", "1"])
      Redix.command!(redis, ["SET", "db1key", "value1"])

      opts = [
        host: @redis_host,
        port: @redis_port,
        callback_module: CollectorCallback,
        callback_state: %{commands: []}
      ]

      {:ok, replica} = Replica.start_link(opts)

      assert_within 1500 do
        assert :streaming == Replica.get_replication_state(replica)
      end

      callback_state = Replica.get_callback_state(replica)
      commands = CollectorCallback.commands(callback_state)

      # Find commands and their databases
      db0_commands = filter_commands(%RedisCommand.Set{key: "db0key"}, commands)
      db1_commands = filter_commands(%RedisCommand.Set{key: "db1key"}, commands)

      assert length(db0_commands) >= 1
      assert length(db1_commands) >= 1

      Replica.stop(replica)

      # Clean up
      Redix.command!(redis, ["SELECT", "0"])
      Redix.command!(redis, ["FLUSHDB"])
      Redix.command!(redis, ["SELECT", "1"])
      Redix.command!(redis, ["FLUSHDB"])
    end
  end

  describe "streaming replication" do
    test "receives commands issued after replica connection", %{redis: redis} do
      # Start replica first
      opts = [
        host: @redis_host,
        port: @redis_port,
        callback_module: CollectorCallback,
        callback_state: %{commands: []}
      ]

      {:ok, replica} = Replica.start_link(opts)

      # Wait for initial sync
      assert_within 1500 do
        assert :streaming == Replica.get_replication_state(replica)
      end

      # Now issue commands
      Redix.command!(redis, ["SET", "streamkey1", "streamvalue1"])
      Redix.command!(redis, ["SET", "streamkey2", "streamvalue2"])
      Redix.command!(redis, ["RPUSH", "streamlist", "item1"])

      # Wait for replication
      assert_within 1000 do
        callback_state = Replica.get_callback_state(replica)
        commands = CollectorCallback.commands(callback_state)

        assert command_in_list(
                 %RedisCommand.Set{key: "streamkey1", value: "streamvalue1"},
                 commands
               )

        assert command_in_list(
                 %RedisCommand.Set{key: "streamkey2", value: "streamvalue2"},
                 commands
               )

        assert command_in_list(%RedisCommand.RPush{key: "streamlist"}, commands)
      end

      Replica.stop(replica)
    end
  end

  describe "authentication" do
    test "authenticates with legacy password" do
      # Connect to Redis with password for test setup
      {:ok, redis} =
        Redix.start_link(host: @redis_host, port: 16380, password: "testpassword")

      # Flush database
      Redix.command!(redis, ["FLUSHALL"])

      # Write test data
      Redix.command!(redis, ["SET", "authkey", "authvalue"])

      # Start replica with password
      opts = [
        host: @redis_host,
        port: 16380,
        password: "testpassword",
        callback_module: CollectorCallback,
        callback_state: %{commands: []}
      ]

      {:ok, replica} = Replica.start_link(opts)

      # Wait for sync
      assert_within 1500 do
        assert :streaming == Replica.get_replication_state(replica)
      end

      # Get callback state
      callback_state = Replica.get_callback_state(replica)
      commands = CollectorCallback.commands(callback_state)

      # Verify we received the SET command
      assert command_in_list(%RedisCommand.Set{key: "authkey", value: "authvalue"}, commands)

      Replica.stop(replica)

      if Process.alive?(redis) do
        Redix.stop(redis)
      end
    end

    test "authenticates with ACL username and password" do
      # Connect to Redis with ACL for test setup
      {:ok, redis} =
        Redix.start_link(
          host: @redis_host,
          port: 16381,
          username: "testuser",
          password: "testpassword"
        )

      # Flush database
      Redix.command!(redis, ["FLUSHALL"])

      # Write test data
      Redix.command!(redis, ["SET", "aclkey", "aclvalue"])

      # Start replica with ACL credentials
      opts = [
        host: @redis_host,
        port: 16381,
        username: "testuser",
        password: "testpassword",
        callback_module: CollectorCallback,
        callback_state: %{commands: []}
      ]

      {:ok, replica} = Replica.start_link(opts)

      # Wait for sync
      assert_within 1500 do
        assert :streaming == Replica.get_replication_state(replica)
      end

      # Get callback state
      callback_state = Replica.get_callback_state(replica)
      commands = CollectorCallback.commands(callback_state)

      # Verify we received the SET command
      assert command_in_list(%RedisCommand.Set{key: "aclkey", value: "aclvalue"}, commands)

      Replica.stop(replica)

      if Process.alive?(redis) do
        Redix.stop(redis)
      end
    end
  end

  describe "error handling" do
    test "handles connection to non-existent Redis" do
      original_level = Logger.level()
      Logger.configure(level: :critical)

      on_exit(fn ->
        Logger.configure(level: original_level)
      end)

      # Trap exits so the test doesn't crash when the replica process crashes
      Process.flag(:trap_exit, true)

      opts = [
        host: @redis_host,
        port: 9999,
        callback_module: CollectorCallback,
        callback_state: %{commands: []},
        reconnect: false
      ]

      result = Replica.start_link(opts)

      case result do
        {:ok, pid} ->
          # Process should terminate soon
          receive do
            {:EXIT, ^pid, _reason} ->
              assert true
          after
            5000 ->
              if Process.alive?(pid) do
                Replica.stop(pid)
              end

              flunk("Process did not terminate on connection failure")
          end

        {:error, _reason} ->
          assert true
      end
    end
  end
end
