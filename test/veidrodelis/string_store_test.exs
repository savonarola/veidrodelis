defmodule Vdr.StringStoreTest do
  use ExUnit.Case, async: true

  alias Vdr.ETSProj.Write.{Strings, Common}
  alias Vdr.ETSProj.Read

  setup do
    # Simple decode function that returns the length
    decode_fun = fn _key, value -> byte_size(value) end

    # Create shared ETS table
    tid = :ets.new(:test_store, [:set, :public])

    write_store = Strings.new(tid, decode_fun)
    read_store = Read.Strings.new(tid)

    on_exit(fn ->
      try do
        :ets.delete(tid)
      rescue
        ArgumentError -> :ok
      end
    end)

    {:ok, write_store: write_store, read_store: read_store, tid: tid}
  end

  describe "new/2" do
    test "creates a StringStore with the given ETS table" do
      decode_fun = fn _key, value -> String.upcase(value) end
      tid = :ets.new(:test_store, [:set, :public])
      write_store = Strings.new(tid, decode_fun)

      assert %Vdr.ETSProj.Write.Strings{tid: ^tid, decode_fun: ^decode_fun} = write_store
      assert is_reference(tid)
      assert :ets.info(tid) != :undefined

      # Clean up
      :ets.delete(tid)
    end
  end

  describe "set/4" do
    test "sets a value and stores decoded value", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.set(write_store, 0, "key1", "hello")

      assert "hello" == Read.Strings.get(read_store, 0, "key1")
      assert 5 == Read.Strings.get_decoded(read_store, 0, "key1")
    end

    test "overwrites existing value", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.set(write_store, 0, "key1", "hello")
      :ok = Strings.set(write_store, 0, "key1", "world!")

      assert "world!" == Read.Strings.get(read_store, 0, "key1")
      assert 6 == Read.Strings.get_decoded(read_store, 0, "key1")
    end

    test "supports multiple databases", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.set(write_store, 0, "key1", "db0")
      :ok = Strings.set(write_store, 1, "key1", "db1")
      :ok = Strings.set(write_store, 2, "key1", "database2")

      assert "db0" == Read.Strings.get(read_store, 0, "key1")
      assert "db1" == Read.Strings.get(read_store, 1, "key1")
      assert "database2" == Read.Strings.get(read_store, 2, "key1")

      assert 3 == Read.Strings.get_decoded(read_store, 0, "key1")
      assert 3 == Read.Strings.get_decoded(read_store, 1, "key1")
      assert 9 == Read.Strings.get_decoded(read_store, 2, "key1")
    end
  end

  describe "mset/3" do
    test "sets multiple key-value pairs", %{write_store: write_store, read_store: read_store} do
      pairs = [{"key1", "value1"}, {"key2", "value2"}, {"key3", "value3"}]
      :ok = Strings.mset(write_store, 0, pairs)

      assert "value1" == Read.Strings.get(read_store, 0, "key1")
      assert "value2" == Read.Strings.get(read_store, 0, "key2")
      assert "value3" == Read.Strings.get(read_store, 0, "key3")

      assert 6 == Read.Strings.get_decoded(read_store, 0, "key1")
      assert 6 == Read.Strings.get_decoded(read_store, 0, "key2")
      assert 6 == Read.Strings.get_decoded(read_store, 0, "key3")
    end

    test "handles empty list", %{write_store: write_store} do
      :ok = Strings.mset(write_store, 0, [])
    end
  end

  describe "append/4" do
    test "appends to existing value and recalculates decoded", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.set(write_store, 0, "key1", "hello")
      :ok = Strings.append(write_store, 0, "key1", " world")

      assert "hello world" == Read.Strings.get(read_store, 0, "key1")
      assert 11 == Read.Strings.get_decoded(read_store, 0, "key1")
    end

    test "creates new key if it doesn't exist", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.append(write_store, 0, "newkey", "data")

      assert "data" == Read.Strings.get(read_store, 0, "newkey")
      assert 4 == Read.Strings.get_decoded(read_store, 0, "newkey")
    end
  end

  describe "setrange/5" do
    test "overwrites part of string at offset", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.set(write_store, 0, "key1", "hello world")
      :ok = Strings.setrange(write_store, 0, "key1", 6, "Redis")

      assert "hello Redis" == Read.Strings.get(read_store, 0, "key1")
      assert 11 == Read.Strings.get_decoded(read_store, 0, "key1")
    end

    test "pads with zero bytes if offset is beyond length", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.set(write_store, 0, "key1", "hello")
      :ok = Strings.setrange(write_store, 0, "key1", 10, "world")

      value = Read.Strings.get(read_store, 0, "key1")
      assert "hello" <> <<0, 0, 0, 0, 0>> <> "world" == value
      assert 15 == Read.Strings.get_decoded(read_store, 0, "key1")
    end

    test "creates new key with padding if it doesn't exist", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.setrange(write_store, 0, "newkey", 5, "test")

      value = Read.Strings.get(read_store, 0, "newkey")
      assert <<0, 0, 0, 0, 0>> <> "test" == value
      assert 9 == Read.Strings.get_decoded(read_store, 0, "newkey")
    end

    test "handles offset at zero", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.set(write_store, 0, "key1", "hello")
      :ok = Strings.setrange(write_store, 0, "key1", 0, "HELLO")

      assert "HELLO" == Read.Strings.get(read_store, 0, "key1")
    end
  end

  describe "setbit/5" do
    test "sets bit to 1 in existing value", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.set(write_store, 0, "key1", <<0>>)
      :ok = Strings.setbit(write_store, 0, "key1", 0, 1)

      assert <<128>> == Read.Strings.get(read_store, 0, "key1")
    end

    test "sets bit to 0 in existing value", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.set(write_store, 0, "key1", <<255>>)
      :ok = Strings.setbit(write_store, 0, "key1", 0, 0)

      assert <<127>> == Read.Strings.get(read_store, 0, "key1")
    end

    test "pads with zero bytes if bit offset is beyond length", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.set(write_store, 0, "key1", "A")
      :ok = Strings.setbit(write_store, 0, "key1", 16, 1)

      value = Read.Strings.get(read_store, 0, "key1")
      assert <<"A", 0, 128>> == value
    end

    test "creates new key with padding if it doesn't exist", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.setbit(write_store, 0, "newkey", 7, 1)

      assert <<1>> == Read.Strings.get(read_store, 0, "newkey")
    end

    test "handles multiple bit operations", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.set(write_store, 0, "key1", <<0>>)
      :ok = Strings.setbit(write_store, 0, "key1", 0, 1)
      :ok = Strings.setbit(write_store, 0, "key1", 2, 1)
      :ok = Strings.setbit(write_store, 0, "key1", 7, 1)

      # Bits: 10100001 = 161
      assert <<161>> == Read.Strings.get(read_store, 0, "key1")
    end
  end

  describe "bitop AND" do
    test "performs bitwise AND on multiple sources", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.set(write_store, 0, "key1", <<0b11110000>>)
      :ok = Strings.set(write_store, 0, "key2", <<0b10101010>>)
      :ok = Strings.set(write_store, 0, "key3", <<0b11001100>>)

      :ok = Strings.bitop(write_store, :AND, 0, "dest", ["key1", "key2", "key3"])

      # 11110000 AND 10101010 = 10100000
      # 10100000 AND 11001100 = 10000000 = 128
      assert <<128>> == Read.Strings.get(read_store, 0, "dest")
    end

    test "pads shorter values with zeros", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.set(write_store, 0, "key1", <<255, 255>>)
      :ok = Strings.set(write_store, 0, "key2", <<255>>)

      :ok = Strings.bitop(write_store, :AND, 0, "dest", ["key1", "key2"])

      # [255, 255] AND [255, 0] = [255, 0]
      assert <<255, 0>> == Read.Strings.get(read_store, 0, "dest")
    end

    test "handles non-existent keys as empty strings", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.set(write_store, 0, "key1", <<255>>)

      :ok = Strings.bitop(write_store, :AND, 0, "dest", ["key1", "nonexistent"])

      assert <<0>> == Read.Strings.get(read_store, 0, "dest")
    end
  end

  describe "bitop OR" do
    test "performs bitwise OR on multiple sources", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.set(write_store, 0, "key1", <<0b10000000>>)
      :ok = Strings.set(write_store, 0, "key2", <<0b00100000>>)
      :ok = Strings.set(write_store, 0, "key3", <<0b00000010>>)

      :ok = Strings.bitop(write_store, :OR, 0, "dest", ["key1", "key2", "key3"])

      # 10000000 OR 00100000 OR 00000010 = 10100010 = 162
      assert <<162>> == Read.Strings.get(read_store, 0, "dest")
    end
  end

  describe "bitop XOR" do
    test "performs bitwise XOR on multiple sources", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.set(write_store, 0, "key1", <<0b11110000>>)
      :ok = Strings.set(write_store, 0, "key2", <<0b10101010>>)

      :ok = Strings.bitop(write_store, :XOR, 0, "dest", ["key1", "key2"])

      # 11110000 XOR 10101010 = 01011010 = 90
      assert <<90>> == Read.Strings.get(read_store, 0, "dest")
    end

    test "handles three operands", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.set(write_store, 0, "key1", <<0b11110000>>)
      :ok = Strings.set(write_store, 0, "key2", <<0b10101010>>)
      :ok = Strings.set(write_store, 0, "key3", <<0b11001100>>)

      :ok = Strings.bitop(write_store, :XOR, 0, "dest", ["key1", "key2", "key3"])

      # 11110000 XOR 10101010 = 01011010
      # 01011010 XOR 11001100 = 10010110 = 150
      assert <<150>> == Read.Strings.get(read_store, 0, "dest")
    end
  end

  describe "bitop NOT" do
    test "performs bitwise NOT on single source", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.set(write_store, 0, "key1", <<0b10101010>>)

      :ok = Strings.bitop(write_store, :NOT, 0, "dest", ["key1"])

      # NOT 10101010 = 01010101 = 85
      assert <<85>> == Read.Strings.get(read_store, 0, "dest")
    end

    test "inverts multi-byte values", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.set(write_store, 0, "key1", <<255, 0, 128>>)

      :ok = Strings.bitop(write_store, :NOT, 0, "dest", ["key1"])

      assert <<0, 255, 127>> == Read.Strings.get(read_store, 0, "dest")
    end
  end

  describe "bitop DIFF" do
    test "performs X AND NOT (Y1 OR Y2 ...)", %{write_store: write_store, read_store: read_store} do
      # X = 11110000
      # Y1 = 10101010
      # Y2 = 00001111
      # Y1 OR Y2 = 10101111
      # NOT (Y1 OR Y2) = 01010000
      # X AND NOT (Y1 OR Y2) = 01010000
      :ok = Strings.set(write_store, 0, "x", <<0b11110000>>)
      :ok = Strings.set(write_store, 0, "y1", <<0b10101010>>)
      :ok = Strings.set(write_store, 0, "y2", <<0b00001111>>)

      :ok = Strings.bitop(write_store, :DIFF, 0, "dest", ["x", "y1", "y2"])

      assert <<0b01010000>> == Read.Strings.get(read_store, 0, "dest")
    end
  end

  describe "bitop DIFF1" do
    test "performs (Y1 OR Y2 ...) AND NOT X", %{write_store: write_store, read_store: read_store} do
      # X = 11110000
      # Y1 = 10101010
      # Y2 = 00001111
      # Y1 OR Y2 = 10101111
      # NOT X = 00001111
      # (Y1 OR Y2) AND NOT X = 00001111
      :ok = Strings.set(write_store, 0, "x", <<0b11110000>>)
      :ok = Strings.set(write_store, 0, "y1", <<0b10101010>>)
      :ok = Strings.set(write_store, 0, "y2", <<0b00001111>>)

      :ok = Strings.bitop(write_store, :DIFF1, 0, "dest", ["x", "y1", "y2"])

      assert <<0b00001111>> == Read.Strings.get(read_store, 0, "dest")
    end
  end

  describe "bitop ANDOR" do
    test "performs X AND (Y1 OR Y2 ...)", %{write_store: write_store, read_store: read_store} do
      # X = 11110000
      # Y1 = 10101010
      # Y2 = 00001111
      # Y1 OR Y2 = 10101111
      # X AND (Y1 OR Y2) = 10100000
      :ok = Strings.set(write_store, 0, "x", <<0b11110000>>)
      :ok = Strings.set(write_store, 0, "y1", <<0b10101010>>)
      :ok = Strings.set(write_store, 0, "y2", <<0b00001111>>)

      :ok = Strings.bitop(write_store, :ANDOR, 0, "dest", ["x", "y1", "y2"])

      assert <<0b10100000>> == Read.Strings.get(read_store, 0, "dest")
    end
  end

  describe "bitop ONE" do
    test "sets bit if exactly one source has it set", %{write_store: write_store, read_store: read_store} do
      # Position:  76543210
      # key1:      10101010
      # key2:      01010101
      # key3:      00000000
      # ONE:       11111111 (each bit is in exactly one source)
      :ok = Strings.set(write_store, 0, "key1", <<0b10101010>>)
      :ok = Strings.set(write_store, 0, "key2", <<0b01010101>>)
      :ok = Strings.set(write_store, 0, "key3", <<0b00000000>>)

      :ok = Strings.bitop(write_store, :ONE, 0, "dest", ["key1", "key2", "key3"])

      assert <<255>> == Read.Strings.get(read_store, 0, "dest")
    end

    test "clears bit if multiple sources have it set", %{write_store: write_store, read_store: read_store} do
      # Position:  76543210
      # key1:      11110000
      # key2:      11001100
      # ONE:       00111100 (only these bits appear exactly once)
      :ok = Strings.set(write_store, 0, "key1", <<0b11110000>>)
      :ok = Strings.set(write_store, 0, "key2", <<0b11001100>>)

      :ok = Strings.bitop(write_store, :ONE, 0, "dest", ["key1", "key2"])

      assert <<0b00111100>> == Read.Strings.get(read_store, 0, "dest")
    end

    test "clears bit if no sources have it set", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.set(write_store, 0, "key1", <<0b11110000>>)
      :ok = Strings.set(write_store, 0, "key2", <<0b11110000>>)

      :ok = Strings.bitop(write_store, :ONE, 0, "dest", ["key1", "key2"])

      # All bits appear 0 or 2 times, never exactly once
      assert <<0>> == Read.Strings.get(read_store, 0, "dest")
    end
  end

  describe "del/3" do
    test "deletes a key", %{write_store: write_store, read_store: read_store, tid: tid} do
      :ok = Strings.set(write_store, 0, "key1", "value")
      assert "value" == Read.Strings.get(read_store, 0, "key1")

      :ok = Common.del(tid, 0, "key1")

      assert nil == Read.Strings.get(read_store, 0, "key1")
      assert nil == Read.Strings.get_decoded(read_store, 0, "key1")
    end

    test "handles deleting non-existent key", %{tid: tid} do
      :ok = Common.del(tid, 0, "nonexistent")
    end
  end

  describe "get/3" do
    test "returns nil for non-existent key", %{read_store: read_store} do
      assert nil == Read.Strings.get(read_store, 0, "nonexistent")
    end

    test "returns original binary value", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.set(write_store, 0, "key1", "hello")

      assert "hello" == Read.Strings.get(read_store, 0, "key1")
    end
  end

  describe "get_decoded/3" do
    test "returns nil for non-existent key", %{read_store: read_store} do
      assert nil == Read.Strings.get_decoded(read_store, 0, "nonexistent")
    end

    test "returns decoded value", %{write_store: write_store, read_store: read_store} do
      :ok = Strings.set(write_store, 0, "key1", "hello")

      assert 5 == Read.Strings.get_decoded(read_store, 0, "key1")
    end

    test "uses custom decode function" do
      # Create write_store with custom decoder that counts vowels
      count_vowels = fn _key, value ->
        value
        |> String.downcase()
        |> String.graphemes()
        |> Enum.count(fn c -> c in ["a", "e", "i", "o", "u"] end)
      end

      tid = :ets.new(:test_store, [:set, :public])
      write_store = Strings.new(tid, count_vowels)

      read_store = Read.Strings.new(tid)
      :ok = Strings.set(write_store, 0, "key1", "hello world")

      assert "hello world" == Read.Strings.get(read_store, 0, "key1")
      # e, o, o
      assert 3 == Read.Strings.get_decoded(read_store, 0, "key1")

      # Clean up
      :ets.delete(tid)
    end

    test "recalculates decoded value on update" do
      # Count uppercase letters
      count_upper = fn _key, value ->
        value
        |> String.graphemes()
        |> Enum.count(fn c -> c == String.upcase(c) and c != String.downcase(c) end)
      end

      tid = :ets.new(:test_store, [:set, :public])
      write_store = Strings.new(tid, count_upper)

      read_store = Read.Strings.new(tid)
      :ok = Strings.set(write_store, 0, "key1", "Hello")
      assert 1 == Read.Strings.get_decoded(read_store, 0, "key1")

      :ok = Strings.set(write_store, 0, "key1", "HELLO")
      assert 5 == Read.Strings.get_decoded(read_store, 0, "key1")

      :ok = Strings.append(write_store, 0, "key1", " world")
      assert 5 == Read.Strings.get_decoded(read_store, 0, "key1")

      # Clean up
      :ets.delete(tid)
    end
  end

  describe "decode function receives key" do
    test "decode function can use key for context" do
      # Decode function that prepends key name
      decode_with_key = fn key, value ->
        "#{key}: #{value}"
      end

      tid = :ets.new(:test_store, [:set, :public])
      write_store = Strings.new(tid, decode_with_key)

      read_store = Read.Strings.new(tid)
      :ok = Strings.set(write_store, 0, "user:1", "Alice")
      :ok = Strings.set(write_store, 0, "user:2", "Bob")

      assert "user:1: Alice" == Read.Strings.get_decoded(read_store, 0, "user:1")
      assert "user:2: Bob" == Read.Strings.get_decoded(read_store, 0, "user:2")

      # Clean up
      :ets.delete(tid)
    end
  end
end
