defmodule Veidrodelis.TransactionTest do
  @moduledoc """
  Smoke tests for transaction support.

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

  describe "transactions" do
    @tag timeout: 15_000
    test "basic transaction with strings", %{redis: redis} do
      opts = [id: @id, host: @redis_host, port: @redis_port]
      {:ok, vdr} = Veidrodelis.start_link(opts)

      assert_within 5000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      # Execute transaction
      Redix.command!(redis, ["SET", "__vdr_tx", "1"])
      Redix.command!(redis, ["SET", "ts_key1", "ts_value1"])
      Redix.command!(redis, ["SET", "ts_key2", "ts_value2"])
      Redix.command!(redis, ["DEL", "__vdr_tx"])

      # Verify
      assert_within 2000 do
        assert {:ok, "ts_value1"} == Veidrodelis.get(@id, 0, "ts_key1")
        assert {:ok, "ts_value2"} == Veidrodelis.get(@id, 0, "ts_key2")
      end

      assert {:ok, nil} == Veidrodelis.get(@id, 0, "__vdr_tx")

      Veidrodelis.stop(vdr)
    end

    @tag timeout: 15_000
    test "transaction with mixed data types", %{redis: redis} do
      opts = [id: @id, host: @redis_host, port: @redis_port]
      {:ok, vdr} = Veidrodelis.start_link(opts)

      assert_within 5000 do
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
      assert_within 3000 do
        assert {:ok, "ts_value"} == Veidrodelis.get(@id, 0, "ts_str")
        assert {:ok, 2} == Veidrodelis.llen(@id, 0, "ts_list")
        assert {:ok, 2} == Veidrodelis.scard(@id, 0, "ts_set")
        assert {:ok, 1} == Veidrodelis.hlen(@id, 0, "ts_hash")
        assert {:ok, 1} == Veidrodelis.zcard(@id, 0, "ts_zset")
      end

      assert {:ok, ["elem1", "elem2"]} == Veidrodelis.lrange(@id, 0, "ts_list", 0, -1)
      assert {:ok, "value1"} == Veidrodelis.hget(@id, 0, "ts_hash", "field1")

      Veidrodelis.stop(vdr)
    end
  end
end
