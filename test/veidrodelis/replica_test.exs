defmodule Veidrodelis.ReplicaTest do
  use ExUnit.Case, async: false

  alias Veidrodelis.Replica
  alias Veidrodelis.Command

  # Callback module that collects all commands
  defmodule CollectorCallback do
    @behaviour Veidrodelis.RedisStream.Callback

    @impl true
    def on_command(state, db, command) do
      # Add command to the list with timestamp
      commands = Map.get(state, :commands, [])
      entry = {System.monotonic_time(), db, command}
      new_state = Map.put(state, :commands, [entry | commands])
      {:ok, new_state}
    end
  end

  @redis_host "localhost"
  @redis_port 16379

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
      Process.sleep(2000)

      # Step 3: Issue more commands AFTER replica is connected
      Redix.command!(redis, ["SET", "key3", "value3"])
      Redix.command!(redis, ["RPUSH", "mylist", "item3"])
      Redix.command!(redis, ["SADD", "myset", "member2"])

      # Wait for commands to replicate
      Process.sleep(500)

      # Step 4: Get callback state and verify
      callback_state = Replica.get_callback_state(replica)
      commands = Map.get(callback_state, :commands, [])

      # Reverse to get chronological order
      commands = Enum.reverse(commands)

      # Extract just the commands (without timestamp and db)
      command_list = Enum.map(commands, fn {_ts, _db, cmd} -> cmd end)

      # Verify we received commands from RDB
      assert Enum.any?(command_list, fn
               %Command.Set{key: "key1", value: "value1"} -> true
               _ -> false
             end)

      assert Enum.any?(command_list, fn
               %Command.Set{key: "key2", value: "value2"} -> true
               _ -> false
             end)

      # Verify list items
      assert Enum.any?(command_list, fn
               %Command.RPush{key: "mylist", value: "item1"} -> true
               _ -> false
             end)

      assert Enum.any?(command_list, fn
               %Command.RPush{key: "mylist", value: "item2"} -> true
               _ -> false
             end)

      # Verify set member
      assert Enum.any?(command_list, fn
               %Command.SAdd{key: "myset", member: "member1"} -> true
               _ -> false
             end)

      # Verify sorted set member
      assert Enum.any?(command_list, fn
               %Command.ZAdd{key: "myzset", score: 1.5, member: "zmember1"} -> true
               _ -> false
             end)

      # Verify hash field
      assert Enum.any?(command_list, fn
               %Command.HSet{key: "myhash", field: "field1", value: "value1"} -> true
               _ -> false
             end)

      # Verify streaming commands
      assert Enum.any?(command_list, fn
               %Command.Set{key: "key3", value: "value3"} -> true
               _ -> false
             end)

      assert Enum.any?(command_list, fn
               %Command.RPush{key: "mylist", value: "item3"} -> true
               _ -> false
             end)

      assert Enum.any?(command_list, fn
               %Command.SAdd{key: "myset", member: "member2"} -> true
               _ -> false
             end)

      # Verify total command count (at least the ones we issued)
      assert length(command_list) >= 10

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
      Process.sleep(1500)

      # Get initial offset
      initial_offset = Replica.get_offset(replica)
      assert is_integer(initial_offset)

      # Write more data
      Redix.command!(redis, ["SET", "key1", "value1"])
      Redix.command!(redis, ["SET", "key2", "value2"])

      # Wait for replication
      Process.sleep(500)

      # Offset should increase (or stay the same if writes weren't replicated yet)
      final_offset = Replica.get_offset(replica)
      assert final_offset >= initial_offset

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
      Process.sleep(1500)

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
      Process.sleep(1500)

      callback_state = Replica.get_callback_state(replica)
      commands = Map.get(callback_state, :commands, [])

      set_commands =
        Enum.filter(commands, fn
          {_ts, _db, %Command.Set{}} -> true
          _ -> false
        end)

      assert length(set_commands) >= 1

      assert Enum.any?(set_commands, fn
               {_ts, _db, %Command.Set{key: "testkey", value: "testvalue"}} -> true
               _ -> false
             end)

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
      Process.sleep(1500)

      callback_state = Replica.get_callback_state(replica)
      commands = Map.get(callback_state, :commands, [])

      rpush_commands =
        Enum.filter(commands, fn
          {_ts, _db, %Command.RPush{}} -> true
          _ -> false
        end)

      # Should have 3 RPUSH commands (one per item)
      assert length(rpush_commands) >= 3

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
      Process.sleep(1500)

      callback_state = Replica.get_callback_state(replica)
      commands = Map.get(callback_state, :commands, [])

      sadd_commands =
        Enum.filter(commands, fn
          {_ts, _db, %Command.SAdd{}} -> true
          _ -> false
        end)

      assert length(sadd_commands) >= 2

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
      Process.sleep(1500)

      callback_state = Replica.get_callback_state(replica)
      commands = Map.get(callback_state, :commands, [])

      zadd_commands =
        Enum.filter(commands, fn
          {_ts, _db, %Command.ZAdd{}} -> true
          _ -> false
        end)

      assert length(zadd_commands) >= 2

      # Verify scores are correct
      assert Enum.any?(zadd_commands, fn
               {_ts, _db, %Command.ZAdd{score: 1.0, member: "member1"}} -> true
               _ -> false
             end)

      assert Enum.any?(zadd_commands, fn
               {_ts, _db, %Command.ZAdd{score: 2.5, member: "member2"}} -> true
               _ -> false
             end)

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
      Process.sleep(1500)

      callback_state = Replica.get_callback_state(replica)
      commands = Map.get(callback_state, :commands, [])

      hset_commands =
        Enum.filter(commands, fn
          {_ts, _db, %Command.HSet{}} -> true
          _ -> false
        end)

      assert length(hset_commands) >= 2

      Replica.stop(replica)
    end

    test "receives PEXPIREAT commands for expiring keys", %{redis: redis} do
      # Set a key with expiration
      Redix.command!(redis, ["SET", "expirekey", "value"])
      Redix.command!(redis, ["PEXPIREAT", "expirekey", "9999999999000"])

      opts = [
        host: @redis_host,
        port: @redis_port,
        callback_module: CollectorCallback,
        callback_state: %{commands: []}
      ]

      {:ok, replica} = Replica.start_link(opts)
      Process.sleep(1500)

      callback_state = Replica.get_callback_state(replica)
      commands = Map.get(callback_state, :commands, [])

      # Should have both SET and PEXPIREAT commands
      set_commands =
        Enum.filter(commands, fn
          {_ts, _db, %Command.Set{key: "expirekey"}} -> true
          _ -> false
        end)

      expire_commands =
        Enum.filter(commands, fn
          {_ts, _db, %Command.PExpireAt{key: "expirekey"}} -> true
          _ -> false
        end)

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
      Process.sleep(1500)

      callback_state = Replica.get_callback_state(replica)
      commands = Map.get(callback_state, :commands, [])

      # Find commands and their databases
      db0_commands =
        Enum.filter(commands, fn
          {_ts, 0, %Command.Set{key: "db0key"}} -> true
          _ -> false
        end)

      db1_commands =
        Enum.filter(commands, fn
          {_ts, 1, %Command.Set{key: "db1key"}} -> true
          _ -> false
        end)

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
      Process.sleep(1500)

      # Now issue commands
      Redix.command!(redis, ["SET", "streamkey1", "streamvalue1"])
      Redix.command!(redis, ["SET", "streamkey2", "streamvalue2"])
      Redix.command!(redis, ["RPUSH", "streamlist", "item1"])

      # Wait for replication
      Process.sleep(500)

      callback_state = Replica.get_callback_state(replica)
      commands = Map.get(callback_state, :commands, [])

      # Verify streaming commands were received
      assert Enum.any?(commands, fn
               {_ts, _db, %Command.Set{key: "streamkey1", value: "streamvalue1"}} -> true
               _ -> false
             end)

      assert Enum.any?(commands, fn
               {_ts, _db, %Command.Set{key: "streamkey2", value: "streamvalue2"}} -> true
               _ -> false
             end)

      assert Enum.any?(commands, fn
               {_ts, _db, %Command.RPush{key: "streamlist", value: "item1"}} -> true
               _ -> false
             end)

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
      Process.sleep(1500)

      # Get callback state
      callback_state = Replica.get_callback_state(replica)
      commands = Map.get(callback_state, :commands, [])

      # Verify we received the SET command
      assert Enum.any?(commands, fn
               {_ts, _db, %Command.Set{key: "authkey", value: "authvalue"}} -> true
               _ -> false
             end)

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
      Process.sleep(1500)

      # Get callback state
      callback_state = Replica.get_callback_state(replica)
      commands = Map.get(callback_state, :commands, [])

      # Verify we received the SET command
      assert Enum.any?(commands, fn
               {_ts, _db, %Command.Set{key: "aclkey", value: "aclvalue"}} -> true
               _ -> false
             end)

      Replica.stop(replica)

      if Process.alive?(redis) do
        Redix.stop(redis)
      end
    end
  end

  describe "error handling" do
    test "handles connection to non-existent Redis" do
      # Trap exits so the test doesn't crash when the replica process crashes
      Process.flag(:trap_exit, true)

      opts = [
        host: @redis_host,
        port: 9999,
        callback_module: CollectorCallback,
        callback_state: %{commands: []}
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
