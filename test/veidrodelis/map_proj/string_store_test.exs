defmodule Vdr.MapProj.StringStoreTest do
  use ExUnit.Case, async: true

  alias Vdr.MapProj.{Strings, Common}

  setup do
    # Simple decode function that returns the length
    decode_fun = fn _key, value -> byte_size(value) end

    config = Strings.new(decode_fun)
    store = %{}

    {:ok, config: config, store: store}
  end

  describe "new/1" do
    test "creates a String config with the given decode function" do
      decode_fun = fn _key, value -> String.upcase(value) end
      config = Strings.new(decode_fun)

      assert %Vdr.MapProj.Strings{decode_fun: ^decode_fun} = config
    end
  end

  describe "set/5" do
    test "sets a value and stores decoded value", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", "hello")

      assert "hello" == Strings.get(store, 0, "key1")
      assert 5 == Strings.get_decoded(store, 0, "key1")
    end

    test "overwrites existing value", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", "hello")
      store = Strings.set(store, config, 0, "key1", "world!")

      assert "world!" == Strings.get(store, 0, "key1")
      assert 6 == Strings.get_decoded(store, 0, "key1")
    end

    test "supports multiple databases", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", "db0")
      store = Strings.set(store, config, 1, "key1", "db1")
      store = Strings.set(store, config, 2, "key1", "database2")

      assert "db0" == Strings.get(store, 0, "key1")
      assert "db1" == Strings.get(store, 1, "key1")
      assert "database2" == Strings.get(store, 2, "key1")

      assert 3 == Strings.get_decoded(store, 0, "key1")
      assert 3 == Strings.get_decoded(store, 1, "key1")
      assert 9 == Strings.get_decoded(store, 2, "key1")
    end
  end

  describe "mset/4" do
    test "sets multiple key-value pairs", %{config: config, store: store} do
      pairs = [{"key1", "value1"}, {"key2", "value2"}, {"key3", "value3"}]
      store = Strings.mset(store, config, 0, pairs)

      assert "value1" == Strings.get(store, 0, "key1")
      assert "value2" == Strings.get(store, 0, "key2")
      assert "value3" == Strings.get(store, 0, "key3")

      assert 6 == Strings.get_decoded(store, 0, "key1")
      assert 6 == Strings.get_decoded(store, 0, "key2")
      assert 6 == Strings.get_decoded(store, 0, "key3")
    end

    test "handles empty list", %{config: config, store: store} do
      store = Strings.mset(store, config, 0, [])
      assert store == %{0 => %{}}
    end
  end

  describe "append/5" do
    test "appends to existing value and recalculates decoded", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", "hello")
      store = Strings.append(store, config, 0, "key1", " world")

      assert "hello world" == Strings.get(store, 0, "key1")
      assert 11 == Strings.get_decoded(store, 0, "key1")
    end

    test "creates new key if it doesn't exist", %{config: config, store: store} do
      store = Strings.append(store, config, 0, "newkey", "data")

      assert "data" == Strings.get(store, 0, "newkey")
      assert 4 == Strings.get_decoded(store, 0, "newkey")
    end
  end

  describe "setrange/6" do
    test "overwrites part of string at offset", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", "hello world")
      store = Strings.setrange(store, config, 0, "key1", 6, "Redis")

      assert "hello Redis" == Strings.get(store, 0, "key1")
      assert 11 == Strings.get_decoded(store, 0, "key1")
    end

    test "pads with zero bytes if offset is beyond length", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", "hello")
      store = Strings.setrange(store, config, 0, "key1", 10, "world")

      value = Strings.get(store, 0, "key1")
      assert "hello" <> <<0, 0, 0, 0, 0>> <> "world" == value
      assert 15 == Strings.get_decoded(store, 0, "key1")
    end

    test "creates new key with padding if it doesn't exist", %{config: config, store: store} do
      store = Strings.setrange(store, config, 0, "newkey", 5, "test")

      value = Strings.get(store, 0, "newkey")
      assert <<0, 0, 0, 0, 0>> <> "test" == value
      assert 9 == Strings.get_decoded(store, 0, "newkey")
    end

    test "handles offset at zero", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", "hello")
      store = Strings.setrange(store, config, 0, "key1", 0, "HELLO")

      assert "HELLO" == Strings.get(store, 0, "key1")
    end
  end

  describe "setbit/6" do
    test "sets bit to 1 in existing value", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", <<0>>)
      store = Strings.setbit(store, config, 0, "key1", 0, 1)

      assert <<128>> == Strings.get(store, 0, "key1")
    end

    test "sets bit to 0 in existing value", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", <<255>>)
      store = Strings.setbit(store, config, 0, "key1", 0, 0)

      assert <<127>> == Strings.get(store, 0, "key1")
    end

    test "pads with zero bytes if bit offset is beyond length", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", "A")
      store = Strings.setbit(store, config, 0, "key1", 16, 1)

      value = Strings.get(store, 0, "key1")
      assert <<"A", 0, 128>> == value
    end

    test "creates new key with padding if it doesn't exist", %{config: config, store: store} do
      store = Strings.setbit(store, config, 0, "newkey", 7, 1)

      assert <<1>> == Strings.get(store, 0, "newkey")
    end

    test "handles multiple bit operations", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", <<0>>)
      store = Strings.setbit(store, config, 0, "key1", 0, 1)
      store = Strings.setbit(store, config, 0, "key1", 2, 1)
      store = Strings.setbit(store, config, 0, "key1", 7, 1)

      # Bits: 10100001 = 161
      assert <<161>> == Strings.get(store, 0, "key1")
    end
  end

  describe "bitop AND" do
    test "performs bitwise AND on multiple sources", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", <<0b11110000>>)
      store = Strings.set(store, config, 0, "key2", <<0b10101010>>)
      store = Strings.set(store, config, 0, "key3", <<0b11001100>>)

      store = Strings.bitop(store, config, :AND, 0, "dest", ["key1", "key2", "key3"])

      # 11110000 AND 10101010 = 10100000
      # 10100000 AND 11001100 = 10000000 = 128
      assert <<128>> == Strings.get(store, 0, "dest")
    end

    test "pads shorter values with zeros", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", <<255, 255>>)
      store = Strings.set(store, config, 0, "key2", <<255>>)

      store = Strings.bitop(store, config, :AND, 0, "dest", ["key1", "key2"])

      # [255, 255] AND [255, 0] = [255, 0]
      assert <<255, 0>> == Strings.get(store, 0, "dest")
    end

    test "handles non-existent keys as empty strings", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", <<255>>)

      store = Strings.bitop(store, config, :AND, 0, "dest", ["key1", "nonexistent"])

      assert <<0>> == Strings.get(store, 0, "dest")
    end
  end

  describe "bitop OR" do
    test "performs bitwise OR on multiple sources", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", <<0b10000000>>)
      store = Strings.set(store, config, 0, "key2", <<0b00100000>>)
      store = Strings.set(store, config, 0, "key3", <<0b00000010>>)

      store = Strings.bitop(store, config, :OR, 0, "dest", ["key1", "key2", "key3"])

      # 10000000 OR 00100000 OR 00000010 = 10100010 = 162
      assert <<162>> == Strings.get(store, 0, "dest")
    end
  end

  describe "bitop XOR" do
    test "performs bitwise XOR on multiple sources", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", <<0b11110000>>)
      store = Strings.set(store, config, 0, "key2", <<0b10101010>>)

      store = Strings.bitop(store, config, :XOR, 0, "dest", ["key1", "key2"])

      # 11110000 XOR 10101010 = 01011010 = 90
      assert <<90>> == Strings.get(store, 0, "dest")
    end

    test "handles three operands", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", <<0b11110000>>)
      store = Strings.set(store, config, 0, "key2", <<0b10101010>>)
      store = Strings.set(store, config, 0, "key3", <<0b11001100>>)

      store = Strings.bitop(store, config, :XOR, 0, "dest", ["key1", "key2", "key3"])

      # 11110000 XOR 10101010 = 01011010
      # 01011010 XOR 11001100 = 10010110 = 150
      assert <<150>> == Strings.get(store, 0, "dest")
    end
  end

  describe "bitop NOT" do
    test "performs bitwise NOT on single source", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", <<0b10101010>>)

      store = Strings.bitop(store, config, :NOT, 0, "dest", ["key1"])

      # NOT 10101010 = 01010101 = 85
      assert <<85>> == Strings.get(store, 0, "dest")
    end

    test "inverts multi-byte values", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", <<255, 0, 128>>)

      store = Strings.bitop(store, config, :NOT, 0, "dest", ["key1"])

      assert <<0, 255, 127>> == Strings.get(store, 0, "dest")
    end
  end

  describe "bitop DIFF" do
    test "performs X AND NOT (Y1 OR Y2 ...)", %{config: config, store: store} do
      # X = 11110000
      # Y1 = 10101010
      # Y2 = 00001111
      # Y1 OR Y2 = 10101111
      # NOT (Y1 OR Y2) = 01010000
      # X AND NOT (Y1 OR Y2) = 01010000
      store = Strings.set(store, config, 0, "x", <<0b11110000>>)
      store = Strings.set(store, config, 0, "y1", <<0b10101010>>)
      store = Strings.set(store, config, 0, "y2", <<0b00001111>>)

      store = Strings.bitop(store, config, :DIFF, 0, "dest", ["x", "y1", "y2"])

      assert <<0b01010000>> == Strings.get(store, 0, "dest")
    end
  end

  describe "bitop DIFF1" do
    test "performs (Y1 OR Y2 ...) AND NOT X", %{config: config, store: store} do
      # X = 11110000
      # Y1 = 10101010
      # Y2 = 00001111
      # Y1 OR Y2 = 10101111
      # NOT X = 00001111
      # (Y1 OR Y2) AND NOT X = 00001111
      store = Strings.set(store, config, 0, "x", <<0b11110000>>)
      store = Strings.set(store, config, 0, "y1", <<0b10101010>>)
      store = Strings.set(store, config, 0, "y2", <<0b00001111>>)

      store = Strings.bitop(store, config, :DIFF1, 0, "dest", ["x", "y1", "y2"])

      assert <<0b00001111>> == Strings.get(store, 0, "dest")
    end
  end

  describe "bitop ANDOR" do
    test "performs X AND (Y1 OR Y2 ...)", %{config: config, store: store} do
      # X = 11110000
      # Y1 = 10101010
      # Y2 = 00001111
      # Y1 OR Y2 = 10101111
      # X AND (Y1 OR Y2) = 10100000
      store = Strings.set(store, config, 0, "x", <<0b11110000>>)
      store = Strings.set(store, config, 0, "y1", <<0b10101010>>)
      store = Strings.set(store, config, 0, "y2", <<0b00001111>>)

      store = Strings.bitop(store, config, :ANDOR, 0, "dest", ["x", "y1", "y2"])

      assert <<0b10100000>> == Strings.get(store, 0, "dest")
    end
  end

  describe "bitop ONE" do
    test "sets bit if exactly one source has it set", %{config: config, store: store} do
      # Position:  76543210
      # key1:      10101010
      # key2:      01010101
      # key3:      00000000
      # ONE:       11111111 (each bit is in exactly one source)
      store = Strings.set(store, config, 0, "key1", <<0b10101010>>)
      store = Strings.set(store, config, 0, "key2", <<0b01010101>>)
      store = Strings.set(store, config, 0, "key3", <<0b00000000>>)

      store = Strings.bitop(store, config, :ONE, 0, "dest", ["key1", "key2", "key3"])

      assert <<255>> == Strings.get(store, 0, "dest")
    end

    test "clears bit if multiple sources have it set", %{config: config, store: store} do
      # Position:  76543210
      # key1:      11110000
      # key2:      11001100
      # ONE:       00111100 (only these bits appear exactly once)
      store = Strings.set(store, config, 0, "key1", <<0b11110000>>)
      store = Strings.set(store, config, 0, "key2", <<0b11001100>>)

      store = Strings.bitop(store, config, :ONE, 0, "dest", ["key1", "key2"])

      assert <<0b00111100>> == Strings.get(store, 0, "dest")
    end

    test "clears bit if no sources have it set", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", <<0b11110000>>)
      store = Strings.set(store, config, 0, "key2", <<0b11110000>>)

      store = Strings.bitop(store, config, :ONE, 0, "dest", ["key1", "key2"])

      # All bits appear 0 or 2 times, never exactly once
      assert <<0>> == Strings.get(store, 0, "dest")
    end
  end

  describe "del/3" do
    test "deletes a key", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", "value")
      assert "value" == Strings.get(store, 0, "key1")

      store = Common.del(store, 0, "key1")

      assert nil == Strings.get(store, 0, "key1")
      assert nil == Strings.get_decoded(store, 0, "key1")
    end

    test "handles deleting non-existent key", %{store: store} do
      store = Common.del(store, 0, "nonexistent")
      assert store == %{}
    end
  end

  describe "get/3" do
    test "returns nil for non-existent key", %{store: store} do
      assert nil == Strings.get(store, 0, "nonexistent")
    end

    test "returns original binary value", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", "hello")

      assert "hello" == Strings.get(store, 0, "key1")
    end
  end

  describe "get_decoded/3" do
    test "returns nil for non-existent key", %{store: store} do
      assert nil == Strings.get_decoded(store, 0, "nonexistent")
    end

    test "returns decoded value", %{config: config, store: store} do
      store = Strings.set(store, config, 0, "key1", "hello")

      assert 5 == Strings.get_decoded(store, 0, "key1")
    end

    test "uses custom decode function" do
      # Create config with custom decoder that counts vowels
      count_vowels = fn _key, value ->
        value
        |> String.downcase()
        |> String.graphemes()
        |> Enum.count(fn c -> c in ["a", "e", "i", "o", "u"] end)
      end

      config = Strings.new(count_vowels)
      store = %{}

      store = Strings.set(store, config, 0, "key1", "hello world")

      assert "hello world" == Strings.get(store, 0, "key1")
      # e, o, o
      assert 3 == Strings.get_decoded(store, 0, "key1")
    end

    test "recalculates decoded value on update" do
      # Count uppercase letters
      count_upper = fn _key, value ->
        value
        |> String.graphemes()
        |> Enum.count(fn c -> c == String.upcase(c) and c != String.downcase(c) end)
      end

      config = Strings.new(count_upper)
      store = %{}

      store = Strings.set(store, config, 0, "key1", "Hello")
      assert 1 == Strings.get_decoded(store, 0, "key1")

      store = Strings.set(store, config, 0, "key1", "HELLO")
      assert 5 == Strings.get_decoded(store, 0, "key1")

      store = Strings.append(store, config, 0, "key1", " world")
      assert 5 == Strings.get_decoded(store, 0, "key1")
    end
  end

  describe "decode function receives key" do
    test "decode function can use key for context" do
      # Decode function that prepends key name
      decode_with_key = fn key, value ->
        "#{key}: #{value}"
      end

      config = Strings.new(decode_with_key)
      store = %{}

      store = Strings.set(store, config, 0, "user:1", "Alice")
      store = Strings.set(store, config, 0, "user:2", "Bob")

      assert "user:1: Alice" == Strings.get_decoded(store, 0, "user:1")
      assert "user:2: Bob" == Strings.get_decoded(store, 0, "user:2")
    end
  end
end
