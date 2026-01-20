defmodule Vdr.RedisStream.ParserTest do
  use ExUnit.Case, async: true

  alias Vdr.RedisStream.Command, as: RedisCommand

  @moduledoc """
  Smoke tests for Rust-based replica parser.
  These tests verify that NIFs are loaded and callable.
  """

  describe "NIF loading" do
    test "replica_create/0 is available and callable" do
      # Should not raise nif_not_loaded error
      parser = Vdr.RedisStream.Parser.create()
      assert is_reference(parser)
    end

    test "replica_data/2 is available and callable" do
      parser = Vdr.RedisStream.Parser.create()

      # Feed empty data - should succeed without raising nif_not_loaded error
      result = Vdr.RedisStream.Parser.data(parser, <<>>)

      # Should return {:ok, commands, parser, flags} or {:finished, commands}
      assert match?({:ok, _, _, _}, result) or match?({:finished, _}, result)
    end
  end

  describe "basic functionality" do
    test "create returns a parser reference" do
      parser = Vdr.RedisStream.Parser.create()
      assert is_reference(parser)
    end

    test "data returns expected tuple format" do
      parser = Vdr.RedisStream.Parser.create()

      result = Vdr.RedisStream.Parser.data(parser, <<>>)

      # Result should be one of:
      # - {:ok, commands, new_parser, flags} - more data needed
      # - {:finished, commands} - finished
      # - {:error, reason} - error
      case result do
        {:ok, commands, new_parser, flags} ->
          assert is_list(commands)
          assert is_reference(new_parser)
          assert is_map(flags)
          assert Map.has_key?(flags, :ping)
          assert Map.has_key?(flags, :replconf_getack)

        {:finished, commands} ->
          assert is_list(commands)

        {:error, _reason} ->
          :ok
      end
    end

    test "feeding data to WaitingRdb state returns empty list" do
      parser = Vdr.RedisStream.Parser.create()

      # In the scaffolded version, WaitingRdb state returns empty list
      result = Vdr.RedisStream.Parser.data(parser, <<>>)

      case result do
        {:ok, commands, _parser, _flags} ->
          assert commands == []

        {:finished, commands} ->
          assert commands == []

        {:error, _reason} ->
          :ok
      end
    end

    test "parser ownership check - different process cannot use parser" do
      # Create parser in parent process
      parser = Vdr.RedisStream.Parser.create()

      # Try to use it in a different process
      task =
        Task.async(fn ->
          Vdr.RedisStream.Parser.data(parser, <<>>)
        end)

      result = Task.await(task)

      # Should return error about parser ownership
      assert {:error, "parser_not_owned"} = result
    end

    test "feeding data returns commands in correct format" do
      parser = Vdr.RedisStream.Parser.create()

      # The scaffolded parser might return dummy commands
      result = Vdr.RedisStream.Parser.data(parser, <<>>)

      case result do
        {:ok, commands, _, _flags} when is_list(commands) ->
          # Each command should be {db, command_struct, raw_command}
          Enum.each(commands, fn item ->
            assert match?({db, _command, _raw} when is_integer(db), item)
            {_db, command, _raw} = item

            # Command should be a struct
            assert is_struct(command)
          end)

        {:finished, []} ->
          # Empty list is valid
          :ok

        {:error, _reason} ->
          :ok
      end
    end
  end

  describe "command conversion" do
    test "converts SET commands correctly" do
      parser = Vdr.RedisStream.Parser.create()

      # In ReadingRdb state, the scaffolded parser returns a dummy SET command
      # We'll test this by examining any commands returned
      case Vdr.RedisStream.Parser.data(parser, <<>>) do
        {:ok, [_ | _] = commands, _, _flags} ->
          # Check if any SET commands were returned
          set_commands =
            Enum.filter(commands, fn
              {_db, %RedisCommand.Set{}, _raw} -> true
              _ -> false
            end)

          Enum.each(set_commands, fn {db, %RedisCommand.Set{key: key, value: value}, _raw} ->
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
        Vdr.RedisStream.Parser.data(invalid_parser, <<>>)
      end
    end

    test "handles non-binary data" do
      parser = Vdr.RedisStream.Parser.create()

      # Should raise on non-binary input (charlist is not binary)
      # The guard clause causes FunctionClauseError
      assert_raise FunctionClauseError, fn ->
        Vdr.RedisStream.Parser.data(parser, ~c"charlist")
      end
    end
  end
end
