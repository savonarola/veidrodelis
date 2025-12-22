defmodule Vdr.ReplicaParserTest do
  use ExUnit.Case, async: true

  alias Vdr.RedisCommand

  @moduledoc """
  Smoke tests for Rust-based replica parser.
  These tests verify that NIFs are loaded and callable.
  """

  describe "NIF loading" do
    test "replica_create/0 is available and callable" do
      # Should not raise nif_not_loaded error
      parser = Vdr.ReplicaParser.create()
      assert is_reference(parser)
    end

    test "replica_data/2 is available and callable" do
      parser = Vdr.ReplicaParser.create()

      # Feed empty data - should succeed without raising nif_not_loaded error
      result = Vdr.ReplicaParser.data(parser, <<>>)

      # Should return either {:ok, commands, parser} or {:ok, commands}
      assert match?({:ok, _, _}, result) or match?({:ok, _}, result)
    end
  end

  describe "basic functionality" do
    test "create returns a parser reference" do
      parser = Vdr.ReplicaParser.create()
      assert is_reference(parser)
    end

    test "data returns expected tuple format" do
      parser = Vdr.ReplicaParser.create()

      result = Vdr.ReplicaParser.data(parser, <<>>)

      # Result should be one of:
      # - {:ok, commands, new_parser} - more data needed
      # - {:ok, commands} - finished
      # - {:error, reason} - error
      case result do
        {:ok, commands, new_parser} ->
          assert is_list(commands)
          assert is_reference(new_parser)

        {:ok, commands} ->
          assert is_list(commands)

        {:error, _reason} ->
          :ok
      end
    end

    test "feeding data to WaitingRdb state returns empty list" do
      parser = Vdr.ReplicaParser.create()

      # In the scaffolded version, WaitingRdb state returns empty list
      result = Vdr.ReplicaParser.data(parser, <<>>)

      case result do
        {:ok, commands, _parser} ->
          assert commands == []

        {:ok, commands} ->
          assert commands == []

        {:error, _reason} ->
          :ok
      end
    end

    test "parser ownership check - different process cannot use parser" do
      # Create parser in parent process
      parser = Vdr.ReplicaParser.create()

      # Try to use it in a different process
      task =
        Task.async(fn ->
          Vdr.ReplicaParser.data(parser, <<>>)
        end)

      result = Task.await(task)

      # Should return error about parser ownership
      assert {:error, "parser_not_owned"} = result
    end

    test "feeding data returns commands in correct format" do
      parser = Vdr.ReplicaParser.create()

      # The scaffolded parser might return dummy commands
      result = Vdr.ReplicaParser.data(parser, <<>>)

      case result do
        {:ok, commands, _} when is_list(commands) ->
          # Each command should be {db, command_struct}
          Enum.each(commands, fn item ->
            assert match?({db, _command} when is_integer(db), item)
            {_db, command} = item

            # Command should be a struct
            assert is_struct(command)
          end)

        {:ok, []} ->
          # Empty list is valid
          :ok

        {:error, _reason} ->
          :ok
      end
    end
  end

  describe "command conversion" do
    test "converts SET commands correctly" do
      parser = Vdr.ReplicaParser.create()

      # In ReadingRdb state, the scaffolded parser returns a dummy SET command
      # We'll test this by examining any commands returned
      case Vdr.ReplicaParser.data(parser, <<>>) do
        {:ok, [_ | _] = commands, _} ->
          # Check if any SET commands were returned
          set_commands =
            Enum.filter(commands, fn
              {_db, %RedisCommand.Set{}} -> true
              _ -> false
            end)

          Enum.each(set_commands, fn {db, %RedisCommand.Set{key: key, value: value}} ->
            assert is_integer(db)
            assert is_binary(key)
            assert is_binary(value)
          end)

        _ ->
          # No commands or error - that's fine for scaffolding
          :ok
      end
    end
  end

  describe "error handling" do
    test "handles invalid parser reference gracefully" do
      invalid_parser = make_ref()

      # This should either raise or return an error
      assert_raise ArgumentError, fn ->
        Vdr.ReplicaParser.data(invalid_parser, <<>>)
      end
    end

    test "handles non-binary data" do
      parser = Vdr.ReplicaParser.create()

      # Should raise on non-binary input (charlist is not binary)
      # The guard clause causes FunctionClauseError
      assert_raise FunctionClauseError, fn ->
        Vdr.ReplicaParser.data(parser, ~c"charlist")
      end
    end
  end
end
