defmodule VeidrodelisTSTest do
  use ExUnit.Case, async: false

  require Logger

  use CommandMatchers

  @redis_host "localhost"
  @redis_port 16378
  @id "vdr_ts_id"

  @veidrodelis_base_opts [
    id: @id,
    host: @redis_host,
    port: @redis_port,
    impl: {Vdr.TSProj, []}
  ]

  def veidrodelis_opts(opts \\ []) do
    @veidrodelis_base_opts ++ opts
  end

  setup do
    # Ensure Redis is running
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

  describe "Veidrodelis with TSProj (string operations only)" do
    test "processes string commands", %{redis: redis} do
      # Write data to Redis
      Redix.command!(redis, ["SET", "key1", "value1"])
      Redix.command!(redis, ["SET", "key2", "value2"])

      # Start Veidrodelis instance with TSProj
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify data in store
      wait_happens_within 100 do
        Veidrodelis.get(@id, 0, "key1") == "value1" &&
          Veidrodelis.get(@id, 0, "key2") == "value2" &&
          Redix.command!(redis, ["GET", "key1"]) == "value1" &&
          Redix.command!(redis, ["GET", "key2"]) == "value2"
      end

      Veidrodelis.stop(pid)
    end

    test "processes streaming string commands", %{redis: redis} do
      # Start Veidrodelis FIRST (before writing data)
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication to start
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # NOW write data to Redis (these will come via streaming, not RDB)
      Redix.command!(redis, ["SET", "stream_key", "stream_value"])

      # Wait for commands to replicate
      assert_happens_within 1000 do
        Veidrodelis.get(@id, 0, "stream_key") != nil
      end

      # Verify the data
      assert Veidrodelis.get(@id, 0, "stream_key") == "stream_value"

      Veidrodelis.stop(pid)
    end

    test "handles del commands", %{redis: redis} do
      # Write data to Redis
      Redix.command!(redis, ["SET", "key1", "value1"])
      Redix.command!(redis, ["SET", "key2", "value2"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify initial data
      wait_happens_within 100 do
        Veidrodelis.get(@id, 0, "key1") == "value1" &&
          Veidrodelis.get(@id, 0, "key2") == "value2"
      end

      # Delete one key
      Redix.command!(redis, ["DEL", "key1"])

      # Wait for deletion to replicate
      wait_happens_within 500 do
        Veidrodelis.get(@id, 0, "key1") == nil &&
          Veidrodelis.get(@id, 0, "key2") == "value2"
      end

      Veidrodelis.stop(pid)
    end

    test "handles multiple databases", %{redis: redis} do
      # Write to different databases
      Redix.command!(redis, ["SELECT", "0"])
      Redix.command!(redis, ["SET", "db0_key", "db0_value"])

      Redix.command!(redis, ["SELECT", "1"])
      Redix.command!(redis, ["SET", "db1_key", "db1_value"])

      Redix.command!(redis, ["SELECT", "0"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify data in both databases
      wait_happens_within 100 do
        Veidrodelis.get(@id, 0, "db0_key") == "db0_value" &&
          Veidrodelis.get(@id, 1, "db1_key") == "db1_value"
      end

      # Verify Redis data
      Redix.command!(redis, ["SELECT", "0"])
      assert Redix.command!(redis, ["GET", "db0_key"]) == "db0_value"

      Redix.command!(redis, ["SELECT", "1"])
      assert Redix.command!(redis, ["GET", "db1_key"]) == "db1_value"

      Veidrodelis.stop(pid)
    end

    test "returns error for non-implemented operations", %{redis: redis} do
      # Write data to Redis
      Redix.command!(redis, ["SADD", "myset", "member1", "member2"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Wait a bit for any potential data
      :timer.sleep(100)

      # Trying to access non-string operations should return error
      assert Veidrodelis.smembers(@id, 0, "myset") == {:error, :not_implemented}
      assert Veidrodelis.llen(@id, 0, "mylist") == {:error, :not_implemented}
      assert Veidrodelis.hget(@id, 0, "myhash", "field") == {:error, :not_implemented}
      assert Veidrodelis.zcard(@id, 0, "myzset") == {:error, :not_implemented}

      Veidrodelis.stop(pid)
    end
  end
end
