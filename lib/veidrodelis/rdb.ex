defmodule Veidrodelis.RDB do
  import Bitwise

  alias Veidrodelis.Command

  @moduledoc """
  Redis RDB (Redis Database) file parser.

  This module provides a streaming parser for Redis RDB files with a callback-based
  interface for processing parsed data as Redis commands.

  ## Example - Parse Complete File

      defmodule MyCallback do
        @behaviour Veidrodelis.RedisStream.Callback

        alias Veidrodelis.Command

        @impl true
        def on_command(state, db, %Command.Set{key: key, value: value}) do
          IO.puts("SET \#{key} = \#{value}")
          {:ok, state}
        end

        def on_command(state, db, %Command.RPush{key: key, value: value}) do
          IO.puts("RPUSH \#{key} \#{value}")
          {:ok, state}
        end

        def on_command(state, db, %Command.SAdd{key: key, member: member}) do
          IO.puts("SADD \#{key} \#{member}")
          {:ok, state}
        end

        def on_command(state, db, %Command.ZAdd{key: key, score: score, member: member}) do
          IO.puts("ZADD \#{key} \#{score} \#{member}")
          {:ok, state}
        end

        def on_command(state, db, %Command.HSet{key: key, field: field, value: value}) do
          IO.puts("HSET \#{key} \#{field} \#{value}")
          {:ok, state}
        end

        def on_command(state, db, %Command.PExpireAt{key: key, timestamp_ms: timestamp_ms}) do
          IO.puts("PEXPIREAT \#{key} \#{timestamp_ms}")
          {:ok, state}
        end
      end

      {:ok, rdb_binary} = File.read("dump.rdb")
      {:ok, final_state} = Veidrodelis.RDB.parse(rdb_binary, MyCallback, %{})

  ## Example - Streaming/Chunked Parsing

  The parser supports streaming/chunked parsing, which is useful for processing
  large RDB files or reading from network streams:

      # Create parser
      parser = Veidrodelis.RDB.create(MyCallback, %{})

      # Feed data in chunks
      {:ok, parser} = Veidrodelis.RDB.data(parser, chunk1)
      {:ok, parser} = Veidrodelis.RDB.data(parser, chunk2)
      {:ok, parser} = Veidrodelis.RDB.data(parser, chunk3)

      # Finish and get final state
      {:ok, final_state} = Veidrodelis.RDB.finish(parser)

  The streaming API efficiently accumulates data chunks in a list and only converts
  to binary when needed, avoiding expensive binary concatenation operations.
  """

  # RDB opcodes
  @rdb_opcode_aux 250
  @rdb_opcode_resizedb 251
  @rdb_opcode_expiretime_ms 252
  @rdb_opcode_expiretime 253
  @rdb_opcode_selectdb 254
  @rdb_opcode_eof 255

  # RDB types (currently supported)
  @rdb_type_string 0
  @rdb_type_list 1
  @rdb_type_set 2
  @rdb_type_zset 3
  @rdb_type_hash 4
  @rdb_type_zset_2 5
  # 7: module_2 (not yet supported)
  # 9: hash_zipmap (deprecated, not supported)
  # 10: list_ziplist (deprecated, not supported)
  @rdb_type_set_intset 11
  @rdb_type_zset_ziplist 12
  @rdb_type_hash_ziplist 13
  @rdb_type_list_quicklist 14
  # 15: stream_listpacks (not yet supported)
  @rdb_type_hash_listpack 16
  @rdb_type_zset_listpack 17
  @rdb_type_list_quicklist_2 18
  # 19: stream_listpacks_2 (not yet supported)
  @rdb_type_set_listpack 20
  # 21: stream_listpacks_3 (not yet supported)

  # Length encoding
  @rdb_6bitlen 0
  @rdb_14bitlen 1
  @rdb_32bitlen 2
  # 64-bit length encoding exists but is covered by @rdb_32bitlen case (value 0x81)
  @rdb_encval 3

  # String encodings
  @rdb_enc_int8 0
  @rdb_enc_int16 1
  @rdb_enc_int32 2
  @rdb_enc_lzf 3

  # Parser state for streaming API
  defstruct [
    # List of binary chunks (accumulates in reverse order)
    :buffer,
    # Total bytes available in buffer
    :buffer_size,
    # Current parsing state
    :parse_state,
    # Callback module
    :callback_module,
    # Callback state
    :callback_state,
    # Current database number
    :current_db,
    # Current expire time in milliseconds
    :expire_ms,
    # Whether parsing has finished (EOF reached)
    :finished
  ]

  @type parse_state ::
          {:magic, pos_integer()}
          | {:version, pos_integer()}
          | :opcode
          | {:processing_opcode, opcode :: non_neg_integer()}
          | {:processing_value, type :: non_neg_integer(), key :: binary()}

  @type t :: %__MODULE__{
          buffer: [binary()],
          buffer_size: non_neg_integer(),
          parse_state: parse_state(),
          callback_module: module(),
          callback_state: term(),
          current_db: non_neg_integer(),
          expire_ms: pos_integer() | nil,
          finished: boolean()
        }

  @doc """
  Create a new streaming RDB parser.

  ## Parameters

    * `callback_module` - Module implementing the `Veidrodelis.RedisStream.Callback` behaviour
    * `initial_state` - Initial state passed to callbacks

  ## Returns

  A parser state that can be used with `data/2` and `finish/1`.

  ## Example

      parser = Veidrodelis.RDB.create(MyCallback, %{})
      {:ok, parser} = Veidrodelis.RDB.data(parser, chunk1)
      {:ok, parser} = Veidrodelis.RDB.data(parser, chunk2)
      {:ok, final_state} = Veidrodelis.RDB.finish(parser)
  """
  @spec create(module(), term()) :: t()
  def create(callback_module, initial_state) do
    %__MODULE__{
      buffer: [],
      buffer_size: 0,
      parse_state: {:magic, 0},
      callback_module: callback_module,
      callback_state: initial_state,
      current_db: 0,
      expire_ms: nil,
      finished: false
    }
  end

  @doc """
  Feed a chunk of binary data to the parser.

  The parser will accumulate chunks and parse as much as possible.
  Chunks are stored in a list and only converted to binary when needed,
  avoiding expensive binary concatenation.

  ## Parameters

    * `parser` - Parser state from `create/2` or previous `data/2` call
    * `chunk` - Binary chunk of RDB data

  ## Returns

    * `{:ok, new_parser}` - Successfully processed chunk
    * `{:error, reason}` - Parsing failed
  """
  @spec data(t(), binary()) :: {:ok, t()} | {:error, term()}
  def data(%__MODULE__{finished: true}, _chunk) do
    {:error, :already_finished}
  end

  def data(%__MODULE__{} = parser, chunk) when is_binary(chunk) do
    # Add chunk to buffer (prepend for O(1) operation)
    new_buffer = [chunk | parser.buffer]
    new_buffer_size = parser.buffer_size + byte_size(chunk)

    parser = %{parser | buffer: new_buffer, buffer_size: new_buffer_size}

    # Try to parse as much as possible
    parse_stream(parser)
  end

  @doc """
  Finish parsing and validate that all data has been consumed.

  ## Parameters

    * `parser` - Parser state from `data/2`

  ## Returns

    * `{:ok, final_callback_state}` - Successfully finished parsing
    * `{:error, reason}` - Parsing incomplete or failed
  """
  @spec finish(t()) :: {:ok, term()} | {:error, term()}
  def finish(%__MODULE__{finished: true, callback_state: state}) do
    {:ok, state}
  end

  def finish(%__MODULE__{finished: false}) do
    {:error, :incomplete_rdb}
  end

  @doc """
  Extract the callback state from the parser.

  This is useful for inspecting the current state during streaming parsing
  without having to finish the parser.

  ## Parameters

    * `parser` - Parser state from `create/2` or `data/2`

  ## Returns

  The current callback state.

  ## Example

      parser = Veidrodelis.RDB.create(MyCallback, %{count: 0})
      {:ok, parser} = Veidrodelis.RDB.data(parser, chunk1)

      # Inspect intermediate state
      current_state = Veidrodelis.RDB.get_state(parser)
      IO.inspect(current_state.count)
  """
  @spec get_state(t()) :: term()
  def get_state(%__MODULE__{callback_state: state}) do
    state
  end

  @doc """
  Update the callback state in the parser.

  This allows you to modify the callback state during streaming parsing,
  which can be useful for resuming parsing with a different state or
  performing external state transformations.

  ## Parameters

    * `parser` - Parser state from `create/2` or `data/2`
    * `new_state` - New callback state to set

  ## Returns

  Updated parser with the new callback state.

  ## Example

      parser = Veidrodelis.RDB.create(MyCallback, %{count: 0})
      {:ok, parser} = Veidrodelis.RDB.data(parser, chunk1)

      # Update state externally
      current_state = Veidrodelis.RDB.get_state(parser)
      updated_state = Map.update!(current_state, :count, &(&1 + 100))
      parser = Veidrodelis.RDB.put_state(parser, updated_state)

      # Continue parsing with updated state
      {:ok, parser} = Veidrodelis.RDB.data(parser, chunk2)
  """
  @spec put_state(t(), term()) :: t()
  def put_state(%__MODULE__{} = parser, new_state) do
    %{parser | callback_state: new_state}
  end

  # Streaming parser implementation
  # Main parsing loop for streaming API
  defp parse_stream(%__MODULE__{} = parser) do
    case parse_next(parser) do
      {:ok, new_parser} ->
        {:ok, new_parser}

      {:continue, new_parser} ->
        # We made progress, try to parse more
        parse_stream(new_parser)

      {:error, _} = error ->
        error
    end
  end

  # Try to parse the next item based on current state
  defp parse_next(%__MODULE__{parse_state: {:magic, bytes_read}} = parser) do
    # Need to read "REDIS" magic string (5 bytes total)
    needed = 5 - bytes_read

    case consume_bytes(parser, needed) do
      {:ok, magic_chunk, new_parser} ->
        magic_so_far = binary_part("REDIS", bytes_read, needed)

        if magic_chunk == magic_so_far do
          {:continue, %{new_parser | parse_state: {:version, 0}}}
        else
          {:error, :invalid_magic}
        end

      :need_more ->
        {:ok, parser}
    end
  end

  defp parse_next(%__MODULE__{parse_state: {:version, bytes_read}} = parser) do
    # Need to read 4-byte version string
    needed = 4 - bytes_read

    case consume_bytes(parser, needed) do
      {:ok, version_chunk, new_parser} ->
        # We've accumulated the full version
        version_bytes = if bytes_read == 0, do: version_chunk, else: version_chunk

        case parse_version(:binary.bin_to_list(version_bytes)) do
          {:ok, _ver} ->
            {:continue, %{new_parser | parse_state: :opcode}}

          {:error, _} = error ->
            error
        end

      :need_more ->
        {:ok, parser}
    end
  end

  defp parse_next(%__MODULE__{parse_state: :opcode} = parser) do
    case consume_bytes(parser, 1) do
      {:ok, <<opcode::8>>, new_parser} ->
        handle_opcode(opcode, new_parser)

      :need_more ->
        {:ok, parser}
    end
  end

  defp parse_next(%__MODULE__{parse_state: {:processing_opcode, opcode}} = parser) do
    # We're in the middle of processing an opcode that needed more data
    # Retry handling it now that we have more data
    handle_opcode(opcode, parser)
  end

  defp parse_next(%__MODULE__{parse_state: {:processing_value, type, key}} = parser) do
    # We're in the middle of processing a value that needed more data
    # Retry parsing the value now that we have more data
    parse_value(type, key, parser)
  end

  # Handle different opcodes
  defp handle_opcode(@rdb_opcode_eof, parser) do
    # EOF reached, mark as finished
    {:ok, %{parser | finished: true, parse_state: :finished}}
  end

  defp handle_opcode(@rdb_opcode_selectdb, parser) do
    case consume_length(parser) do
      {:ok, db_num, new_parser} ->
        {:continue, %{new_parser | current_db: db_num, parse_state: :opcode}}

      :need_more ->
        {:ok, %{parser | parse_state: {:processing_opcode, @rdb_opcode_selectdb}}}
    end
  end

  defp handle_opcode(@rdb_opcode_expiretime, parser) do
    case consume_bytes(parser, 4) do
      {:ok, <<expire_sec::32-little>>, new_parser} ->
        {:continue, %{new_parser | expire_ms: expire_sec * 1000, parse_state: :opcode}}

      :need_more ->
        {:ok, %{parser | parse_state: {:processing_opcode, @rdb_opcode_expiretime}}}
    end
  end

  defp handle_opcode(@rdb_opcode_expiretime_ms, parser) do
    case consume_bytes(parser, 8) do
      {:ok, <<expire_ms::64-little>>, new_parser} ->
        {:continue, %{new_parser | expire_ms: expire_ms, parse_state: :opcode}}

      :need_more ->
        {:ok, %{parser | parse_state: {:processing_opcode, @rdb_opcode_expiretime_ms}}}
    end
  end

  defp handle_opcode(@rdb_opcode_resizedb, parser) do
    with {:ok, _db_size, parser2} <- consume_length(parser),
         {:ok, _expires_size, parser3} <- consume_length(parser2) do
      {:continue, %{parser3 | parse_state: :opcode}}
    else
      :need_more -> {:ok, %{parser | parse_state: {:processing_opcode, @rdb_opcode_resizedb}}}
    end
  end

  defp handle_opcode(@rdb_opcode_aux, parser) do
    with {:ok, _key, parser2} <- consume_string(parser),
         {:ok, _value, parser3} <- consume_string(parser2) do
      {:continue, %{parser3 | parse_state: :opcode}}
    else
      :need_more -> {:ok, %{parser | parse_state: {:processing_opcode, @rdb_opcode_aux}}}
    end
  end

  defp handle_opcode(type, parser) when type >= 0 and type <= 21 do
    # This is a key-value pair, need to read the key first
    case consume_string(parser) do
      {:ok, key, new_parser} ->
        # Now we need to parse the value based on type
        parse_value(type, key, new_parser)

      :need_more ->
        {:ok, %{parser | parse_state: {:processing_opcode, type}}}
    end
  end

  defp handle_opcode(opcode, _parser) do
    {:error, {:unknown_opcode, opcode}}
  end

  # Parse value and emit commands - this is complex and needs the full binary approach
  # For now, we'll convert the entire buffer to binary when parsing values
  defp parse_value(type, key, parser) do
    # Convert buffer to binary
    binary = buffer_to_binary(parser)

    try do
      case load_object(
             type,
             binary,
             parser.callback_module,
             parser.callback_state,
             parser.current_db,
             key,
             parser.expire_ms
           ) do
        {:ok, new_callback_state, rest} ->
          # Update parser with remaining bytes and reset expire_ms
          bytes_consumed = byte_size(binary) - byte_size(rest)

          new_parser =
            consume_exact_bytes(parser, bytes_consumed)
            |> update_callback_state(new_callback_state)
            |> reset_expire()

          {:continue, %{new_parser | parse_state: :opcode}}

        {:error, _} = error ->
          error
      end
    catch
      # Catch all errors - they're all likely due to insufficient data when parsing values
      # Pattern match errors, function clause errors, etc. indicate we need more data
      _kind, _reason ->
        {:ok, %{parser | parse_state: {:processing_value, type, key}}}
    end
  end

  # Buffer management helpers

  # Convert buffer list to binary (reverses list since we prepend)
  defp buffer_to_binary(%__MODULE__{buffer: buffer}) do
    buffer |> Enum.reverse() |> :erlang.iolist_to_binary()
  end

  # Try to consume N bytes from buffer
  defp consume_bytes(%__MODULE__{buffer_size: size}, needed) when size < needed do
    :need_more
  end

  defp consume_bytes(%__MODULE__{buffer: buffer} = parser, needed) do
    binary = buffer |> Enum.reverse() |> :erlang.iolist_to_binary()
    <<consumed::binary-size(needed), rest::binary>> = binary

    new_parser = %{
      parser
      | buffer: if(byte_size(rest) > 0, do: [rest], else: []),
        buffer_size: byte_size(rest)
    }

    {:ok, consumed, new_parser}
  end

  # Consume exactly N bytes (assumes they exist)
  defp consume_exact_bytes(%__MODULE__{buffer: buffer, buffer_size: size} = parser, n)
       when n <= size do
    binary = buffer |> Enum.reverse() |> :erlang.iolist_to_binary()
    rest = :binary.part(binary, n, byte_size(binary) - n)

    %{
      parser
      | buffer: if(byte_size(rest) > 0, do: [rest], else: []),
        buffer_size: byte_size(rest)
    }
  end

  # Try to consume a length-encoded value
  defp consume_length(parser) do
    case consume_bytes(parser, 1) do
      {:ok, <<byte::8>>, parser2} ->
        type = (byte &&& 0xC0) >>> 6

        case type do
          @rdb_6bitlen ->
            len = byte &&& 0x3F
            {:ok, len, parser2}

          @rdb_14bitlen ->
            case consume_bytes(parser2, 1) do
              {:ok, <<next_byte::8>>, parser3} ->
                len = (byte &&& 0x3F) <<< 8 ||| next_byte
                {:ok, len, parser3}

              :need_more ->
                :need_more
            end

          @rdb_32bitlen ->
            case byte do
              0x80 ->
                case consume_bytes(parser2, 4) do
                  {:ok, <<len::32-big>>, parser3} -> {:ok, len, parser3}
                  :need_more -> :need_more
                end

              0x81 ->
                case consume_bytes(parser2, 8) do
                  {:ok, <<len::64-big>>, parser3} -> {:ok, len, parser3}
                  :need_more -> :need_more
                end

              _ ->
                {:error, :invalid_length_encoding}
            end

          @rdb_encval ->
            # This is an encoded value marker, not a length
            {:encoded, byte &&& 0x3F, parser2}
        end

      :need_more ->
        :need_more
    end
  end

  # Try to consume a string
  defp consume_string(parser) do
    case consume_length(parser) do
      {:encoded, enc_type, parser2} ->
        consume_encoded_string(enc_type, parser2)

      {:ok, len, parser2} ->
        case consume_bytes(parser2, len) do
          {:ok, str, parser3} -> {:ok, str, parser3}
          :need_more -> :need_more
        end

      :need_more ->
        :need_more
    end
  end

  # Consume encoded string
  defp consume_encoded_string(@rdb_enc_int8, parser) do
    case consume_bytes(parser, 1) do
      {:ok, <<val::signed-8>>, parser2} -> {:ok, Integer.to_string(val), parser2}
      :need_more -> :need_more
    end
  end

  defp consume_encoded_string(@rdb_enc_int16, parser) do
    case consume_bytes(parser, 2) do
      {:ok, <<val::signed-little-16>>, parser2} -> {:ok, Integer.to_string(val), parser2}
      :need_more -> :need_more
    end
  end

  defp consume_encoded_string(@rdb_enc_int32, parser) do
    case consume_bytes(parser, 4) do
      {:ok, <<val::signed-little-32>>, parser2} -> {:ok, Integer.to_string(val), parser2}
      :need_more -> :need_more
    end
  end

  defp consume_encoded_string(@rdb_enc_lzf, parser) do
    with {:ok, comp_len, parser2} <- consume_length(parser),
         {:ok, uncomp_len, parser3} <- consume_length(parser2),
         {:ok, comp_data, parser4} <- consume_bytes(parser3, comp_len) do
      case lzf_decompress(comp_data, uncomp_len) do
        uncomp_data -> {:ok, uncomp_data, parser4}
      end
    else
      :need_more -> :need_more
    end
  end

  defp consume_encoded_string(enc_type, _parser) do
    {:error, {:unknown_encoding, enc_type}}
  end

  # Helper to update callback state
  defp update_callback_state(parser, new_state) do
    %{parser | callback_state: new_state}
  end

  # Helper to reset expire time
  defp reset_expire(parser) do
    %{parser | expire_ms: nil}
  end

  @doc """
  Parse an RDB file binary with the given callback module.

  This is a convenience function that wraps the streaming API for
  processing a complete RDB binary at once.

  ## Parameters

    * `rdb_binary` - Binary content of an RDB file
    * `callback_module` - Module implementing the `Veidrodelis.RedisStream.Callback` behaviour
    * `initial_state` - Initial state passed to callbacks

  ## Returns

    * `{:ok, final_state}` - Successfully parsed with final state
    * `{:error, reason}` - Parsing failed with reason
  """
  @spec parse(binary(), module(), term()) :: {:ok, term()} | {:error, term()}
  def parse(rdb_binary, callback_module, initial_state) do
    parser = create(callback_module, initial_state)

    with {:ok, parser} <- data(parser, rdb_binary),
         {:ok, final_state} <- finish(parser) do
      {:ok, final_state}
    end
  end

  defp parse_version(version_str) do
    try do
      ver = :erlang.list_to_integer(version_str)

      if ver >= 1 and ver <= 12 do
        {:ok, ver}
      else
        {:error, {:invalid_version, version_str}}
      end
    catch
      _, _ -> {:error, {:invalid_version, version_str}}
    end
  end

  # Helper to emit PExpireAt command if expire_ms is set
  defp emit_pexpireat(_callback_module, state, _db_num, _key, nil) do
    {:ok, state}
  end

  defp emit_pexpireat(callback_module, state, db_num, key, expire_ms) do
    command = %Command.PExpireAt{key: key, timestamp_ms: expire_ms}
    callback_module.on_command(state, db_num, command)
  end

  # Load an object based on its type
  defp load_object(@rdb_type_string, rest, callback_module, state, db_num, key, expire_ms) do
    {value, rest1} = load_string(rest)
    command = %Command.Set{key: key, value: value}

    with {:ok, new_state} <- callback_module.on_command(state, db_num, command),
         {:ok, final_state} <- emit_pexpireat(callback_module, new_state, db_num, key, expire_ms) do
      {:ok, final_state, rest1}
    end
  end

  defp load_object(@rdb_type_list, rest, callback_module, state, db_num, key, expire_ms) do
    {count, rest1} = load_length(rest)

    with {:ok, new_state, rest2} <-
           load_list_entries(count, rest1, callback_module, state, db_num, key),
         {:ok, final_state} <- emit_pexpireat(callback_module, new_state, db_num, key, expire_ms) do
      {:ok, final_state, rest2}
    end
  end

  defp load_object(@rdb_type_set, rest, callback_module, state, db_num, key, expire_ms) do
    {count, rest1} = load_length(rest)

    with {:ok, new_state, rest2} <-
           load_set_entries(count, rest1, callback_module, state, db_num, key),
         {:ok, final_state} <- emit_pexpireat(callback_module, new_state, db_num, key, expire_ms) do
      {:ok, final_state, rest2}
    end
  end

  defp load_object(@rdb_type_zset, rest, callback_module, state, db_num, key, expire_ms) do
    {count, rest1} = load_length(rest)

    with {:ok, new_state, rest2} <-
           load_zset_entries(count, rest1, callback_module, state, db_num, key),
         {:ok, final_state} <- emit_pexpireat(callback_module, new_state, db_num, key, expire_ms) do
      {:ok, final_state, rest2}
    end
  end

  defp load_object(@rdb_type_zset_2, rest, callback_module, state, db_num, key, expire_ms) do
    {count, rest1} = load_length(rest)

    with {:ok, new_state, rest2} <-
           load_zset_entries_v2(count, rest1, callback_module, state, db_num, key),
         {:ok, final_state} <- emit_pexpireat(callback_module, new_state, db_num, key, expire_ms) do
      {:ok, final_state, rest2}
    end
  end

  defp load_object(@rdb_type_hash, rest, callback_module, state, db_num, key, expire_ms) do
    {count, rest1} = load_length(rest)

    with {:ok, new_state, rest2} <-
           load_hash_entries(count, rest1, callback_module, state, db_num, key),
         {:ok, final_state} <- emit_pexpireat(callback_module, new_state, db_num, key, expire_ms) do
      {:ok, final_state, rest2}
    end
  end

  defp load_object(@rdb_type_list_quicklist, rest, callback_module, state, db_num, key, expire_ms) do
    {count, rest1} = load_length(rest)

    with {:ok, new_state, rest2} <-
           load_quicklist(count, rest1, callback_module, state, db_num, key, false),
         {:ok, final_state} <- emit_pexpireat(callback_module, new_state, db_num, key, expire_ms) do
      {:ok, final_state, rest2}
    end
  end

  defp load_object(
         @rdb_type_list_quicklist_2,
         rest,
         callback_module,
         state,
         db_num,
         key,
         expire_ms
       ) do
    {count, rest1} = load_length(rest)

    with {:ok, new_state, rest2} <-
           load_quicklist_2(count, rest1, callback_module, state, db_num, key),
         {:ok, final_state} <- emit_pexpireat(callback_module, new_state, db_num, key, expire_ms) do
      {:ok, final_state, rest2}
    end
  end

  defp load_object(@rdb_type_set_intset, rest, callback_module, state, db_num, key, expire_ms) do
    {intset_bin, rest1} = load_string(rest)

    with {:ok, new_state, rest2} <-
           load_intset(intset_bin, callback_module, state, db_num, key, rest1),
         {:ok, final_state} <- emit_pexpireat(callback_module, new_state, db_num, key, expire_ms) do
      {:ok, final_state, rest2}
    end
  end

  defp load_object(@rdb_type_set_listpack, rest, callback_module, state, db_num, key, expire_ms) do
    {listpack_bin, rest1} = load_string(rest)

    with {:ok, new_state, rest2} <-
           load_set_listpack(listpack_bin, callback_module, state, db_num, key, rest1),
         {:ok, final_state} <- emit_pexpireat(callback_module, new_state, db_num, key, expire_ms) do
      {:ok, final_state, rest2}
    end
  end

  defp load_object(@rdb_type_hash_ziplist, rest, callback_module, state, db_num, key, expire_ms) do
    {ziplist_bin, rest1} = load_string(rest)

    with {:ok, new_state, rest2} <-
           load_hash_ziplist(ziplist_bin, callback_module, state, db_num, key, rest1),
         {:ok, final_state} <- emit_pexpireat(callback_module, new_state, db_num, key, expire_ms) do
      {:ok, final_state, rest2}
    end
  end

  defp load_object(@rdb_type_hash_listpack, rest, callback_module, state, db_num, key, expire_ms) do
    {listpack_bin, rest1} = load_string(rest)

    with {:ok, new_state, rest2} <-
           load_hash_listpack(listpack_bin, callback_module, state, db_num, key, rest1),
         {:ok, final_state} <- emit_pexpireat(callback_module, new_state, db_num, key, expire_ms) do
      {:ok, final_state, rest2}
    end
  end

  defp load_object(@rdb_type_zset_ziplist, rest, callback_module, state, db_num, key, expire_ms) do
    {ziplist_bin, rest1} = load_string(rest)

    with {:ok, new_state, rest2} <-
           load_zset_ziplist(ziplist_bin, callback_module, state, db_num, key, rest1),
         {:ok, final_state} <- emit_pexpireat(callback_module, new_state, db_num, key, expire_ms) do
      {:ok, final_state, rest2}
    end
  end

  defp load_object(@rdb_type_zset_listpack, rest, callback_module, state, db_num, key, expire_ms) do
    {listpack_bin, rest1} = load_string(rest)

    with {:ok, new_state, rest2} <-
           load_zset_listpack(listpack_bin, callback_module, state, db_num, key, rest1),
         {:ok, final_state} <- emit_pexpireat(callback_module, new_state, db_num, key, expire_ms) do
      {:ok, final_state, rest2}
    end
  end

  defp load_object(type, rest, _callback_module, state, _db_num, _key, _expire_ms) do
    # Unknown or unsupported type, skip it
    # We try to skip by loading as a string, but this may fail
    try do
      {_value, rest1} = load_string(rest)
      {:ok, state, rest1}
    catch
      _, _ ->
        {:error, {:unsupported_type, type}}
    end
  end

  # Load list entries (RDB_TYPE_LIST)
  defp load_list_entries(0, rest, _callback_module, state, _db_num, _key) do
    {:ok, state, rest}
  end

  defp load_list_entries(count, rest, callback_module, state, db_num, key) do
    {value, rest1} = load_string(rest)
    command = %Command.RPush{key: key, value: value}

    case callback_module.on_command(state, db_num, command) do
      {:ok, new_state} ->
        load_list_entries(count - 1, rest1, callback_module, new_state, db_num, key)

      {:error, _} = error ->
        error
    end
  end

  # Load set entries (RDB_TYPE_SET)
  defp load_set_entries(0, rest, _callback_module, state, _db_num, _key) do
    {:ok, state, rest}
  end

  defp load_set_entries(count, rest, callback_module, state, db_num, key) do
    {member, rest1} = load_string(rest)
    command = %Command.SAdd{key: key, member: member}

    case callback_module.on_command(state, db_num, command) do
      {:ok, new_state} ->
        load_set_entries(count - 1, rest1, callback_module, new_state, db_num, key)

      {:error, _} = error ->
        error
    end
  end

  # Load zset entries (RDB_TYPE_ZSET - old format with string scores)
  defp load_zset_entries(0, rest, _callback_module, state, _db_num, _key) do
    {:ok, state, rest}
  end

  defp load_zset_entries(count, rest, callback_module, state, db_num, key) do
    {member, rest1} = load_string(rest)
    {score, rest2} = load_double_value(rest1)
    command = %Command.ZAdd{key: key, score: score, member: member}

    case callback_module.on_command(state, db_num, command) do
      {:ok, new_state} ->
        load_zset_entries(count - 1, rest2, callback_module, new_state, db_num, key)

      {:error, _} = error ->
        error
    end
  end

  # Load zset entries (RDB_TYPE_ZSET_2 - new format with binary scores)
  defp load_zset_entries_v2(0, rest, _callback_module, state, _db_num, _key) do
    {:ok, state, rest}
  end

  defp load_zset_entries_v2(count, rest, callback_module, state, db_num, key) do
    {member, rest1} = load_string(rest)
    <<score::float-little-64, rest2::binary>> = rest1
    command = %Command.ZAdd{key: key, score: score, member: member}

    case callback_module.on_command(state, db_num, command) do
      {:ok, new_state} ->
        load_zset_entries_v2(count - 1, rest2, callback_module, new_state, db_num, key)

      {:error, _} = error ->
        error
    end
  end

  # Load hash entries (RDB_TYPE_HASH)
  defp load_hash_entries(0, rest, _callback_module, state, _db_num, _key) do
    {:ok, state, rest}
  end

  defp load_hash_entries(count, rest, callback_module, state, db_num, key) do
    {field, rest1} = load_string(rest)
    {value, rest2} = load_string(rest1)
    command = %Command.HSet{key: key, field: field, value: value}

    case callback_module.on_command(state, db_num, command) do
      {:ok, new_state} ->
        load_hash_entries(count - 1, rest2, callback_module, new_state, db_num, key)

      {:error, _} = error ->
        error
    end
  end

  # Load quicklist (RDB_TYPE_LIST_QUICKLIST)
  defp load_quicklist(0, rest, _callback_module, state, _db_num, _key, _is_v2) do
    {:ok, state, rest}
  end

  defp load_quicklist(count, rest, callback_module, state, db_num, key, is_v2) do
    {ziplist_or_listpack, rest1} = load_string(rest)
    # In older versions, this is a ziplist; in newer versions (RDB 10+), it's a listpack
    case load_list_listpack(ziplist_or_listpack, callback_module, state, db_num, key) do
      {:ok, new_state} ->
        load_quicklist(count - 1, rest1, callback_module, new_state, db_num, key, is_v2)

      {:error, _} = error ->
        error
    end
  end

  # Load quicklist_2 (RDB_TYPE_LIST_QUICKLIST_2) - has container type field
  defp load_quicklist_2(0, rest, _callback_module, state, _db_num, _key) do
    {:ok, state, rest}
  end

  defp load_quicklist_2(count, rest, callback_module, state, db_num, key) do
    # Read container type: 1 = plain, 2 = packed (LZF compressed)
    <<_container_type::8, rest1::binary>> = rest
    {listpack_bin, rest2} = load_string(rest1)
    # ContainerType 2 means LZF compressed, but load_string already handles that
    case load_list_listpack(listpack_bin, callback_module, state, db_num, key) do
      {:ok, new_state} ->
        load_quicklist_2(count - 1, rest2, callback_module, new_state, db_num, key)

      {:error, _} = error ->
        error
    end
  end

  # Load list from listpack
  defp load_list_listpack(listpack_bin, callback_module, state, db_num, key) do
    try do
      case parse_listpack(listpack_bin) do
        {:ok, entries} ->
          load_listpack_entries_as_list(entries, callback_module, state, db_num, key)

        {:error, _} = error ->
          error
      end
    catch
      class, reason ->
        {:error, {:invalid_listpack, class, reason, byte_size(listpack_bin)}}
    end
  end

  defp load_listpack_entries_as_list([], _callback_module, state, _db_num, _key) do
    {:ok, state}
  end

  defp load_listpack_entries_as_list([entry | rest], callback_module, state, db_num, key) do
    command = %Command.RPush{key: key, value: entry}

    case callback_module.on_command(state, db_num, command) do
      {:ok, new_state} ->
        load_listpack_entries_as_list(rest, callback_module, new_state, db_num, key)

      {:error, _} = error ->
        error
    end
  end

  # Load intset (RDB_TYPE_SET_INTSET)
  defp load_intset(intset_bin, callback_module, state, db_num, key, rest) do
    try do
      case parse_intset(intset_bin) do
        {:ok, entries} ->
          load_intset_entries(entries, callback_module, state, db_num, key, rest)

        {:error, _} = error ->
          error
      end
    catch
      _, _ -> {:error, :invalid_intset}
    end
  end

  defp load_intset_entries([], _callback_module, state, _db_num, _key, rest) do
    {:ok, state, rest}
  end

  defp load_intset_entries([entry | rest_entries], callback_module, state, db_num, key, rest) do
    entry_bin = Integer.to_string(entry)
    command = %Command.SAdd{key: key, member: entry_bin}

    case callback_module.on_command(state, db_num, command) do
      {:ok, new_state} ->
        load_intset_entries(rest_entries, callback_module, new_state, db_num, key, rest)

      {:error, _} = error ->
        error
    end
  end

  # Load set from listpack (RDB_TYPE_SET_LISTPACK)
  defp load_set_listpack(listpack_bin, callback_module, state, db_num, key, rest) do
    try do
      case parse_listpack(listpack_bin) do
        {:ok, entries} ->
          load_listpack_entries_as_set(entries, callback_module, state, db_num, key, rest)

        {:error, _} = error ->
          error
      end
    catch
      _, _ -> {:error, :invalid_listpack}
    end
  end

  defp load_listpack_entries_as_set([], _callback_module, state, _db_num, _key, rest) do
    {:ok, state, rest}
  end

  defp load_listpack_entries_as_set(
         [entry | rest_entries],
         callback_module,
         state,
         db_num,
         key,
         rest
       ) do
    command = %Command.SAdd{key: key, member: entry}

    case callback_module.on_command(state, db_num, command) do
      {:ok, new_state} ->
        load_listpack_entries_as_set(rest_entries, callback_module, new_state, db_num, key, rest)

      {:error, _} = error ->
        error
    end
  end

  # Load hash from ziplist (RDB_TYPE_HASH_ZIPLIST)
  defp load_hash_ziplist(ziplist_bin, callback_module, state, db_num, key, rest) do
    try do
      case parse_ziplist(ziplist_bin) do
        {:ok, entries} ->
          load_ziplist_entries_as_hash(entries, callback_module, state, db_num, key, rest)

        {:error, _} = error ->
          error
      end
    catch
      _, _ -> {:error, :invalid_ziplist}
    end
  end

  defp load_ziplist_entries_as_hash([], _callback_module, state, _db_num, _key, rest) do
    {:ok, state, rest}
  end

  defp load_ziplist_entries_as_hash(
         [field, value | rest_entries],
         callback_module,
         state,
         db_num,
         key,
         rest
       ) do
    command = %Command.HSet{key: key, field: field, value: value}

    case callback_module.on_command(state, db_num, command) do
      {:ok, new_state} ->
        load_ziplist_entries_as_hash(rest_entries, callback_module, new_state, db_num, key, rest)

      {:error, _} = error ->
        error
    end
  end

  defp load_ziplist_entries_as_hash([_], _callback_module, _state, _db_num, _key, _rest) do
    {:error, :odd_hash_entries}
  end

  # Load hash from listpack (RDB_TYPE_HASH_LISTPACK)
  defp load_hash_listpack(listpack_bin, callback_module, state, db_num, key, rest) do
    try do
      case parse_listpack(listpack_bin) do
        {:ok, entries} ->
          load_listpack_entries_as_hash(entries, callback_module, state, db_num, key, rest)

        {:error, _} = error ->
          error
      end
    catch
      _, _ -> {:error, :invalid_listpack}
    end
  end

  defp load_listpack_entries_as_hash([], _callback_module, state, _db_num, _key, rest) do
    {:ok, state, rest}
  end

  defp load_listpack_entries_as_hash(
         [field, value | rest_entries],
         callback_module,
         state,
         db_num,
         key,
         rest
       ) do
    command = %Command.HSet{key: key, field: field, value: value}

    case callback_module.on_command(state, db_num, command) do
      {:ok, new_state} ->
        load_listpack_entries_as_hash(rest_entries, callback_module, new_state, db_num, key, rest)

      {:error, _} = error ->
        error
    end
  end

  defp load_listpack_entries_as_hash([_], _callback_module, _state, _db_num, _key, _rest) do
    {:error, :odd_hash_entries}
  end

  # Load zset from ziplist (RDB_TYPE_ZSET_ZIPLIST)
  defp load_zset_ziplist(ziplist_bin, callback_module, state, db_num, key, rest) do
    try do
      case parse_ziplist(ziplist_bin) do
        {:ok, entries} ->
          load_ziplist_entries_as_zset(entries, callback_module, state, db_num, key, rest)

        {:error, _} = error ->
          error
      end
    catch
      _, _ -> {:error, :invalid_ziplist}
    end
  end

  defp load_ziplist_entries_as_zset([], _callback_module, state, _db_num, _key, rest) do
    {:ok, state, rest}
  end

  defp load_ziplist_entries_as_zset(
         [member, score_bin | rest_entries],
         callback_module,
         state,
         db_num,
         key,
         rest
       ) do
    score = binary_to_float_safe(score_bin)
    command = %Command.ZAdd{key: key, score: score, member: member}

    case callback_module.on_command(state, db_num, command) do
      {:ok, new_state} ->
        load_ziplist_entries_as_zset(rest_entries, callback_module, new_state, db_num, key, rest)

      {:error, _} = error ->
        error
    end
  end

  defp load_ziplist_entries_as_zset([_], _callback_module, _state, _db_num, _key, _rest) do
    {:error, :odd_zset_entries}
  end

  # Load zset from listpack (RDB_TYPE_ZSET_LISTPACK)
  defp load_zset_listpack(listpack_bin, callback_module, state, db_num, key, rest) do
    try do
      case parse_listpack(listpack_bin) do
        {:ok, entries} ->
          load_listpack_entries_as_zset(entries, callback_module, state, db_num, key, rest)

        {:error, _} = error ->
          error
      end
    catch
      _, _ -> {:error, :invalid_listpack}
    end
  end

  defp load_listpack_entries_as_zset([], _callback_module, state, _db_num, _key, rest) do
    {:ok, state, rest}
  end

  defp load_listpack_entries_as_zset(
         [member, score_bin | rest_entries],
         callback_module,
         state,
         db_num,
         key,
         rest
       ) do
    score = binary_to_float_safe(score_bin)
    command = %Command.ZAdd{key: key, score: score, member: member}

    case callback_module.on_command(state, db_num, command) do
      {:ok, new_state} ->
        load_listpack_entries_as_zset(rest_entries, callback_module, new_state, db_num, key, rest)

      {:error, _} = error ->
        error
    end
  end

  defp load_listpack_entries_as_zset([_], _callback_module, _state, _db_num, _key, _rest) do
    {:error, :odd_zset_entries}
  end

  # Helper to convert binary to float safely
  defp binary_to_float_safe(bin) do
    try do
      :erlang.binary_to_float(bin)
    catch
      :error, :badarg ->
        # Try as integer first
        try do
          :erlang.binary_to_integer(bin) * 1.0
        catch
          :error, :badarg -> 0.0
        end
    end
  end

  # Load length encoding
  defp load_length(<<byte::8, rest::binary>>) do
    type = (byte &&& 0xC0) >>> 6

    case type do
      @rdb_6bitlen ->
        # 6 bit length
        len = byte &&& 0x3F
        {len, rest}

      @rdb_14bitlen ->
        # 14 bit length
        <<next_byte::8, rest1::binary>> = rest
        len = (byte &&& 0x3F) <<< 8 ||| next_byte
        {len, rest1}

      @rdb_32bitlen ->
        # Check if it's 32-bit or 64-bit
        case byte do
          0x80 ->
            # 32 bit length
            <<len::32-big, rest1::binary>> = rest
            {len, rest1}

          0x81 ->
            # 64 bit length
            <<len::64-big, rest1::binary>> = rest
            {len, rest1}

          _ ->
            throw({:error, :invalid_length_encoding})
        end

      @rdb_encval ->
        # Encoded value
        {:encoded, byte &&& 0x3F, rest}
    end
  end

  # Load string (handles encoding)
  defp load_string(data) do
    case load_length(data) do
      {:encoded, enc_type, rest} ->
        load_encoded_string(enc_type, rest)

      {len, rest} ->
        <<str::binary-size(len), rest1::binary>> = rest
        {str, rest1}
    end
  end

  # Load encoded string
  defp load_encoded_string(@rdb_enc_int8, <<val::signed-8, rest::binary>>) do
    {Integer.to_string(val), rest}
  end

  defp load_encoded_string(@rdb_enc_int16, <<val::signed-little-16, rest::binary>>) do
    {Integer.to_string(val), rest}
  end

  defp load_encoded_string(@rdb_enc_int32, <<val::signed-little-32, rest::binary>>) do
    {Integer.to_string(val), rest}
  end

  defp load_encoded_string(@rdb_enc_lzf, data) do
    {comp_len, rest1} = load_length(data)
    {uncomp_len, rest2} = load_length(rest1)
    <<comp_data::binary-size(comp_len), rest3::binary>> = rest2

    case lzf_decompress(comp_data, uncomp_len) do
      uncomp_data when byte_size(uncomp_data) == uncomp_len ->
        {uncomp_data, rest3}

      uncomp_data ->
        # Size mismatch, but continue anyway
        {uncomp_data, rest3}
    end
  end

  defp load_encoded_string(enc_type, _rest) do
    throw({:error, {:unknown_encoding, enc_type}})
  end

  # Load double value (old format - string representation)
  defp load_double_value(<<len::8, rest::binary>>) do
    case len do
      253 ->
        # NaN
        {:nan, rest}

      254 ->
        # +Inf
        {:pos_inf, rest}

      255 ->
        # -Inf
        {:neg_inf, rest}

      _ ->
        <<str_val::binary-size(len), rest1::binary>> = rest

        score =
          try do
            :erlang.binary_to_float(str_val)
          catch
            :error, :badarg -> :erlang.binary_to_integer(str_val) * 1.0
          end

        {score, rest1}
    end
  end

  # LZF decompression using NIF
  defp lzf_decompress(comp_data, uncomp_len) do
    case Veidrodelis.LZF.decompress(comp_data, uncomp_len) do
      {:ok, decompressed} ->
        decompressed

      {:error, _reason} ->
        # If decompression fails, return empty binary
        <<0::size(uncomp_len)-unit(8)>>
    end
  end

  # Parse ziplist format
  defp parse_ziplist(
         <<_total_bytes::32-little, _tail_offset::32-little, num_entries::16-little,
           rest::binary>>
       ) do
    # Skip header, parse entries
    parse_ziplist_entries(rest, num_entries, [])
  end

  defp parse_ziplist_entries(<<0xFF, _::binary>>, _num_entries, acc) do
    # End marker
    {:ok, Enum.reverse(acc)}
  end

  defp parse_ziplist_entries(_data, 0, acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp parse_ziplist_entries(data, num_entries, acc) do
    case parse_ziplist_entry(data) do
      {entry, rest} ->
        parse_ziplist_entries(rest, num_entries - 1, [entry | acc])

      :error ->
        {:error, :invalid_ziplist_entry}
    end
  end

  defp parse_ziplist_entry(<<prev_len::8, rest::binary>>) when prev_len < 254 do
    # Previous entry length is 1 byte
    parse_ziplist_entry_encoding(rest)
  end

  defp parse_ziplist_entry(<<254, _prev_len::32-little, rest::binary>>) do
    # Previous entry length is 5 bytes
    parse_ziplist_entry_encoding(rest)
  end

  defp parse_ziplist_entry_encoding(<<enc::8, rest::binary>>) do
    case enc &&& 0xC0 do
      0x00 ->
        # String with length <= 63
        len = enc &&& 0x3F
        <<str::binary-size(len), rest1::binary>> = rest
        {str, rest1}

      0x40 ->
        # String with length <= 16383
        <<next_byte::8, rest1::binary>> = rest
        len = (enc &&& 0x3F) <<< 8 ||| next_byte
        <<str::binary-size(len), rest2::binary>> = rest1
        {str, rest2}

      0x80 ->
        # String with length > 16383
        <<len::32-big, rest1::binary>> = rest
        <<str::binary-size(len), rest2::binary>> = rest1
        {str, rest2}

      0xC0 ->
        # Integer encoding
        case enc do
          0xF0 ->
            # 16-bit integer
            <<val::signed-little-16, rest1::binary>> = rest
            {Integer.to_string(val), rest1}

          0xFE ->
            # 8-bit integer
            <<val::signed-8, rest1::binary>> = rest
            {Integer.to_string(val), rest1}

          0xF1 ->
            # 32-bit integer
            <<val::signed-little-32, rest1::binary>> = rest
            {Integer.to_string(val), rest1}

          0xF2 ->
            # 64-bit integer
            <<val::signed-little-64, rest1::binary>> = rest
            {Integer.to_string(val), rest1}

          0xF3 ->
            # 24-bit integer
            <<val::signed-little-24, rest1::binary>> = rest
            {Integer.to_string(val), rest1}

          _ when enc >= 0xF4 and enc <= 0xFD ->
            # 4-bit integer (0-12)
            val = (enc &&& 0x0F) - 1
            {Integer.to_string(val), rest}

          _ ->
            :error
        end
    end
  end

  # Parse intset format
  defp parse_intset(bin) when byte_size(bin) < 8 do
    {:error, {:intset_too_small, byte_size(bin)}}
  end

  defp parse_intset(<<encoding::32-little, length::32-little, rest::binary>>) do
    parse_intset_entries(rest, encoding, length, [])
  end

  defp parse_intset_entries(_data, _encoding, 0, acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp parse_intset_entries(data, 2, length, acc) when byte_size(data) >= 2 do
    # 16-bit integers
    <<val::signed-little-16, rest::binary>> = data
    parse_intset_entries(rest, 2, length - 1, [val | acc])
  end

  defp parse_intset_entries(data, 4, length, acc) when byte_size(data) >= 4 do
    # 32-bit integers
    <<val::signed-little-32, rest::binary>> = data
    parse_intset_entries(rest, 4, length - 1, [val | acc])
  end

  defp parse_intset_entries(data, 8, length, acc) when byte_size(data) >= 8 do
    # 64-bit integers
    <<val::signed-little-64, rest::binary>> = data
    parse_intset_entries(rest, 8, length - 1, [val | acc])
  end

  defp parse_intset_entries(_data, encoding, _length, _acc) do
    {:error, {:unknown_intset_encoding, encoding}}
  end

  # Parse listpack format
  defp parse_listpack(bin) when byte_size(bin) < 6 do
    {:error, {:listpack_too_small, byte_size(bin)}}
  end

  defp parse_listpack(<<_total_bytes::32-little, num_entries::16-little, rest::binary>>) do
    parse_listpack_entries(rest, num_entries, [])
  end

  defp parse_listpack_entries(<<0xFF, _::binary>>, _num_entries, acc) do
    # End marker
    {:ok, Enum.reverse(acc)}
  end

  defp parse_listpack_entries(_data, 0, acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp parse_listpack_entries(data, num_entries, acc) do
    case parse_listpack_entry(data) do
      {entry, rest} ->
        parse_listpack_entries(rest, num_entries - 1, [entry | acc])

      :error ->
        {:error, :invalid_listpack_entry}
    end
  end

  defp parse_listpack_entry(<<enc::8, rest::binary>>) do
    case enc &&& 0x80 do
      0 ->
        # 7-bit unsigned integer - 1 byte encoding + 1 byte backlen
        val = enc &&& 0x7F
        <<_back_len::8, rest1::binary>> = rest
        {Integer.to_string(val), rest1}

      0x80 ->
        case enc &&& 0xC0 do
          0x80 ->
            # 6-bit string - 1 byte encoding + N bytes data + 1 byte backlen
            len = enc &&& 0x3F
            <<str::binary-size(len), _back_len::8, rest1::binary>> = rest
            {str, rest1}

          0xC0 ->
            case enc &&& 0xF0 do
              0xC0 ->
                # 13-bit signed integer - 2 bytes encoding + 1 byte backlen
                <<next_byte::8, _back_len::8, rest1::binary>> = rest
                val = (enc &&& 0x1F) <<< 8 ||| next_byte

                signed_val =
                  if val >= 4096 do
                    val - 8192
                  else
                    val
                  end

                {Integer.to_string(signed_val), rest1}

              0xD0 ->
                # 16-bit string - 3 bytes encoding + N bytes data + variable backlen
                <<len::16-big, rest1::binary>> = rest
                backlen_size = calculate_backlen_size(3 + len)
                <<str::binary-size(len), _::binary-size(backlen_size), rest2::binary>> = rest1
                {str, rest2}

              0xE0 ->
                # 12-bit string - 2 bytes encoding + N bytes data + variable backlen
                # For 0xE0-0xEF: lower 4 bits of Enc + next byte form the 12-bit length
                <<next_byte::8, rest1::binary>> = rest
                len = (enc &&& 0x0F) <<< 8 ||| next_byte
                backlen_size = calculate_backlen_size(2 + len)
                <<str::binary-size(len), _::binary-size(backlen_size), rest2::binary>> = rest1
                {str, rest2}

              0xF0 ->
                case enc do
                  0xF0 ->
                    # 32-bit string - 5 bytes encoding + N bytes data + variable backlen
                    <<len::32-little, rest1::binary>> = rest
                    backlen_size = calculate_backlen_size(5 + len)

                    <<str::binary-size(len), _::binary-size(backlen_size), rest2::binary>> =
                      rest1

                    {str, rest2}

                  0xF1 ->
                    # 16-bit signed integer - 3 bytes encoding + 1 byte backlen
                    <<val::signed-little-16, _back_len::8, rest1::binary>> = rest
                    {Integer.to_string(val), rest1}

                  0xF2 ->
                    # 24-bit signed integer - 4 bytes encoding + 1 byte backlen
                    <<val::signed-little-24, _back_len::8, rest1::binary>> = rest
                    {Integer.to_string(val), rest1}

                  0xF3 ->
                    # 32-bit signed integer - 5 bytes encoding + 1 byte backlen
                    <<val::signed-little-32, _back_len::8, rest1::binary>> = rest
                    {Integer.to_string(val), rest1}

                  0xF4 ->
                    # 64-bit signed integer - 9 bytes encoding + 1 byte backlen
                    <<val::signed-little-64, _back_len::8, rest1::binary>> = rest
                    {Integer.to_string(val), rest1}

                  _ ->
                    :error
                end

              _ ->
                :error
            end
        end
    end
  end

  # Calculate listpack back length size based on entry size
  # 1 byte
  defp calculate_backlen_size(entry_size) when entry_size <= 127, do: 1
  # 2 bytes
  defp calculate_backlen_size(entry_size) when entry_size <= 16383, do: 2
  # 3 bytes
  defp calculate_backlen_size(entry_size) when entry_size <= 2_097_151, do: 3
  # 4 bytes
  defp calculate_backlen_size(entry_size) when entry_size <= 268_435_455, do: 4
  # 5 bytes
  defp calculate_backlen_size(_), do: 5
end
