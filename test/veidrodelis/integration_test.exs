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

  @redis [host: "localhost", port: 26378]
  @valkey [host: "localhost", port: 16378]

  use ExUnit.Case,
    async: false,
    parameterize: [
      %{backend: :redis, conn_opts: @redis},
      %{backend: :valkey, conn_opts: @valkey}
    ]

  alias Vdr.RedisStream.Replica
  use CommandMatchers
  require Logger

  # Callback module that collects all commands with database info
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
      |> Enum.map(fn {_ts, db, cmd} -> {db, cmd} end)
    end

    def commands_for_db(state, db) do
      commands(state)
      |> Enum.filter(fn {cmd_db, _cmd} -> cmd_db == db end)
      |> Enum.map(fn {_db, cmd} -> cmd end)
    end
  end

  @doc """
  Issues a maximally diverse set of Redis commands covering all Vdr.RedisCommand types.

  The `backend` parameter controls which commands are issued:
  - `:valkey`: All commands including hash field expiration (HEXPIRE, etc.)
  - `:redis`: Skips hash field expiration commands which are Valkey-specific
  """
  def issue_diverse_commands(redis, db \\ 0, backend \\ :valkey) do
    # Select database
    if db != 0 do
      Redix.command!(redis, ["SELECT", "#{db}"])
    end

    Redix.command!(redis, ["FLUSHALL"])

    # ===== String Commands =====
    Redix.command!(redis, ["SET", "simple_key", "simple_value"])
    Redix.command!(redis, ["MSET", "mkey1", "mval1", "mkey2", "mval2"])
    Redix.command!(redis, ["SET", "append_key", "initial"])
    Redix.command!(redis, ["APPEND", "append_key", "_appended"])
    Redix.command!(redis, ["SET", "range_key", "0000000000"])
    Redix.command!(redis, ["SETRANGE", "range_key", "5", "HELLO"])
    Redix.command!(redis, ["SETBIT", "bit_key", "7", "1"])
    Redix.command!(redis, ["SETBIT", "bit_key", "15", "1"])

    # Commands that replicate as SET (not as their original command type)
    Redix.command!(redis, ["INCR", "incr_key"])
    # incr_key now has value "1"
    Redix.command!(redis, ["SET", "incrby_key", "100"])
    Redix.command!(redis, ["INCRBY", "incrby_key", "42"])
    # incrby_key now has value "142"
    Redix.command!(redis, ["INCRBYFLOAT", "incrbyfloat_key", "3.14"])
    # incrbyfloat_key now has value "3.14"
    Redix.command!(redis, ["SET", "decr_key", "10"])
    Redix.command!(redis, ["DECR", "decr_key"])
    # decr_key now has value "9"
    Redix.command!(redis, ["SET", "decrby_key", "100"])
    Redix.command!(redis, ["DECRBY", "decrby_key", "30"])
    # decrby_key now has value "70"
    Redix.command!(redis, ["SET", "getset_key", "old_value"])
    Redix.command!(redis, ["GETSET", "getset_key", "getset_value"])
    # getset_key now has value "getset_value"
    Redix.command!(redis, ["SETNX", "setnx_key", "setnx_value"])
    # setnx_key now has value "setnx_value" (successful SETNX replicates as SET)
    Redix.command!(redis, ["MSETNX", "msetnx_key1", "val1", "msetnx_key2", "val2"])
    # msetnx_key1/2 now have values (successful MSETNX replicates as MSET)
    Redix.command!(redis, ["SETEX", "setex_key", "3600", "setex_value"])
    # setex_key now has value "setex_value" with expiration (replicates as SET + PEXPIREAT)
    Redix.command!(redis, ["PSETEX", "psetex_key", "3600000", "psetex_value"])
    # psetex_key now has value "psetex_value" with expiration (replicates as SET + PEXPIREAT)
    Redix.command!(redis, ["SET", "getdel_key", "will_be_deleted"])
    Redix.command!(redis, ["GETDEL", "getdel_key"])
    # getdel_key is now deleted (GETDEL replicates as DEL)

    # DELIFEQ tests - conditional delete (Valkey 9.0.0+)
    if backend == :valkey do
      Redix.command!(redis, ["SET", "delifeq_key", "expected_value"])
      Redix.command!(redis, ["DELIFEQ", "delifeq_key", "expected_value"])
      # delifeq_key is now deleted - need to check how it replicates
    end

    # GETEX tests - get with TTL modification (Redis 6.2.0+)
    Redix.command!(redis, ["SET", "getex_key", "getex_value"])
    Redix.command!(redis, ["GETEX", "getex_key", "EX", "3600"])
    # getex_key now has 1 hour expiration (GETEX with EX replicates as PEXPIREAT)
    Redix.command!(redis, ["SET", "getex_persist_key", "persist_value"])
    Redix.command!(redis, ["EXPIRE", "getex_persist_key", "3600"])
    Redix.command!(redis, ["GETEX", "getex_persist_key", "PERSIST"])
    # getex_persist_key now has no expiration (GETEX with PERSIST replicates as PERSIST)

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

    # LMOVE tests (Redis 6.2.0+)
    Redix.command!(redis, ["RPUSH", "lmove_src", "a", "b", "c"])
    Redix.command!(redis, ["RPUSH", "lmove_dst", "x"])
    Redix.command!(redis, ["LMOVE", "lmove_src", "lmove_dst", "LEFT", "RIGHT"])

    # LMPOP tests (Redis 7.0.0+)
    Redix.command!(redis, ["RPUSH", "lmpop_list1", "p1", "p2", "p3"])
    Redix.command!(redis, ["RPUSH", "lmpop_list2", "q1", "q2"])
    Redix.command!(redis, ["LMPOP", "2", "lmpop_list1", "lmpop_list2", "LEFT", "COUNT", "2"])

    # Blocking list commands - these replicate as their non-blocking equivalents
    # BLPOP (Redis 2.0.0+) - replicates as LPOP
    Redix.command!(redis, ["RPUSH", "blpop_list", "bl1", "bl2"])
    Redix.command!(redis, ["BLPOP", "blpop_list", "0"])

    # BRPOP (Redis 2.0.0+) - replicates as RPOP
    Redix.command!(redis, ["RPUSH", "brpop_list", "br1", "br2"])
    Redix.command!(redis, ["BRPOP", "brpop_list", "0"])

    # BRPOPLPUSH (Redis 2.2.0+) - replicates as RPOPLPUSH
    Redix.command!(redis, ["RPUSH", "brpoplpush_src", "brs1", "brs2"])
    Redix.command!(redis, ["RPUSH", "brpoplpush_dst", "brd1"])
    Redix.command!(redis, ["BRPOPLPUSH", "brpoplpush_src", "brpoplpush_dst", "0"])

    # BLMOVE (Redis 6.2.0+) - replicates as LMOVE
    Redix.command!(redis, ["RPUSH", "blmove_src", "bm1", "bm2", "bm3"])
    Redix.command!(redis, ["RPUSH", "blmove_dst", "bmx"])
    Redix.command!(redis, ["BLMOVE", "blmove_src", "blmove_dst", "LEFT", "RIGHT", "0"])

    # BLMPOP (Redis 7.0.0+) - replicates as LPOP with count
    Redix.command!(redis, ["RPUSH", "blmpop_list1", "blmp1", "blmp2", "blmp3"])
    Redix.command!(redis, ["RPUSH", "blmpop_list2", "blmq1", "blmq2"])

    Redix.command!(redis, [
      "BLMPOP",
      "0",
      "2",
      "blmpop_list1",
      "blmpop_list2",
      "LEFT",
      "COUNT",
      "2"
    ])

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
    Redix.command!(redis, ["SADD", "spop_set", "p1", "p2", "p3"])
    Redix.command!(redis, ["SPOP", "spop_set"])
    Redix.command!(redis, ["SPOP", "spop_set", "2"])

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

    # ZADD with CH option - returns count of changed elements
    Redix.command!(redis, ["ZADD", "zadd_ch_test", "1", "member1", "2", "member2"])
    # This should return 1 (only member1 is new, member2 score changes from 2 to 3)
    Redix.command!(redis, ["ZADD", "zadd_ch_test", "CH", "1", "member1", "3", "member2"])

    # ZADD with GT option - only update if new score is greater
    Redix.command!(redis, ["ZADD", "zadd_gt_test", "5", "member"])
    # This should NOT update (3 < 5)
    Redix.command!(redis, ["ZADD", "zadd_gt_test", "GT", "3", "member"])
    # This SHOULD update (10 > 5)
    Redix.command!(redis, ["ZADD", "zadd_gt_test", "GT", "10", "member"])
    # ZADD with GT and CH together
    Redix.command!(redis, ["ZADD", "zadd_gt_ch_test", "5", "m1", "10", "m2"])
    # Only m2 should be updated (15 > 10), m1 should NOT be updated (3 < 5)
    Redix.command!(redis, ["ZADD", "zadd_gt_ch_test", "GT", "CH", "3", "m1", "15", "m2"])

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

    # ZDIFFSTORE tests (Redis 6.2.0+)
    Redix.command!(redis, ["ZADD", "zdiff_a", "1", "a", "2", "b", "3", "c"])
    Redix.command!(redis, ["ZADD", "zdiff_b", "2", "b", "4", "d"])
    Redix.command!(redis, ["ZDIFFSTORE", "zdiff_result", "2", "zdiff_a", "zdiff_b"])

    # ZRANGESTORE tests (Redis 6.2.0+)
    Redix.command!(redis, [
      "ZADD",
      "zrangestore_src",
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

    Redix.command!(redis, ["ZRANGESTORE", "zrangestore_dest", "zrangestore_src", "1", "3"])

    # ZMPOP tests (Redis 7.0.0+) - replicates as ZPOPMAX/ZPOPMIN on the key with members
    Redix.command!(redis, ["ZADD", "zmpop_zset1", "1", "a", "2", "b", "3", "c"])
    Redix.command!(redis, ["ZADD", "zmpop_zset2", "4", "d", "5", "e"])
    Redix.command!(redis, ["ZMPOP", "2", "zmpop_zset1", "zmpop_zset2", "MAX", "COUNT", "2"])

    # Blocking sorted set commands - these replicate as their non-blocking equivalents
    # BZPOPMAX (Redis 5.0.0+) - replicates as ZPOPMAX
    Redix.command!(redis, ["ZADD", "bzpopmax_zset", "1", "a", "2", "b", "3", "c"])
    Redix.command!(redis, ["BZPOPMAX", "bzpopmax_zset", "0"])

    # BZPOPMIN (Redis 5.0.0+) - replicates as ZPOPMIN
    Redix.command!(redis, ["ZADD", "bzpopmin_zset", "1", "a", "2", "b", "3", "c"])
    Redix.command!(redis, ["BZPOPMIN", "bzpopmin_zset", "0"])

    # BZMPOP (Redis 7.0.0+) - replicates as ZMPOP (which in turn replicates as ZPOPMAX/ZPOPMIN)
    Redix.command!(redis, ["ZADD", "bzmpop_zset1", "1", "x", "2", "y", "3", "z"])
    Redix.command!(redis, ["ZADD", "bzmpop_zset2", "4", "p", "5", "q"])

    Redix.command!(redis, [
      "BZMPOP",
      "0",
      "2",
      "bzmpop_zset1",
      "bzmpop_zset2",
      "MIN",
      "COUNT",
      "2"
    ])

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

    # HMSET test
    Redix.command!(redis, ["HMSET", "hmset_hash", "f1", "v1", "f2", "v2"])

    # HSETNX tests
    Redix.command!(redis, ["HSET", "hsetnx_hash", "existing", "value1"])
    Redix.command!(redis, ["HSETNX", "hsetnx_hash", "existing", "should_not_change"])
    Redix.command!(redis, ["HSETNX", "hsetnx_hash", "new_field", "new_value"])

    # HINCRBY tests
    Redix.command!(redis, ["HSET", "hincrby_hash", "counter", "10"])
    Redix.command!(redis, ["HINCRBY", "hincrby_hash", "counter", "5"])
    Redix.command!(redis, ["HINCRBY", "hincrby_hash", "new_counter", "100"])

    # HINCRBYFLOAT tests
    result1 = Redix.command!(redis, ["HSET", "hincrbyfloat_hash", "score", "10.5"])
    Logger.info("HSET hincrbyfloat_hash result: #{inspect(result1)}")
    result2 = Redix.command!(redis, ["HINCRBYFLOAT", "hincrbyfloat_hash", "score", "3.7"])
    Logger.info("HINCRBYFLOAT score result: #{inspect(result2)}")
    result3 = Redix.command!(redis, ["HINCRBYFLOAT", "hincrbyfloat_hash", "new_score", "42.3"])
    Logger.info("HINCRBYFLOAT new_score result: #{inspect(result3)}")

    # Hash field expiration commands (Valkey-specific, not available in Redis)
    if backend == :valkey do
      Redix.command!(redis, ["HSET", "hexpire_hash", "f1", "v1", "f2", "v2", "f3", "v3"])
      Redix.command!(redis, ["HEXPIRE", "hexpire_hash", "3600", "FIELDS", "1", "f1"])

      Redix.command!(redis, [
        "HEXPIREAT",
        "hexpire_hash",
        "#{System.os_time(:second) + 86400}",
        "FIELDS",
        "1",
        "f2"
      ])

      Redix.command!(redis, ["HPEXPIRE", "hexpire_hash", "3600000", "FIELDS", "1", "f3"])

      Redix.command!(redis, ["HSET", "hpexpireat_hash", "f1", "v1"])

      Redix.command!(redis, [
        "HPEXPIREAT",
        "hpexpireat_hash",
        "#{System.os_time(:millisecond) + 86_400_000}",
        "FIELDS",
        "1",
        "f1"
      ])

      # HPEXPIREAT with all options (NX, XX, GT, LT) - Valkey-specific
      # NX: Set expiry only when field has no expiry
      Redix.command!(redis, [
        "HSET",
        "hpexpireat_opts",
        "f1",
        "v1",
        "f2",
        "v2",
        "f3",
        "v3",
        "f4",
        "v4"
      ])

      Redix.command!(redis, [
        "HPEXPIREAT",
        "hpexpireat_opts",
        "#{System.os_time(:millisecond) + 86_400_000}",
        "NX",
        "FIELDS",
        "1",
        "f1"
      ])

      # XX: Set expiry only when field has existing expiry
      Redix.command!(redis, ["HEXPIRE", "hpexpireat_opts", "3600", "FIELDS", "1", "f2"])

      Redix.command!(redis, [
        "HPEXPIREAT",
        "hpexpireat_opts",
        "#{System.os_time(:millisecond) + 172_800_000}",
        "XX",
        "FIELDS",
        "1",
        "f2"
      ])

      # GT: Set expiry only when new expiry is greater than current expiry
      Redix.command!(redis, ["HEXPIRE", "hpexpireat_opts", "3600", "FIELDS", "1", "f3"])

      Redix.command!(redis, [
        "HPEXPIREAT",
        "hpexpireat_opts",
        "#{System.os_time(:millisecond) + 172_800_000}",
        "GT",
        "FIELDS",
        "1",
        "f3"
      ])

      # LT: Set expiry only when new expiry is less than current expiry
      Redix.command!(redis, ["HEXPIRE", "hpexpireat_opts", "86400", "FIELDS", "1", "f4"])

      Redix.command!(redis, [
        "HPEXPIREAT",
        "hpexpireat_opts",
        "#{System.os_time(:millisecond) + 36_000_000}",
        "LT",
        "FIELDS",
        "1",
        "f4"
      ])

      Redix.command!(redis, ["HSET", "hpersist_hash", "f1", "v1"])
      Redix.command!(redis, ["HEXPIRE", "hpersist_hash", "3600", "FIELDS", "1", "f1"])
      Redix.command!(redis, ["HPERSIST", "hpersist_hash", "FIELDS", "1", "f1"])

      # HGETEX tests (Valkey 9.0.0+) - get with TTL modification
      Redix.command!(redis, ["HSET", "hgetex_hash", "f1", "v1", "f2", "v2"])
      Redix.command!(redis, ["HGETEX", "hgetex_hash", "EX", "3600", "FIELDS", "1", "f1"])
      Redix.command!(redis, ["HGETEX", "hgetex_hash", "PERSIST", "FIELDS", "1", "f2"])
    end

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

    # UNLINK - async delete (replicates as UNLINK or DEL depending on Redis version)
    Redix.command!(redis, ["SET", "unlink_key1", "v1"])
    Redix.command!(redis, ["SET", "unlink_key2", "v2"])
    Redix.command!(redis, ["UNLINK", "unlink_key1", "unlink_key2"])

    # COPY - copy key to another key (Redis 6.2.0+)
    Redix.command!(redis, ["SET", "copy_source", "copy_value"])
    Redix.command!(redis, ["COPY", "copy_source", "copy_dest"])

    # RESTORE - create a key from a serialized value (Redis 2.6.0+)
    # First create and DUMP a key, then RESTORE it to a new key
    Redix.command!(redis, ["SET", "restore_source", "restore_value"])
    serialized = Redix.command!(redis, ["DUMP", "restore_source"])
    Logger.info("DUMP result for restore_source: #{inspect(serialized)}")

    # RESTORE format: RESTORE key ttl serialized-value [REPLACE] [ABSTTL] [IDLETIME seconds] [FREQ frequency]
    # TTL 0 means no expiration
    restore_result = Redix.command!(redis, ["RESTORE", "restore_dest", "0", serialized])
    Logger.info("RESTORE result: #{inspect(restore_result)}")

    # MOVE - move key to another database (always to db 3)
    # Test with different data types to see how MOVE replicates
    # Explicitly SELECT before each pair of create+move
    Redix.command!(redis, ["SELECT", "#{db}"])
    Redix.command!(redis, ["SET", "move_string", "move_value"])
    Redix.command!(redis, ["MOVE", "move_string", "3"])
    Redix.command!(redis, ["SELECT", "#{db}"])
    Redix.command!(redis, ["RPUSH", "move_list", "a", "b", "c"])
    Redix.command!(redis, ["MOVE", "move_list", "3"])
    Redix.command!(redis, ["SELECT", "#{db}"])
    Redix.command!(redis, ["SADD", "move_set", "x", "y", "z"])
    Redix.command!(redis, ["MOVE", "move_set", "3"])
    Redix.command!(redis, ["SELECT", "#{db}"])
    Redix.command!(redis, ["HSET", "move_hash", "f1", "v1", "f2", "v2"])
    Redix.command!(redis, ["MOVE", "move_hash", "3"])
    Redix.command!(redis, ["SELECT", "#{db}"])
    Redix.command!(redis, ["ZADD", "move_zset", "1", "a", "2", "b"])
    Redix.command!(redis, ["MOVE", "move_zset", "3"])
    Redix.command!(redis, ["SELECT", "#{db}"])

    # EXPIRE/PEXPIRE - these are ignored (no-op) but we still want to test they're parsed
    Redix.command!(redis, ["SET", "expire_test_key", "expire_value"])
    Redix.command!(redis, ["EXPIRE", "expire_test_key", "3600"])
    Redix.command!(redis, ["PEXPIRE", "expire_test_key", "3600000"])
    Redix.command!(redis, ["EXPIREAT", "expire_test_key", "#{System.os_time(:second) + 86400}"])

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
    assert command_in_list({:set, "simple_key", "simple_value"}, commands),
           "Missing SET simple_key"

    # MSET might be broken down into individual SETs in RDB
    assert command_in_list({:mset, _}, commands) or
             (command_in_list({:set, "mkey1", _}, commands) and
                command_in_list({:set, "mkey2", _}, commands)),
           "Missing MSET or individual keys from MSET"

    # Final value after APPEND - saved as a SET
    assert command_in_list(
             {:set, "append_key", "initial_appended"},
             commands
           ),
           "Missing final state of append_key"

    # List commands - only final state (after all modifications)
    # mylist has LPUSH then RPUSH, final state will be present
    assert command_in_list({:rpush, "mylist", _}, commands) or
             command_in_list({:lpush, "mylist", _}, commands),
           "Missing mylist"

    # Set commands - final state
    assert command_in_list({:sadd, "myset", _}, commands), "Missing SADD myset"
    assert command_in_list({:sadd, "rem_set", _}, commands), "Missing SADD rem_set"

    # Set operations create result keys, but in RDB they're saved as SADDs
    assert command_in_list({:sadd, "set_inter", _}, commands),
           "Missing set_inter result"

    assert command_in_list({:sadd, "set_union", _}, commands),
           "Missing set_union result"

    assert command_in_list({:sadd, "set_diff", _}, commands),
           "Missing set_diff result"

    # Sorted set commands - final state
    assert command_in_list({:zadd, "myzset", _, _}, commands), "Missing ZADD myzset"

    # Sorted set operations create result keys, but in RDB they're saved as ZADDs
    assert command_in_list({:zadd, "zset_union", _, _}, commands),
           "Missing zset_union result"

    assert command_in_list({:zadd, "zset_inter", _, _}, commands),
           "Missing zset_inter result"

    # Hash commands - final state
    assert command_in_list({:hmset, "myhash", _}, commands), "Missing HSET myhash"

    assert command_in_list({:hmset, "hash_for_del", _}, commands),
           "Missing HSET hash_for_del"

    # Expiration
    assert command_in_list({:pexpireat, "expire_key", _}, commands),
           "Missing PEXPIREAT"

    # Key management - Renamed keys
    assert command_in_list({:set, "new_name", _}, commands),
           "Missing renamed key new_name"

    assert command_in_list({:set, "renamenx_new", _}, commands),
           "Missing renamenx key renamenx_new"

    # Deleted keys should not have any commands for them (checked via absence)
  end

  @doc """
  Verifies that the replica received all expected commands from streaming replication.

  In streaming mode, all commands are replicated as they happen, including modification commands.

  The `backend` parameter controls which commands are verified:
  - `:valkey`: All commands including hash field expiration (HEXPIRE, etc.)
  - `:redis`: Skips hash field expiration command checks which are Valkey-specific
  """
  def verify_streaming_commands(commands, backend \\ :valkey) do
    # String commands
    assert command_in_list({:set, "simple_key", "simple_value"}, commands),
           "Missing SET simple_key"

    assert command_in_list({:mset, _}, commands), "Missing MSET"
    assert command_in_list({:append, "append_key", _}, commands), "Missing APPEND"
    assert command_in_list({:setrange, "range_key", _, _}, commands), "Missing SETRANGE"
    assert command_in_list({:setbit, "bit_key", _, _}, commands), "Missing SETBIT"

    # Numeric commands replicate as-is in Redis 8.4.0
    assert command_in_list({:incr, "incr_key"}, commands),
           "Missing INCR command"

    assert command_in_list({:incrby, "incrby_key", 42}, commands),
           "Missing INCRBY command"

    assert command_in_list({:decr, "decr_key"}, commands),
           "Missing DECR command"

    assert command_in_list({:decrby, "decrby_key", 30}, commands),
           "Missing DECRBY command"

    # Conditional set commands replicate as-is
    assert command_in_list({:setnx, "setnx_key", _}, commands),
           "Missing SETNX command"

    assert command_in_list({:msetnx, _}, commands),
           "Missing MSETNX command"

    # Get-and-modify commands
    # GETSET is converted to SET in replication stream
    # GETDEL is converted to DEL in replication stream
    assert command_in_list({:set, "getset_key", "getset_value"}, commands),
           "Missing SET from GETSET (GETSET replicates as SET)"

    assert command_in_list({:del, ["getdel_key"]}, commands),
           "Missing DEL from GETDEL (GETDEL replicates as DEL)"

    # INCRBYFLOAT, SETEX, and PSETEX are converted to SET with options
    # They will be parsed as regular SET commands (options are ignored)
    assert command_in_list({:set, "incrbyfloat_key", _}, commands),
           "Missing SET from INCRBYFLOAT"

    assert command_in_list({:set, "setex_key", _}, commands),
           "Missing SET from SETEX"

    assert command_in_list({:set, "psetex_key", _}, commands),
           "Missing SET from PSETEX"

    # GETEX commands - get with TTL modification (Redis 6.2.0+)
    # GETEX with EX/PX/EXAT/PXAT replicates as PEXPIREAT
    assert command_in_list({:pexpireat, "getex_key", _}, commands),
           "Missing PEXPIREAT from GETEX with EX"

    # GETEX with PERSIST replicates as PERSIST
    assert command_in_list({:persist, "getex_persist_key"}, commands),
           "Missing PERSIST from GETEX with PERSIST"

    # DELIFEQ replicates as DEL (Valkey 9.0.0+)
    if backend == :valkey do
      assert command_in_list({:del, ["delifeq_key"]}, commands),
             "Missing DEL from DELIFEQ (DELIFEQ replicates as DEL)"
    end

    # List commands - all operations
    assert command_in_list({:rpush, "mylist", _}, commands), "Missing RPUSH mylist"
    assert command_in_list({:lpush, "mylist", _}, commands), "Missing LPUSH mylist"
    assert command_in_list({:lpushx, "other_list", _}, commands), "Missing LPUSHX"

    assert command_in_list({:rpushx, "yet_another_list", _}, commands),
           "Missing RPUSHX"

    assert command_in_list({:ltrim, "trim_list", _, _}, commands), "Missing LTRIM"
    assert command_in_list({:lset, "set_list", _, _}, commands), "Missing LSET"
    assert command_in_list({:linsert, "insert_list", _, _, _}, commands), "Missing LINSERT"
    assert command_in_list({:lpop, "pop_list"}, commands), "Missing LPOP"
    assert command_in_list({:rpop, "pop_list"}, commands), "Missing RPOP"
    assert command_in_list({:lrem, "rem_list", _, _}, commands), "Missing LREM"
    assert command_in_list({:rpoplpush, _, _}, commands), "Missing RPOPLPUSH"

    # LMOVE (Redis 6.2.0+)
    assert command_in_list({:lmove, "lmove_src", _, _, _}, commands), "Missing LMOVE"

    # LMPOP (Redis 7.0.0+) - replicates as LPOP with count
    assert command_in_list({:lpop_count, "lmpop_list1", 2}, commands),
           "Missing LPOP with count (from LMPOP)"

    # Blocking list commands - verify they replicate as non-blocking equivalents
    # BLPOP replicates as LPOP
    assert command_in_list({:lpop, "blpop_list"}, commands),
           "Missing LPOP (from BLPOP)"

    # BRPOP replicates as RPOP
    assert command_in_list({:rpop, "brpop_list"}, commands),
           "Missing RPOP (from BRPOP)"

    # BRPOPLPUSH replicates as RPOPLPUSH
    assert command_in_list({:rpoplpush, "brpoplpush_src", "brpoplpush_dst"}, commands),
           "Missing RPOPLPUSH (from BRPOPLPUSH)"

    # BLMOVE replicates as LMOVE
    assert command_in_list({:lmove, "blmove_src", _, _, _}, commands),
           "Missing LMOVE (from BLMOVE)"

    # BLMPOP replicates as LPOP with count
    assert command_in_list({:lpop_count, "blmpop_list1", 2}, commands),
           "Missing LPOP with count (from BLMPOP)"

    # Set commands
    assert command_in_list({:sadd, "myset", _}, commands), "Missing SADD myset"
    assert command_in_list({:srem, "rem_set", _}, commands), "Missing SREM"
    assert command_in_list({:smove, _, _, _}, commands), "Missing SMOVE"
    assert command_in_list({:sinterstore, _, _}, commands), "Missing SINTERSTORE"
    assert command_in_list({:sunionstore, _, _}, commands), "Missing SUNIONSTORE"
    assert command_in_list({:sdiffstore, _, _}, commands), "Missing SDIFFSTORE"

    # SPOP is replicated as SREM
    assert command_in_list({:sadd, "spop_set", _}, commands), "Missing SADD spop_set"

    assert command_in_list({:srem, "spop_set", _}, commands),
           "Missing SREM (from SPOP)"

    # Sorted set commands
    assert command_in_list({:zadd, "myzset", _, _}, commands), "Missing ZADD myzset"
    assert command_in_list({:zunionstore, _, _, _, _}, commands), "Missing ZUNIONSTORE"
    assert command_in_list({:zinterstore, _, _, _, _}, commands), "Missing ZINTERSTORE"

    # ZADD with CH option - verify commands are replicated
    assert command_in_list({:zadd, "zadd_ch_test", _, _}, commands),
           "Missing ZADD with CH option"

    # ZADD with GT option - verify commands are replicated
    assert command_in_list({:zadd, "zadd_gt_test", _, _}, commands),
           "Missing ZADD with GT option"

    # ZADD with GT and CH options together
    assert command_in_list({:zadd, "zadd_gt_ch_test", _, _}, commands),
           "Missing ZADD with GT and CH options"

    assert command_in_list({:zrem, "zset_for_rem", _}, commands), "Missing ZREM"
    assert command_in_list({:zpopmax, "pop_zset", _}, commands), "Missing ZPOPMAX"
    assert command_in_list({:zpopmin, "pop_zset", _}, commands), "Missing ZPOPMIN"

    assert command_in_list({:zremrangebyrank, "remrange_zset", _, _}, commands),
           "Missing ZREMRANGEBYRANK"

    assert command_in_list({:zremrangebyscore, "remrange_score_zset", _, _}, commands),
           "Missing ZREMRANGEBYSCORE"

    assert command_in_list({:zremrangebylex, "remrange_lex_zset", _, _}, commands),
           "Missing ZREMRANGEBYLEX"

    # ZINCRBY replicates as ZADD (with final score) in Redis
    assert command_in_list({:zadd, "zincrby_test", _, _}, commands),
           "Missing ZADD (from ZINCRBY)"

    # ZDIFFSTORE
    assert command_in_list({:zdiffstore, "zdiff_result", _}, commands),
           "Missing ZDIFFSTORE"

    # ZRANGESTORE
    assert command_in_list(
             {:zrangestore, "zrangestore_dest", "zrangestore_src", _, _, _},
             commands
           ),
           "Missing ZRANGESTORE"

    # ZMPOP replicates as ZPOPMAX or ZPOPMIN (on the first key with members)
    assert command_in_list({:zpopmax, "zmpop_zset1", 2}, commands),
           "Missing ZPOPMAX (from ZMPOP with MAX)"

    # Blocking sorted set commands - verify they replicate as non-blocking equivalents
    # BZPOPMAX replicates as ZPOPMAX
    assert command_in_list({:zpopmax, "bzpopmax_zset", _}, commands),
           "Missing ZPOPMAX (from BZPOPMAX)"

    # BZPOPMIN replicates as ZPOPMIN
    assert command_in_list({:zpopmin, "bzpopmin_zset", _}, commands),
           "Missing ZPOPMIN (from BZPOPMIN)"

    # BZMPOP replicates as ZPOPMAX/ZPOPMIN (on the first key with members)
    assert command_in_list({:zpopmin, "bzmpop_zset1", 2}, commands),
           "Missing ZPOPMIN (from BZMPOP with MIN)"

    # Hash commands
    assert command_in_list({:hmset, "myhash", _}, commands), "Missing HSET myhash"
    assert command_in_list({:hdel, "hash_for_del", _}, commands), "Missing HDEL"
    assert command_in_list({:hmset, "hmset_hash", _}, commands), "Missing HMSET"
    assert command_in_list({:hsetnx, "hsetnx_hash", _, _}, commands), "Missing HSETNX"

    assert command_in_list({:hincrby, "hincrby_hash", _, _}, commands),
           "Missing HINCRBY"

    # NOTE: HINCRBYFLOAT is replicated as HSETEX (Redis) or HSET (Valkey 9.0+)
    assert command_in_list({:hsetex, "hincrbyfloat_hash", _, _}, commands) or
             command_in_list({:hmset, "hincrbyfloat_hash", _}, commands),
           "Missing HSETEX or HSET (HINCRBYFLOAT replicated)"

    # Hash field expiration commands (Valkey-specific, not available in Redis)
    # NOTE: Valkey converts all expiration commands to HPEXPIREAT during replication.
    if backend == :valkey do
      assert command_in_list({:hexpire, "hexpire_hash", _, _, _}, commands) or
               command_in_list({:hpexpireat, "hexpire_hash", _, _, _}, commands),
             "Missing HEXPIRE or HPEXPIREAT"

      assert command_in_list({:hexpireat, "hexpire_hash", _, _, _}, commands) or
               command_in_list({:hpexpireat, "hexpire_hash", _, _, _}, commands),
             "Missing HEXPIREAT or HPEXPIREAT"

      assert command_in_list({:hpexpire, "hexpire_hash", _, _, _}, commands) or
               command_in_list({:hpexpireat, "hexpire_hash", _, _, _}, commands),
             "Missing HPEXPIRE or HPEXPIREAT"

      assert command_in_list({:hpexpireat, "hpexpireat_hash", _, _, _}, commands),
             "Missing HPEXPIREAT"

      assert command_in_list({:hpersist, "hpersist_hash", _}, commands),
             "Missing HPERSIST"

      # HGETEX with TTL option (Valkey 9.0.0+)
      # Valkey converts to HPEXPIREAT
      assert command_in_list({:hgetex, "hgetex_hash", _, _}, commands) or
               command_in_list({:hpexpireat, "hgetex_hash", _, _, _}, commands),
             "Missing HGETEX or HPEXPIREAT"
    end

    # Expiration
    assert command_in_list({:pexpireat, "expire_key", _}, commands),
           "Missing PEXPIREAT"

    # Key management
    assert command_in_list({:rename, _, _}, commands), "Missing RENAME"
    assert command_in_list({:renamenx, _, _}, commands), "Missing RENAMENX"
    assert Enum.any?(commands, fn cmd -> match?({:del, _}, cmd) end), "Missing DEL"

    # UNLINK - converted to DEL by CommandParser
    assert command_in_list({:del, ["unlink_key1", "unlink_key2"]}, commands),
           "Missing DEL (from UNLINK)"

    # COPY - replicates as COPY
    assert command_in_list({:copy, "copy_source", "copy_dest", _}, commands),
           "Missing COPY"

    # MOVE - replicates as MOVE (move_string to db 3)
    assert command_in_list({:move_key, "move_string", 3}, commands),
           "Missing MOVE for move_string"

    # EXPIRE/PEXPIRE/EXPIREAT - these are converted to PEXPIREAT in replication
    assert command_in_list({:pexpireat, "expire_test_key", _}, commands),
           "Missing PEXPIREAT (from EXPIRE/PEXPIRE/EXPIREAT)"
  end

  @id "vdr_id"

  setup %{backend: backend, conn_opts: conn_opts} do
    {:ok, redis} = Redix.start_link(conn_opts)
    Redix.command!(redis, ["FLUSHALL"])

    {:ok, redis: redis, conn_opts: conn_opts, backend: backend}
  end

  describe "low-level replica: comprehensive command replication" do
    @tag timeout: 30_000
    test "replicates all command types from RDB and streaming", %{
      redis: redis,
      conn_opts: conn_opts,
      backend: backend
    } do
      Logger.info("=== [Replica] Phase 1: Setting up diverse dataset in DB 0 ===")
      issue_diverse_commands(redis, 0, backend)

      # Ensure all data is persisted before starting replica
      Redix.command!(redis, ["SAVE"])

      Logger.info("=== [Replica] Phase 2: Starting replica and waiting for RDB sync ===")

      opts = [
        host: conn_opts[:host],
        port: conn_opts[:port],
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

      # Debug: log commands by type
      cmd_types =
        Enum.frequencies_by(db0_commands, fn cmd ->
          case cmd do
            {cmd_atom, _, _} when is_atom(cmd_atom) -> Atom.to_string(cmd_atom)
            {cmd_atom, _} when is_atom(cmd_atom) -> Atom.to_string(cmd_atom)
            _ -> "unknown"
          end
        end)

      Logger.info("RDB commands by type: #{inspect(cmd_types)}")

      verify_rdb_commands(db0_commands)

      Logger.info("=== [Replica] Phase 4: Issuing commands to DB 1 while streaming ===")

      issue_diverse_commands(redis, 1, backend)

      assert_within 3000 do
        callback_state = Replica.get_callback_state(replica)
        db1_commands = CollectorCallback.commands_for_db(callback_state, 1)
        assert 50 < length(db1_commands)
      end

      Logger.info("=== [Replica] Phase 5: Verifying streaming commands ===")

      callback_state = Replica.get_callback_state(replica)
      db1_commands = CollectorCallback.commands_for_db(callback_state, 1)

      # Debug: Log RESTORE-related commands to see how they replicate
      restore_commands =
        Enum.filter(db1_commands, fn cmd ->
          cmd_str = inspect(cmd)
          String.contains?(cmd_str, "restore")
        end)

      Logger.info(
        "=== RESTORE-related commands (by string match): #{inspect(restore_commands, pretty: true)} ==="
      )

      # Log all command types to see if RESTORE appears as something else
      all_types =
        Enum.frequencies_by(db1_commands, fn cmd ->
          case cmd do
            {cmd_atom, _, _} when is_atom(cmd_atom) -> cmd_atom
            {cmd_atom, _} when is_atom(cmd_atom) -> cmd_atom
            _ -> :unknown
          end
        end)

      Logger.info("=== All command types in streaming: #{inspect(all_types)} ===")

      verify_streaming_commands(db1_commands, backend)

      Replica.stop(replica)
    end
  end

  # ===== High-level Veidrodelis Tests =====

  describe "high-level veidrodelis: comprehensive data verification" do
    @tag timeout: 30_000
    test "verifies all data types from RDB and streaming via query API", %{
      redis: redis,
      conn_opts: conn_opts,
      backend: backend
    } do
      Logger.info("=== [Veidrodelis] Phase 1: Setting up diverse dataset in DB 0 ===")
      issue_diverse_commands(redis, 0, backend)

      Process.sleep(100)

      Logger.info("=== [Veidrodelis] Phase 2: Starting Veidrodelis and waiting for RDB sync ===")

      opts = [
        id: @id,
        host: conn_opts[:host],
        port: conn_opts[:port],
      ]

      {:ok, vdr} = Veidrodelis.start_link(opts)

      assert_within 5000 do
        assert :streaming == Veidrodelis.get_replication_state(vdr)
      end

      Logger.info("=== [Veidrodelis] Phase 3: Verifying RDB data via query API ===")

      # Wait for data to be fully processed
      Process.sleep(200)

      # String values
      assert {:ok, "simple_value"} == Veidrodelis.get(@id, 0, "simple_key")
      assert {:ok, "mval1"} == Veidrodelis.get(@id, 0, "mkey1")
      assert {:ok, "mval2"} == Veidrodelis.get(@id, 0, "mkey2")
      assert {:ok, "initial_appended"} == Veidrodelis.get(@id, 0, "append_key")
      assert {:ok, "rename_value"} == Veidrodelis.get(@id, 0, "new_name")
      assert {:ok, "value"} == Veidrodelis.get(@id, 0, "renamenx_new")
      assert {:ok, "will_expire"} == Veidrodelis.get(@id, 0, "expire_key")

      # Deleted keys should not exist
      assert {:ok, nil} == Veidrodelis.get(@id, 0, "delete_key1")
      assert {:ok, nil} == Veidrodelis.get(@id, 0, "delete_key2")
      assert {:ok, nil} == Veidrodelis.get(@id, 0, "old_name")

      # List values
      assert {:ok, 4} == Veidrodelis.llen(@id, 0, "mylist")

      assert {:ok, ["elem0", "elem1", "elem2", "elem3"]} ==
               Veidrodelis.lrange(@id, 0, "mylist", 0, -1)

      assert {:ok, ["b", "c", "d"]} == Veidrodelis.lrange(@id, 0, "trim_list", 0, -1)
      assert {:ok, ["x", "Y", "z"]} == Veidrodelis.lrange(@id, 0, "set_list", 0, -1)
      assert {:ok, ["a", "b", "c"]} == Veidrodelis.lrange(@id, 0, "insert_list", 0, -1)

      # After LPOP and RPOP, pop_list should have only "b"
      assert {:ok, ["b"]} == Veidrodelis.lrange(@id, 0, "pop_list", 0, -1)

      # Set values
      assert {:ok, 3} == Veidrodelis.scard(@id, 0, "myset")
      {:ok, members} = Veidrodelis.smembers(@id, 0, "myset")
      assert "member1" in members
      assert "member2" in members
      assert "member3" in members

      # rem_set should have m1 and m3 (m2 was removed)
      assert {:ok, 2} == Veidrodelis.scard(@id, 0, "rem_set")
      {:ok, rem_members} = Veidrodelis.smembers(@id, 0, "rem_set")
      assert "m1" in rem_members
      assert "m3" in rem_members
      refute "m2" in rem_members

      # Set operations
      {:ok, inter_members} = Veidrodelis.smembers(@id, 0, "set_inter")
      assert "2" in inter_members
      assert "3" in inter_members
      assert {:ok, 4} == Veidrodelis.scard(@id, 0, "set_union")
      assert {:ok, 1} == Veidrodelis.scard(@id, 0, "set_diff")

      # Hash values
      assert {:ok, 3} == Veidrodelis.hlen(@id, 0, "myhash")
      assert {:ok, "value1"} == Veidrodelis.hget(@id, 0, "myhash", "field1")
      assert {:ok, "value2"} == Veidrodelis.hget(@id, 0, "myhash", "field2")
      assert {:ok, "value3"} == Veidrodelis.hget(@id, 0, "myhash", "field3")

      # hash_for_del should have only f1 (f2 was deleted)
      assert {:ok, 1} == Veidrodelis.hlen(@id, 0, "hash_for_del")
      assert {:ok, "v1"} == Veidrodelis.hget(@id, 0, "hash_for_del", "f1")
      assert {:ok, nil} == Veidrodelis.hget(@id, 0, "hash_for_del", "f2")

      # HMSET verification
      assert {:ok, 2} == Veidrodelis.hlen(@id, 0, "hmset_hash")
      assert {:ok, "v1"} == Veidrodelis.hget(@id, 0, "hmset_hash", "f1")
      assert {:ok, "v2"} == Veidrodelis.hget(@id, 0, "hmset_hash", "f2")

      # HSETNX verification
      assert {:ok, "value1"} == Veidrodelis.hget(@id, 0, "hsetnx_hash", "existing")
      assert {:ok, "new_value"} == Veidrodelis.hget(@id, 0, "hsetnx_hash", "new_field")

      # HINCRBY verification (10 + 5 = 15)
      assert {:ok, "15"} == Veidrodelis.hget(@id, 0, "hincrby_hash", "counter")
      assert {:ok, "100"} == Veidrodelis.hget(@id, 0, "hincrby_hash", "new_counter")

      # HINCRBYFLOAT verification (10.5 + 3.7 = 14.2)
      {:ok, score} = Veidrodelis.hget(@id, 0, "hincrbyfloat_hash", "score")
      assert_in_delta String.to_float(score), 14.2, 0.0001
      {:ok, new_score} = Veidrodelis.hget(@id, 0, "hincrbyfloat_hash", "new_score")
      assert_in_delta String.to_float(new_score), 42.3, 0.0001

      # Sorted set values
      assert {:ok, 3} == Veidrodelis.zcard(@id, 0, "myzset")
      assert {:ok, 1.0} == Veidrodelis.zscore(@id, 0, "myzset", "member1")
      assert {:ok, 2.5} == Veidrodelis.zscore(@id, 0, "myzset", "member2")
      assert {:ok, 3.7} == Veidrodelis.zscore(@id, 0, "myzset", "member3")

      # zset_for_rem should have x and z (y was removed)
      assert {:ok, 2} == Veidrodelis.zcard(@id, 0, "zset_for_rem")
      assert {:ok, 1.0} == Veidrodelis.zscore(@id, 0, "zset_for_rem", "x")
      assert {:ok, 3.0} == Veidrodelis.zscore(@id, 0, "zset_for_rem", "z")
      assert {:ok, nil} == Veidrodelis.zscore(@id, 0, "zset_for_rem", "y")

      # pop_zset should have only "b" after ZPOPMAX and ZPOPMIN
      assert {:ok, 1} == Veidrodelis.zcard(@id, 0, "pop_zset")
      assert {:ok, 2.0} == Veidrodelis.zscore(@id, 0, "pop_zset", "b")

      # Verify set/zset operations created correct results
      {:ok, zcard_union} = Veidrodelis.zcard(@id, 0, "zset_union")
      assert zcard_union > 0
      {:ok, zcard_inter} = Veidrodelis.zcard(@id, 0, "zset_inter")
      assert zcard_inter > 0

      # Verify ZINCRBY results (replicated as ZADD with final scores)
      # Test 1: existing key, existing member (10.0 + 5.5 = 15.5)
      assert {:ok, 15.5} == Veidrodelis.zscore(@id, 0, "zincrby_test", "counter")

      # Test 2: existing key, non-existing member (0 + 7.5 = 7.5)
      assert {:ok, 2} == Veidrodelis.zcard(@id, 0, "zincrby_test2")
      assert {:ok, 1.0} == Veidrodelis.zscore(@id, 0, "zincrby_test2", "existing")
      assert {:ok, 7.5} == Veidrodelis.zscore(@id, 0, "zincrby_test2", "new_member")

      # Test 3: non-existing key (creates key with member at score 42.0)
      assert {:ok, 1} == Veidrodelis.zcard(@id, 0, "zincrby_new_key")
      assert {:ok, 42.0} == Veidrodelis.zscore(@id, 0, "zincrby_new_key", "member1")

      # Test 4: negative delta (100.0 - 25.5 = 74.5)
      assert {:ok, 74.5} == Veidrodelis.zscore(@id, 0, "zincrby_decr", "score")

      # ZADD with CH option - verify final state
      assert {:ok, 2} == Veidrodelis.zcard(@id, 0, "zadd_ch_test")
      assert {:ok, 1.0} == Veidrodelis.zscore(@id, 0, "zadd_ch_test", "member1")
      assert {:ok, 3.0} == Veidrodelis.zscore(@id, 0, "zadd_ch_test", "member2")

      # ZADD with GT option - verify final state (score should be 10, not 3)
      assert {:ok, 1} == Veidrodelis.zcard(@id, 0, "zadd_gt_test")
      assert {:ok, 10.0} == Veidrodelis.zscore(@id, 0, "zadd_gt_test", "member")

      # ZADD with GT and CH options - verify final state
      # m1 should still be 5 (3 < 5, so not updated)
      # m2 should be 15 (15 > 10, so updated)
      assert {:ok, 2} == Veidrodelis.zcard(@id, 0, "zadd_gt_ch_test")
      assert {:ok, 5.0} == Veidrodelis.zscore(@id, 0, "zadd_gt_ch_test", "m1")
      assert {:ok, 15.0} == Veidrodelis.zscore(@id, 0, "zadd_gt_ch_test", "m2")

      Logger.info("=== [Veidrodelis] Phase 4: Issuing commands to DB 1 while streaming ===")

      issue_diverse_commands(redis, 1, backend)

      # Wait for streaming replication
      assert_within 3000 do
        assert {:ok, "simple_value"} == Veidrodelis.get(@id, 1, "simple_key")
        assert {:ok, 4} == Veidrodelis.llen(@id, 1, "mylist")
        assert {:ok, 3} == Veidrodelis.scard(@id, 1, "myset")
        assert {:ok, 3} == Veidrodelis.hlen(@id, 1, "myhash")
        assert {:ok, 3} == Veidrodelis.zcard(@id, 1, "myzset")
      end

      Logger.info("=== [Veidrodelis] Phase 5: Verifying streaming data via query API ===")

      # String values
      assert {:ok, "simple_value"} == Veidrodelis.get(@id, 1, "simple_key")
      assert {:ok, "mval1"} == Veidrodelis.get(@id, 1, "mkey1")
      assert {:ok, "initial_appended"} == Veidrodelis.get(@id, 1, "append_key")

      # List values
      assert {:ok, 4} == Veidrodelis.llen(@id, 1, "mylist")

      assert {:ok, ["elem0", "elem1", "elem2", "elem3"]} ==
               Veidrodelis.lrange(@id, 1, "mylist", 0, -1)

      # Set values
      assert {:ok, 3} == Veidrodelis.scard(@id, 1, "myset")
      {:ok, members_db1} = Veidrodelis.smembers(@id, 1, "myset")
      assert "member1" in members_db1
      assert "member2" in members_db1
      assert "member3" in members_db1

      # Hash values
      assert {:ok, 3} == Veidrodelis.hlen(@id, 1, "myhash")
      assert {:ok, "value1"} == Veidrodelis.hget(@id, 1, "myhash", "field1")

      # Sorted set values
      assert {:ok, 3} == Veidrodelis.zcard(@id, 1, "myzset")
      assert {:ok, 1.0} == Veidrodelis.zscore(@id, 1, "myzset", "member1")

      # Verify ZINCRBY results in DB 1 (streaming replication)
      assert {:ok, 15.5} == Veidrodelis.zscore(@id, 1, "zincrby_test", "counter")
      assert {:ok, 7.5} == Veidrodelis.zscore(@id, 1, "zincrby_test2", "new_member")
      assert {:ok, 42.0} == Veidrodelis.zscore(@id, 1, "zincrby_new_key", "member1")
      assert {:ok, 74.5} == Veidrodelis.zscore(@id, 1, "zincrby_decr", "score")

      # Verify ZADD with CH option in DB 1 (streaming replication)
      assert {:ok, 2} == Veidrodelis.zcard(@id, 1, "zadd_ch_test")
      assert {:ok, 1.0} == Veidrodelis.zscore(@id, 1, "zadd_ch_test", "member1")
      assert {:ok, 3.0} == Veidrodelis.zscore(@id, 1, "zadd_ch_test", "member2")

      # Verify ZADD with GT option in DB 1 (streaming replication)
      assert {:ok, 1} == Veidrodelis.zcard(@id, 1, "zadd_gt_test")
      assert {:ok, 10.0} == Veidrodelis.zscore(@id, 1, "zadd_gt_test", "member")

      # Verify ZADD with GT and CH options in DB 1 (streaming replication)
      assert {:ok, 2} == Veidrodelis.zcard(@id, 1, "zadd_gt_ch_test")
      assert {:ok, 5.0} == Veidrodelis.zscore(@id, 1, "zadd_gt_ch_test", "m1")
      assert {:ok, 15.0} == Veidrodelis.zscore(@id, 1, "zadd_gt_ch_test", "m2")

      Logger.info("=== [Veidrodelis] Test completed successfully ===")

      Veidrodelis.stop(vdr)
    end
  end
end
