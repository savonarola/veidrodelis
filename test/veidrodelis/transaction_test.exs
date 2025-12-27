defmodule Veidrodelis.TransactionTest do
  @moduledoc """
  Smoke tests for transaction support in MapProj and TSProj.

  Transactions are controlled via special SET and DEL commands on the key "__vdr_tx":
  - SET __vdr_tx: Start buffering commands instead of executing them
  - DEL __vdr_tx: Apply all buffered commands and clear the transaction buffer
  - On disconnect: Drop the transaction buffer
  """

  use ExUnit.Case, async: false
  use CommandMatchers
  require Logger

  @redis_host "localhost"
  @redis_port 16378
  @id "vdr_tx_test"

  setup do
    {:ok, redis} = Redix.start_link(host: @redis_host, port: @redis_port)
    Redix.command!(redis, ["FLUSHALL"])
    {:ok, redis: redis}
  end

  describe "MapProj transactions" do
    @tag timeout: 15_000
    test "basic transaction with strings", %{redis: redis} do
      opts = [id: @id, host: @redis_host, port: @redis_port]
      {:ok, vdr} = Veidrodelis.start_link(opts)

      assert_happens_within 5000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      # Execute transaction
      Redix.command!(redis, ["SET", "__vdr_tx", "1"])
      Redix.command!(redis, ["SET", "key1", "value1"])
      Redix.command!(redis, ["SET", "key2", "value2"])
      Redix.command!(redis, ["DEL", "__vdr_tx"])

      # Verify
      assert_happens_within 2000 do
        Veidrodelis.get(@id, 0, "key1") == "value1" &&
          Veidrodelis.get(@id, 0, "key2") == "value2"
      end

      assert Veidrodelis.get(@id, 0, "__vdr_tx") == nil

      Veidrodelis.stop(vdr)
    end

    @tag timeout: 15_000
    test "transaction with mixed data types", %{redis: redis} do
      opts = [id: @id, host: @redis_host, port: @redis_port]
      {:ok, vdr} = Veidrodelis.start_link(opts)

      assert_happens_within 5000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      # Execute transaction with multiple data types
      Redix.command!(redis, ["SET", "__vdr_tx", "1"])
      Redix.command!(redis, ["SET", "str_key", "str_value"])
      Redix.command!(redis, ["RPUSH", "list_key", "elem1", "elem2"])
      Redix.command!(redis, ["SADD", "set_key", "member1", "member2"])
      Redix.command!(redis, ["HSET", "hash_key", "field1", "value1", "field2", "value2"])
      Redix.command!(redis, ["ZADD", "zset_key", "1.0", "member1", "2.0", "member2"])
      Redix.command!(redis, ["DEL", "__vdr_tx"])

      # Verify all data types
      assert_happens_within 3000 do
        Veidrodelis.get(@id, 0, "str_key") == "str_value" &&
          Veidrodelis.llen(@id, 0, "list_key") == 2 &&
          Veidrodelis.scard(@id, 0, "set_key") == 2 &&
          Veidrodelis.hlen(@id, 0, "hash_key") == 2 &&
          Veidrodelis.zcard(@id, 0, "zset_key") == 2
      end

      assert Veidrodelis.lrange(@id, 0, "list_key", 0, -1) == ["elem1", "elem2"]
      assert Veidrodelis.hget(@id, 0, "hash_key", "field1") == "value1"
      assert Veidrodelis.zscore(@id, 0, "zset_key", "member1") == 1.0

      Veidrodelis.stop(vdr)
    end

    @tag timeout: 15_000
    test "DEL __vdr_tx with multiple keys", %{redis: redis} do
      opts = [id: @id, host: @redis_host, port: @redis_port]
      {:ok, vdr} = Veidrodelis.start_link(opts)

      assert_happens_within 5000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      # Set up some keys first
      Redix.command!(redis, ["SET", "pre_key1", "pre_value1"])
      Redix.command!(redis, ["SET", "pre_key2", "pre_value2"])

      Process.sleep(100)

      # Transaction that deletes keys
      Redix.command!(redis, ["SET", "__vdr_tx", "1"])
      Redix.command!(redis, ["SET", "tx_key", "tx_value"])
      Redix.command!(redis, ["DEL", "pre_key1"])
      Redix.command!(redis, ["DEL", "__vdr_tx", "pre_key2"])

      # Verify
      assert_happens_within 2000 do
        Veidrodelis.get(@id, 0, "tx_key") == "tx_value" &&
          Veidrodelis.get(@id, 0, "pre_key1") == nil &&
          Veidrodelis.get(@id, 0, "pre_key2") == nil
      end

      Veidrodelis.stop(vdr)
    end

    @tag timeout: 15_000
    test "empty transaction", %{redis: redis} do
      opts = [id: @id, host: @redis_host, port: @redis_port]
      {:ok, vdr} = Veidrodelis.start_link(opts)

      assert_happens_within 5000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      # Empty transaction
      Redix.command!(redis, ["SET", "__vdr_tx", "1"])
      Redix.command!(redis, ["DEL", "__vdr_tx"])

      Process.sleep(200)

      # Should not crash
      assert Veidrodelis.get(@id, 0, "__vdr_tx") == nil

      Veidrodelis.stop(vdr)
    end

    @tag timeout: 15_000
    test "multiple sequential transactions", %{redis: redis} do
      opts = [id: @id, host: @redis_host, port: @redis_port]
      {:ok, vdr} = Veidrodelis.start_link(opts)

      assert_happens_within 5000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      # First transaction
      Redix.command!(redis, ["SET", "__vdr_tx", "1"])
      Redix.command!(redis, ["SET", "tx1_key", "tx1_value"])
      Redix.command!(redis, ["DEL", "__vdr_tx"])

      assert_happens_within 2000 do
        Veidrodelis.get(@id, 0, "tx1_key") == "tx1_value"
      end

      # Second transaction
      Redix.command!(redis, ["SET", "__vdr_tx", "2"])
      Redix.command!(redis, ["SET", "tx2_key", "tx2_value"])
      Redix.command!(redis, ["DEL", "__vdr_tx"])

      assert_happens_within 2000 do
        Veidrodelis.get(@id, 0, "tx2_key") == "tx2_value"
      end

      assert Veidrodelis.get(@id, 0, "tx1_key") == "tx1_value"
      assert Veidrodelis.get(@id, 0, "tx2_key") == "tx2_value"

      Veidrodelis.stop(vdr)
    end
  end

  describe "TSProj transactions" do
    @tag timeout: 15_000
    test "basic transaction with strings", %{redis: redis} do
      opts = [id: @id, host: @redis_host, port: @redis_port, impl: {Vdr.TSProj, []}]
      {:ok, vdr} = Veidrodelis.start_link(opts)

      assert_happens_within 5000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      # Execute transaction
      Redix.command!(redis, ["SET", "__vdr_tx", "1"])
      Redix.command!(redis, ["SET", "ts_key1", "ts_value1"])
      Redix.command!(redis, ["SET", "ts_key2", "ts_value2"])
      Redix.command!(redis, ["DEL", "__vdr_tx"])

      # Verify
      assert_happens_within 2000 do
        Veidrodelis.get(@id, 0, "ts_key1") == "ts_value1" &&
          Veidrodelis.get(@id, 0, "ts_key2") == "ts_value2"
      end

      assert Veidrodelis.get(@id, 0, "__vdr_tx") == nil

      Veidrodelis.stop(vdr)
    end

    @tag timeout: 15_000
    test "transaction with mixed data types", %{redis: redis} do
      opts = [id: @id, host: @redis_host, port: @redis_port, impl: {Vdr.TSProj, []}]
      {:ok, vdr} = Veidrodelis.start_link(opts)

      assert_happens_within 5000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      # Execute transaction
      Redix.command!(redis, ["SET", "__vdr_tx", "1"])
      Redix.command!(redis, ["SET", "ts_str", "ts_value"])
      Redix.command!(redis, ["RPUSH", "ts_list", "elem1", "elem2"])
      Redix.command!(redis, ["SADD", "ts_set", "member1", "member2"])
      Redix.command!(redis, ["HSET", "ts_hash", "field1", "value1"])
      Redix.command!(redis, ["ZADD", "ts_zset", "1.0", "member1"])
      Redix.command!(redis, ["DEL", "__vdr_tx"])

      # Verify
      assert_happens_within 3000 do
        Veidrodelis.get(@id, 0, "ts_str") == "ts_value" &&
          Veidrodelis.llen(@id, 0, "ts_list") == 2 &&
          Veidrodelis.scard(@id, 0, "ts_set") == 2 &&
          Veidrodelis.hlen(@id, 0, "ts_hash") == 1 &&
          Veidrodelis.zcard(@id, 0, "ts_zset") == 1
      end

      assert Veidrodelis.lrange(@id, 0, "ts_list", 0, -1) == ["elem1", "elem2"]
      assert Veidrodelis.hget(@id, 0, "ts_hash", "field1") == "value1"

      Veidrodelis.stop(vdr)
    end
  end
end
