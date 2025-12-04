defmodule VDR.ETSRead do
  @moduledoc """
  Utilities for reading from ETS tables with streaming support.

  This module provides functions for efficiently reading data from ETS tables
  using streams and key-based lookups with ETS ordering.
  """

  @type tid :: :ets.tid()
  @type match_spec :: :ets.match_spec()
  @type match_pattern :: :ets.match_pattern()

  @doc """
  Creates a stream of matched objects from an ETS table in forward order.

  Uses `:ets.match/3` with continuation to lazily fetch matched objects
  in batches of the specified limit.

  ## Parameters

    * `tid` - The ETS table identifier
    * `match_pattern` - The match pattern (see `:ets.match/2`)
    * `limit` - Number of objects to fetch per batch (default: 1)

  ## Returns

  A `Stream.t()` that yields matched results in forward order.

  ## Examples

      iex> tid = :ets.new(:test, [:ordered_set, :public])
      iex> :ets.insert(tid, {:key1, "value1"})
      iex> :ets.insert(tid, {:key2, "value2"})
      iex> VDR.ETSRead.match_stream(tid, {:"$1", :"$2"}, 10) |> Enum.to_list()
      [[:key1, "value1"], [:key2, "value2"]]

  """
  @spec match_stream(tid(), match_pattern(), pos_integer()) :: Enumerable.t()
  def match_stream(tid, match_pattern, limit \\ 1) do
    Stream.resource(
      fn -> :ets.match(tid, match_pattern, limit) end,
      fn
        :"$end_of_table" ->
          {:halt, nil}

        {matches, continuation} ->
          {matches, :ets.match(continuation)}
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  Creates a stream of matched objects from an ETS table in reverse order.

  Uses `:ets.match/3` with continuation to lazily fetch matched objects
  in reverse order in batches of the specified limit.

  ## Parameters

    * `tid` - The ETS table identifier (must be an `:ordered_set`)
    * `match_pattern` - The match pattern (see `:ets.match/2`)
    * `limit` - Number of objects to fetch per batch (default: 1)

  ## Returns

  A `Stream.t()` that yields matched results in reverse order.

  ## Examples

      iex> tid = :ets.new(:test, [:ordered_set, :public])
      iex> :ets.insert(tid, {:key1, "value1"})
      iex> :ets.insert(tid, {:key2, "value2"})
      iex> VDR.ETSRead.match_rev_stream(tid, {:"$1", :"$2"}, 10) |> Enum.to_list()
      [[:key2, "value2"], [:key1, "value1"]]

  """
  @spec match_rev_stream(tid(), match_pattern(), pos_integer()) :: Enumerable.t()
  def match_rev_stream(tid, match_pattern, limit \\ 1) do
    # Build a match spec from the pattern for use with select_reverse
    # Convert match pattern {:"$1", :"$2"} to match spec [{{:"$1", :"$2"}, [], [:"$$"]}]
    match_spec = [{match_pattern, [], [[:"$$"]]}]

    Stream.resource(
      fn -> :ets.select_reverse(tid, match_spec, limit) end,
      fn
        :"$end_of_table" ->
          {:halt, nil}

        {results, continuation} ->
          # select_reverse returns full results, we need to flatten for match-like output
          matches = Enum.map(results, fn [result] -> result end)
          {matches, :ets.select_reverse(continuation)}
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  Creates a stream of selected objects from an ETS table in forward order.

  Uses `:ets.select/3` with continuation to lazily fetch selected objects
  in batches of the specified limit.

  ## Parameters

    * `tid` - The ETS table identifier
    * `match_spec` - The match specification (see `:ets.select/2`)
    * `limit` - Number of objects to fetch per batch

  ## Returns

  A `Stream.t()` that yields selected results in forward order.

  ## Examples

      iex> tid = :ets.new(:test, [:set, :public])
      iex> :ets.insert(tid, {:key1, "value1"})
      iex> :ets.insert(tid, {:key2, "value2"})
      iex> match_spec = [{{:"$1", :"$2"}, [], [:"$$"]}]
      iex> VDR.ETSRead.select_stream(tid, match_spec, 10) |> Enum.to_list()
      [[:key1, "value1"], [:key2, "value2"]]

  """
  @spec select_stream(tid(), match_spec(), pos_integer()) :: Enumerable.t()
  def select_stream(tid, match_spec, limit) do
    Stream.resource(
      fn -> :ets.select(tid, match_spec, limit) end,
      fn
        :"$end_of_table" ->
          {:halt, nil}

        {results, continuation} ->
          {results, :ets.select(continuation)}
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  Creates a stream of selected objects from an ETS table in reverse order.

  Uses `:ets.select_reverse/3` with continuation to lazily fetch selected objects
  in reverse order in batches of the specified limit.

  ## Parameters

    * `tid` - The ETS table identifier (must be an `:ordered_set`)
    * `match_spec` - The match specification (see `:ets.select/2`)
    * `limit` - Number of objects to fetch per batch

  ## Returns

  A `Stream.t()` that yields selected results in reverse order.

  ## Examples

      iex> tid = :ets.new(:test, [:ordered_set, :public])
      iex> :ets.insert(tid, {:key1, "value1"})
      iex> :ets.insert(tid, {:key2, "value2"})
      iex> match_spec = [{{:"$1", :"$2"}, [], [:"$$"]}]
      iex> VDR.ETSRead.select_rev_stream(tid, match_spec, 10) |> Enum.to_list()
      [[:key2, "value2"], [:key1, "value1"]]

  """
  @spec select_rev_stream(tid(), match_spec(), pos_integer()) :: Enumerable.t()
  def select_rev_stream(tid, match_spec, limit) do
    Stream.resource(
      fn -> :ets.select_reverse(tid, match_spec, limit) end,
      fn
        :"$end_of_table" ->
          {:halt, nil}

        {results, continuation} ->
          {results, :ets.select_reverse(continuation)}
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  Finds the last key in an ETS table matching the given match specification head.

  Efficiently finds the last key matching the pattern using `:ets.select_reverse/3`.

  The function takes just the match spec head (pattern part) and internally constructs
  the full match spec with empty conditions and `$_` as the result.

  ## Parameters

    * `tid` - The ETS table identifier (must be an `:ordered_set`)
    * `match_spec_head` - The pattern to match (head part of match spec)

  ## Returns

  The last matching key or `nil` if no match is found.

  ## Examples

      iex> tid = :ets.new(:test, [:ordered_set, :public])
      iex> :ets.insert(tid, {{:user, :profile, 1}, "value1"})
      iex> :ets.insert(tid, {{:user, :profile, 2}, "value2"})
      iex> :ets.insert(tid, {{:user, :other, 1}, "value3"})
      iex> VDR.ETSRead.last_key(tid, {{:user, :profile, :_}, :_})
      {:user, :profile, 2}

  """
  @spec last_key(tid(), tuple()) :: term() | nil
  def last_key(tid, match_spec_head) when is_tuple(match_spec_head) do
    # Build full match spec: [{head, [], [:"$_"]}]
    match_spec = [{match_spec_head, [], [:"$_"]}]

    # Use select_reverse to efficiently get the last matching object
    case :ets.select_reverse(tid, match_spec, 1) do
      {[object | _], _continuation} ->
        # Extract key from the object (first element)
        elem(object, 0)

      :"$end_of_table" ->
        nil
    end
  end

  @doc """
  Finds the first key in an ETS table matching the given match specification head.

  Efficiently finds the first key matching the pattern using `:ets.select/3`.

  The function takes just the match spec head (pattern part) and internally constructs
  the full match spec with empty conditions and `$_` as the result.

  ## Parameters

    * `tid` - The ETS table identifier (must be an `:ordered_set`)
    * `match_spec_head` - The pattern to match (head part of match spec)

  ## Returns

  The first matching key or `nil` if no match is found.

  ## Examples

      iex> tid = :ets.new(:test, [:ordered_set, :public])
      iex> :ets.insert(tid, {{:user, :profile, 1}, "value1"})
      iex> :ets.insert(tid, {{:user, :profile, 2}, "value2"})
      iex> :ets.insert(tid, {{:user, :other, 1}, "value3"})
      iex> VDR.ETSRead.first_key(tid, {{:user, :profile, :_}, :_})
      {:user, :profile, 1}

  """
  @spec first_key(tid(), tuple()) :: term() | nil
  def first_key(tid, match_spec_head) when is_tuple(match_spec_head) do
    # Build full match spec: [{head, [], [:"$_"]}]
    match_spec = [{match_spec_head, [], [:"$_"]}]

    # Use select with limit 1 to efficiently get the first matching object
    case :ets.select(tid, match_spec, 1) do
      {[object | _], _continuation} ->
        # Extract key from the object (first element)
        elem(object, 0)

      :"$end_of_table" ->
        nil
    end
  end

  @doc """
  Creates a stream of objects within a key range using forward traversal.

  Uses `:ets.next/2` to traverse from `key_first` to `key_last` (inclusive)
  in forward order.

  ## Parameters

    * `tid` - The ETS table identifier
    * `key_first` - The first key in the range
    * `key_last` - The last key in the range

  ## Returns

  A `Stream.t()` that yields objects in the key range.

  ## Examples

      iex> tid = :ets.new(:test, [:ordered_set, :public])
      iex> :ets.insert(tid, {:key1, "value1"})
      iex> :ets.insert(tid, {:key2, "value2"})
      iex> :ets.insert(tid, {:key3, "value3"})
      iex> VDR.ETSRead.key_range_stream(tid, :key1, :key2) |> Enum.to_list()
      [{:key1, "value1"}, {:key2, "value2"}]

  """
  @spec key_range_stream(tid(), term(), term()) :: Enumerable.t()
  def key_range_stream(tid, key_first, key_last) do
    Stream.resource(
      fn ->
        # Start from key_first or find the first key >= key_first
        find_next_valid_key(tid, key_first, key_last, :next)
      end,
      fn
        :done ->
          {:halt, :done}

        {object, current_key} ->
          if current_key == key_last do
            # Emit last object and halt
            {[object], :done}
          else
            # Emit current object and move to next key
            case :ets.next(tid, current_key) do
              :"$end_of_table" ->
                {[object], :done}

              next_key when next_key > key_last ->
                # Next key is beyond range
                {[object], :done}

              next_key ->
                # Continue searching for next valid key
                next_state = find_next_valid_key(tid, next_key, key_last, :next)
                {[object], next_state}
            end
          end
      end,
      fn _ -> :ok end
    )
  end

  # Helper function to find the next valid key with an object
  defp find_next_valid_key(tid, start_key, end_key, direction) do
    case :ets.lookup(tid, start_key) do
      [object] ->
        {object, start_key}
      [] ->
        # Key doesn't exist, try to find the next/prev key
        next_key = case direction do
          :next -> :ets.next(tid, start_key)
          :prev -> :ets.prev(tid, start_key)
        end

        case next_key do
          :"$end_of_table" ->
            :done
          key when direction == :next and key > end_key ->
            :done
          key when direction == :prev and key < end_key ->
            :done
          key ->
            # Recursively search for a valid key
            find_next_valid_key(tid, key, end_key, direction)
        end
    end
  end

  @doc """
  Creates a stream of objects within a key range using reverse traversal.

  Uses `:ets.prev/2` to traverse from `key_first` to `key_last` (inclusive)
  in reverse order.

  ## Parameters

    * `tid` - The ETS table identifier
    * `key_first` - The first key in the range (highest key)
    * `key_last` - The last key in the range (lowest key)

  ## Returns

  A `Stream.t()` that yields objects in reverse key order.

  ## Examples

      iex> tid = :ets.new(:test, [:ordered_set, :public])
      iex> :ets.insert(tid, {:key1, "value1"})
      iex> :ets.insert(tid, {:key2, "value2"})
      iex> :ets.insert(tid, {:key3, "value3"})
      iex> VDR.ETSRead.key_rev_range_stream(tid, :key3, :key2) |> Enum.to_list()
      [{:key3, "value3"}, {:key2, "value2"}]

  """
  @spec key_rev_range_stream(tid(), term(), term()) :: Enumerable.t()
  def key_rev_range_stream(tid, key_first, key_last) do
    Stream.resource(
      fn ->
        # Start from key_first (highest key) or find the first key <= key_first
        find_next_valid_key(tid, key_first, key_last, :prev)
      end,
      fn
        :done ->
          {:halt, :done}

        {object, current_key} ->
          if current_key == key_last do
            # Emit last object and halt
            {[object], :done}
          else
            # Emit current object and move to previous key
            case :ets.prev(tid, current_key) do
              :"$end_of_table" ->
                {[object], :done}

              prev_key when prev_key < key_last ->
                # Previous key is beyond range
                {[object], :done}

              prev_key ->
                # Continue searching for next valid key
                next_state = find_next_valid_key(tid, prev_key, key_last, :prev)
                {[object], next_state}
            end
          end
      end,
      fn _ -> :ok end
    )
  end
end
