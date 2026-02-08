defmodule VeidrodelisTest do
  use ExUnit.Case, async: false

  require Logger

  use CommandMatchers

  @redis_host "localhost"
  @redis_port 16378
  @id "vdr_id"

  @veidrodelis_base_opts [
    id: @id,
    host: @redis_host,
    port: @redis_port
  ]

  def veidrodelis_opts(opts \\ []) do
    @veidrodelis_base_opts ++ opts
  end

  setup do
    # Ensure Redis is running
    {:ok, redis} = Redix.start_link(host: @redis_host, port: @redis_port)

    # Flush all databases before each test
    Redix.command!(redis, ["FLUSHALL"])

    {:ok, redis: redis}
  end

  describe "tx/3" do
    test "smoke test for Lua execution", %{redis: redis} do
      id = :"test_tx_#{:erlang.unique_integer([:positive])}"

      {:ok, _pid} =
        Veidrodelis.start_link(
          id: id,
          host: @redis_host,
          port: @redis_port
        )

      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(id)
      end

      # Test basic script execution (returns proper type now)
      assert {:ok, 42} = Veidrodelis.read_tx(id, 0, "return 42")

      # Test ts.get access to replicated data
      Redix.command!(redis, ["SET", "lua_key", "lua_value"])

      assert_within 500 do
        assert {:ok, "lua_value"} == Veidrodelis.get(id, 0, "lua_key")
      end

      script = "return ts.get('lua_key')"
      assert {:ok, "lua_value"} = Veidrodelis.read_tx(id, 0, script)
    end
  end

  describe "read_tx/3 with command list" do
    test "executes multiple read commands atomically", %{redis: redis} do
      id = :"test_read_tx_list_#{:erlang.unique_integer([:positive])}"

      # Set up test data
      Redix.command!(redis, ["SET", "key1", "value1"])
      Redix.command!(redis, ["SET", "key2", "value2"])
      Redix.command!(redis, ["HSET", "hash1", "field1", "hvalue1", "field2", "hvalue2"])

      {:ok, _pid} =
        Veidrodelis.start_link(
          id: id,
          host: @redis_host,
          port: @redis_port
        )

      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(id)
      end

      # Wait for data to replicate
      assert_within 500 do
        assert {:ok, "value1"} == Veidrodelis.get(id, 0, "key1")
      end

      # Execute multiple read commands atomically
      assert {:ok, [val1, val2, hval1]} =
               Veidrodelis.read_tx(id, 0, [
                 {:get, "key1"},
                 {:get, "key2"},
                 {:hget, "hash1", "field1"}
               ])

      assert val1 == {:ok, "value1"}
      assert val2 == {:ok, "value2"}
      assert hval1 == {:ok, "hvalue1"}
    end

    test "handles mixed data types in single transaction", %{redis: redis} do
      id = :"test_read_tx_mixed_#{:erlang.unique_integer([:positive])}"

      # Set up diverse test data
      Redix.command!(redis, ["SET", "str_key", "string_value"])
      Redix.command!(redis, ["RPUSH", "list_key", "item1", "item2", "item3"])
      Redix.command!(redis, ["SADD", "set_key", "member1", "member2"])
      Redix.command!(redis, ["HSET", "hash_key", "f1", "v1", "f2", "v2"])
      Redix.command!(redis, ["ZADD", "zset_key", "1.0", "a", "2.0", "b", "3.0", "c"])

      {:ok, _pid} =
        Veidrodelis.start_link(
          id: id,
          host: @redis_host,
          port: @redis_port
        )

      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(id)
      end

      # Wait for data to replicate
      assert_within 500 do
        assert {:ok, "string_value"} == Veidrodelis.get(id, 0, "str_key")
      end

      # Execute mixed read commands
      assert {:ok, [str_val, list_len, set_card, hash_val, zset_card]} =
               Veidrodelis.read_tx(id, 0, [
                 {:get, "str_key"},
                 {:llen, "list_key"},
                 {:scard, "set_key"},
                 {:hget, "hash_key", "f1"},
                 {:zcard, "zset_key"}
               ])

      assert str_val == {:ok, "string_value"}
      assert list_len == {:ok, 3}
      assert set_card == {:ok, 2}
      assert hash_val == {:ok, "v1"}
      assert zset_card == {:ok, 3}
    end

    test "returns nil for non-existent keys", %{redis: redis} do
      id = :"test_read_tx_nil_#{:erlang.unique_integer([:positive])}"

      Redix.command!(redis, ["SET", "existing_key", "exists"])

      {:ok, _pid} =
        Veidrodelis.start_link(
          id: id,
          host: @redis_host,
          port: @redis_port
        )

      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(id)
      end

      assert_within 500 do
        assert {:ok, "exists"} == Veidrodelis.get(id, 0, "existing_key")
      end

      # Mix of existing and non-existing keys
      assert {:ok, [val1, val2, val3]} =
               Veidrodelis.read_tx(id, 0, [
                 {:get, "existing_key"},
                 {:get, "nonexistent_key"},
                 {:hget, "nonexistent_hash", "field"}
               ])

      assert val1 == {:ok, "exists"}
      assert val2 == {:ok, nil}
      assert val3 == {:ok, nil}
    end

    test "rejects write commands with readonly_violation error", %{redis: redis} do
      id = :"test_read_tx_readonly_#{:erlang.unique_integer([:positive])}"

      Redix.command!(redis, ["SET", "some_key", "some_value"])

      {:ok, _pid} =
        Veidrodelis.start_link(
          id: id,
          host: @redis_host,
          port: @redis_port
        )

      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(id)
      end

      # Attempt to include a write command - returns readonly_violation for that command
      assert {:ok, [get_result, set_result]} =
               Veidrodelis.read_tx(id, 0, [
                 {:get, "some_key"},
                 {:set, "new_key", "new_value"}
               ])

      assert get_result == {:ok, "some_value"}
      assert set_result == {:error, "Unknown read command"}
    end

    test "handles empty command list", %{redis: _redis} do
      id = :"test_read_tx_empty_#{:erlang.unique_integer([:positive])}"

      {:ok, _pid} =
        Veidrodelis.start_link(
          id: id,
          host: @redis_host,
          port: @redis_port
        )

      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(id)
      end

      # Empty command list should return empty results
      assert {:ok, []} = Veidrodelis.read_tx(id, 0, [])
    end

    test "works with hmget for multiple hash fields", %{redis: redis} do
      id = :"test_read_tx_hmget_#{:erlang.unique_integer([:positive])}"

      Redix.command!(redis, ["HSET", "user:1", "name", "Alice", "age", "30", "city", "NYC"])

      {:ok, _pid} =
        Veidrodelis.start_link(
          id: id,
          host: @redis_host,
          port: @redis_port
        )

      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(id)
      end

      assert_within 500 do
        assert {:ok, "Alice"} == Veidrodelis.hget(id, 0, "user:1", "name")
      end

      # Use hmget in read_tx
      assert {:ok, [values]} =
               Veidrodelis.read_tx(id, 0, [
                 {:hmget, "user:1", ["name", "age", "nonexistent"]}
               ])

      assert values == {:ok, ["Alice", "30", nil]}
    end
  end

  describe "replication state fetching" do
    @tag :slow

    def acc_status(id, deadline, acc \\ %{}) do
      if deadline < :os.system_time(:millisecond) do
        acc
      else
        try do
          status = Veidrodelis.get_replication_state(id)
          acc_status(id, deadline, Map.put(acc, status, true))
        catch
          _, _ ->
            acc_status(id, deadline, acc)
        end
      end
    end

    test "fetches replication state" do
      id = :"test_status_fetching_#{:erlang.unique_integer([:positive])}"

      spawn_link(fn ->
        {:ok, _pid} =
          Veidrodelis.start_link(
            id: id,
            host: @redis_host,
            port: @redis_port
          )

        Process.sleep(:infinity)
      end)

      statuses = acc_status(id, :os.system_time(:millisecond) + 2000)
      assert %{streaming: true} = statuses

      statuses
      |> Map.keys()
      |> Enum.each(fn status ->
        assert status in [
                 :init,
                 :ping,
                 :auth,
                 :replconf_listening_port,
                 :replconf_capa,
                 :psync,
                 :rdb_transfer,
                 :streaming
               ]
      end)
    end
  end
end
