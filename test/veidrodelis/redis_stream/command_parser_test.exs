defmodule Vdr.RedisStream.CommandParserTest do
  use ExUnit.Case, async: true

  alias Vdr.RedisStream.Command, as: RedisCommand
  alias Vdr.RedisStream.CommandParser

  describe "parse/1" do
    test "SET command" do
      result = CommandParser.parse(["SET", "mykey", "myvalue"])
      assert {:ok, %RedisCommand.Set{key: "mykey", value: "myvalue"}} = result
    end

    test "SINTERSTORE command - should include all keys" do
      # Redis format: SINTERSTORE destination key [key ...]
      # No numkeys parameter!
      result = CommandParser.parse(["SINTERSTORE", "dest", "key1", "key2", "key3"])

      assert {:ok, %RedisCommand.SInterStore{destination: "dest", keys: ["key1", "key2", "key3"]}} =
               result
    end

    test "SUNIONSTORE command - should include all keys" do
      result = CommandParser.parse(["SUNIONSTORE", "dest", "keyA", "keyB"])

      assert {:ok, %RedisCommand.SUnionStore{destination: "dest", keys: ["keyA", "keyB"]}} =
               result
    end

    test "SDIFFSTORE command - should include all keys" do
      result = CommandParser.parse(["SDIFFSTORE", "dest", "base", "sub1", "sub2"])

      assert {:ok, %RedisCommand.SDiffStore{destination: "dest", keys: ["base", "sub1", "sub2"]}} =
               result
    end

    test "ZUNIONSTORE command - has numkeys parameter" do
      # Redis format: ZUNIONSTORE destination numkeys key [key ...]
      result = CommandParser.parse(["ZUNIONSTORE", "dest", "2", "key1", "key2"])

      # CommandParser currently doesn't handle numkeys, so this will fail
      # We'll fix this as part of the refactoring
      assert {:ok, %RedisCommand.ZUnionStore{destination: "dest", keys: ["key1", "key2"]}} =
               result
    end

    test "ZADD with inf score" do
      result = CommandParser.parse(["ZADD", "myzset", "inf", "member1"])
      assert {:ok, %RedisCommand.ZAdd{key: "myzset", members: [{:pos_inf, "member1"}]}} = result
    end

    test "ZADD with +inf score" do
      result = CommandParser.parse(["ZADD", "myzset", "+inf", "member1"])
      assert {:ok, %RedisCommand.ZAdd{key: "myzset", members: [{:pos_inf, "member1"}]}} = result
    end

    test "ZADD with -inf score" do
      result = CommandParser.parse(["ZADD", "myzset", "-inf", "member1"])
      assert {:ok, %RedisCommand.ZAdd{key: "myzset", members: [{:neg_inf, "member1"}]}} = result
    end

    test "ZADD with nan score" do
      result = CommandParser.parse(["ZADD", "myzset", "nan", "member1"])
      assert {:ok, %RedisCommand.ZAdd{key: "myzset", members: [{:nan, "member1"}]}} = result
    end

    test "ZINCRBY with positive increment" do
      result = CommandParser.parse(["ZINCRBY", "myzset", "5.5", "member1"])

      assert {:ok, %RedisCommand.ZIncrBy{key: "myzset", increment: 5.5, member: "member1"}} =
               result
    end

    test "ZINCRBY with negative increment" do
      result = CommandParser.parse(["ZINCRBY", "myzset", "-2.5", "counter"])

      assert {:ok, %RedisCommand.ZIncrBy{key: "myzset", increment: -2.5, member: "counter"}} =
               result
    end

    test "ZINCRBY with integer increment" do
      result = CommandParser.parse(["ZINCRBY", "myzset", "10", "member1"])

      assert {:ok, %RedisCommand.ZIncrBy{key: "myzset", increment: 10.0, member: "member1"}} =
               result
    end

    test "LPUSH command" do
      result = CommandParser.parse(["LPUSH", "mylist", "v1", "v2", "v3"])
      assert {:ok, %RedisCommand.LPush{key: "mylist", values: ["v1", "v2", "v3"]}} = result
    end

    test "HSET command" do
      result = CommandParser.parse(["HSET", "myhash", "f1", "v1", "f2", "v2"])

      assert {:ok, %RedisCommand.HSet{key: "myhash", fields: [{"f1", "v1"}, {"f2", "v2"}]}} =
               result
    end

    test "DEL command" do
      result = CommandParser.parse(["DEL", "key1", "key2"])
      assert {:ok, %RedisCommand.Del{keys: ["key1", "key2"]}} = result
    end

    test "unknown command returns Generic" do
      result = CommandParser.parse(["UNKNOWN", "arg1", "arg2"])
      assert {:ok, %RedisCommand.Generic{args: ["UNKNOWN", "arg1", "arg2"]}} = result
    end
  end
end
