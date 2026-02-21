defmodule Veidrodelis.Integration.LuaCommandsTest do
  @moduledoc """
  Smoke test for the Lua interface to TS storage.

  This test:
  1. Sets up test data in Redis using Redix
  2. Starts a Veidrodelis instance to replicate the data
  3. Runs comprehensive Lua scripts via Veidrodelis.read_tx/3
  4. Verifies all ts.* functions work correctly
  """

  @redis [host: "localhost", port: 26378]

  use ExUnit.Case, async: false
  use CommandMatchers

  require Logger

  @id "lua_test_vdr"

  setup do
    {:ok, redis} = Redix.start_link(@redis)
    Redix.command!(redis, ["FLUSHALL"])

    {:ok, redis: redis}
  end

  @doc """
  Prepares a diverse dataset in Redis covering all Redis data types.
  """
  def prepare_test_data(redis) do
    # String data
    Redix.command!(redis, ["SET", "string_key", "hello_world"])

    # List data
    Redix.command!(redis, ["RPUSH", "list_key", "item1", "item2", "item3", "item4", "item5"])
    Redix.command!(redis, ["LPUSH", "list_key", "item0"])

    # Set data
    Redix.command!(redis, ["SADD", "set_a", "member1", "member2", "member3"])
    Redix.command!(redis, ["SADD", "set_b", "member2", "member3", "member4"])
    Redix.command!(redis, ["SADD", "set_c", "member3", "member4", "member5"])

    # Hash data
    Redix.command!(redis, [
      "HSET",
      "hash_key",
      "field1",
      "value1",
      "field2",
      "value2",
      "field3",
      "value3",
      "field4",
      "value4"
    ])

    # Sorted set data
    Redix.command!(redis, [
      "ZADD",
      "zset_key",
      "1.0",
      "member_a",
      "2.5",
      "member_b",
      "3.7",
      "member_c",
      "5.0",
      "member_d",
      "7.2",
      "member_e"
    ])

    # Persist to RDB
    Redix.command!(redis, ["SAVE"])

    :ok
  end

  describe "lua smoke test" do
    @tag timeout: 30_000
    test "executes all known Lua functions and gathers results", %{redis: redis} do
      Logger.info("=== Setting up test data in Redis ===")
      prepare_test_data(redis)

      Logger.info("=== Starting Veidrodelis for replication ===")

      opts = [
        id: @id,
        host: @redis[:host],
        port: @redis[:port]
      ]

      {:ok, vdr} = Veidrodelis.start_link(opts)

      # Wait for streaming state
      assert_within 5000 do
        assert :streaming == Veidrodelis.get_replication_state(vdr)
      end

      db = 0

      # Comprehensive Lua script that exercises all ts.* functions
      lua_script = """
      local results = {}

      -- String functions
      results.string_get = ts.get("string_key")

      -- List functions
      results.list_llen = ts.llen("list_key")
      results.list_lrange = ts.lrange("list_key", 0, -1)
      results.list_lrange_partial = ts.lrange("list_key", 1, 3)

      -- Set functions
      results.set_smembers = ts.smembers("set_a")
      results.set_scard = ts.scard("set_a")
      results.set_sismember_true = ts.sismember("set_a", "member1")
      results.set_sismember_false = ts.sismember("set_a", "nonexistent")
      results.set_sfirst = ts.sfirst("set_a", 1)
      results.set_slast = ts.slast("set_a", 1)
      results.set_snext = ts.snext("set_a", "member1", 1)
      results.set_sprev = ts.sprev("set_a", "member3", 1)

      -- Set operations
      results.set_smismember = ts.smismember("set_a", {"member1", "member2", "nonexistent"})
      results.set_srandmember = ts.srandmember("set_a", 2)
      results.set_sunion = ts.sunion({"set_a", "set_b"})
      results.set_sinter = ts.sinter({"set_a", "set_b"})
      results.set_sdiff = ts.sdiff({"set_a", "set_b"})
      results.set_sintercard = ts.sintercard({"set_a", "set_b"})

      -- Hash functions
      results.hash_hget = ts.hget("hash_key", "field1")
      results.hash_hmget = ts.hmget("hash_key", {"field1", "field2", "nonexistent"})
      results.hash_hgetall = ts.hgetall("hash_key")
      results.hash_hkeys = ts.hkeys("hash_key")
      results.hash_hvals = ts.hvals("hash_key")
      results.hash_hlen = ts.hlen("hash_key")
      results.hash_hexists_true = ts.hexists("hash_key", "field1")
      results.hash_hexists_false = ts.hexists("hash_key", "nonexistent")
      results.hash_hfirst = ts.hfirst("hash_key", 1)
      results.hash_hlast = ts.hlast("hash_key", 1)
      results.hash_hnext = ts.hnext("hash_key", "field1", 1)
      results.hash_hprev = ts.hprev("hash_key", "field4", 1)
      results.hash_hstrlen = ts.hstrlen("hash_key", "field1")
      results.hash_hrandfield = ts.hrandfield("hash_key", 2, true)

      -- Sorted set functions
      results.zset_zscore = ts.zscore("zset_key", "member_b")
      results.zset_zcard = ts.zcard("zset_key")
      results.zset_zrange = ts.zrange("zset_key", 0, -1)
      results.zset_zrangebyscore = ts.zrangebyscore("zset_key", 2.0, 5.0)
      results.zset_zrank = ts.zrank("zset_key", "member_c")
      results.zset_zrevrank = ts.zrevrank("zset_key", "member_c")
      results.zset_zcount = ts.zcount("zset_key", 2.0, 5.0)
      results.zset_zfirst = ts.zfirst("zset_key", 1)
      results.zset_zlast = ts.zlast("zset_key", 1)
      results.zset_znext = ts.znext("zset_key", "member_b", 1)
      results.zset_zprev = ts.zprev("zset_key", "member_c", 1)

      -- Non-existent key tests
      results.nil_string = ts.get("nonexistent_string")
      results.nil_hash = ts.hget("nonexistent_hash", "field")
      results.nil_zscore = ts.zscore("nonexistent_zset", "member")

      return results
      """

      # Execute the Lua script via Veidrodelis
      assert {:ok, results} = Veidrodelis.read_tx(@id, db, lua_script)

      # Verify string results
      assert results["string_get"] == "hello_world"

      # Verify list results
      assert results["list_llen"] == 6
      assert length(results["list_lrange"]) == 6
      assert length(results["list_lrange_partial"]) == 3

      # Verify set results
      assert length(results["set_smembers"]) == 3
      assert results["set_scard"] == 3
      assert results["set_sismember_true"] == true
      assert results["set_sismember_false"] == false
      assert is_list(results["set_sfirst"])
      assert is_list(results["set_slast"])
      assert is_list(results["set_snext"])
      assert is_list(results["set_sprev"])

      # Set operations
      assert length(results["set_smismember"]) == 3
      assert length(results["set_srandmember"]) == 2
      assert length(results["set_sunion"]) >= 3
      assert length(results["set_sinter"]) >= 1
      assert length(results["set_sdiff"]) >= 1
      assert is_integer(results["set_sintercard"])

      # Hash results
      assert results["hash_hget"] == "value1"
      # HMGET returns values for each requested field (nil for non-existent)
      assert length(results["hash_hmget"]) >= 2
      assert is_map(results["hash_hgetall"])
      assert map_size(results["hash_hgetall"]) == 4
      assert length(results["hash_hkeys"]) == 4
      assert length(results["hash_hvals"]) == 4
      assert results["hash_hlen"] == 4
      assert results["hash_hexists_true"] == true
      assert results["hash_hexists_false"] == false
      # hfirst/hlast/hnext/hprev return lists of [field, value]
      assert is_list(results["hash_hfirst"])
      assert is_list(results["hash_hlast"])
      assert is_list(results["hash_hnext"])
      assert is_list(results["hash_hprev"])
      assert is_integer(results["hash_hstrlen"])
      assert length(results["hash_hrandfield"]) == 2

      # Sorted set results
      assert results["zset_zscore"] == 2.5
      assert results["zset_zcard"] == 5
      assert length(results["zset_zrange"]) == 5
      assert length(results["zset_zrangebyscore"]) >= 1
      assert is_integer(results["zset_zrank"])
      assert is_integer(results["zset_zrevrank"])
      assert results["zset_zcount"] == 3
      # zfirst/zlast/znext/zprev return lists of [score, member]
      assert is_list(results["zset_zfirst"])
      assert is_list(results["zset_zlast"])
      assert is_list(results["zset_znext"])
      assert is_list(results["zset_zprev"])

      # Non-existent key tests
      assert results["nil_string"] == nil
      assert results["nil_hash"] == nil
      assert results["nil_zscore"] == nil

      Veidrodelis.stop(vdr)
    end

    @tag timeout: 30_000
    test "lua supports smnext/smprev hmnext/hmprev zmnext/zmprev and mfirst/mlast smoke test", %{
      redis: redis
    } do
      prepare_test_data(redis)

      opts = [
        id: @id,
        host: @redis[:host],
        port: @redis[:port]
      ]

      {:ok, vdr} = Veidrodelis.start_link(opts)

      assert_within 5000 do
        assert :streaming == Veidrodelis.get_replication_state(vdr)
      end

      script = """
      local result = {}
      result.smnext = ts.snext("set_a", "member1", 2)
      result.smprev = ts.sprev("set_a", "member3", 2)
      result.smfirst = ts.sfirst("set_a", 2)
      result.smlast = ts.slast("set_a", 2)
      result.hmnext = ts.hnext("hash_key", "field1", 2)
      result.hmprev = ts.hprev("hash_key", "field4", 2)
      result.hmfirst = ts.hfirst("hash_key", 2)
      result.hmlast = ts.hlast("hash_key", 2)
      result.zmnext = ts.znext("zset_key", "member_b", 2)
      result.zmprev = ts.zprev("zset_key", "member_d", 2)
      result.zmfirst = ts.zfirst("zset_key", 2)
      result.zmlast = ts.zlast("zset_key", 2)
      return result
      """

      assert {:ok, result} = Veidrodelis.read_tx(@id, 0, script)
      assert result["smnext"] == ["member2", "member3"]
      assert result["smprev"] == ["member2", "member1"]
      assert result["smfirst"] == ["member1", "member2"]
      assert result["smlast"] == ["member3", "member2"]
      assert result["hmnext"] == [["field2", "value2"], ["field3", "value3"]]
      assert result["hmprev"] == [["field3", "value3"], ["field2", "value2"]]
      assert result["hmfirst"] == [["field1", "value1"], ["field2", "value2"]]
      assert result["hmlast"] == [["field4", "value4"], ["field3", "value3"]]
      assert result["zmnext"] == [[3.7, "member_c"], [5.0, "member_d"]]
      assert result["zmprev"] == [[3.7, "member_c"], [2.5, "member_b"]]
      assert result["zmfirst"] == [[1.0, "member_a"], [2.5, "member_b"]]
      assert result["zmlast"] == [[7.2, "member_e"], [5.0, "member_d"]]

      Veidrodelis.stop(vdr)
    end

    @tag timeout: 30_000
    test "lua traverses zset in batches as in README/about", %{redis: redis} do
      args =
        ["ZADD", "leaderboard"] ++
          Enum.flat_map(0..25, fn i ->
            member = [?a + i]
            score = i
            [score, member]
          end)

      Redix.command!(redis, args)

      opts = [
        id: @id,
        host: @redis[:host],
        port: @redis[:port]
      ]

      {:ok, vdr} = Veidrodelis.start_link(opts)

      assert_within 5000 do
        assert :streaming == Veidrodelis.get_replication_state(vdr)
      end

      script = """
      local timeline = {}
      local batch_size = 10
      local batch = ts.zfirst('leaderboard', batch_size)

      while #batch > 0 do
        for i = 1, #batch do
          local item = batch[i]
          local score = item[1]
          local member = item[2]
          table.insert(timeline, {member, score})
        end

        local last_member = batch[#batch][2]
        batch = ts.znext('leaderboard', last_member, batch_size)
      end
      return timeline
      """

      assert {:ok, timeline} = Veidrodelis.read_tx(@id, 0, script)
      assert length(timeline) == 26
      assert List.first(timeline) == ["a", 0.0]
      assert List.last(timeline) == ["z", 25.0]

      Veidrodelis.stop(vdr)
    end

    @tag timeout: 30_000
    test "lua_load compiles script to bytecode and executes correctly", %{redis: redis} do
      prepare_test_data(redis)

      opts = [
        id: @id,
        host: @redis[:host],
        port: @redis[:port]
      ]

      {:ok, vdr} = Veidrodelis.start_link(opts)

      assert_within 5000 do
        assert :streaming == Veidrodelis.get_replication_state(vdr)
      end

      Process.sleep(200)

      db = 0

      # Original script
      script = """
      return {
        value = ts.get("string_key"),
        count = ts.scard("set_a")
      }
      """

      # Compile to bytecode via Veidrodelis
      assert {:ok, bytecode} = Veidrodelis.lua_load(@id, script)
      assert is_binary(bytecode)

      # Execute the bytecode via Veidrodelis
      assert {:ok, results} = Veidrodelis.read_tx(@id, db, bytecode)
      assert results["value"] == "hello_world"
      assert results["count"] == 3

      Veidrodelis.stop(vdr)
    end

    @tag timeout: 30_000
    test "handles errors gracefully", %{redis: redis} do
      prepare_test_data(redis)

      opts = [
        id: @id,
        host: @redis[:host],
        port: @redis[:port]
      ]

      {:ok, vdr} = Veidrodelis.start_link(opts)

      assert_within 5000 do
        assert :streaming == Veidrodelis.get_replication_state(vdr)
      end

      db = 0

      # Script with syntax error
      bad_script = """
      this is not valid lua syntax!!!
      """

      assert {:error, _reason} = Veidrodelis.read_tx(@id, db, bad_script)

      # Script accessing non-existent functions
      unknown_script = """
      return ts.unknown_function("key")
      """

      assert {:error, _reason} = Veidrodelis.read_tx(@id, db, unknown_script)

      Veidrodelis.stop(vdr)
    end

    @tag timeout: 30_000
    test "lua script returns complex nested structures", %{redis: redis} do
      prepare_test_data(redis)

      opts = [
        id: @id,
        host: @redis[:host],
        port: @redis[:port]
      ]

      {:ok, vdr} = Veidrodelis.start_link(opts)

      assert_within 5000 do
        assert :streaming == Veidrodelis.get_replication_state(vdr)
      end

      db = 0

      script = """
      local first = ts.zfirst("zset_key", 1)[1]
      local last = ts.zlast("zset_key", 1)[1]

      return {
        strings = {
          key1 = ts.get("string_key"),
          key2 = nil
        },
        lists = {
          length = ts.llen("list_key"),
          items = ts.lrange("list_key", 0, 2)
        },
        sets = {
          members = ts.smembers("set_a"),
          card = ts.scard("set_a")
        },
        hashes = {
          all = ts.hgetall("hash_key"),
          len = ts.hlen("hash_key")
        },
        zsets = {
          first = first,
          last = last,
          range = ts.zrange("zset_key", 1, 3)
        }
      }
      """

      assert {:ok, results} = Veidrodelis.read_tx(@id, db, script)

      # Verify nested structure with a single pattern match
      assert %{
               "strings" => %{"key1" => "hello_world"},
               "lists" => %{"length" => 6, "items" => [_ | _]},
               "sets" => %{"members" => [_, _, _], "card" => 3},
               "hashes" => %{"all" => %{"field1" => _}, "len" => 4},
               "zsets" => %{
                 "first" => [_, "member_a"],
                 "last" => [_, "member_e"],
                 "range" => [_ | _]
               }
             } = results

      Veidrodelis.stop(vdr)
    end
  end
end
