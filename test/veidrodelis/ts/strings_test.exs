defmodule Vdr.TS.StringsTest do
  use ExUnit.Case, async: true

  alias Vdr.TS

  describe "set/4 and get/3" do
    test "stores and retrieves binary values" do
      storage = TS.create()
      [:ok] = TS.tx(storage, [{0, {:set, "key", "value"}}])
      assert "value" == TS.get(storage, 0, "key")
    end

    test "stores and retrieves binary data" do
      storage = TS.create()
      data = <<0, 1, 2, 3, 4, 5>>
      [:ok] = TS.tx(storage, [{0, {:set, "data", data}}])
      assert ^data = TS.get(storage, 0, "data")
    end

    test "overwrites existing values" do
      storage = TS.create()

      TS.tx(storage, [{0, {:set, "key", "value1"}}])
      assert "value1" == TS.get(storage, 0, "key")

      TS.tx(storage, [{0, {:set, "key", "value2"}}])
      assert "value2" == TS.get(storage, 0, "key")
    end

    test "returns nil for missing keys" do
      storage = TS.create()
      assert nil == TS.get(storage, 0, "missing")
    end

    test "handles binary keys with colons" do
      storage = TS.create()
      TS.tx(storage, [{0, {:set, "key:with:colons", "value"}}])
      assert "value" == TS.get(storage, 0, "key:with:colons")
    end

    test "handles binary keys with slashes" do
      storage = TS.create()
      TS.tx(storage, [{0, {:set, "key/with/slashes", "value"}}])
      assert "value" == TS.get(storage, 0, "key/with/slashes")
    end

    test "handles binary keys with spaces" do
      storage = TS.create()
      TS.tx(storage, [{0, {:set, "key with spaces", "value"}}])
      assert "value" == TS.get(storage, 0, "key with spaces")
    end

    test "handles empty binary key" do
      storage = TS.create()
      TS.tx(storage, [{0, {:set, "", "empty_key"}}])
      assert "empty_key" == TS.get(storage, 0, "")
    end

    test "handles empty binary value" do
      storage = TS.create()
      TS.tx(storage, [{0, {:set, "key", ""}}])
      assert "" == TS.get(storage, 0, "key")
    end

    test "handles UTF-8 binary values" do
      storage = TS.create()
      utf8_value = "Hello, 世界! 🌍"
      TS.tx(storage, [{0, {:set, "utf8", utf8_value}}])
      assert ^utf8_value = TS.get(storage, 0, "utf8")
    end
  end

  describe "del/3" do
    test "deletes existing keys" do
      storage = TS.create()

      TS.tx(storage, [{0, {:set, "key", "value"}}])
      assert "value" == TS.get(storage, 0, "key")

      [:ok] = TS.tx(storage, [{0, {:del, ["key"]}}])
      assert nil == TS.get(storage, 0, "key")
    end

    test "returns :ok for missing keys" do
      storage = TS.create()
      assert [:ok] == TS.tx(storage, [{0, {:del, ["missing"]}}])
    end

    test "allows re-setting after deletion" do
      storage = TS.create()

      TS.tx(storage, [{0, {:set, "key", "value1"}}])
      TS.tx(storage, [{0, {:del, ["key"]}}])
      TS.tx(storage, [{0, {:set, "key", "value2"}}])

      assert "value2" == TS.get(storage, 0, "key")
    end

    test "deleting multiple times is idempotent" do
      storage = TS.create()

      TS.tx(storage, [{0, {:set, "key", "value"}}])
      assert [:ok] = TS.tx(storage, [{0, {:del, ["key"]}}])
      assert [:ok] = TS.tx(storage, [{0, {:del, ["key"]}}])
      assert [:ok] = TS.tx(storage, [{0, {:del, ["key"]}}])
    end
  end
end
