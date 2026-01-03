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

      assert_happens_within 5000 do
        Replica.get_replication_state(replica) == :streaming
      end

      Logger.info("=== [Replica] Phase 3: Verifying RDB commands ===")

      callback_state = Replica.get_callback_state(replica)
      db0_commands = CollectorCallback.commands_for_db(callback_state, 0)

      Logger.info("Received #{length(db0_commands)} commands from RDB")
      verify_rdb_commands(db0_commands)

      Logger.info("=== [Replica] Phase 4: Issuing commands to DB 1 while streaming ===")

      issue_diverse_commands(redis, 1)

      assert_happens_within 3000 do
        callback_state = Replica.get_callback_state(replica)
        db1_commands = CollectorCallback.commands_for_db(callback_state, 1)
        length(db1_commands) > 50
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

      assert_happens_within 5000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      Logger.info("=== [Veidrodelis] Phase 3: Verifying RDB data via query API ===")

      # Wait for data to be fully processed
      Process.sleep(200)

      # String values
      assert Veidrodelis.get(@id, 0, "simple_key") == "simple_value"
      assert Veidrodelis.get(@id, 0, "mkey1") == "mval1"
      assert Veidrodelis.get(@id, 0, "mkey2") == "mval2"
      assert Veidrodelis.get(@id, 0, "append_key") == "initial_appended"
      assert Veidrodelis.get(@id, 0, "new_name") == "rename_value"
      assert Veidrodelis.get(@id, 0, "renamenx_new") == "value"
      assert Veidrodelis.get(@id, 0, "expire_key") == "will_expire"

      # Deleted keys should not exist
      assert Veidrodelis.get(@id, 0, "delete_key1") == nil
      assert Veidrodelis.get(@id, 0, "delete_key2") == nil
      assert Veidrodelis.get(@id, 0, "old_name") == nil

      # List values
      assert Veidrodelis.llen(@id, 0, "mylist") == 4
      assert Veidrodelis.lrange(@id, 0, "mylist", 0, -1) == ["elem0", "elem1", "elem2", "elem3"]
      assert Veidrodelis.lrange(@id, 0, "trim_list", 0, -1) == ["b", "c", "d"]
      assert Veidrodelis.lrange(@id, 0, "set_list", 0, -1) == ["x", "Y", "z"]
      assert Veidrodelis.lrange(@id, 0, "insert_list", 0, -1) == ["a", "b", "c"]

      # After LPOP and RPOP, pop_list should have only "b"
      assert Veidrodelis.lrange(@id, 0, "pop_list", 0, -1) == ["b"]

      # Set values
      assert Veidrodelis.scard(@id, 0, "myset") == 3
      members = Veidrodelis.smembers(@id, 0, "myset")
      assert "member1" in members
      assert "member2" in members
      assert "member3" in members

      # rem_set should have m1 and m3 (m2 was removed)
      assert Veidrodelis.scard(@id, 0, "rem_set") == 2
      rem_members = Veidrodelis.smembers(@id, 0, "rem_set")
      assert "m1" in rem_members
      assert "m3" in rem_members
      refute "m2" in rem_members

      # Set operations
      inter_members = Veidrodelis.smembers(@id, 0, "set_inter")
      assert "2" in inter_members
      assert "3" in inter_members
      assert Veidrodelis.scard(@id, 0, "set_union") == 4
      assert Veidrodelis.scard(@id, 0, "set_diff") == 1

      # Hash values
      assert Veidrodelis.hlen(@id, 0, "myhash") == 3
      assert Veidrodelis.hget(@id, 0, "myhash", "field1") == "value1"
      assert Veidrodelis.hget(@id, 0, "myhash", "field2") == "value2"
      assert Veidrodelis.hget(@id, 0, "myhash", "field3") == "value3"

      # hash_for_del should have only f1 (f2 was deleted)
      assert Veidrodelis.hlen(@id, 0, "hash_for_del") == 1
      assert Veidrodelis.hget(@id, 0, "hash_for_del", "f1") == "v1"
      assert Veidrodelis.hget(@id, 0, "hash_for_del", "f2") == nil

      # Sorted set values
      assert Veidrodelis.zcard(@id, 0, "myzset") == 3
      assert Veidrodelis.zscore(@id, 0, "myzset", "member1") == 1.0
      assert Veidrodelis.zscore(@id, 0, "myzset", "member2") == 2.5
      assert Veidrodelis.zscore(@id, 0, "myzset", "member3") == 3.7

      # zset_for_rem should have x and z (y was removed)
      assert Veidrodelis.zcard(@id, 0, "zset_for_rem") == 2
      assert Veidrodelis.zscore(@id, 0, "zset_for_rem", "x") == 1.0
      assert Veidrodelis.zscore(@id, 0, "zset_for_rem", "z") == 3.0
      assert Veidrodelis.zscore(@id, 0, "zset_for_rem", "y") == nil

      # pop_zset should have only "b" after ZPOPMAX and ZPOPMIN
      assert Veidrodelis.zcard(@id, 0, "pop_zset") == 1
      assert Veidrodelis.zscore(@id, 0, "pop_zset", "b") == 2.0

      # Verify set/zset operations created correct results
      assert Veidrodelis.zcard(@id, 0, "zset_union") > 0
      assert Veidrodelis.zcard(@id, 0, "zset_inter") > 0

      # Verify ZINCRBY results (replicated as ZADD with final scores)
      # Test 1: existing key, existing member (10.0 + 5.5 = 15.5)
      assert Veidrodelis.zscore(@id, 0, "zincrby_test", "counter") == 15.5

      # Test 2: existing key, non-existing member (0 + 7.5 = 7.5)
      assert Veidrodelis.zcard(@id, 0, "zincrby_test2") == 2
      assert Veidrodelis.zscore(@id, 0, "zincrby_test2", "existing") == 1.0
      assert Veidrodelis.zscore(@id, 0, "zincrby_test2", "new_member") == 7.5

      # Test 3: non-existing key (creates key with member at score 42.0)
      assert Veidrodelis.zcard(@id, 0, "zincrby_new_key") == 1
      assert Veidrodelis.zscore(@id, 0, "zincrby_new_key", "member1") == 42.0

      # Test 4: negative delta (100.0 - 25.5 = 74.5)
      assert Veidrodelis.zscore(@id, 0, "zincrby_decr", "score") == 74.5

      Logger.info("=== [Veidrodelis] Phase 4: Issuing commands to DB 1 while streaming ===")

      issue_diverse_commands(redis, 1)

      # Wait for streaming replication
      assert_happens_within 3000 do
        Veidrodelis.get(@id, 1, "simple_key") == "simple_value" &&
          Veidrodelis.llen(@id, 1, "mylist") == 4 &&
          Veidrodelis.scard(@id, 1, "myset") == 3 &&
          Veidrodelis.hlen(@id, 1, "myhash") == 3 &&
          Veidrodelis.zcard(@id, 1, "myzset") == 3
      end

      Logger.info("=== [Veidrodelis] Phase 5: Verifying streaming data via query API ===")

      # String values
      assert Veidrodelis.get(@id, 1, "simple_key") == "simple_value"
      assert Veidrodelis.get(@id, 1, "mkey1") == "mval1"
      assert Veidrodelis.get(@id, 1, "append_key") == "initial_appended"

      # List values
      assert Veidrodelis.llen(@id, 1, "mylist") == 4
      assert Veidrodelis.lrange(@id, 1, "mylist", 0, -1) == ["elem0", "elem1", "elem2", "elem3"]

      # Set values
      assert Veidrodelis.scard(@id, 1, "myset") == 3
      members_db1 = Veidrodelis.smembers(@id, 1, "myset")
      assert "member1" in members_db1
      assert "member2" in members_db1
      assert "member3" in members_db1

      # Hash values
      assert Veidrodelis.hlen(@id, 1, "myhash") == 3
      assert Veidrodelis.hget(@id, 1, "myhash", "field1") == "value1"

      # Sorted set values
      assert Veidrodelis.zcard(@id, 1, "myzset") == 3
      assert Veidrodelis.zscore(@id, 1, "myzset", "member1") == 1.0

      # Verify ZINCRBY results in DB 1 (streaming replication)
      assert Veidrodelis.zscore(@id, 1, "zincrby_test", "counter") == 15.5
      assert Veidrodelis.zscore(@id, 1, "zincrby_test2", "new_member") == 7.5
      assert Veidrodelis.zscore(@id, 1, "zincrby_new_key", "member1") == 42.0
      assert Veidrodelis.zscore(@id, 1, "zincrby_decr", "score") == 74.5

      Logger.info("=== [Veidrodelis] Test completed successfully ===")

      Veidrodelis.stop(vdr)
    end
  end

  # Triple comparison tests: verify that Redis value, TS value, and expected value are all equal
  describe "string commands" do
    setup %{redis: redis} do
      {:ok, vdr} =
        Veidrodelis.start_link(
          id: @id,
          host: @redis_host,
          port: @redis_port,
          impl: {Vdr.TSProj, []}
        )

      assert_happens_within 5000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      {:ok, redis: redis, vdr: vdr}
    end

    test "MSET replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["MSET", "k1", "v1", "k2", "v2"])

      assert_happens_within 1000 do
        expected_k1 = "v1"
        expected_k2 = "v2"
        redis_k1 = Redix.command!(redis, ["GET", "k1"])
        redis_k2 = Redix.command!(redis, ["GET", "k2"])
        ts_k1 = Veidrodelis.get(@id, 0, "k1")
        ts_k2 = Veidrodelis.get(@id, 0, "k2")

        redis_k1 == expected_k1 and ts_k1 == expected_k1 and
          redis_k2 == expected_k2 and ts_k2 == expected_k2
      end
    end

    test "APPEND replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["SET", "append_test", "Hello"])
      Redix.command!(redis, ["APPEND", "append_test", " World"])

      assert_happens_within 1000 do
        expected = "Hello World"
        redis_val = Redix.command!(redis, ["GET", "append_test"])
        ts_val = Veidrodelis.get(@id, 0, "append_test")

        redis_val == expected and ts_val == expected and redis_val == ts_val
      end
    end

    test "RENAME replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["SET", "old_key", "rename_test"])
      Redix.command!(redis, ["RENAME", "old_key", "new_key"])

      assert_happens_within 1000 do
        expected = "rename_test"
        redis_new = Redix.command!(redis, ["GET", "new_key"])
        redis_old = Redix.command!(redis, ["GET", "old_key"])
        ts_new = Veidrodelis.get(@id, 0, "new_key")
        ts_old = Veidrodelis.get(@id, 0, "old_key")

        redis_new == expected and ts_new == expected and
          redis_old == nil and ts_old == nil
      end
    end

    test "RENAMENX replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["SET", "renamenx_src", "test"])
      Redix.command!(redis, ["RENAMENX", "renamenx_src", "renamenx_dst"])

      assert_happens_within 1000 do
        expected = "test"
        redis_dst = Redix.command!(redis, ["GET", "renamenx_dst"])
        ts_dst = Veidrodelis.get(@id, 0, "renamenx_dst")

        redis_dst == expected and ts_dst == expected
      end
    end
  end

  describe "list commands" do
    setup %{redis: redis} do
      {:ok, vdr} =
        Veidrodelis.start_link(
          id: @id,
          host: @redis_host,
          port: @redis_port,
          impl: {Vdr.TSProj, []}
        )

      assert_happens_within 5000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      {:ok, redis: redis, vdr: vdr}
    end

    test "LPUSHX replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["LPUSH", "test_list", "a"])
      Redix.command!(redis, ["LPUSHX", "test_list", "b"])

      assert_happens_within 1000 do
        expected = ["b", "a"]
        redis_list = Redix.command!(redis, ["LRANGE", "test_list", "0", "-1"])
        ts_list = Veidrodelis.lrange(@id, 0, "test_list", 0, -1)

        redis_list == expected and ts_list == expected and redis_list == ts_list
      end
    end

    test "RPUSHX replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "test_list", "a"])
      Redix.command!(redis, ["RPUSHX", "test_list", "b"])

      assert_happens_within 1000 do
        expected = ["a", "b"]
        redis_list = Redix.command!(redis, ["LRANGE", "test_list", "0", "-1"])
        ts_list = Veidrodelis.lrange(@id, 0, "test_list", 0, -1)

        redis_list == expected and ts_list == expected and redis_list == ts_list
      end
    end

    test "LREM replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "rem_list", "x", "y", "x", "z", "x"])
      Redix.command!(redis, ["LREM", "rem_list", "2", "x"])

      assert_happens_within 1000 do
        expected = ["y", "z", "x"]
        redis_list = Redix.command!(redis, ["LRANGE", "rem_list", "0", "-1"])
        ts_list = Veidrodelis.lrange(@id, 0, "rem_list", 0, -1)

        redis_list == expected and ts_list == expected and redis_list == ts_list
      end
    end

    test "LTRIM replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "trim_list", "a", "b", "c", "d", "e"])
      Redix.command!(redis, ["LTRIM", "trim_list", "1", "3"])

      assert_happens_within 1000 do
        expected = ["b", "c", "d"]
        redis_list = Redix.command!(redis, ["LRANGE", "trim_list", "0", "-1"])
        ts_list = Veidrodelis.lrange(@id, 0, "trim_list", 0, -1)

        redis_list == expected and ts_list == expected and redis_list == ts_list
      end
    end

    test "LINSERT replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "insert_list", "a", "c"])
      Redix.command!(redis, ["LINSERT", "insert_list", "BEFORE", "c", "b"])

      assert_happens_within 1000 do
        expected = ["a", "b", "c"]
        redis_list = Redix.command!(redis, ["LRANGE", "insert_list", "0", "-1"])
        ts_list = Veidrodelis.lrange(@id, 0, "insert_list", 0, -1)

        redis_list == expected and ts_list == expected and redis_list == ts_list
      end
    end
  end

  describe "sorted set commands" do
    setup %{redis: redis} do
      {:ok, vdr} =
        Veidrodelis.start_link(
          id: @id,
          host: @redis_host,
          port: @redis_port,
          impl: {Vdr.TSProj, []}
        )

      assert_happens_within 5000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      {:ok, redis: redis, vdr: vdr}
    end

    test "ZPOPMAX replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "pop_test", "1", "a", "2", "b", "3", "c"])
      Redix.command!(redis, ["ZPOPMAX", "pop_test", "1"])

      assert_happens_within 1000 do
        expected_card = 2
        redis_card = Redix.command!(redis, ["ZCARD", "pop_test"])
        ts_card = Veidrodelis.zcard(@id, 0, "pop_test")

        redis_card == expected_card and ts_card == expected_card and redis_card == ts_card
      end
    end

    test "ZPOPMIN replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "pop_test", "1", "a", "2", "b", "3", "c"])
      Redix.command!(redis, ["ZPOPMIN", "pop_test", "1"])

      assert_happens_within 1000 do
        expected_card = 2
        redis_card = Redix.command!(redis, ["ZCARD", "pop_test"])
        ts_card = Veidrodelis.zcard(@id, 0, "pop_test")

        redis_card == expected_card and ts_card == expected_card
      end
    end

    test "ZREMRANGEBYRANK replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "rank_test", "1", "a", "2", "b", "3", "c", "4", "d"])
      Redix.command!(redis, ["ZREMRANGEBYRANK", "rank_test", "1", "2"])

      assert_happens_within 1000 do
        expected = ["a", "d"]
        redis_members = Redix.command!(redis, ["ZRANGE", "rank_test", "0", "-1"])
        ts_members = Veidrodelis.zrange(@id, 0, "rank_test", 0, -1, false)

        redis_members == expected and ts_members == expected and redis_members == ts_members
      end
    end

    test "ZREMRANGEBYSCORE replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "score_test", "1", "a", "2", "b", "3", "c", "4", "d"])
      Redix.command!(redis, ["ZREMRANGEBYSCORE", "score_test", "2", "3"])

      assert_happens_within 1000 do
        expected = ["a", "d"]
        redis_members = Redix.command!(redis, ["ZRANGE", "score_test", "0", "-1"])
        ts_members = Veidrodelis.zrange(@id, 0, "score_test", 0, -1, false)

        redis_members == expected and ts_members == expected and redis_members == ts_members
      end
    end

    test "ZUNIONSTORE replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zset_a", "1", "a", "2", "b"])
      Redix.command!(redis, ["ZADD", "zset_b", "2", "b", "3", "c"])
      Redix.command!(redis, ["ZUNIONSTORE", "zset_union", "2", "zset_a", "zset_b"])

      assert_happens_within 1000 do
        expected_card = 3
        # 2.0 + 2.0
        expected_score_b = 4.0
        redis_card = Redix.command!(redis, ["ZCARD", "zset_union"])
        ts_card = Veidrodelis.zcard(@id, 0, "zset_union")
        redis_score = Redix.command!(redis, ["ZSCORE", "zset_union", "b"])
        ts_score = Veidrodelis.zscore(@id, 0, "zset_union", "b")

        redis_score_float =
          case Float.parse(redis_score) do
            {f, _} -> f
            :error -> String.to_integer(redis_score) * 1.0
          end

        redis_card == expected_card and ts_card == expected_card and
          redis_score_float == expected_score_b and ts_score == expected_score_b
      end
    end

    test "ZINTERSTORE replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zset_a", "1", "a", "2", "b"])
      Redix.command!(redis, ["ZADD", "zset_b", "2", "b", "3", "c"])
      Redix.command!(redis, ["ZINTERSTORE", "zset_inter", "2", "zset_a", "zset_b"])

      assert_happens_within 1000 do
        expected_card = 1
        expected_members = ["b"]
        redis_card = Redix.command!(redis, ["ZCARD", "zset_inter"])
        ts_card = Veidrodelis.zcard(@id, 0, "zset_inter")
        redis_members = Redix.command!(redis, ["ZRANGE", "zset_inter", "0", "-1"])
        ts_members = Veidrodelis.zrange(@id, 0, "zset_inter", 0, -1, false)

        redis_card == expected_card and ts_card == expected_card and
          redis_members == expected_members and ts_members == expected_members
      end
    end

    # ===== Comprehensive Edge Case Tests =====

    test "ZADD with options: NX only adds new members", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "nx_test", "1", "existing"])
      Redix.command!(redis, ["ZADD", "nx_test", "NX", "2", "existing", "3", "new"])

      assert_happens_within 1000 do
        assert {1.0, ""} == Float.parse(Redix.command!(redis, ["ZSCORE", "nx_test", "existing"]))
        assert 1.0 == Veidrodelis.zscore(@id, 0, "nx_test", "existing")
        assert {3.0, ""} == Float.parse(Redix.command!(redis, ["ZSCORE", "nx_test", "new"]))
        assert 3.0 == Veidrodelis.zscore(@id, 0, "nx_test", "new")
      end
    end

    test "ZADD with options: XX only updates existing members", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "xx_test", "1", "existing"])
      Redix.command!(redis, ["ZADD", "xx_test", "XX", "5", "existing", "3", "new"])

      assert_happens_within 1000 do
        # "existing" should be updated to 5
        # "new" should NOT be added
        redis_score_existing = Redix.command!(redis, ["ZSCORE", "xx_test", "existing"])
        ts_score_existing = Veidrodelis.zscore(@id, 0, "xx_test", "existing")
        ts_score_new = Veidrodelis.zscore(@id, 0, "xx_test", "new")

        Float.parse(redis_score_existing) == {5.0, ""} and ts_score_existing == 5.0 and
          ts_score_new == nil
      end
    end

    test "ZADD with options: GT only updates if new score greater", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "gt_test", "5", "member"])
      # Should not update (3 < 5)
      Redix.command!(redis, ["ZADD", "gt_test", "GT", "3", "member"])

      assert_happens_within 1000 do
        redis_score = Redix.command!(redis, ["ZSCORE", "gt_test", "member"])
        ts_score = Veidrodelis.zscore(@id, 0, "gt_test", "member")

        Float.parse(redis_score) == {5.0, ""} and ts_score == 5.0
      end
    end

    test "ZADD with options: LT only updates if new score less", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "lt_test", "5", "member"])
      # Should update (3 < 5)
      Redix.command!(redis, ["ZADD", "lt_test", "LT", "3", "member"])

      assert_happens_within 1000 do
        redis_score = Redix.command!(redis, ["ZSCORE", "lt_test", "member"])
        ts_score = Veidrodelis.zscore(@id, 0, "lt_test", "member")

        Float.parse(redis_score) == {3.0, ""} and ts_score == 3.0
      end
    end

    test "ZADD with options: INCR increments score", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "incr_test", "5", "member"])
      # Should be 5 + 3 = 8
      Redix.command!(redis, ["ZADD", "incr_test", "INCR", "3", "member"])

      assert_happens_within 1000 do
        redis_score = Redix.command!(redis, ["ZSCORE", "incr_test", "member"])
        ts_score = Veidrodelis.zscore(@id, 0, "incr_test", "member")

        Float.parse(redis_score) == {8.0, ""} and ts_score == 8.0
      end
    end

    test "ZINCRBY increments existing member in existing key", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zincrby_existing", "10.0", "counter"])
      # Should be 10.0 + 5.5 = 15.5
      Redix.command!(redis, ["ZINCRBY", "zincrby_existing", "5.5", "counter"])

      assert_happens_within 1000 do
        redis_score = Redix.command!(redis, ["ZSCORE", "zincrby_existing", "counter"])
        ts_score = Veidrodelis.zscore(@id, 0, "zincrby_existing", "counter")

        Float.parse(redis_score) == {15.5, ""} and ts_score == 15.5
      end
    end

    test "ZINCRBY creates member in existing key", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zincrby_new_member", "1.0", "existing"])
      # Should create "new_member" with score 7.5 (0 + 7.5)
      Redix.command!(redis, ["ZINCRBY", "zincrby_new_member", "7.5", "new_member"])

      assert_happens_within 1000 do
        redis_count = Redix.command!(redis, ["ZCARD", "zincrby_new_member"])
        ts_count = Veidrodelis.zcard(@id, 0, "zincrby_new_member")
        redis_score = Redix.command!(redis, ["ZSCORE", "zincrby_new_member", "new_member"])
        ts_score = Veidrodelis.zscore(@id, 0, "zincrby_new_member", "new_member")

        redis_count == 2 and ts_count == 2 and
          Float.parse(redis_score) == {7.5, ""} and ts_score == 7.5
      end
    end

    test "ZINCRBY creates key and member when key doesn't exist", %{redis: redis} do
      # Should create key and member with score 42.0 (0 + 42.0)
      Redix.command!(redis, ["ZINCRBY", "zincrby_new_key", "42.0", "member1"])

      assert_happens_within 1000 do
        redis_count = Redix.command!(redis, ["ZCARD", "zincrby_new_key"])
        ts_count = Veidrodelis.zcard(@id, 0, "zincrby_new_key")
        redis_score = Redix.command!(redis, ["ZSCORE", "zincrby_new_key", "member1"])
        ts_score = Veidrodelis.zscore(@id, 0, "zincrby_new_key", "member1")

        redis_count == 1 and ts_count == 1 and
          Float.parse(redis_score) == {42.0, ""} and ts_score == 42.0
      end
    end

    test "ZINCRBY decrements with negative increment", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zincrby_decr", "100.0", "score"])
      # Should be 100.0 + (-25.5) = 74.5
      Redix.command!(redis, ["ZINCRBY", "zincrby_decr", "-25.5", "score"])

      assert_happens_within 1000 do
        redis_score = Redix.command!(redis, ["ZSCORE", "zincrby_decr", "score"])
        ts_score = Veidrodelis.zscore(@id, 0, "zincrby_decr", "score")

        Float.parse(redis_score) == {74.5, ""} and ts_score == 74.5
      end
    end

    test "ZREMRANGEBYSCORE with exclusive min boundary", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "excl_min", "1", "a", "2", "b", "3", "c", "4", "d"])
      Redix.command!(redis, ["ZREMRANGEBYSCORE", "excl_min", "(2", "3"])

      assert_happens_within 1000 do
        # Only "c" removed (score 3), "b" (score 2) kept
        expected = ["a", "b", "d"]
        redis_members = Redix.command!(redis, ["ZRANGE", "excl_min", "0", "-1"])
        ts_members = Veidrodelis.zrange(@id, 0, "excl_min", 0, -1, false)

        redis_members == expected and ts_members == expected
      end
    end

    test "ZREMRANGEBYSCORE with exclusive max boundary", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "excl_max", "1", "a", "2", "b", "3", "c", "4", "d"])
      Redix.command!(redis, ["ZREMRANGEBYSCORE", "excl_max", "2", "(3"])

      assert_happens_within 1000 do
        # Only "b" removed (score 2), "c" (score 3) kept
        expected = ["a", "c", "d"]
        redis_members = Redix.command!(redis, ["ZRANGE", "excl_max", "0", "-1"])
        ts_members = Veidrodelis.zrange(@id, 0, "excl_max", 0, -1, false)

        redis_members == expected and ts_members == expected
      end
    end

    test "ZREMRANGEBYSCORE with both exclusive boundaries", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "excl_both", "1", "a", "2", "b", "3", "c", "4", "d"])
      Redix.command!(redis, ["ZREMRANGEBYSCORE", "excl_both", "(2", "(4"])

      assert_happens_within 1000 do
        # Only "c" removed, "b" and "d" kept
        expected = ["a", "b", "d"]
        redis_members = Redix.command!(redis, ["ZRANGE", "excl_both", "0", "-1"])
        ts_members = Veidrodelis.zrange(@id, 0, "excl_both", 0, -1, false)

        redis_members == expected and ts_members == expected
      end
    end

    test "ZREMRANGEBYSCORE from -inf to value", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "inf_min", "1", "a", "2", "b", "3", "c", "4", "d"])
      Redix.command!(redis, ["ZREMRANGEBYSCORE", "inf_min", "-inf", "2"])

      assert_happens_within 1000 do
        # "a" and "b" removed
        expected = ["c", "d"]
        redis_members = Redix.command!(redis, ["ZRANGE", "inf_min", "0", "-1"])
        ts_members = Veidrodelis.zrange(@id, 0, "inf_min", 0, -1, false)

        redis_members == expected and ts_members == expected
      end
    end

    test "ZREMRANGEBYSCORE from value to +inf", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "inf_max", "1", "a", "2", "b", "3", "c", "4", "d"])
      Redix.command!(redis, ["ZREMRANGEBYSCORE", "inf_max", "3", "+inf"])

      assert_happens_within 1000 do
        # "c" and "d" removed
        expected = ["a", "b"]
        redis_members = Redix.command!(redis, ["ZRANGE", "inf_max", "0", "-1"])
        ts_members = Veidrodelis.zrange(@id, 0, "inf_max", 0, -1, false)

        redis_members == expected and ts_members == expected
      end
    end

    test "ZREMRANGEBYSCORE from -inf to +inf removes all", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "inf_all", "1", "a", "2", "b", "3", "c"])
      Redix.command!(redis, ["ZREMRANGEBYSCORE", "inf_all", "-inf", "+inf"])

      assert_happens_within 1000 do
        redis_card = Redix.command!(redis, ["ZCARD", "inf_all"])
        ts_card = Veidrodelis.zcard(@id, 0, "inf_all")

        redis_card == 0 and ts_card == 0
      end
    end

    test "ZREMRANGEBYLEX with inclusive range", %{redis: redis} do
      # All members must have same score for lex operations
      Redix.command!(redis, ["ZADD", "lex_incl", "0", "a", "0", "b", "0", "c", "0", "d"])
      Redix.command!(redis, ["ZREMRANGEBYLEX", "lex_incl", "[b", "[c"])

      assert_happens_within 1000 do
        # "b" and "c" removed
        expected = ["a", "d"]
        redis_members = Redix.command!(redis, ["ZRANGE", "lex_incl", "0", "-1"])
        ts_members = Veidrodelis.zrange(@id, 0, "lex_incl", 0, -1, false)

        redis_members == expected and ts_members == expected
      end
    end

    test "ZREMRANGEBYLEX with exclusive range", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "lex_excl", "0", "a", "0", "b", "0", "c", "0", "d"])
      Redix.command!(redis, ["ZREMRANGEBYLEX", "lex_excl", "(a", "(d"])

      assert_happens_within 1000 do
        # "b" and "c" removed, "a" and "d" kept
        expected = ["a", "d"]
        redis_members = Redix.command!(redis, ["ZRANGE", "lex_excl", "0", "-1"])
        ts_members = Veidrodelis.zrange(@id, 0, "lex_excl", 0, -1, false)

        redis_members == expected and ts_members == expected
      end
    end

    test "ZREMRANGEBYLEX with - (min) boundary", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "lex_min", "0", "a", "0", "b", "0", "c", "0", "d"])
      Redix.command!(redis, ["ZREMRANGEBYLEX", "lex_min", "-", "[b"])

      assert_happens_within 1000 do
        # "a" and "b" removed
        expected = ["c", "d"]
        redis_members = Redix.command!(redis, ["ZRANGE", "lex_min", "0", "-1"])
        ts_members = Veidrodelis.zrange(@id, 0, "lex_min", 0, -1, false)

        redis_members == expected and ts_members == expected
      end
    end

    test "ZREMRANGEBYLEX with + (max) boundary", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "lex_max", "0", "a", "0", "b", "0", "c", "0", "d"])
      Redix.command!(redis, ["ZREMRANGEBYLEX", "lex_max", "[c", "+"])

      assert_happens_within 1000 do
        # "c" and "d" removed
        expected = ["a", "b"]
        redis_members = Redix.command!(redis, ["ZRANGE", "lex_max", "0", "-1"])
        ts_members = Veidrodelis.zrange(@id, 0, "lex_max", 0, -1, false)

        redis_members == expected and ts_members == expected
      end
    end

    test "ZREMRANGEBYLEX from - to + removes all", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "lex_all", "0", "a", "0", "b", "0", "c"])
      Redix.command!(redis, ["ZREMRANGEBYLEX", "lex_all", "-", "+"])

      assert_happens_within 1000 do
        redis_card = Redix.command!(redis, ["ZCARD", "lex_all"])
        ts_card = Veidrodelis.zcard(@id, 0, "lex_all")

        redis_card == 0 and ts_card == 0
      end
    end

    test "ZADD with infinity scores", %{redis: redis} do
      # Redis supports +inf and -inf as scores
      Redix.command!(redis, ["ZADD", "inf_scores", "-inf", "min", "0", "mid", "+inf", "max"])

      assert_happens_within 1000 do
        expected = ["min", "mid", "max"]
        redis_members = Redix.command!(redis, ["ZRANGE", "inf_scores", "0", "-1"])
        ts_members = Veidrodelis.zrange(@id, 0, "inf_scores", 0, -1, false)

        redis_members == expected and ts_members == expected
      end
    end

    test "ZREMRANGEBYSCORE with infinity score members", %{redis: redis} do
      Redix.command!(redis, [
        "ZADD",
        "inf_members",
        "-inf",
        "minval",
        "1",
        "a",
        "2",
        "b",
        "+inf",
        "maxval"
      ])

      # Remove from score 1 to +inf (inclusive)
      Redix.command!(redis, ["ZREMRANGEBYSCORE", "inf_members", "1", "+inf"])

      assert_happens_within 1000 do
        # Only -inf member remains
        expected = ["minval"]
        redis_members = Redix.command!(redis, ["ZRANGE", "inf_members", "0", "-1"])
        ts_members = Veidrodelis.zrange(@id, 0, "inf_members", 0, -1, false)

        redis_members == expected and ts_members == expected
      end
    end

    test "ZUNIONSTORE with WEIGHTS", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "union_w1", "1", "a", "2", "b"])
      Redix.command!(redis, ["ZADD", "union_w2", "1", "b", "3", "c"])

      Redix.command!(redis, [
        "ZUNIONSTORE",
        "union_weighted",
        "2",
        "union_w1",
        "union_w2",
        "WEIGHTS",
        "2",
        "3"
      ])

      assert_happens_within 1000 do
        # a: 1*2 = 2, b: 2*2 + 1*3 = 7, c: 3*3 = 9
        redis_score_b = Redix.command!(redis, ["ZSCORE", "union_weighted", "b"])
        ts_score_b = Veidrodelis.zscore(@id, 0, "union_weighted", "b")

        Float.parse(redis_score_b) == {7.0, ""} and ts_score_b == 7.0
      end
    end

    test "ZUNIONSTORE with AGGREGATE MIN", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "union_min1", "1", "a", "5", "b"])
      Redix.command!(redis, ["ZADD", "union_min2", "3", "b", "2", "c"])

      Redix.command!(redis, [
        "ZUNIONSTORE",
        "union_min_result",
        "2",
        "union_min1",
        "union_min2",
        "AGGREGATE",
        "MIN"
      ])

      assert_happens_within 1000 do
        # b should have min(5, 3) = 3
        redis_score_b = Redix.command!(redis, ["ZSCORE", "union_min_result", "b"])
        ts_score_b = Veidrodelis.zscore(@id, 0, "union_min_result", "b")

        Float.parse(redis_score_b) == {3.0, ""} and ts_score_b == 3.0
      end
    end

    test "ZUNIONSTORE with AGGREGATE MAX", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "union_max1", "1", "a", "5", "b"])
      Redix.command!(redis, ["ZADD", "union_max2", "3", "b", "2", "c"])

      Redix.command!(redis, [
        "ZUNIONSTORE",
        "union_max_result",
        "2",
        "union_max1",
        "union_max2",
        "AGGREGATE",
        "MAX"
      ])

      assert_happens_within 1000 do
        # b should have max(5, 3) = 5
        redis_score_b = Redix.command!(redis, ["ZSCORE", "union_max_result", "b"])
        ts_score_b = Veidrodelis.zscore(@id, 0, "union_max_result", "b")

        Float.parse(redis_score_b) == {5.0, ""} and ts_score_b == 5.0
      end
    end

    test "ZINTERSTORE with WEIGHTS", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "inter_w1", "1", "a", "2", "b"])
      Redix.command!(redis, ["ZADD", "inter_w2", "3", "b", "4", "c"])

      Redix.command!(redis, [
        "ZINTERSTORE",
        "inter_weighted",
        "2",
        "inter_w1",
        "inter_w2",
        "WEIGHTS",
        "2",
        "3"
      ])

      assert_happens_within 1000 do
        # Only b is in both: 2*2 + 3*3 = 13
        redis_card = Redix.command!(redis, ["ZCARD", "inter_weighted"])
        ts_card = Veidrodelis.zcard(@id, 0, "inter_weighted")
        redis_score_b = Redix.command!(redis, ["ZSCORE", "inter_weighted", "b"])
        ts_score_b = Veidrodelis.zscore(@id, 0, "inter_weighted", "b")

        redis_card == 1 and ts_card == 1 and
          Float.parse(redis_score_b) == {13.0, ""} and ts_score_b == 13.0
      end
    end

    test "ZINTERSTORE with AGGREGATE MAX", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "inter_max1", "5", "b", "1", "a"])
      Redix.command!(redis, ["ZADD", "inter_max2", "3", "b", "2", "c"])

      Redix.command!(redis, [
        "ZINTERSTORE",
        "inter_max_result",
        "2",
        "inter_max1",
        "inter_max2",
        "AGGREGATE",
        "MAX"
      ])

      assert_happens_within 1000 do
        # Only b: max(5, 3) = 5
        redis_score_b = Redix.command!(redis, ["ZSCORE", "inter_max_result", "b"])
        ts_score_b = Veidrodelis.zscore(@id, 0, "inter_max_result", "b")

        Float.parse(redis_score_b) == {5.0, ""} and ts_score_b == 5.0
      end
    end

    test "ZREMRANGEBYRANK with negative indices", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "rank_neg", "1", "a", "2", "b", "3", "c", "4", "d"])
      Redix.command!(redis, ["ZREMRANGEBYRANK", "rank_neg", "-2", "-1"])

      assert_happens_within 1000 do
        # Last two removed
        expected = ["a", "b"]
        redis_members = Redix.command!(redis, ["ZRANGE", "rank_neg", "0", "-1"])
        ts_members = Veidrodelis.zrange(@id, 0, "rank_neg", 0, -1, false)

        redis_members == expected and ts_members == expected
      end
    end

    test "ZPOPMAX with count", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "popmax_count", "1", "a", "2", "b", "3", "c", "4", "d"])
      Redix.command!(redis, ["ZPOPMAX", "popmax_count", "2"])

      assert_happens_within 1000 do
        # Top 2 (d, c) removed
        expected = ["a", "b"]
        redis_members = Redix.command!(redis, ["ZRANGE", "popmax_count", "0", "-1"])
        ts_members = Veidrodelis.zrange(@id, 0, "popmax_count", 0, -1, false)

        redis_members == expected and ts_members == expected
      end
    end

    test "ZPOPMIN with count", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "popmin_count", "1", "a", "2", "b", "3", "c", "4", "d"])
      Redix.command!(redis, ["ZPOPMIN", "popmin_count", "2"])

      assert_happens_within 1000 do
        # Bottom 2 (a, b) removed
        expected = ["c", "d"]
        redis_members = Redix.command!(redis, ["ZRANGE", "popmin_count", "0", "-1"])
        ts_members = Veidrodelis.zrange(@id, 0, "popmin_count", 0, -1, false)

        redis_members == expected and ts_members == expected
      end
    end
  end
end
