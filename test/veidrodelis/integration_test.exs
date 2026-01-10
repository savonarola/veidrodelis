defmodule Veidrodelis.IntegrationTest do
  @moduledoc """
  Comprehensive integration test that exercises all command types from Vdr.RedisCommand.

  This test verifies both RDB loading and streaming replication phases by:
  1. Setting up a maximally diverse dataset in Redis
  2. Connecting a veidrodelis replica
  3. Verifying all commands were replicated from RDB
  4. Issuing the same diverse set while replica is connected
  5. Verifying all commands were replicated in streaming mode

  The test has two variants:
  - Low-level: Tests the Replica module directly using a CollectorCallback
  - High-level: Tests the Veidrodelis module using its query API
  """

  use ExUnit.Case, async: false

  alias Vdr.RedisStream.Replica
  alias Vdr.RedisStream.Command, as: RedisCommand
  use CommandMatchers
  require Logger

  # Callback module that collects all commands with database info
  defmodule CollectorCallback do
    @behaviour Vdr.RedisStream.Callback

    @impl true
    def init(_opts) do
      {:ok, %{}}
    end

    @impl true
    def handle_replication_start(state) do
      {:ok, state}
    end

    @impl true
    def handle_streaming_start(state) do
      {:ok, state}
    end

    @impl true
    def handle_command(state, %Vdr.RedisStream.ReplicaCommand{db: db, command: command}) do
      commands = Map.get(state, :commands, [])
      entry = {System.monotonic_time(), db, command}
      new_state = Map.put(state, :commands, [entry | commands])
      {:ok, new_state}
    end

    def commands(state) do
      Map.get(state, :commands, [])
      |> Enum.reverse()
      |> Enum.map(fn {_ts, db, cmd} -> {db, cmd} end)
    end

    def commands_for_db(state, db) do
      commands(state)
      |> Enum.filter(fn {cmd_db, _cmd} -> cmd_db == db end)
      |> Enum.map(fn {_db, cmd} -> cmd end)
    end
  end

  # Simple identity decoder for high-level testing

  @redis_host "localhost"
  @redis_port 16378
  @id "vdr_id"

  setup do
    {:ok, redis} = Redix.start_link(host: @redis_host, port: @redis_port)
    Redix.command!(redis, ["FLUSHALL"])

    {:ok, redis: redis}
  end

  @doc """
  Issues a maximally diverse set of Redis commands covering all Vdr.RedisCommand types.
  """
  def issue_diverse_commands(redis, db \\ 0) do
    # Select database
    if db != 0 do
      Redix.command!(redis, ["SELECT", "#{db}"])
    end

    # ===== String Commands =====
    Redix.command!(redis, ["SET", "simple_key", "simple_value"])
    Redix.command!(redis, ["MSET", "mkey1", "mval1", "mkey2", "mval2"])
    Redix.command!(redis, ["SET", "append_key", "initial"])
    Redix.command!(redis, ["APPEND", "append_key", "_appended"])
    Redix.command!(redis, ["SET", "range_key", "0000000000"])
    Redix.command!(redis, ["SETRANGE", "range_key", "5", "HELLO"])
    Redix.command!(redis, ["SETBIT", "bit_key", "7", "1"])
    Redix.command!(redis, ["SETBIT", "bit_key", "15", "1"])

    # ===== List Commands =====
    Redix.command!(redis, ["RPUSH", "mylist", "elem1", "elem2", "elem3"])
    Redix.command!(redis, ["LPUSH", "mylist", "elem0"])
    Redix.command!(redis, ["LPUSH", "other_list", "initial"])
    Redix.command!(redis, ["LPUSHX", "other_list", "prepended"])
    Redix.command!(redis, ["RPUSH", "yet_another_list", "base"])
    Redix.command!(redis, ["RPUSHX", "yet_another_list", "appended"])
    Redix.command!(redis, ["RPUSH", "trim_list", "a", "b", "c", "d", "e"])
    Redix.command!(redis, ["LTRIM", "trim_list", "1", "3"])
    Redix.command!(redis, ["RPUSH", "set_list", "x", "y", "z"])
    Redix.command!(redis, ["LSET", "set_list", "1", "Y"])
    Redix.command!(redis, ["RPUSH", "insert_list", "a", "c"])
    Redix.command!(redis, ["LINSERT", "insert_list", "BEFORE", "c", "b"])
    Redix.command!(redis, ["RPUSH", "pop_list", "a", "b", "c"])
    Redix.command!(redis, ["LPOP", "pop_list"])
    Redix.command!(redis, ["RPOP", "pop_list"])
    Redix.command!(redis, ["RPUSH", "rem_list", "x", "y", "z", "y"])
    Redix.command!(redis, ["LREM", "rem_list", "1", "y"])
    Redix.command!(redis, ["RPUSH", "source_list", "s1", "s2"])
    Redix.command!(redis, ["RPUSH", "dest_list", "d1"])
    Redix.command!(redis, ["RPOPLPUSH", "source_list", "dest_list"])

    # ===== Set Commands =====
    Redix.command!(redis, ["SADD", "myset", "member1", "member2", "member3"])
    Redix.command!(redis, ["SADD", "rem_set", "m1", "m2", "m3"])
    Redix.command!(redis, ["SREM", "rem_set", "m2"])
    Redix.command!(redis, ["SADD", "set_for_move", "moving_member", "staying"])
    Redix.command!(redis, ["SADD", "move_dest_set", "existing"])
    Redix.command!(redis, ["SMOVE", "set_for_move", "move_dest_set", "moving_member"])
    Redix.command!(redis, ["SADD", "set_a", "1", "2", "3"])
    Redix.command!(redis, ["SADD", "set_b", "2", "3", "4"])
    Redix.command!(redis, ["SINTERSTORE", "set_inter", "set_a", "set_b"])
    Redix.command!(redis, ["SUNIONSTORE", "set_union", "set_a", "set_b"])
    Redix.command!(redis, ["SDIFFSTORE", "set_diff", "set_a", "set_b"])

    # ===== Sorted Set Commands =====
    Redix.command!(redis, ["ZADD", "myzset", "1.0", "member1", "2.5", "member2", "3.7", "member3"])

    Redix.command!(redis, ["ZADD", "zset_a", "1", "a", "2", "b", "3", "c"])
    Redix.command!(redis, ["ZADD", "zset_b", "2", "b", "3", "c", "4", "d"])
    Redix.command!(redis, ["ZUNIONSTORE", "zset_union", "2", "zset_a", "zset_b"])
    Redix.command!(redis, ["ZINTERSTORE", "zset_inter", "2", "zset_a", "zset_b"])
    Redix.command!(redis, ["ZADD", "zset_for_rem", "1", "x", "2", "y", "3", "z"])
    Redix.command!(redis, ["ZREM", "zset_for_rem", "y"])
    Redix.command!(redis, ["ZADD", "pop_zset", "1", "a", "2", "b", "3", "c"])
    Redix.command!(redis, ["ZPOPMAX", "pop_zset", "1"])
    Redix.command!(redis, ["ZPOPMIN", "pop_zset", "1"])
    Redix.command!(redis, ["ZADD", "remrange_zset", "1", "a", "2", "b", "3", "c", "4", "d"])
    Redix.command!(redis, ["ZREMRANGEBYRANK", "remrange_zset", "0", "1"])

    Redix.command!(redis, [
      "ZADD",
      "remrange_score_zset",
      "1",
      "a",
      "2",
      "b",
      "3",
      "c",
      "4",
      "d",
      "5",
      "e"
    ])

    Redix.command!(redis, ["ZREMRANGEBYSCORE", "remrange_score_zset", "2", "4"])
    Redix.command!(redis, ["ZADD", "remrange_lex_zset", "0", "a", "0", "b", "0", "c", "0", "d"])
    Redix.command!(redis, ["ZREMRANGEBYLEX", "remrange_lex_zset", "[a", "[c"])

    # ZINCRBY tests - note: ZINCRBY is replicated as ZADD with final score
    # Test 1: ZINCRBY on existing key with existing member
    Redix.command!(redis, ["ZADD", "zincrby_test", "10.0", "counter"])
    Redix.command!(redis, ["ZINCRBY", "zincrby_test", "5.5", "counter"])

    # Test 2: ZINCRBY on existing key with non-existing member (creates member)
    Redix.command!(redis, ["ZADD", "zincrby_test2", "1.0", "existing"])
    Redix.command!(redis, ["ZINCRBY", "zincrby_test2", "7.5", "new_member"])

    # Test 3: ZINCRBY on non-existing key (creates key and member)
    Redix.command!(redis, ["ZINCRBY", "zincrby_new_key", "42.0", "member1"])

    # Test 4: ZINCRBY with negative delta (decrement)
    Redix.command!(redis, ["ZADD", "zincrby_decr", "100.0", "score"])
    Redix.command!(redis, ["ZINCRBY", "zincrby_decr", "-25.5", "score"])

    # ===== Hash Commands =====
    Redix.command!(redis, [
      "HSET",
      "myhash",
      "field1",
      "value1",
      "field2",
      "value2",
      "field3",
      "value3"
    ])

    Redix.command!(redis, ["HSET", "hash_for_del", "f1", "v1", "f2", "v2"])
    Redix.command!(redis, ["HDEL", "hash_for_del", "f2"])

    # ===== Expiration Commands =====
    future_timestamp_ms = (System.os_time(:second) + 86400) * 1000
    Redix.command!(redis, ["SET", "expire_key", "will_expire"])
    Redix.command!(redis, ["PEXPIREAT", "expire_key", "#{future_timestamp_ms}"])

    # ===== Key Management Commands =====
    Redix.command!(redis, ["SET", "old_name", "rename_value"])
    Redix.command!(redis, ["RENAME", "old_name", "new_name"])
    Redix.command!(redis, ["SET", "renamenx_old", "value"])
    Redix.command!(redis, ["RENAMENX", "renamenx_old", "renamenx_new"])
    Redix.command!(redis, ["SET", "delete_key1", "v1"])
    Redix.command!(redis, ["SET", "delete_key2", "v2"])
    Redix.command!(redis, ["DEL", "delete_key1", "delete_key2"])

    # Ensure all data is persisted
    Redix.command!(redis, ["SAVE"])

    # Return to default database if needed
    if db != 0 do
      Redix.command!(redis, ["SELECT", "0"])
    end
  end

  @doc """
  Verifies that the replica received expected commands from RDB.

  RDB files contain the final state, not the command history. So modification commands
  like APPEND, SETRANGE, LTRIM, LPOP, RPOP, etc. are not present - only the final data.
  """
  def verify_rdb_commands(commands) do
    # String commands - only final state
    assert command_in_list(%RedisCommand.Set{key: "simple_key", value: "simple_value"}, commands),
           "Missing SET simple_key"

    # MSET might be broken down into individual SETs in RDB
    assert command_in_list(%RedisCommand.MSet{}, commands) or
             (command_in_list(%RedisCommand.Set{key: "mkey1"}, commands) and
                command_in_list(%RedisCommand.Set{key: "mkey2"}, commands)),
           "Missing MSET or individual keys from MSET"

    # Final value after APPEND - saved as a SET
    assert command_in_list(
             %RedisCommand.Set{key: "append_key", value: "initial_appended"},
             commands
           ),
           "Missing final state of append_key"

    # List commands - only final state (after all modifications)
    # mylist has LPUSH then RPUSH, final state will be present
    assert command_in_list(%RedisCommand.RPush{key: "mylist"}, commands) or
             command_in_list(%RedisCommand.LPush{key: "mylist"}, commands),
           "Missing mylist"

    # Set commands - final state
    assert command_in_list(%RedisCommand.SAdd{key: "myset"}, commands), "Missing SADD myset"
    assert command_in_list(%RedisCommand.SAdd{key: "rem_set"}, commands), "Missing SADD rem_set"

    # Set operations create result keys, but in RDB they're saved as SADDs
    assert command_in_list(%RedisCommand.SAdd{key: "set_inter"}, commands),
           "Missing set_inter result"

    assert command_in_list(%RedisCommand.SAdd{key: "set_union"}, commands),
           "Missing set_union result"

    assert command_in_list(%RedisCommand.SAdd{key: "set_diff"}, commands),
           "Missing set_diff result"

    # Sorted set commands - final state
    assert command_in_list(%RedisCommand.ZAdd{key: "myzset"}, commands), "Missing ZADD myzset"

    # Sorted set operations create result keys, but in RDB they're saved as ZADDs
    assert command_in_list(%RedisCommand.ZAdd{key: "zset_union"}, commands),
           "Missing zset_union result"

    assert command_in_list(%RedisCommand.ZAdd{key: "zset_inter"}, commands),
           "Missing zset_inter result"

    # Hash commands - final state
    assert command_in_list(%RedisCommand.HSet{key: "myhash"}, commands), "Missing HSET myhash"

    assert command_in_list(%RedisCommand.HSet{key: "hash_for_del"}, commands),
           "Missing HSET hash_for_del"

    # Expiration
    assert command_in_list(%RedisCommand.PExpireAt{key: "expire_key"}, commands),
           "Missing PEXPIREAT"

    # Key management - Renamed keys
    assert command_in_list(%RedisCommand.Set{key: "new_name"}, commands),
           "Missing renamed key new_name"

    assert command_in_list(%RedisCommand.Set{key: "renamenx_new"}, commands),
           "Missing renamenx key renamenx_new"

    # Deleted keys should not have any commands for them (checked via absence)
  end

  @doc """
  Verifies that the replica received all expected commands from streaming replication.

  In streaming mode, all commands are replicated as they happen, including modification commands.
  """
  def verify_streaming_commands(commands) do
    # String commands
    assert command_in_list(%RedisCommand.Set{key: "simple_key", value: "simple_value"}, commands),
           "Missing SET simple_key"

    assert command_in_list(%RedisCommand.MSet{}, commands), "Missing MSET"
    assert command_in_list(%RedisCommand.Append{key: "append_key"}, commands), "Missing APPEND"
    assert command_in_list(%RedisCommand.SetRange{key: "range_key"}, commands), "Missing SETRANGE"
    assert command_in_list(%RedisCommand.SetBit{key: "bit_key"}, commands), "Missing SETBIT"

    # List commands - all operations
    assert command_in_list(%RedisCommand.RPush{key: "mylist"}, commands), "Missing RPUSH mylist"
    assert command_in_list(%RedisCommand.LPush{key: "mylist"}, commands), "Missing LPUSH mylist"
    assert command_in_list(%RedisCommand.LPushX{key: "other_list"}, commands), "Missing LPUSHX"

    assert command_in_list(%RedisCommand.RPushX{key: "yet_another_list"}, commands),
           "Missing RPUSHX"

    assert command_in_list(%RedisCommand.LTrim{key: "trim_list"}, commands), "Missing LTRIM"
    assert command_in_list(%RedisCommand.LSet{key: "set_list"}, commands), "Missing LSET"
    assert command_in_list(%RedisCommand.LInsert{key: "insert_list"}, commands), "Missing LINSERT"
    assert command_in_list(%RedisCommand.LPop{key: "pop_list"}, commands), "Missing LPOP"
    assert command_in_list(%RedisCommand.RPop{key: "pop_list"}, commands), "Missing RPOP"
    assert command_in_list(%RedisCommand.LRem{key: "rem_list"}, commands), "Missing LREM"
    assert command_in_list(%RedisCommand.RPopLPush{}, commands), "Missing RPOPLPUSH"

    # Set commands
    assert command_in_list(%RedisCommand.SAdd{key: "myset"}, commands), "Missing SADD myset"
    assert command_in_list(%RedisCommand.SRem{key: "rem_set"}, commands), "Missing SREM"
    assert command_in_list(%RedisCommand.SMove{}, commands), "Missing SMOVE"
    assert command_in_list(%RedisCommand.SInterStore{}, commands), "Missing SINTERSTORE"
    assert command_in_list(%RedisCommand.SUnionStore{}, commands), "Missing SUNIONSTORE"
    assert command_in_list(%RedisCommand.SDiffStore{}, commands), "Missing SDIFFSTORE"

    # Sorted set commands
    assert command_in_list(%RedisCommand.ZAdd{key: "myzset"}, commands), "Missing ZADD myzset"
    assert command_in_list(%RedisCommand.ZUnionStore{}, commands), "Missing ZUNIONSTORE"
    assert command_in_list(%RedisCommand.ZInterStore{}, commands), "Missing ZINTERSTORE"
    assert command_in_list(%RedisCommand.ZRem{key: "zset_for_rem"}, commands), "Missing ZREM"
    assert command_in_list(%RedisCommand.ZPopMax{key: "pop_zset"}, commands), "Missing ZPOPMAX"
    assert command_in_list(%RedisCommand.ZPopMin{key: "pop_zset"}, commands), "Missing ZPOPMIN"

    assert command_in_list(%RedisCommand.ZRemRangeByRank{key: "remrange_zset"}, commands),
           "Missing ZREMRANGEBYRANK"

    assert command_in_list(%RedisCommand.ZRemRangeByScore{key: "remrange_score_zset"}, commands),
           "Missing ZREMRANGEBYSCORE"

    assert command_in_list(%RedisCommand.ZRemRangeByLex{key: "remrange_lex_zset"}, commands),
           "Missing ZREMRANGEBYLEX"

    # Hash commands
    assert command_in_list(%RedisCommand.HSet{key: "myhash"}, commands), "Missing HSET myhash"
    assert command_in_list(%RedisCommand.HDel{key: "hash_for_del"}, commands), "Missing HDEL"

    # Expiration
    assert command_in_list(%RedisCommand.PExpireAt{key: "expire_key"}, commands),
           "Missing PEXPIREAT"

    # Key management
    assert command_in_list(%RedisCommand.Rename{}, commands), "Missing RENAME"
    assert command_in_list(%RedisCommand.RenameNX{}, commands), "Missing RENAMENX"
    assert command_in_list(%RedisCommand.Del{}, commands), "Missing DEL"
  end

  # ===== Low-level Replica Tests =====

  describe "low-level replica: comprehensive command replication" do
    @tag timeout: 30_000
    test "replicates all command types from RDB and streaming", %{redis: redis} do
      Logger.info("=== [Replica] Phase 1: Setting up diverse dataset in DB 0 ===")
      issue_diverse_commands(redis, 0)

      Process.sleep(100)

      Logger.info("=== [Replica] Phase 2: Starting replica and waiting for RDB sync ===")

      opts = [
        host: @redis_host,
        port: @redis_port,
        callback_module: CollectorCallback,
        callback_state: %{commands: []}
      ]

      {:ok, replica} = Replica.start_link(opts)

      assert_within 5000 do
        assert :streaming == Replica.get_replication_state(replica)
      end

      Logger.info("=== [Replica] Phase 3: Verifying RDB commands ===")

      callback_state = Replica.get_callback_state(replica)
      db0_commands = CollectorCallback.commands_for_db(callback_state, 0)

      Logger.info("Received #{length(db0_commands)} commands from RDB")
      verify_rdb_commands(db0_commands)

      Logger.info("=== [Replica] Phase 4: Issuing commands to DB 1 while streaming ===")

      issue_diverse_commands(redis, 1)

      assert_within 3000 do
        callback_state = Replica.get_callback_state(replica)
        db1_commands = CollectorCallback.commands_for_db(callback_state, 1)
        assert 50 < length(db1_commands)
      end

      Logger.info("=== [Replica] Phase 5: Verifying streaming commands ===")

      callback_state = Replica.get_callback_state(replica)
      db1_commands = CollectorCallback.commands_for_db(callback_state, 1)

      Logger.info("Received #{length(db1_commands)} commands from streaming")
      verify_streaming_commands(db1_commands)

      Logger.info("=== [Replica] Test completed successfully ===")

      Replica.stop(replica)
    end
  end

  # ===== High-level Veidrodelis Tests =====

  describe "high-level veidrodelis: comprehensive data verification" do
    @tag timeout: 30_000
    test "verifies all data types from RDB and streaming via query API", %{redis: redis} do
      Logger.info("=== [Veidrodelis] Phase 1: Setting up diverse dataset in DB 0 ===")
      issue_diverse_commands(redis, 0)

      Process.sleep(100)

      Logger.info("=== [Veidrodelis] Phase 2: Starting Veidrodelis and waiting for RDB sync ===")

      opts = [
        id: @id,
        host: @redis_host,
        port: @redis_port
      ]

      {:ok, vdr} = Veidrodelis.start_link(opts)

      assert_within 5000 do
        assert :streaming == Veidrodelis.get_replication_state(vdr)
      end

      Logger.info("=== [Veidrodelis] Phase 3: Verifying RDB data via query API ===")

      # Wait for data to be fully processed
      Process.sleep(200)

      # String values
      assert "simple_value" == Veidrodelis.get(@id, 0, "simple_key")
      assert "mval1" == Veidrodelis.get(@id, 0, "mkey1")
      assert "mval2" == Veidrodelis.get(@id, 0, "mkey2")
      assert "initial_appended" == Veidrodelis.get(@id, 0, "append_key")
      assert "rename_value" == Veidrodelis.get(@id, 0, "new_name")
      assert "value" == Veidrodelis.get(@id, 0, "renamenx_new")
      assert "will_expire" == Veidrodelis.get(@id, 0, "expire_key")

      # Deleted keys should not exist
      assert nil == Veidrodelis.get(@id, 0, "delete_key1")
      assert nil == Veidrodelis.get(@id, 0, "delete_key2")
      assert nil == Veidrodelis.get(@id, 0, "old_name")

      # List values
      assert 4 == Veidrodelis.llen(@id, 0, "mylist")
      assert ["elem0", "elem1", "elem2", "elem3"] == Veidrodelis.lrange(@id, 0, "mylist", 0, -1)
      assert ["b", "c", "d"] == Veidrodelis.lrange(@id, 0, "trim_list", 0, -1)
      assert ["x", "Y", "z"] == Veidrodelis.lrange(@id, 0, "set_list", 0, -1)
      assert ["a", "b", "c"] == Veidrodelis.lrange(@id, 0, "insert_list", 0, -1)

      # After LPOP and RPOP, pop_list should have only "b"
      assert ["b"] == Veidrodelis.lrange(@id, 0, "pop_list", 0, -1)

      # Set values
      assert 3 == Veidrodelis.scard(@id, 0, "myset")
      members = Veidrodelis.smembers(@id, 0, "myset")
      assert "member1" in members
      assert "member2" in members
      assert "member3" in members

      # rem_set should have m1 and m3 (m2 was removed)
      assert 2 == Veidrodelis.scard(@id, 0, "rem_set")
      rem_members = Veidrodelis.smembers(@id, 0, "rem_set")
      assert "m1" in rem_members
      assert "m3" in rem_members
      refute "m2" in rem_members

      # Set operations
      inter_members = Veidrodelis.smembers(@id, 0, "set_inter")
      assert "2" in inter_members
      assert "3" in inter_members
      assert 4 == Veidrodelis.scard(@id, 0, "set_union")
      assert 1 == Veidrodelis.scard(@id, 0, "set_diff")

      # Hash values
      assert 3 == Veidrodelis.hlen(@id, 0, "myhash")
      assert "value1" == Veidrodelis.hget(@id, 0, "myhash", "field1")
      assert "value2" == Veidrodelis.hget(@id, 0, "myhash", "field2")
      assert "value3" == Veidrodelis.hget(@id, 0, "myhash", "field3")

      # hash_for_del should have only f1 (f2 was deleted)
      assert 1 == Veidrodelis.hlen(@id, 0, "hash_for_del")
      assert "v1" == Veidrodelis.hget(@id, 0, "hash_for_del", "f1")
      assert nil == Veidrodelis.hget(@id, 0, "hash_for_del", "f2")

      # Sorted set values
      assert 3 == Veidrodelis.zcard(@id, 0, "myzset")
      assert 1.0 == Veidrodelis.zscore(@id, 0, "myzset", "member1")
      assert 2.5 == Veidrodelis.zscore(@id, 0, "myzset", "member2")
      assert 3.7 == Veidrodelis.zscore(@id, 0, "myzset", "member3")

      # zset_for_rem should have x and z (y was removed)
      assert 2 == Veidrodelis.zcard(@id, 0, "zset_for_rem")
      assert 1.0 == Veidrodelis.zscore(@id, 0, "zset_for_rem", "x")
      assert 3.0 == Veidrodelis.zscore(@id, 0, "zset_for_rem", "z")
      assert nil == Veidrodelis.zscore(@id, 0, "zset_for_rem", "y")

      # pop_zset should have only "b" after ZPOPMAX and ZPOPMIN
      assert 1 == Veidrodelis.zcard(@id, 0, "pop_zset")
      assert 2.0 == Veidrodelis.zscore(@id, 0, "pop_zset", "b")

      # Verify set/zset operations created correct results
      assert Veidrodelis.zcard(@id, 0, "zset_union") > 0
      assert Veidrodelis.zcard(@id, 0, "zset_inter") > 0

      # Verify ZINCRBY results (replicated as ZADD with final scores)
      # Test 1: existing key, existing member (10.0 + 5.5 = 15.5)
      assert 15.5 == Veidrodelis.zscore(@id, 0, "zincrby_test", "counter")

      # Test 2: existing key, non-existing member (0 + 7.5 = 7.5)
      assert 2 == Veidrodelis.zcard(@id, 0, "zincrby_test2")
      assert 1.0 == Veidrodelis.zscore(@id, 0, "zincrby_test2", "existing")
      assert 7.5 == Veidrodelis.zscore(@id, 0, "zincrby_test2", "new_member")

      # Test 3: non-existing key (creates key with member at score 42.0)
      assert 1 == Veidrodelis.zcard(@id, 0, "zincrby_new_key")
      assert 42.0 == Veidrodelis.zscore(@id, 0, "zincrby_new_key", "member1")

      # Test 4: negative delta (100.0 - 25.5 = 74.5)
      assert 74.5 == Veidrodelis.zscore(@id, 0, "zincrby_decr", "score")

      Logger.info("=== [Veidrodelis] Phase 4: Issuing commands to DB 1 while streaming ===")

      issue_diverse_commands(redis, 1)

      # Wait for streaming replication
      assert_within 3000 do
        assert "simple_value" == Veidrodelis.get(@id, 1, "simple_key")
        assert 4 == Veidrodelis.llen(@id, 1, "mylist")
        assert 3 == Veidrodelis.scard(@id, 1, "myset")
        assert 3 == Veidrodelis.hlen(@id, 1, "myhash")
        assert 3 == Veidrodelis.zcard(@id, 1, "myzset")
      end

      Logger.info("=== [Veidrodelis] Phase 5: Verifying streaming data via query API ===")

      # String values
      assert "simple_value" == Veidrodelis.get(@id, 1, "simple_key")
      assert "mval1" == Veidrodelis.get(@id, 1, "mkey1")
      assert "initial_appended" == Veidrodelis.get(@id, 1, "append_key")

      # List values
      assert 4 == Veidrodelis.llen(@id, 1, "mylist")
      assert ["elem0", "elem1", "elem2", "elem3"] == Veidrodelis.lrange(@id, 1, "mylist", 0, -1)

      # Set values
      assert 3 == Veidrodelis.scard(@id, 1, "myset")
      members_db1 = Veidrodelis.smembers(@id, 1, "myset")
      assert "member1" in members_db1
      assert "member2" in members_db1
      assert "member3" in members_db1

      # Hash values
      assert 3 == Veidrodelis.hlen(@id, 1, "myhash")
      assert "value1" == Veidrodelis.hget(@id, 1, "myhash", "field1")

      # Sorted set values
      assert 3 == Veidrodelis.zcard(@id, 1, "myzset")
      assert 1.0 == Veidrodelis.zscore(@id, 1, "myzset", "member1")

      # Verify ZINCRBY results in DB 1 (streaming replication)
      assert 15.5 == Veidrodelis.zscore(@id, 1, "zincrby_test", "counter")
      assert 7.5 == Veidrodelis.zscore(@id, 1, "zincrby_test2", "new_member")
      assert 42.0 == Veidrodelis.zscore(@id, 1, "zincrby_new_key", "member1")
      assert 74.5 == Veidrodelis.zscore(@id, 1, "zincrby_decr", "score")

      Logger.info("=== [Veidrodelis] Test completed successfully ===")

      Veidrodelis.stop(vdr)
    end
  end

end
