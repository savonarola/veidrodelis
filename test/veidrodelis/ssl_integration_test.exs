defmodule Veidrodelis.SSLIntegrationTest do
  @moduledoc """
  Integration test verifying SSL/TLS replication works correctly.

  Tests that Veidrodelis can:
  1. Connect to a Redis/Valkey server over SSL
  2. Replicate data from RDB over SSL
  3. Stream commands over SSL
  """

  use ExUnit.Case, async: false
  use CommandMatchers
  require Logger

  @ssl_port 16382
  @ssl_dir Path.expand("../assets/ssl", __DIR__)

  @tag :ssl
  @tag timeout: 30_000
  test "replicates data over SSL connection" do
    # SSL connection options
    ssl_opts = [
      verify: :verify_peer,
      cacertfile: Path.join(@ssl_dir, "ca-cert.pem"),
      certfile: Path.join(@ssl_dir, "client-cert.pem"),
      keyfile: Path.join(@ssl_dir, "client-key.pem"),
      server_name_indication: ~c"localhost",
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]

    conn_opts = [
      host: "localhost",
      port: @ssl_port,
      ssl: true,
      socket_opts: ssl_opts
    ]

    Logger.info("=== [SSL Test] Connecting to Valkey over SSL on port #{@ssl_port} ===")

    # Connect to Redis/Valkey with SSL
    {:ok, redis} = Redix.start_link(conn_opts)

    # Clean up
    Redix.command!(redis, ["FLUSHALL"])

    Logger.info("=== [SSL Test] Phase 1: Setting up test data ===")

    # Issue some test commands
    Redix.command!(redis, ["SET", "ssl_test_key", "ssl_test_value"])
    Redix.command!(redis, ["RPUSH", "ssl_test_list", "item1", "item2", "item3"])
    Redix.command!(redis, ["SADD", "ssl_test_set", "member1", "member2"])
    Redix.command!(redis, ["ZADD", "ssl_test_zset", "1.0", "elem1", "2.0", "elem2"])
    Redix.command!(redis, ["HSET", "ssl_test_hash", "field1", "value1", "field2", "value2"])

    # Ensure data is persisted
    Redix.command!(redis, ["SAVE"])

    Logger.info("=== [SSL Test] Phase 2: Starting Veidrodelis replica with SSL ===")

    # Start Veidrodelis with SSL
    id = "ssl_test_replica"

    replica_opts = [
      id: id
    ] ++ conn_opts

    {:ok, pid} = Veidrodelis.start_link(replica_opts)

    # Wait for replica to sync
    assert_within 5000 do
      assert :streaming == Veidrodelis.get_replication_state(id)
    end

    Logger.info("=== [SSL Test] Phase 3: Verifying replicated data ===")

    # Verify string
    assert {:ok, "ssl_test_value"} == Veidrodelis.get(id, 0, "ssl_test_key")

    # Verify list
    assert {:ok, ["item1", "item2", "item3"]} ==
             Veidrodelis.lrange(id, 0, "ssl_test_list", 0, -1)

    # Verify set
    {:ok, set_members} = Veidrodelis.smembers(id, 0, "ssl_test_set")
    assert MapSet.new(set_members) == MapSet.new(["member1", "member2"])

    # Verify sorted set
    assert {:ok, [{"elem1", 1.0}, {"elem2", 2.0}]} ==
             Veidrodelis.zrange(id, 0, "ssl_test_zset", 0, -1, true)

    # Verify hash
    {:ok, hash_result} = Veidrodelis.hgetall(id, 0, "ssl_test_hash")
    assert Map.new(hash_result) == %{"field1" => "value1", "field2" => "value2"}

    Logger.info("=== [SSL Test] Phase 4: Testing streaming replication over SSL ===")

    # Issue more commands while replica is connected
    Redix.command!(redis, ["SET", "streaming_ssl_key", "streaming_value"])
    Redix.command!(redis, ["RPUSH", "streaming_ssl_list", "new_item"])

    # Wait a bit for commands to replicate
    Process.sleep(100)

    # Verify streaming commands were replicated
    assert {:ok, "streaming_value"} == Veidrodelis.get(id, 0, "streaming_ssl_key")
    assert {:ok, ["new_item"]} == Veidrodelis.lrange(id, 0, "streaming_ssl_list", 0, -1)

    Logger.info("=== [SSL Test] SUCCESS: All data replicated correctly over SSL ===")

    # Cleanup
    Veidrodelis.stop(pid)
    Redix.stop(redis)
  end
end
