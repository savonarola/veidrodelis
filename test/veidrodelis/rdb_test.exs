defmodule Vdr.RedisStream.RDBTest do
  @moduledoc """
  Tests for RDB parsing by generating data in Valkey and verifying Veidrodelis receives it correctly.

  This test exercises all RDB data types supported by rdb.rs:
  - Strings (integer, embstr, raw, LZF-compressed)
  - Lists (listpack, quicklist, quicklist v2)
  - Sets (intset, hashtable, listpack)
  - Sorted sets (ziplist/listpack, skiplist)
  - Hashes (listpack, hashtable)
  """

  use ExUnit.Case, async: false

  @valkey [host: "localhost", port: 16378]

  use CommandMatchers
  require Logger

  @id "rdb_test_id"

  setup do
    {:ok, valkey} = Redix.start_link(@valkey)
    Redix.command!(valkey, ["FLUSHALL"])

    {:ok, valkey: valkey}
  end

  @doc """
  Issues commands to create diverse data types that will be saved in RDB format.
  Uses various encodings to ensure comprehensive RDB coverage.
  """
  def issue_rdb_diverse_commands(valkey) do
    # ===== String Commands - Various Encodings =====
    # Integer-encoded string (small integer values are encoded efficiently)
    Redix.command!(valkey, ["SET", "str_int", "1234567890"])

    # embstr string (short strings use embedded string encoding)
    Redix.command!(valkey, ["SET", "str_embstr", "this is a short embstr string"])

    # Raw string (longer strings use raw encoding)
    long_string =
      String.duplicate("This string is intentionally made very long to force raw encoding. ", 20)

    Redix.command!(valkey, ["SET", "str_raw", long_string])

    # LZF-compressed string (highly compressible data triggers compression)
    compressible = String.duplicate("a", 1000)
    Redix.command!(valkey, ["SET", "str_compressible_lzf", compressible])

    # String with expiration
    Redix.command!(valkey, ["SET", "str_with_expire", "will_expire"])

    Redix.command!(valkey, [
      "PEXPIREAT",
      "str_with_expire",
      "#{System.os_time(:millisecond) + 86_400_000}"
    ])

    # ===== List Commands - Various Encodings =====
    # Listpack-encoded list (small lists use listpack)
    Redix.command!(valkey, ["RPUSH", "list_listpack", "first", "second", "third", "4", "five"])

    # Quicklist with big element (forces quicklist encoding)
    big_element =
      "This single element is intentionally large to force quicklist encoding with LZF compression. It exceeds the list-max-listpack-size setting. " <>
        String.duplicate("X", 500)

    Redix.command!(valkey, ["RPUSH", "list_quicklist_big_element", big_element])

    # Quicklist with many elements
    Enum.each(1..78, fn i ->
      suffix =
        if i <= 26, do: <<?a + i - 1>>, else: <<?a + rem(i - 1, 26) - 1>> <> "#{div(i - 1, 26)}"

      Redix.command!(valkey, ["RPUSH", "list_quicklist_many_elements", suffix])
    end)

    # Guaranteed quicklist (multiple elements that exceed listpack limits)
    Redix.command!(valkey, ["RPUSH", "list_guaranteed_quicklist", "alpha", "beta", "gamma"])

    # ===== Hash Commands - Various Encodings =====
    # Listpack-encoded hash (small hashes use listpack)
    Redix.command!(valkey, [
      "HSET",
      "hash_listpack",
      "field1",
      "value1",
      "name",
      "valkey",
      "version",
      "7.2"
    ])

    # Hashtable-encoded hash (large field values force hashtable)
    Redix.command!(valkey, ["HSET", "hash_hashtable", "field1", "value1"])

    large_value =
      "This is an extremely long value that will force hashtable encoding for this hash field. " <>
        String.duplicate("Y", 200)

    Redix.command!(valkey, ["HSET", "hash_hashtable", "field2", large_value])

    # ===== Set Commands - Various Encodings =====
    # Intset-encoded set (small integers use intset, 16-bit)
    Redix.command!(valkey, ["SADD", "set_intset", "100", "200", "300", "42", "999", "10000"])

    # Intset with larger integers that force 32-bit encoding
    Redix.command!(valkey, ["SADD", "set_intset_32bit", "100000", "500000", "999999"])

    # Intset with very large integers that force 64-bit encoding
    Redix.command!(valkey, [
      "SADD",
      "set_intset_64bit",
      "10000000000",
      "50000000000",
      "99999999999"
    ])

    # Hashtable-encoded set (strings use hashtable)
    Redix.command!(valkey, [
      "SADD",
      "set_hashtable",
      "apple",
      "banana",
      "cherry",
      "123",
      "another-string"
    ])

    # ===== Sorted Set Commands - Various Encodings =====
    # Listpack-encoded zset (small zsets use listpack)
    Redix.command!(valkey, ["ZADD", "zset_listpack", "1.0", "one", "2.0", "two", "3.0", "three"])

    # Skiplist-encoded zset (larger zsets or larger values use skiplist)
    Redix.command!(valkey, ["ZADD", "zset_skiplist", "1.0", "member_one", "2.0", "member_two"])

    long_member =
      "This is an exceptionally long member name that will force skiplist encoding instead of listpack. " <>
        String.duplicate("Z", 200)

    Redix.command!(valkey, ["ZADD", "zset_skiplist", "3.0", long_member])

    # Store long_member for later verification
    Process.put(:long_member, long_member)

    # ===== Hash with Per-Field TTLs (Valkey 9.0+) =====
    # Tests RDB_TYPE_HASH_2 (type 22) - hash with field-level expiration
    # Create hash with per-field TTLs using HEXPIRE command
    Redix.command!(valkey, ["HSET", "hash_with_ttl", "field1", "value1", "field2", "value2"])

    # Set expiration on individual fields (this creates RDB_TYPE_HASH_2 in RDB)
    # HEXPIRE key field seconds
    Redix.command!(valkey, ["HEXPIRE", "hash_with_ttl", "3600", "FIELDS", "1", "field1"])

    # Ensure all data is persisted
    Redix.command!(valkey, ["SAVE"])
  end

  @doc """
  Issues commands to create unsupported data types (streams, HyperLogLog, etc.)
  to verify that the RDB parser correctly skips them without crashing.
  """
  def issue_unsupported_types_commands(valkey) do
    # Create a stream (RDB type 15 - STREAM_LISTPACKS)
    # Streams are not supported by Veidrodelis
    try do
      Redix.command!(valkey, ["XADD", "test_stream", "*", "field1", "value1", "field2", "value2"])
      Redix.command!(valkey, ["XADD", "test_stream", "*", "field3", "value3"])
      Logger.info("Created stream 'test_stream'")
    catch
      :error, %{reason: :unknown_command} ->
        Logger.warning("XADD not supported - skipping stream creation")
    end

    Redix.command!(valkey, ["PFADD", "test_hll", "element1", "element2", "element3"])

    Redix.command!(valkey, ["SETBIT", "test_bitmap", "100", "1"])
    Redix.command!(valkey, ["SETBIT", "test_bitmap", "200", "1"])
    Redix.command!(valkey, ["SETBIT", "test_bitmap", "1000", "1"])

    Redix.command!(valkey, ["XADD", "test_stream_cg", "*", "data", "value1"])
    Redix.command!(valkey, ["XGROUP", "CREATE", "test_stream_cg", "mygroup", "$"])
    Redix.command!(valkey, ["XADD", "test_stream_cg", "*", "data", "value2"])

    # Persist all data
    Redix.command!(valkey, ["SAVE"])
  end

  describe "RDB data replication via Veidrodelis" do
    @tag timeout: 30_000
    test "replicates all data types from RDB snapshot", %{valkey: valkey} do
      Logger.info("=== Phase 1: Creating diverse dataset for RDB ===")
      issue_rdb_diverse_commands(valkey)

      Logger.info("=== Phase 2: Starting Veidrodelis and waiting for RDB sync ===")

      opts = [
        id: @id,
        host: @valkey[:host],
        port: @valkey[:port]
      ]

      {:ok, vdr} = Veidrodelis.start_link(opts)

      assert_within 5000 do
        assert :streaming == Veidrodelis.get_replication_state(vdr)
      end

      # Wait for data to be fully processed
      Process.sleep(200)

      Logger.info("=== Phase 3: Verifying all data types from RDB ===")

      # ===== String Verification =====
      assert {:ok, "1234567890"} == Veidrodelis.get(@id, 0, "str_int")
      assert {:ok, "this is a short embstr string"} == Veidrodelis.get(@id, 0, "str_embstr")

      {:ok, raw_str} = Veidrodelis.get(@id, 0, "str_raw")
      assert is_binary(raw_str)
      assert raw_str =~ "This string is intentionally made very long"

      {:ok, lzf_str} = Veidrodelis.get(@id, 0, "str_compressible_lzf")
      assert byte_size(lzf_str) >= 1000
      assert String.to_charlist(lzf_str) |> Enum.all?(&(&1 == ?a))

      # String with expiration should still have value
      assert {:ok, "will_expire"} == Veidrodelis.get(@id, 0, "str_with_expire")

      # ===== List Verification =====
      # Listpack-encoded list
      assert {:ok, 5} == Veidrodelis.llen(@id, 0, "list_listpack")
      {:ok, listpack_items} = Veidrodelis.lrange(@id, 0, "list_listpack", 0, -1)
      assert "first" in listpack_items
      assert "second" in listpack_items
      assert "third" in listpack_items
      assert "4" in listpack_items
      assert "five" in listpack_items

      # Quicklist with big element
      assert {:ok, 1} == Veidrodelis.llen(@id, 0, "list_quicklist_big_element")
      {:ok, [big_elem]} = Veidrodelis.lrange(@id, 0, "list_quicklist_big_element", 0, -1)
      assert byte_size(big_elem) > 100
      assert big_elem =~ "This single element"

      # Quicklist with many elements
      assert {:ok, 78} == Veidrodelis.llen(@id, 0, "list_quicklist_many_elements")
      {:ok, many_items} = Veidrodelis.lrange(@id, 0, "list_quicklist_many_elements", 0, -1)
      assert "a" in many_items
      assert "z" in many_items
      # After z (i=26), we get `a, a1, b1, ..., `1 (backtick+1), `2, a2, etc.
      assert "a1" in many_items
      # backtick followed by 2
      assert "`2" in many_items

      # Guaranteed quicklist
      assert {:ok, 3} == Veidrodelis.llen(@id, 0, "list_guaranteed_quicklist")
      {:ok, quicklist_items} = Veidrodelis.lrange(@id, 0, "list_guaranteed_quicklist", 0, -1)
      assert "alpha" in quicklist_items
      assert "beta" in quicklist_items
      assert "gamma" in quicklist_items

      # ===== Hash Verification =====
      # Listpack-encoded hash
      assert {:ok, 3} == Veidrodelis.hlen(@id, 0, "hash_listpack")
      assert {:ok, "value1"} == Veidrodelis.hget(@id, 0, "hash_listpack", "field1")
      assert {:ok, "valkey"} == Veidrodelis.hget(@id, 0, "hash_listpack", "name")
      assert {:ok, "7.2"} == Veidrodelis.hget(@id, 0, "hash_listpack", "version")

      # Hashtable-encoded hash
      assert {:ok, 2} == Veidrodelis.hlen(@id, 0, "hash_hashtable")
      assert {:ok, "value1"} == Veidrodelis.hget(@id, 0, "hash_hashtable", "field1")
      {:ok, large_val} = Veidrodelis.hget(@id, 0, "hash_hashtable", "field2")
      assert byte_size(large_val) > 100
      assert large_val =~ "extremely long"

      # ===== Set Verification =====
      # Intset-encoded set
      assert {:ok, 6} == Veidrodelis.scard(@id, 0, "set_intset")
      {:ok, intset_members} = Veidrodelis.smembers(@id, 0, "set_intset")
      assert "100" in intset_members
      assert "200" in intset_members
      assert "300" in intset_members
      assert "42" in intset_members
      assert "999" in intset_members
      assert "10000" in intset_members

      # Intset 32-bit encoded set
      assert {:ok, 3} == Veidrodelis.scard(@id, 0, "set_intset_32bit")
      {:ok, intset32_members} = Veidrodelis.smembers(@id, 0, "set_intset_32bit")
      assert "100000" in intset32_members
      assert "500000" in intset32_members
      assert "999999" in intset32_members

      # Intset 64-bit encoded set
      assert {:ok, 3} == Veidrodelis.scard(@id, 0, "set_intset_64bit")
      {:ok, intset64_members} = Veidrodelis.smembers(@id, 0, "set_intset_64bit")
      assert "10000000000" in intset64_members
      assert "50000000000" in intset64_members
      assert "99999999999" in intset64_members

      # Hashtable-encoded set
      assert {:ok, 5} == Veidrodelis.scard(@id, 0, "set_hashtable")
      {:ok, hashtable_members} = Veidrodelis.smembers(@id, 0, "set_hashtable")
      assert "apple" in hashtable_members
      assert "banana" in hashtable_members
      assert "cherry" in hashtable_members
      assert "123" in hashtable_members
      assert "another-string" in hashtable_members

      # ===== Hash with Per-Field TTL Verification (Valkey 9.0+) =====
      # Tests RDB_TYPE_HASH_2 (type 22) - hash with field-level expiration
      assert {:ok, 2} == Veidrodelis.hlen(@id, 0, "hash_with_ttl")
      assert {:ok, "value1"} == Veidrodelis.hget(@id, 0, "hash_with_ttl", "field1")
      assert {:ok, "value2"} == Veidrodelis.hget(@id, 0, "hash_with_ttl", "field2")

      # ===== Sorted Set Verification =====
      # Listpack-encoded zset
      assert {:ok, 3} == Veidrodelis.zcard(@id, 0, "zset_listpack")
      assert {:ok, 1.0} == Veidrodelis.zscore(@id, 0, "zset_listpack", "one")
      assert {:ok, 2.0} == Veidrodelis.zscore(@id, 0, "zset_listpack", "two")
      assert {:ok, 3.0} == Veidrodelis.zscore(@id, 0, "zset_listpack", "three")

      # Skiplist-encoded zset
      assert {:ok, 3} == Veidrodelis.zcard(@id, 0, "zset_skiplist")
      assert {:ok, 1.0} == Veidrodelis.zscore(@id, 0, "zset_skiplist", "member_one")
      assert {:ok, 2.0} == Veidrodelis.zscore(@id, 0, "zset_skiplist", "member_two")
      long_member = Process.get(:long_member)
      {:ok, long_member_score} = Veidrodelis.zscore(@id, 0, "zset_skiplist", long_member)
      assert long_member_score == 3.0

      Logger.info("=== RDB test completed successfully ===")

      Veidrodelis.stop(vdr)
    end
  end

  describe "RDB parser streaming API" do
    test "requires checksum after EOF" do
      # Create minimal valid RDB (header + EOF + 8-byte checksum)
      minimal_rdb = <<"REDIS", "0012", 255, 0, 0, 0, 0, 0, 0, 0, 0>>

      parser = Vdr.RedisStream.RDB.create()

      # First call should return empty commands (EOF reached)
      # With Rust implementation, when EOF is reached, parser is not returned
      result = Vdr.RedisStream.RDB.data(parser, minimal_rdb)

      # Should return {:ok, commands} without parser (indicating finished)
      case result do
        {:ok, _commands} ->
          # EOF reached, this is correct
          assert true

        {:ok, _commands, _parser} ->
          # Should not happen with minimal RDB that has immediate EOF
          flunk("Expected EOF to be reached")

        {:error, reason} ->
          flunk("Unexpected error: #{inspect(reason)}")
      end
    end

    test "rejects RDB without checksum" do
      # Create invalid RDB (header + EOF but NO checksum)
      rdb_no_checksum = <<"REDIS", "0012", 255>>

      parser = Vdr.RedisStream.RDB.create()
      result = Vdr.RedisStream.RDB.data(parser, rdb_no_checksum)

      # Should return {:ok, [], parser} indicating more data needed (waiting for checksum)
      case result do
        {:ok, commands, _parser} ->
          # Parser is waiting for checksum, not finished
          assert commands == []

        {:ok, _commands} ->
          # Should NOT finish without checksum
          flunk("Parser should not finish without checksum")

        {:error, _reason} ->
          # Also acceptable - could error immediately
          assert true
      end
    end

    test "rejects RDB with incomplete checksum" do
      # Create invalid RDB (header + EOF + only 4 bytes of checksum)
      rdb_partial_checksum = <<"REDIS", "0012", 255, 0, 0, 0, 0>>

      parser = Vdr.RedisStream.RDB.create()
      result = Vdr.RedisStream.RDB.data(parser, rdb_partial_checksum)

      # Should return {:ok, [], parser} indicating more data needed
      case result do
        {:ok, commands, _parser} ->
          # Parser is waiting for remaining checksum bytes
          assert commands == []

        {:ok, _commands} ->
          # Should NOT finish with partial checksum
          flunk("Parser should not finish with incomplete checksum")

        {:error, _reason} ->
          # Also acceptable
          assert true
      end
    end
  end

  describe "RDB parser handles unsupported types" do
    @tag timeout: 30_000
    test "gracefully skips unsupported data types like streams and HLL", %{valkey: valkey} do
      # First, create some supported data
      Redix.command!(valkey, ["SET", "supported_string", "this_should_be_replicated"])
      Redix.command!(valkey, ["HSET", "supported_hash", "field1", "value1"])
      Redix.command!(valkey, ["SADD", "supported_set", "member1", "member2"])

      # Then create unsupported types
      issue_unsupported_types_commands(valkey)

      id = "unsupported_types_test_id"
      # Start Veidrodelis
      opts = [
        id: id,
        host: @valkey[:host],
        port: @valkey[:port]
      ]

      {:ok, vdr} = Veidrodelis.start_link(opts)

      assert_within 5000 do
        assert :streaming == Veidrodelis.get_replication_state(vdr)
      end

      # Verify that supported data was replicated correctly
      assert {:ok, "this_should_be_replicated"} ==
               Veidrodelis.get(id, 0, "supported_string")

      assert {:ok, "value1"} ==
               Veidrodelis.hget(id, 0, "supported_hash", "field1")

      assert {:ok, 2} == Veidrodelis.scard(id, 0, "supported_set")

      assert {:ok, nil} == Veidrodelis.get(id, 0, "test_stream")
      assert {:ok, nil} == Veidrodelis.get(id, 0, "test_stream_cg")

      assert {:ok, nil} == Veidrodelis.get(id, 0, "test_hll")

      assert {:ok, nil} == Veidrodelis.get(id, 0, "test_bitmap")

      Veidrodelis.stop(vdr)
    end
  end
end
