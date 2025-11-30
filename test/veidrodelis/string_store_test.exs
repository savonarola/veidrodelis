defmodule Veidrodelis.StringStoreTest do
  use ExUnit.Case, async: true

  alias Veidrodelis.StringStore

  setup do
    # Simple decode function that returns the length
    decode_fun = fn _key, value -> byte_size(value) end

    store = StringStore.new(decode_fun)

    {:ok, store: store}
  end

  describe "new/1" do
    test "creates a new ETS table and returns a struct" do
      decode_fun = fn _key, value -> String.upcase(value) end
      store = StringStore.new(decode_fun)

      assert %StringStore{tid: tid, decode_fun: ^decode_fun} = store
      assert is_reference(tid)
      assert :ets.info(tid) != :undefined

      # Clean up
      StringStore.destroy(store)
    end
  end

  describe "set/4" do
    test "sets a value and stores decoded value", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", "hello")

      assert "hello" == StringStore.get(store, 0, "key1")
      assert 5 == StringStore.get_decoded(store, 0, "key1")
    end

    test "overwrites existing value", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", "hello")
      :ok = StringStore.set(store, 0, "key1", "world!")

      assert "world!" == StringStore.get(store, 0, "key1")
      assert 6 == StringStore.get_decoded(store, 0, "key1")
    end

    test "supports multiple databases", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", "db0")
      :ok = StringStore.set(store, 1, "key1", "db1")
      :ok = StringStore.set(store, 2, "key1", "database2")

      assert "db0" == StringStore.get(store, 0, "key1")
      assert "db1" == StringStore.get(store, 1, "key1")
      assert "database2" == StringStore.get(store, 2, "key1")

      assert 3 == StringStore.get_decoded(store, 0, "key1")
      assert 3 == StringStore.get_decoded(store, 1, "key1")
      assert 9 == StringStore.get_decoded(store, 2, "key1")
    end
  end

  describe "mset/3" do
    test "sets multiple key-value pairs", %{store: store} do
      pairs = [{"key1", "value1"}, {"key2", "value2"}, {"key3", "value3"}]
      :ok = StringStore.mset(store, 0, pairs)

      assert "value1" == StringStore.get(store, 0, "key1")
      assert "value2" == StringStore.get(store, 0, "key2")
      assert "value3" == StringStore.get(store, 0, "key3")

      assert 6 == StringStore.get_decoded(store, 0, "key1")
      assert 6 == StringStore.get_decoded(store, 0, "key2")
      assert 6 == StringStore.get_decoded(store, 0, "key3")
    end

    test "handles empty list", %{store: store} do
      :ok = StringStore.mset(store, 0, [])
    end
  end

  describe "append/4" do
    test "appends to existing value and recalculates decoded", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", "hello")
      :ok = StringStore.append(store, 0, "key1", " world")

      assert "hello world" == StringStore.get(store, 0, "key1")
      assert 11 == StringStore.get_decoded(store, 0, "key1")
    end

    test "creates new key if it doesn't exist", %{store: store} do
      :ok = StringStore.append(store, 0, "newkey", "data")

      assert "data" == StringStore.get(store, 0, "newkey")
      assert 4 == StringStore.get_decoded(store, 0, "newkey")
    end
  end

  describe "setrange/5" do
    test "overwrites part of string at offset", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", "hello world")
      :ok = StringStore.setrange(store, 0, "key1", 6, "Redis")

      assert "hello Redis" == StringStore.get(store, 0, "key1")
      assert 11 == StringStore.get_decoded(store, 0, "key1")
    end

    test "pads with zero bytes if offset is beyond length", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", "hello")
      :ok = StringStore.setrange(store, 0, "key1", 10, "world")

      value = StringStore.get(store, 0, "key1")
      assert "hello" <> <<0, 0, 0, 0, 0>> <> "world" == value
      assert 15 == StringStore.get_decoded(store, 0, "key1")
    end

    test "creates new key with padding if it doesn't exist", %{store: store} do
      :ok = StringStore.setrange(store, 0, "newkey", 5, "test")

      value = StringStore.get(store, 0, "newkey")
      assert <<0, 0, 0, 0, 0>> <> "test" == value
      assert 9 == StringStore.get_decoded(store, 0, "newkey")
    end

    test "handles offset at zero", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", "hello")
      :ok = StringStore.setrange(store, 0, "key1", 0, "HELLO")

      assert "HELLO" == StringStore.get(store, 0, "key1")
    end
  end

  describe "setbit/5" do
    test "sets bit to 1 in existing value", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", <<0>>)
      :ok = StringStore.setbit(store, 0, "key1", 0, 1)

      assert <<128>> == StringStore.get(store, 0, "key1")
    end

    test "sets bit to 0 in existing value", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", <<255>>)
      :ok = StringStore.setbit(store, 0, "key1", 0, 0)

      assert <<127>> == StringStore.get(store, 0, "key1")
    end

    test "pads with zero bytes if bit offset is beyond length", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", "A")
      :ok = StringStore.setbit(store, 0, "key1", 16, 1)

      value = StringStore.get(store, 0, "key1")
      assert <<"A", 0, 128>> == value
    end

    test "creates new key with padding if it doesn't exist", %{store: store} do
      :ok = StringStore.setbit(store, 0, "newkey", 7, 1)

      assert <<1>> == StringStore.get(store, 0, "newkey")
    end

    test "handles multiple bit operations", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", <<0>>)
      :ok = StringStore.setbit(store, 0, "key1", 0, 1)
      :ok = StringStore.setbit(store, 0, "key1", 2, 1)
      :ok = StringStore.setbit(store, 0, "key1", 7, 1)

      # Bits: 10100001 = 161
      assert <<161>> == StringStore.get(store, 0, "key1")
    end
  end

  describe "bitop AND" do
    test "performs bitwise AND on multiple sources", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", <<0b11110000>>)
      :ok = StringStore.set(store, 0, "key2", <<0b10101010>>)
      :ok = StringStore.set(store, 0, "key3", <<0b11001100>>)

      :ok = StringStore.bitop(store, :AND, 0, "dest", ["key1", "key2", "key3"])

      # 11110000 AND 10101010 = 10100000
      # 10100000 AND 11001100 = 10000000 = 128
      assert <<128>> == StringStore.get(store, 0, "dest")
    end

    test "pads shorter values with zeros", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", <<255, 255>>)
      :ok = StringStore.set(store, 0, "key2", <<255>>)

      :ok = StringStore.bitop(store, :AND, 0, "dest", ["key1", "key2"])

      # [255, 255] AND [255, 0] = [255, 0]
      assert <<255, 0>> == StringStore.get(store, 0, "dest")
    end

    test "handles non-existent keys as empty strings", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", <<255>>)

      :ok = StringStore.bitop(store, :AND, 0, "dest", ["key1", "nonexistent"])

      assert <<0>> == StringStore.get(store, 0, "dest")
    end
  end

  describe "bitop OR" do
    test "performs bitwise OR on multiple sources", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", <<0b10000000>>)
      :ok = StringStore.set(store, 0, "key2", <<0b00100000>>)
      :ok = StringStore.set(store, 0, "key3", <<0b00000010>>)

      :ok = StringStore.bitop(store, :OR, 0, "dest", ["key1", "key2", "key3"])

      # 10000000 OR 00100000 OR 00000010 = 10100010 = 162
      assert <<162>> == StringStore.get(store, 0, "dest")
    end
  end

  describe "bitop XOR" do
    test "performs bitwise XOR on multiple sources", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", <<0b11110000>>)
      :ok = StringStore.set(store, 0, "key2", <<0b10101010>>)

      :ok = StringStore.bitop(store, :XOR, 0, "dest", ["key1", "key2"])

      # 11110000 XOR 10101010 = 01011010 = 90
      assert <<90>> == StringStore.get(store, 0, "dest")
    end

    test "handles three operands", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", <<0b11110000>>)
      :ok = StringStore.set(store, 0, "key2", <<0b10101010>>)
      :ok = StringStore.set(store, 0, "key3", <<0b11001100>>)

      :ok = StringStore.bitop(store, :XOR, 0, "dest", ["key1", "key2", "key3"])

      # 11110000 XOR 10101010 = 01011010
      # 01011010 XOR 11001100 = 10010110 = 150
      assert <<150>> == StringStore.get(store, 0, "dest")
    end
  end

  describe "bitop NOT" do
    test "performs bitwise NOT on single source", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", <<0b10101010>>)

      :ok = StringStore.bitop(store, :NOT, 0, "dest", ["key1"])

      # NOT 10101010 = 01010101 = 85
      assert <<85>> == StringStore.get(store, 0, "dest")
    end

    test "inverts multi-byte values", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", <<255, 0, 128>>)

      :ok = StringStore.bitop(store, :NOT, 0, "dest", ["key1"])

      assert <<0, 255, 127>> == StringStore.get(store, 0, "dest")
    end
  end

  describe "bitop DIFF" do
    test "performs X AND NOT (Y1 OR Y2 ...)", %{store: store} do
      # X = 11110000
      # Y1 = 10101010
      # Y2 = 00001111
      # Y1 OR Y2 = 10101111
      # NOT (Y1 OR Y2) = 01010000
      # X AND NOT (Y1 OR Y2) = 01010000
      :ok = StringStore.set(store, 0, "x", <<0b11110000>>)
      :ok = StringStore.set(store, 0, "y1", <<0b10101010>>)
      :ok = StringStore.set(store, 0, "y2", <<0b00001111>>)

      :ok = StringStore.bitop(store, :DIFF, 0, "dest", ["x", "y1", "y2"])

      assert <<0b01010000>> == StringStore.get(store, 0, "dest")
    end
  end

  describe "bitop DIFF1" do
    test "performs (Y1 OR Y2 ...) AND NOT X", %{store: store} do
      # X = 11110000
      # Y1 = 10101010
      # Y2 = 00001111
      # Y1 OR Y2 = 10101111
      # NOT X = 00001111
      # (Y1 OR Y2) AND NOT X = 00001111
      :ok = StringStore.set(store, 0, "x", <<0b11110000>>)
      :ok = StringStore.set(store, 0, "y1", <<0b10101010>>)
      :ok = StringStore.set(store, 0, "y2", <<0b00001111>>)

      :ok = StringStore.bitop(store, :DIFF1, 0, "dest", ["x", "y1", "y2"])

      assert <<0b00001111>> == StringStore.get(store, 0, "dest")
    end
  end

  describe "bitop ANDOR" do
    test "performs X AND (Y1 OR Y2 ...)", %{store: store} do
      # X = 11110000
      # Y1 = 10101010
      # Y2 = 00001111
      # Y1 OR Y2 = 10101111
      # X AND (Y1 OR Y2) = 10100000
      :ok = StringStore.set(store, 0, "x", <<0b11110000>>)
      :ok = StringStore.set(store, 0, "y1", <<0b10101010>>)
      :ok = StringStore.set(store, 0, "y2", <<0b00001111>>)

      :ok = StringStore.bitop(store, :ANDOR, 0, "dest", ["x", "y1", "y2"])

      assert <<0b10100000>> == StringStore.get(store, 0, "dest")
    end
  end

  describe "bitop ONE" do
    test "sets bit if exactly one source has it set", %{store: store} do
      # Position:  76543210
      # key1:      10101010
      # key2:      01010101
      # key3:      00000000
      # ONE:       11111111 (each bit is in exactly one source)
      :ok = StringStore.set(store, 0, "key1", <<0b10101010>>)
      :ok = StringStore.set(store, 0, "key2", <<0b01010101>>)
      :ok = StringStore.set(store, 0, "key3", <<0b00000000>>)

      :ok = StringStore.bitop(store, :ONE, 0, "dest", ["key1", "key2", "key3"])

      assert <<255>> == StringStore.get(store, 0, "dest")
    end

    test "clears bit if multiple sources have it set", %{store: store} do
      # Position:  76543210
      # key1:      11110000
      # key2:      11001100
      # ONE:       00111100 (only these bits appear exactly once)
      :ok = StringStore.set(store, 0, "key1", <<0b11110000>>)
      :ok = StringStore.set(store, 0, "key2", <<0b11001100>>)

      :ok = StringStore.bitop(store, :ONE, 0, "dest", ["key1", "key2"])

      assert <<0b00111100>> == StringStore.get(store, 0, "dest")
    end

    test "clears bit if no sources have it set", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", <<0b11110000>>)
      :ok = StringStore.set(store, 0, "key2", <<0b11110000>>)

      :ok = StringStore.bitop(store, :ONE, 0, "dest", ["key1", "key2"])

      # All bits appear 0 or 2 times, never exactly once
      assert <<0>> == StringStore.get(store, 0, "dest")
    end
  end

  describe "del/3" do
    test "deletes a key", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", "value")
      assert "value" == StringStore.get(store, 0, "key1")

      :ok = StringStore.del(store, 0, "key1")

      assert nil == StringStore.get(store, 0, "key1")
      assert nil == StringStore.get_decoded(store, 0, "key1")
    end

    test "handles deleting non-existent key", %{store: store} do
      :ok = StringStore.del(store, 0, "nonexistent")
    end
  end

  describe "get/3" do
    test "returns nil for non-existent key", %{store: store} do
      assert nil == StringStore.get(store, 0, "nonexistent")
    end

    test "returns original binary value", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", "hello")

      assert "hello" == StringStore.get(store, 0, "key1")
    end
  end

  describe "get_decoded/3" do
    test "returns nil for non-existent key", %{store: store} do
      assert nil == StringStore.get_decoded(store, 0, "nonexistent")
    end

    test "returns decoded value", %{store: store} do
      :ok = StringStore.set(store, 0, "key1", "hello")

      assert 5 == StringStore.get_decoded(store, 0, "key1")
    end

    test "uses custom decode function" do
      # Create store with custom decoder that counts vowels
      count_vowels = fn _key, value ->
        value
        |> String.downcase()
        |> String.graphemes()
        |> Enum.count(fn c -> c in ["a", "e", "i", "o", "u"] end)
      end

      store = StringStore.new(count_vowels)

      :ok = StringStore.set(store, 0, "key1", "hello world")

      assert "hello world" == StringStore.get(store, 0, "key1")
      # e, o, o
      assert 3 == StringStore.get_decoded(store, 0, "key1")

      # Clean up
      StringStore.destroy(store)
    end

    test "recalculates decoded value on update" do
      # Count uppercase letters
      count_upper = fn _key, value ->
        value
        |> String.graphemes()
        |> Enum.count(fn c -> c == String.upcase(c) and c != String.downcase(c) end)
      end

      store = StringStore.new(count_upper)

      :ok = StringStore.set(store, 0, "key1", "Hello")
      assert 1 == StringStore.get_decoded(store, 0, "key1")

      :ok = StringStore.set(store, 0, "key1", "HELLO")
      assert 5 == StringStore.get_decoded(store, 0, "key1")

      :ok = StringStore.append(store, 0, "key1", " world")
      assert 5 == StringStore.get_decoded(store, 0, "key1")

      # Clean up
      StringStore.destroy(store)
    end
  end

  describe "decode function receives key" do
    test "decode function can use key for context" do
      # Decode function that prepends key name
      decode_with_key = fn key, value ->
        "#{key}: #{value}"
      end

      store = StringStore.new(decode_with_key)

      :ok = StringStore.set(store, 0, "user:1", "Alice")
      :ok = StringStore.set(store, 0, "user:2", "Bob")

      assert "user:1: Alice" == StringStore.get_decoded(store, 0, "user:1")
      assert "user:2: Bob" == StringStore.get_decoded(store, 0, "user:2")

      # Clean up
      StringStore.destroy(store)
    end
  end
end
