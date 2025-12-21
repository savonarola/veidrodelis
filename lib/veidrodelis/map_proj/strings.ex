defmodule Vdr.MapProj.Strings do
  @moduledoc """
  String store operations for MapProj.

  Stores string values in a map structure as raw binaries.
  """

  import Bitwise

  @type db :: non_neg_integer()
  @type key :: binary()
  @type value :: binary()
  @type store :: %{db() => %{key() => value()}}
  @type bitop ::
          :AND | :OR | :XOR | :NOT | :DIFF | :DIFF1 | :ANDOR | :ONE

  @doc """
  Sets the value for a key in the specified database.
  Returns the updated store.
  """
  @spec set(store(), db(), key(), value()) :: store()
  def set(store, db, key, value) when is_binary(value) do
    db_map = Map.get(store, db, %{})
    new_db_map = Map.put(db_map, key, value)
    Map.put(store, db, new_db_map)
  end

  @doc """
  Sets multiple key-value pairs at once.
  Returns the updated store.
  """
  @spec mset(store(), db(), [{key(), value()}]) :: store()
  def mset(store, db, pairs) do
    db_map = Map.get(store, db, %{})
    new_db_map = Enum.reduce(pairs, db_map, fn {key, value}, acc -> Map.put(acc, key, value) end)
    Map.put(store, db, new_db_map)
  end

  @doc """
  Appends data to the value at key.
  If the key doesn't exist, it's created with the data as value.
  Returns the updated store.
  """
  @spec append(store(), db(), key(), value()) :: store()
  def append(store, db, key, data) when is_binary(data) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil ->
        set(store, db, key, data)

      orig_value when is_binary(orig_value) ->
        new_value = orig_value <> data
        new_db_map = Map.put(db_map, key, new_value)
        Map.put(store, db, new_db_map)
    end
  end

  @doc """
  Overwrites part of the string at key starting at the specified offset.
  Pads with zero bytes if needed.
  Returns the updated store.
  """
  @spec setrange(store(), db(), key(), non_neg_integer(), value()) :: store()
  def setrange(store, db, key, offset, value)
      when is_integer(offset) and offset >= 0 and is_binary(value) do
    db_map = Map.get(store, db, %{})

    orig_value =
      case Map.get(db_map, key) do
        nil -> ""
        val when is_binary(val) -> val
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
    new_db_map = Map.put(db_map, key, new_value)
    Map.put(store, db, new_db_map)
  end

  @doc """
  Sets or clears the bit at the given offset.
  Bits are numbered from 0, with bit 0 being the most significant bit of the first byte.
  Returns the updated store.
  """
  @spec setbit(store(), db(), key(), non_neg_integer(), 0 | 1) :: store()
  def setbit(store, db, key, offset, bit)
      when is_integer(offset) and offset >= 0 and bit in [0, 1] do
    db_map = Map.get(store, db, %{})

    orig_value =
      case Map.get(db_map, key) do
        nil -> ""
        val when is_binary(val) -> val
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
    new_db_map = Map.put(db_map, key, new_value)
    Map.put(store, db, new_db_map)
  end

  @doc """
  Performs a bitwise operation on source keys and stores result in dest.
  Returns the updated store.

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
  @spec bitop(store(), bitop(), db(), key(), [key()]) :: store()
  def bitop(store, op, db, dest_key, source_keys)

  def bitop(store, :NOT, db, dest_key, [source_key]) do
    db_map = Map.get(store, db, %{})

    value =
      case Map.get(db_map, source_key) do
        nil -> ""
        val when is_binary(val) -> val
      end

    result = invert_binary(value)
    store_result(store, db, dest_key, result)
  end

  def bitop(store, op, db, dest_key, source_keys) when is_list(source_keys) do
    db_map = Map.get(store, db, %{})

    # Get all source values
    values =
      Enum.map(source_keys, fn key ->
        case Map.get(db_map, key) do
          nil -> ""
          val when is_binary(val) -> val
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
  Gets the value for a key.
  Returns nil if the key doesn't exist.
  """
  @spec get(store(), db(), key()) :: value() | nil
  def get(store, db, key) do
    case Map.get(store, db) do
      nil ->
        nil

      db_map ->
        case Map.get(db_map, key) do
          nil -> nil
          value when is_binary(value) -> value
          _ -> nil
        end
    end
  end

  # Private helpers

  @spec store_result(store(), db(), key(), binary()) :: store()
  defp store_result(store, db, dest_key, result) do
    db_map = Map.get(store, db, %{})
    new_db_map = Map.put(db_map, dest_key, result)
    Map.put(store, db, new_db_map)
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
