defmodule Vdr.StringStore do
  @moduledoc """
  An ETS-backed store for Redis string operations.

  Uses a protected ETS table to store key-value pairs with decoded values.
  Each entry is stored as `{{db, key}, original_value, decoded_value}`.

  The decode function is called whenever the original value changes to compute
  a decoded representation.
  """

  import Bitwise

  defstruct [:tid, :decode_fun]

  @type t :: %__MODULE__{
          tid: :ets.tid(),
          decode_fun: decode_fun()
        }

  @type db :: non_neg_integer()
  @type key :: any()
  @type value :: binary()
  @type decode_fun :: (key(), value() -> any())
  @type bitop ::
          :AND | :OR | :XOR | :NOT | :DIFF | :DIFF1 | :ANDOR | :ONE

  @doc """
  Creates a new string store with the given decode function.

  The decode function receives `(key, value)` and returns a decoded value.
  It is called whenever a value is set or modified.

  Returns a StringStore struct containing the table id and decode function.
  """
  @spec new(decode_fun()) :: t()
  def new(decode_fun) when is_function(decode_fun, 2) do
    tid = :ets.new(__MODULE__, [:ordered_set, :protected])
    %__MODULE__{tid: tid, decode_fun: decode_fun}
  end

  @doc """
  Sets the value for a key in the specified database.
  """
  @spec set(t(), db(), key(), value()) :: :ok
  def set(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, key, value)
      when is_binary(value) do
    decoded = decode_fun.(key, value)
    :ets.insert(tid, {{db, key}, value, decoded})
    :ok
  end

  @doc """
  Sets multiple key-value pairs at once.
  """
  @spec mset(t(), db(), [{key(), value()}]) :: :ok
  def mset(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, pairs) do
    entries =
      Enum.map(pairs, fn {key, value} ->
        decoded = decode_fun.(key, value)
        {{db, key}, value, decoded}
      end)

    :ets.insert(tid, entries)
    :ok
  end

  @doc """
  Appends data to the value at key.
  If the key doesn't exist, it's created with the data as value.
  """
  @spec append(t(), db(), key(), value()) :: :ok
  def append(%__MODULE__{tid: tid, decode_fun: decode_fun} = store, db, key, data)
      when is_binary(data) do
    case :ets.lookup(tid, {db, key}) do
      [] ->
        set(store, db, key, data)

      [{{^db, ^key}, orig_value, _decoded}] ->
        new_value = orig_value <> data
        new_decoded = decode_fun.(key, new_value)
        :ets.insert(tid, {{db, key}, new_value, new_decoded})
        :ok
    end
  end

  @doc """
  Overwrites part of the string at key starting at the specified offset.
  Pads with zero bytes if needed.
  """
  @spec setrange(t(), db(), key(), non_neg_integer(), value()) :: :ok
  def setrange(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, key, offset, value)
      when is_integer(offset) and offset >= 0 and is_binary(value) do
    orig_value =
      case :ets.lookup(tid, {db, key}) do
        [] -> ""
        [{{^db, ^key}, val, _decoded}] -> val
      end

    # Pad with zero bytes if offset is beyond current length
    padded =
      if byte_size(orig_value) < offset do
        orig_value <> :binary.copy(<<0>>, offset - byte_size(orig_value))
      else
        orig_value
      end

    # Replace substring at offset
    prefix = binary_part(padded, 0, offset)

    suffix_start = min(offset + byte_size(value), byte_size(padded))

    suffix =
      if suffix_start < byte_size(padded) do
        binary_part(padded, suffix_start, byte_size(padded) - suffix_start)
      else
        ""
      end

    new_value = prefix <> value <> suffix

    new_decoded = decode_fun.(key, new_value)
    :ets.insert(tid, {{db, key}, new_value, new_decoded})
    :ok
  end

  @doc """
  Sets or clears the bit at the given offset.
  Bits are numbered from 0, with bit 0 being the most significant bit of the first byte.
  """
  @spec setbit(t(), db(), key(), non_neg_integer(), 0 | 1) :: :ok
  def setbit(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, key, offset, bit)
      when is_integer(offset) and offset >= 0 and bit in [0, 1] do
    orig_value =
      case :ets.lookup(tid, {db, key}) do
        [] -> ""
        [{{^db, ^key}, val, _decoded}] -> val
      end

    byte_offset = div(offset, 8)
    bit_offset = rem(offset, 8)

    # Pad with zero bytes if needed
    padded =
      if byte_size(orig_value) <= byte_offset do
        orig_value <> :binary.copy(<<0>>, byte_offset - byte_size(orig_value) + 1)
      else
        orig_value
      end

    # Get the byte to modify
    byte_val = :binary.at(padded, byte_offset)

    # Set the bit (bits are numbered from MSB, left to right)
    mask = 1 <<< (7 - bit_offset)

    new_byte =
      if bit == 1 do
        byte_val ||| mask
      else
        byte_val &&& bnot(mask) &&& 0xFF
      end

    # Reconstruct the value
    prefix = if byte_offset > 0, do: binary_part(padded, 0, byte_offset), else: ""

    suffix =
      if byte_offset + 1 < byte_size(padded) do
        binary_part(padded, byte_offset + 1, byte_size(padded) - byte_offset - 1)
      else
        ""
      end

    new_value = prefix <> <<new_byte>> <> suffix

    new_decoded = decode_fun.(key, new_value)
    :ets.insert(tid, {{db, key}, new_value, new_decoded})
    :ok
  end

  @doc """
  Performs a bitwise operation on source keys and stores result in dest.

  Supported operations:
  - `:AND` - Set bit if set in ALL source bitmaps
  - `:OR` - Set bit if set in ANY source bitmap
  - `:XOR` - Set bit if set in ODD number of source bitmaps
  - `:NOT` - Unary operation, inverts bits (requires exactly one source)
  - `:DIFF` - Set bit if set in first source but NOT in any others (X AND NOT (Y1 OR Y2 OR ...))
  - `:DIFF1` - Set bit if set in any Y but NOT in X ((Y1 OR Y2 OR ...) AND NOT X)
  - `:ANDOR` - Set bit if set in X AND in any Y (X AND (Y1 OR Y2 OR ...))
  - `:ONE` - Set bit if set in EXACTLY one source bitmap
  """
  @spec bitop(t(), bitop(), db(), key(), [key()]) :: :ok
  def bitop(store, op, db, dest_key, source_keys)

  def bitop(%__MODULE__{tid: tid} = store, :NOT, db, dest_key, [source_key]) do
    value =
      case :ets.lookup(tid, {db, source_key}) do
        [] -> ""
        [{{^db, ^source_key}, val, _decoded}] -> val
      end

    result = invert_binary(value)
    store_result(store, db, dest_key, result)
  end

  def bitop(%__MODULE__{tid: tid} = store, op, db, dest_key, source_keys)
      when is_list(source_keys) do
    # Get all source values
    values =
      Enum.map(source_keys, fn key ->
        case :ets.lookup(tid, {db, key}) do
          [] -> ""
          [{{^db, ^key}, val, _decoded}] -> val
        end
      end)

    result =
      case values do
        [] ->
          ""

        values ->
          # Pad all values to same length
          max_len = Enum.max_by(values, &byte_size/1) |> byte_size()

          padded =
            Enum.map(values, fn val ->
              if byte_size(val) < max_len do
                val <> :binary.copy(<<0>>, max_len - byte_size(val))
              else
                val
              end
            end)

          # Perform operation
          apply_bitop(op, padded)
      end

    store_result(store, db, dest_key, result)
  end

  @doc """
  Deletes a key from the store.
  """
  @spec del(t(), db(), key()) :: :ok
  def del(%__MODULE__{tid: tid}, db, key) do
    :ets.delete(tid, {db, key})
    :ok
  end

  @doc """
  Destroys the ETS table and releases resources.
  """
  @spec destroy(t()) :: :ok
  def destroy(%__MODULE__{tid: tid}) do
    :ets.delete(tid)
    :ok
  end

  @doc """
  Gets the original (binary) value for a key.
  Returns nil if the key doesn't exist.
  """
  @spec get(t(), db(), key()) :: value() | nil
  def get(%__MODULE__{tid: tid}, db, key) do
    case :ets.lookup(tid, {db, key}) do
      [] -> nil
      [{{^db, ^key}, value, _decoded}] -> value
    end
  end

  @doc """
  Gets the decoded value for a key.
  Returns nil if the key doesn't exist.
  """
  @spec get_decoded(t(), db(), key()) :: any()
  def get_decoded(%__MODULE__{tid: tid}, db, key) do
    case :ets.lookup(tid, {db, key}) do
      [] -> nil
      [{{^db, ^key}, _value, decoded}] -> decoded
    end
  end

  # Private helpers

  @spec store_result(t(), db(), key(), binary()) :: :ok
  defp store_result(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, dest_key, result) do
    decoded = decode_fun.(dest_key, result)
    :ets.insert(tid, {{db, dest_key}, result, decoded})
    :ok
  end

  @spec apply_bitop(bitop(), [binary()]) :: binary()
  defp apply_bitop(:AND, binaries) do
    Enum.reduce(binaries, fn bin, acc -> and_binaries(acc, bin) end)
  end

  defp apply_bitop(:OR, binaries) do
    Enum.reduce(binaries, fn bin, acc -> or_binaries(acc, bin) end)
  end

  defp apply_bitop(:XOR, binaries) do
    Enum.reduce(binaries, fn bin, acc -> xor_binaries(acc, bin) end)
  end

  defp apply_bitop(:DIFF, [first | rest]) do
    # X AND NOT (Y1 OR Y2 OR ...)
    others_or = Enum.reduce(rest, fn bin, acc -> or_binaries(acc, bin) end)
    and_binaries(first, invert_binary(others_or))
  end

  defp apply_bitop(:DIFF1, [first | rest]) do
    # (Y1 OR Y2 OR ...) AND NOT X
    ys_or = Enum.reduce(rest, fn bin, acc -> or_binaries(acc, bin) end)
    and_binaries(ys_or, invert_binary(first))
  end

  defp apply_bitop(:ANDOR, [first | rest]) do
    # X AND (Y1 OR Y2 OR ...)
    ys_or = Enum.reduce(rest, fn bin, acc -> or_binaries(acc, bin) end)
    and_binaries(first, ys_or)
  end

  defp apply_bitop(:ONE, binaries) do
    # Exactly one bit set across all bitmaps
    # Count set bits for each position
    list_of_lists = Enum.map(binaries, &:binary.bin_to_list/1)

    Enum.zip(list_of_lists)
    |> Enum.map(fn bytes_tuple ->
      bytes = Tuple.to_list(bytes_tuple)
      # For each byte position, count bits across all sources
      count_one_bits(bytes)
    end)
    |> :binary.list_to_bin()
  end

  # Count bits that are set in exactly one source
  @spec count_one_bits([byte()]) :: byte()
  defp count_one_bits(bytes) do
    for bit_pos <- 0..7, reduce: 0 do
      acc ->
        # Count how many sources have this bit set
        count =
          Enum.count(bytes, fn byte ->
            mask = 1 <<< (7 - bit_pos)
            (byte &&& mask) != 0
          end)

        # Set bit if exactly one source has it
        if count == 1 do
          acc ||| 1 <<< (7 - bit_pos)
        else
          acc
        end
    end
  end

  @spec and_binaries(binary(), binary()) :: binary()
  defp and_binaries(bin1, bin2) do
    list1 = :binary.bin_to_list(bin1)
    list2 = :binary.bin_to_list(bin2)

    Enum.zip(list1, list2)
    |> Enum.map(fn {b1, b2} -> b1 &&& b2 end)
    |> :binary.list_to_bin()
  end

  @spec or_binaries(binary(), binary()) :: binary()
  defp or_binaries(bin1, bin2) do
    list1 = :binary.bin_to_list(bin1)
    list2 = :binary.bin_to_list(bin2)

    Enum.zip(list1, list2)
    |> Enum.map(fn {b1, b2} -> b1 ||| b2 end)
    |> :binary.list_to_bin()
  end

  @spec xor_binaries(binary(), binary()) :: binary()
  defp xor_binaries(bin1, bin2) do
    :crypto.exor(bin1, bin2)
  end

  @spec invert_binary(binary()) :: binary()
  defp invert_binary(bin) do
    :binary.bin_to_list(bin)
    |> Enum.map(fn byte -> bnot(byte) &&& 0xFF end)
    |> :binary.list_to_bin()
  end
end
