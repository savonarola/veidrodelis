defmodule Vdr.MapProj.StringStoreTest do
  use ExUnit.Case, async: true

  alias Vdr.MapProj.{Strings, Common}

  setup do
    store = %{}

    {:ok, store: store}
  end

  describe "set/4" do
    test "sets a value", %{store: store} do
      store = Strings.set(store, 0, "key1", "hello")

      assert "hello" == Strings.get(store, 0, "key1")
    end

    test "overwrites existing value", %{store: store} do
      store = Strings.set(store, 0, "key1", "hello")
      store = Strings.set(store, 0, "key1", "world!")

      assert "world!" == Strings.get(store, 0, "key1")
    end

    test "supports multiple databases", %{store: store} do
      store = Strings.set(store, 0, "key1", "db0")
      store = Strings.set(store, 1, "key1", "db1")
      store = Strings.set(store, 2, "key1", "database2")

      assert "db0" == Strings.get(store, 0, "key1")
      assert "db1" == Strings.get(store, 1, "key1")
      assert "database2" == Strings.get(store, 2, "key1")
    end
  end

  describe "mset/3" do
    test "sets multiple key-value pairs", %{store: store} do
      pairs = [{"key1", "value1"}, {"key2", "value2"}, {"key3", "value3"}]
      store = Strings.mset(store, 0, pairs)

      assert "value1" == Strings.get(store, 0, "key1")
      assert "value2" == Strings.get(store, 0, "key2")
      assert "value3" == Strings.get(store, 0, "key3")
    end

    test "handles empty list", %{store: store} do
      store = Strings.mset(store, 0, [])
      assert store == %{0 => %{}}
    end
  end

  describe "append/4" do
    test "appends to existing value", %{store: store} do
      store = Strings.set(store, 0, "key1", "hello")
      store = Strings.append(store, 0, "key1", " world")

      assert "hello world" == Strings.get(store, 0, "key1")
    end

    test "creates new key if it doesn't exist", %{store: store} do
      store = Strings.append(store, 0, "newkey", "data")

      assert "data" == Strings.get(store, 0, "newkey")
    end
  end

  describe "setrange/5" do
    test "overwrites part of string at offset", %{store: store} do
      store = Strings.set(store, 0, "key1", "hello world")
      store = Strings.setrange(store, 0, "key1", 6, "Redis")

      assert "hello Redis" == Strings.get(store, 0, "key1")
    end

    test "pads with zero bytes if offset is beyond length", %{store: store} do
      store = Strings.set(store, 0, "key1", "hello")
      store = Strings.setrange(store, 0, "key1", 10, "world")

      value = Strings.get(store, 0, "key1")
      assert "hello" <> <<0, 0, 0, 0, 0>> <> "world" == value
    end

    test "creates new key with padding if it doesn't exist", %{store: store} do
      store = Strings.setrange(store, 0, "newkey", 5, "test")

      value = Strings.get(store, 0, "newkey")
      assert <<0, 0, 0, 0, 0>> <> "test" == value
    end

    test "handles offset at zero", %{store: store} do
      store = Strings.set(store, 0, "key1", "hello")
      store = Strings.setrange(store, 0, "key1", 0, "HELLO")

      assert "HELLO" == Strings.get(store, 0, "key1")
    end
  end

  describe "setbit/5" do
    test "sets bit to 1 in existing value", %{store: store} do
      store = Strings.set(store, 0, "key1", <<0>>)
      store = Strings.setbit(store, 0, "key1", 0, 1)

      assert <<128>> == Strings.get(store, 0, "key1")
    end

    test "sets bit to 0 in existing value", %{store: store} do
      store = Strings.set(store, 0, "key1", <<255>>)
      store = Strings.setbit(store, 0, "key1", 0, 0)

      assert <<127>> == Strings.get(store, 0, "key1")
    end

    test "pads with zero bytes if bit offset is beyond length", %{store: store} do
      store = Strings.set(store, 0, "key1", "A")
      store = Strings.setbit(store, 0, "key1", 16, 1)

      value = Strings.get(store, 0, "key1")
      assert <<"A", 0, 128>> == value
    end

    test "creates new key with padding if it doesn't exist", %{store: store} do
      store = Strings.setbit(store, 0, "newkey", 7, 1)

      assert <<1>> == Strings.get(store, 0, "newkey")
    end

    test "handles multiple bit operations", %{store: store} do
      store = Strings.set(store, 0, "key1", <<0>>)
      store = Strings.setbit(store, 0, "key1", 0, 1)
      store = Strings.setbit(store, 0, "key1", 2, 1)
      store = Strings.setbit(store, 0, "key1", 7, 1)

      # Bits: 10100001 = 161
      assert <<161>> == Strings.get(store, 0, "key1")
    end
  end

  describe "bitop AND" do
    test "performs bitwise AND on multiple sources", %{store: store} do
      store = Strings.set(store, 0, "key1", <<0b11110000>>)
      store = Strings.set(store, 0, "key2", <<0b10101010>>)
      store = Strings.set(store, 0, "key3", <<0b11001100>>)

      store = Strings.bitop(store, :AND, 0, "dest", ["key1", "key2", "key3"])

      # 11110000 AND 10101010 = 10100000
      # 10100000 AND 11001100 = 10000000 = 128
      assert <<128>> == Strings.get(store, 0, "dest")
    end

    test "pads shorter values with zeros", %{store: store} do
      store = Strings.set(store, 0, "key1", <<255, 255>>)
      store = Strings.set(store, 0, "key2", <<255>>)

      store = Strings.bitop(store, :AND, 0, "dest", ["key1", "key2"])

      # [255, 255] AND [255, 0] = [255, 0]
      assert <<255, 0>> == Strings.get(store, 0, "dest")
    end

    test "handles non-existent keys as empty strings", %{store: store} do
      store = Strings.set(store, 0, "key1", <<255>>)

      store = Strings.bitop(store, :AND, 0, "dest", ["key1", "nonexistent"])

      assert <<0>> == Strings.get(store, 0, "dest")
    end
  end

  describe "bitop OR" do
    test "performs bitwise OR on multiple sources", %{store: store} do
      store = Strings.set(store, 0, "key1", <<0b10000000>>)
      store = Strings.set(store, 0, "key2", <<0b00100000>>)
      store = Strings.set(store, 0, "key3", <<0b00000010>>)

      store = Strings.bitop(store, :OR, 0, "dest", ["key1", "key2", "key3"])

      # 10000000 OR 00100000 OR 00000010 = 10100010 = 162
      assert <<162>> == Strings.get(store, 0, "dest")
    end
  end

  describe "bitop XOR" do
    test "performs bitwise XOR on multiple sources", %{store: store} do
      store = Strings.set(store, 0, "key1", <<0b11110000>>)
      store = Strings.set(store, 0, "key2", <<0b10101010>>)

      store = Strings.bitop(store, :XOR, 0, "dest", ["key1", "key2"])

      # 11110000 XOR 10101010 = 01011010 = 90
      assert <<90>> == Strings.get(store, 0, "dest")
    end

    test "handles three operands", %{store: store} do
      store = Strings.set(store, 0, "key1", <<0b11110000>>)
      store = Strings.set(store, 0, "key2", <<0b10101010>>)
      store = Strings.set(store, 0, "key3", <<0b11001100>>)

      store = Strings.bitop(store, :XOR, 0, "dest", ["key1", "key2", "key3"])

      # 11110000 XOR 10101010 = 01011010
      # 01011010 XOR 11001100 = 10010110 = 150
      assert <<150>> == Strings.get(store, 0, "dest")
    end
  end

  describe "bitop NOT" do
    test "performs bitwise NOT on single source", %{store: store} do
      store = Strings.set(store, 0, "key1", <<0b10101010>>)

      store = Strings.bitop(store, :NOT, 0, "dest", ["key1"])

      # NOT 10101010 = 01010101 = 85
      assert <<85>> == Strings.get(store, 0, "dest")
    end

    test "inverts multi-byte values", %{store: store} do
      store = Strings.set(store, 0, "key1", <<255, 0, 128>>)

      store = Strings.bitop(store, :NOT, 0, "dest", ["key1"])

      assert <<0, 255, 127>> == Strings.get(store, 0, "dest")
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
      store = Strings.set(store, 0, "x", <<0b11110000>>)
      store = Strings.set(store, 0, "y1", <<0b10101010>>)
      store = Strings.set(store, 0, "y2", <<0b00001111>>)

      store = Strings.bitop(store, :DIFF, 0, "dest", ["x", "y1", "y2"])

      assert <<0b01010000>> == Strings.get(store, 0, "dest")
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
      store = Strings.set(store, 0, "x", <<0b11110000>>)
      store = Strings.set(store, 0, "y1", <<0b10101010>>)
      store = Strings.set(store, 0, "y2", <<0b00001111>>)

      store = Strings.bitop(store, :DIFF1, 0, "dest", ["x", "y1", "y2"])

      assert <<0b00001111>> == Strings.get(store, 0, "dest")
    end
  end

  describe "bitop ANDOR" do
    test "performs X AND (Y1 OR Y2 ...)", %{store: store} do
      # X = 11110000
      # Y1 = 10101010
      # Y2 = 00001111
      # Y1 OR Y2 = 10101111
      # X AND (Y1 OR Y2) = 10100000
      store = Strings.set(store, 0, "x", <<0b11110000>>)
      store = Strings.set(store, 0, "y1", <<0b10101010>>)
      store = Strings.set(store, 0, "y2", <<0b00001111>>)

      store = Strings.bitop(store, :ANDOR, 0, "dest", ["x", "y1", "y2"])

      assert <<0b10100000>> == Strings.get(store, 0, "dest")
    end
  end

  describe "bitop ONE" do
    test "sets bit if exactly one source has it set", %{store: store} do
      # Position:  76543210
      # key1:      10101010
      # key2:      01010101
      # key3:      00000000
      # ONE:       11111111 (each bit is in exactly one source)
      store = Strings.set(store, 0, "key1", <<0b10101010>>)
      store = Strings.set(store, 0, "key2", <<0b01010101>>)
      store = Strings.set(store, 0, "key3", <<0b00000000>>)

      store = Strings.bitop(store, :ONE, 0, "dest", ["key1", "key2", "key3"])

      assert <<255>> == Strings.get(store, 0, "dest")
    end

    test "clears bit if multiple sources have it set", %{store: store} do
      # Position:  76543210
      # key1:      11110000
      # key2:      11001100
      # ONE:       00111100 (only these bits appear exactly once)
      store = Strings.set(store, 0, "key1", <<0b11110000>>)
      store = Strings.set(store, 0, "key2", <<0b11001100>>)

      store = Strings.bitop(store, :ONE, 0, "dest", ["key1", "key2"])

      assert <<0b00111100>> == Strings.get(store, 0, "dest")
    end

    test "clears bit if no sources have it set", %{store: store} do
      store = Strings.set(store, 0, "key1", <<0b11110000>>)
      store = Strings.set(store, 0, "key2", <<0b11110000>>)

      store = Strings.bitop(store, :ONE, 0, "dest", ["key1", "key2"])

      # All bits appear 0 or 2 times, never exactly once
      assert <<0>> == Strings.get(store, 0, "dest")
    end
  end

  describe "del/3" do
    test "deletes a key", %{store: store} do
      store = Strings.set(store, 0, "key1", "value")
      assert "value" == Strings.get(store, 0, "key1")

      store = Common.del(store, 0, "key1")

      assert nil == Strings.get(store, 0, "key1")
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

    test "returns binary value", %{store: store} do
      store = Strings.set(store, 0, "key1", "hello")

      assert "hello" == Strings.get(store, 0, "key1")
    end
  end
end
