defmodule Vdr.TS do
  @moduledoc """
  Term Storage (TS) - Thread-safe binary storage.

  Provides independent storage instances that hold binary key-value pairs.
  Storage is process-independent and thread-safe, allowing concurrent access
  from multiple processes.

  Both keys and values must be binaries. The storage uses a Rust-native
  structure for efficient memory management.

  ## Example

      storage = Vdr.TS.create()

      Vdr.TS.tx(storage, [{0, {:set, "user:1", "Alice"}}])
      Vdr.TS.tx(storage, [{0, {:set, "user:2", "Bob"}}])

      "Alice" = Vdr.TS.get(storage, 0, "user:1")
      nil = Vdr.TS.get(storage, 0, "missing")

      Vdr.TS.tx(storage, [{0, {:del, "user:1"}}])
      :ok = Vdr.TS.destroy(storage)

  ## Thread Safety

  Storage instances are thread-safe and can be safely shared across
  multiple processes. All operations are protected by internal locking.

  ## Memory Management

  Binary data is stored in Rust-native structures. When you destroy
  a storage instance or it is garbage collected, all stored data is
  automatically freed.
  """

  use Rustler,
    otp_app: :veidrodelis,
    crate: :vdr_ts_nif,
    mode: if(Mix.env() == :prod, do: :release, else: :debug)

  @doc """
  Creates a new storage instance.

  Each call creates an independent storage with its own data.

  Returns an opaque reference to the storage that can be used with
  other functions.

  ## Examples

      storage = Vdr.TS.create()
      is_reference(storage)
      #=> true

      # Create multiple independent storages
      storage1 = Vdr.TS.create()
      storage2 = Vdr.TS.create()
      Vdr.TS.tx(storage1, [{0, {:set, "key", "value1"}}])
      Vdr.TS.tx(storage2, [{0, {:set, "key", "value2"}}])
      Vdr.TS.get(storage1, 0, "key")
      #=> "value1"
      Vdr.TS.get(storage2, 0, "key")
      #=> "value2"
  """
  @spec create() :: reference()
  def create(), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Retrieves a binary value by key from a specific database.

  Returns the stored binary, or `nil` if the key doesn't exist.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.tx(storage, [{0, {:set, "key", "value"}}])

      Vdr.TS.get(storage, 0, "key")
      #=> "value"

      Vdr.TS.get(storage, 0, "missing")
      #=> nil

      # Different databases are isolated
      Vdr.TS.tx(storage, [{0, {:set, "key", "value0"}}])
      Vdr.TS.tx(storage, [{1, {:set, "key", "value1"}}])
      Vdr.TS.get(storage, 0, "key")
      #=> "value0"
      Vdr.TS.get(storage, 1, "key")
      #=> "value1"

      # Binary data is preserved exactly
      data = <<0, 1, 2, 255, 254, 253>>
      Vdr.TS.tx(storage, [{0, {:set, "binary", data}}])
      Vdr.TS.get(storage, 0, "binary")
      #=> <<0, 1, 2, 255, 254, 253>>
  """
  @spec get(reference(), non_neg_integer(), binary()) :: binary() | nil
  def get(storage, db, key) do
    [result] = tx(storage, [{db, {:get, key}}])
    case result do
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end

  @doc """
  Destroys a storage instance, clearing all data.

  This clears the key-value map, freeing all stored binary data.

  After calling `destroy/1`, the storage can still be used (it will
  be empty), but it's generally better to create a new storage if
  you need one.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.tx(storage, [{0, {:set, "key1", "value1"}}])
      Vdr.TS.tx(storage, [{0, {:set, "key2", "value2"}}])

      :ok = Vdr.TS.destroy(storage)

      Vdr.TS.get(storage, 0, "key1")
      #=> nil
      Vdr.TS.get(storage, 0, "key2")
      #=> nil
  """
  @spec destroy(reference()) :: :ok
  def destroy(_storage), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Executes multiple commands atomically under a single mutex lock.

  This function takes a list of command tuples and executes them all while
  holding the storage mutex, making the entire batch atomic.

  Each command tuple has the format: `{db, {command_atom, ...args}}`

  Returns a list of results, one for each command.

  ## Supported Commands

  - `{db, {:set, key, value}}` - Set a string value
  - `{db, {:del, key}}` - Delete a key
  - `{db, {:sadd, key, members}}` - Add members to a set
  - `{db, {:srem, key, members}}` - Remove members from a set
  - `{db, {:smove, source_key, dest_key, member}}` - Move member between sets
  - `{db, {:sunionstore, dest_key, source_keys}}` - Store union of sets
  - `{db, {:sinterstore, dest_key, source_keys}}` - Store intersection of sets
  - `{db, {:sdiffstore, dest_key, source_keys}}` - Store difference of sets
  - `{db, {:lpush, key, values}}` - Push values to list head
  - `{db, {:rpush, key, values}}` - Push values to list tail
  - `{db, {:lpop, key}}` - Pop value from list head
  - `{db, {:rpop, key}}` - Pop value from list tail
  - `{db, {:lset, key, index, value}}` - Set list element at index
  - `{db, {:rpoplpush, source_key, dest_key}}` - Pop from source and push to dest
  - `{db, {:hset, key, field, value}}` - Set hash field
  - `{db, {:hmset, key, fields}}` - Set multiple hash fields
  - `{db, {:hdel, key, fields}}` - Delete hash fields
  - `{db, {:zadd, key, members}}` - Add members to sorted set (members is `[{score, member}, ...]`)
  - `{db, {:zrem, key, members}}` - Remove members from sorted set

  ## Examples

      storage = Vdr.TS.create()

      # Execute multiple commands atomically
      results = Vdr.TS.tx(storage, [
        {0, {:sadd, "set1", ["a", "b"]}},
        {0, {:sadd, "set2", ["c", "d"]}},
        {0, {:set, "key1", "value1"}}
      ])
      #=> [:ok, :ok, :ok]

      # Mix different command types
      results = Vdr.TS.tx(storage, [
        {0, {:zadd, "myzset", [{1.0, "one"}, {2.0, "two"}]}},
        {0, {:hset, "myhash", "field1", "value1"}},
        {0, {:del, "oldkey"}}
      ])
      #=> [{:ok, 2}, :ok, :ok]
  """
  @spec tx(reference(), [tuple()]) :: [term()]
  def tx(_storage, _commands), do: :erlang.nif_error(:nif_not_loaded)

  # Set operations (read-only)

  @doc """
  Returns all members of the set stored at key.

  Returns `{:ok, members}` where members is a list of binaries. If key doesn't exist,
  returns `{:ok, []}`. Returns `{:error, :wrong_type}` if the key exists and
  holds a non-set value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.sadd(storage, 0, "myset", ["a", "b", "c"])
      {:ok, members} = Vdr.TS.smembers(storage, 0, "myset")
      # members is ["a", "b", "c"] (order may vary)
      {:ok, []} = Vdr.TS.smembers(storage, 0, "nonexistent")
  """
  @spec smembers(reference(), non_neg_integer(), binary()) ::
          {:ok, [binary()]} | {:error, :wrong_type}
  def smembers(storage, db, key) do
    [result] = tx(storage, [{db, {:smembers, key}}])
    result
  end

  @doc """
  Checks if a member exists in the set stored at key.

  Returns `{:ok, true}` if the member exists, `{:ok, false}` otherwise.
  Returns `{:error, :wrong_type}` if the key exists and holds a non-set value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.sadd(storage, 0, "myset", ["a", "b", "c"])
      {:ok, true} = Vdr.TS.sismember(storage, 0, "myset", "b")
      {:ok, false} = Vdr.TS.sismember(storage, 0, "myset", "z")
  """
  @spec sismember(reference(), non_neg_integer(), binary(), binary()) ::
          {:ok, boolean()} | {:error, :wrong_type}
  def sismember(storage, db, key, member) do
    [result] = tx(storage, [{db, {:sismember, key, member}}])
    result
  end

  @doc """
  Returns the cardinality (number of members) of the set stored at key.

  Returns `{:ok, count}` where count is a non-negative integer. If key doesn't exist,
  returns `{:ok, 0}`. Returns `{:error, :wrong_type}` if the key exists and holds
  a non-set value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.sadd(storage, 0, "myset", ["a", "b", "c"])
      {:ok, 3} = Vdr.TS.scard(storage, 0, "myset")
      {:ok, 0} = Vdr.TS.scard(storage, 0, "nonexistent")
  """
  @spec scard(reference(), non_neg_integer(), binary()) ::
          {:ok, non_neg_integer()} | {:error, :wrong_type}
  def scard(storage, db, key) do
    [result] = tx(storage, [{db, {:scard, key}}])
    result
  end

  # List operations (read-only)

  @doc """
  Returns the length of the list stored at key.

  Returns `{:ok, count}` where count is a non-negative integer. If key doesn't exist,
  returns `{:ok, 0}`. Returns `{:error, :wrong_type}` if the key exists and holds
  a non-list value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.rpush(storage, 0, "mylist", ["a", "b", "c"])
      {:ok, 3} = Vdr.TS.llen(storage, 0, "mylist")
      {:ok, 0} = Vdr.TS.llen(storage, 0, "nonexistent")
  """
  @spec llen(reference(), non_neg_integer(), binary()) ::
          {:ok, non_neg_integer()} | {:error, :wrong_type}
  def llen(storage, db, key) do
    [result] = tx(storage, [{db, {:llen, key}}])
    result
  end

  @doc """
  Returns a range of elements from the list stored at key.

  Both start and stop are inclusive and support negative indices (counting from the end).
  Returns `{:ok, elements}` where elements is a list of binaries. If key doesn't exist,
  returns `{:ok, []}`. Returns `{:error, :wrong_type}` if the key exists and holds
  a non-list value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.rpush(storage, 0, "mylist", ["a", "b", "c", "d"])
      {:ok, ["a", "b", "c"]} = Vdr.TS.lrange(storage, 0, "mylist", 0, 2)
      {:ok, ["c", "d"]} = Vdr.TS.lrange(storage, 0, "mylist", -2, -1)
      {:ok, []} = Vdr.TS.lrange(storage, 0, "nonexistent", 0, -1)
  """
  @spec lrange(reference(), non_neg_integer(), binary(), integer(), integer()) ::
          {:ok, [binary()]} | {:error, :wrong_type}
  def lrange(storage, db, key, start, stop) do
    [result] = tx(storage, [{db, {:lrange, key, start, stop}}])
    result
  end

  # Hash operations (read-only)

  @doc """
  Gets the value of a field in the hash stored at key.

  Returns `{:ok, value}` if field exists, `{:ok, nil}` if field or key doesn't exist.
  Returns `{:error, :wrong_type}` if the key exists and holds a non-hash value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.hset(storage, 0, "myhash", "field1", "value1")
      {:ok, "value1"} = Vdr.TS.hget(storage, 0, "myhash", "field1")
      {:ok, nil} = Vdr.TS.hget(storage, 0, "myhash", "nonexistent")
  """
  @spec hget(reference(), non_neg_integer(), binary(), binary()) ::
          {:ok, binary() | nil} | {:error, :wrong_type}
  def hget(storage, db, key, field) do
    [result] = tx(storage, [{db, {:hget, key, field}}])
    result
  end

  @doc """
  Gets the values of multiple fields in the hash stored at key.

  Returns `{:ok, values}` where values is a list of binaries or nils.
  Returns `{:error, :wrong_type}` if the key exists and holds a non-hash value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.hmset(storage, 0, "myhash", [{"f1", "v1"}, {"f2", "v2"}])
      {:ok, ["v1", "v2", nil]} = Vdr.TS.hmget(storage, 0, "myhash", ["f1", "f2", "f3"])
  """
  @spec hmget(reference(), non_neg_integer(), binary(), [binary()]) ::
          {:ok, [binary() | nil]} | {:error, :wrong_type}
  def hmget(storage, db, key, fields) do
    [result] = tx(storage, [{db, {:hmget, key, fields}}])
    result
  end

  @doc """
  Gets all field-value pairs in the hash stored at key.

  Returns `{:ok, pairs}` where pairs is a list of {field, value} tuples.
  Returns `{:error, :wrong_type}` if the key exists and holds a non-hash value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.hmset(storage, 0, "myhash", [{"field1", "value1"}, {"field2", "value2"}])
      {:ok, pairs} = Vdr.TS.hgetall(storage, 0, "myhash")
      # pairs contains [{"field1", "value1"}, {"field2", "value2"}]
  """
  @spec hgetall(reference(), non_neg_integer(), binary()) ::
          {:ok, [{binary(), binary()}]} | {:error, :wrong_type}
  def hgetall(storage, db, key) do
    [result] = tx(storage, [{db, {:hgetall, key}}])
    result
  end

  @doc """
  Gets all field names in the hash stored at key.

  Returns `{:ok, fields}` where fields is a list of binaries.
  Returns `{:error, :wrong_type}` if the key exists and holds a non-hash value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.hmset(storage, 0, "myhash", [{"field1", "value1"}, {"field2", "value2"}])
      {:ok, ["field1", "field2"]} = Vdr.TS.hkeys(storage, 0, "myhash")
  """
  @spec hkeys(reference(), non_neg_integer(), binary()) ::
          {:ok, [binary()]} | {:error, :wrong_type}
  def hkeys(storage, db, key) do
    [result] = tx(storage, [{db, {:hkeys, key}}])
    result
  end

  @doc """
  Gets all values in the hash stored at key.

  Returns `{:ok, values}` where values is a list of binaries.
  Returns `{:error, :wrong_type}` if the key exists and holds a non-hash value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.hmset(storage, 0, "myhash", [{"field1", "value1"}, {"field2", "value2"}])
      {:ok, values} = Vdr.TS.hvals(storage, 0, "myhash")
      # values contains ["value1", "value2"]
  """
  @spec hvals(reference(), non_neg_integer(), binary()) ::
          {:ok, [binary()]} | {:error, :wrong_type}
  def hvals(storage, db, key) do
    [result] = tx(storage, [{db, {:hvals, key}}])
    result
  end

  @doc """
  Gets the number of fields in the hash stored at key.

  Returns `{:ok, count}` where count is a non-negative integer.
  Returns `{:error, :wrong_type}` if the key exists and holds a non-hash value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.hmset(storage, 0, "myhash", [{"field1", "value1"}, {"field2", "value2"}])
      {:ok, 2} = Vdr.TS.hlen(storage, 0, "myhash")
      {:ok, 0} = Vdr.TS.hlen(storage, 0, "nonexistent")
  """
  @spec hlen(reference(), non_neg_integer(), binary()) ::
          {:ok, non_neg_integer()} | {:error, :wrong_type}
  def hlen(storage, db, key) do
    [result] = tx(storage, [{db, {:hlen, key}}])
    result
  end

  @doc """
  Checks if field exists in the hash stored at key.

  Returns `{:ok, true}` if field exists, `{:ok, false}` otherwise.
  Returns `{:error, :wrong_type}` if the key exists and holds a non-hash value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.hset(storage, 0, "myhash", "field1", "value1")
      {:ok, true} = Vdr.TS.hexists(storage, 0, "myhash", "field1")
      {:ok, false} = Vdr.TS.hexists(storage, 0, "myhash", "nonexistent")
  """
  @spec hexists(reference(), non_neg_integer(), binary(), binary()) ::
          {:ok, boolean()} | {:error, :wrong_type}
  def hexists(storage, db, key, field) do
    [result] = tx(storage, [{db, {:hexists, key, field}}])
    result
  end

  # Sorted set (zset) operations (read-only)

  @doc """
  Gets the score of a member in the sorted set stored at key.

  Returns `{:ok, score}` if member exists, `{:ok, nil}` if member or key doesn't exist.
  Returns `{:error, :wrong_type}` if the key exists and holds a non-zset value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.zadd(storage, 0, "myzset", [{1.5, "member"}])
      {:ok, 1.5} = Vdr.TS.zscore(storage, 0, "myzset", "member")
      {:ok, nil} = Vdr.TS.zscore(storage, 0, "myzset", "nonexistent")
  """
  @spec zscore(reference(), non_neg_integer(), binary(), binary()) ::
          {:ok, float() | nil} | {:error, :wrong_type}
  def zscore(storage, db, key, member) do
    [result] = tx(storage, [{db, {:zscore, key, member}}])
    result
  end

  @doc """
  Gets the cardinality (number of members) of the sorted set stored at key.

  Returns `{:ok, count}` where count is a non-negative integer.
  Returns `{:error, :wrong_type}` if the key exists and holds a non-zset value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.zadd(storage, 0, "myzset", [{1.0, "one"}, {2.0, "two"}])
      {:ok, 2} = Vdr.TS.zcard(storage, 0, "myzset")
      {:ok, 0} = Vdr.TS.zcard(storage, 0, "nonexistent")
  """
  @spec zcard(reference(), non_neg_integer(), binary()) ::
          {:ok, non_neg_integer()} | {:error, :wrong_type}
  def zcard(storage, db, key) do
    [result] = tx(storage, [{db, {:zcard, key}}])
    result
  end

  @doc """
  Gets a range of members from the sorted set by rank (index).

  Both start and stop are inclusive and support negative indices.
  If with_scores is true, returns flat list: [member1, score1, member2, score2, ...].
  If with_scores is false, returns list of members: [member1, member2, ...].

  Returns `{:ok, elements}` where elements is a list.
  Returns `{:error, :wrong_type}` if the key exists and holds a non-zset value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.zadd(storage, 0, "myzset", [{1.0, "one"}, {2.0, "two"}, {3.0, "three"}])
      {:ok, ["one", "two"]} = Vdr.TS.zrange(storage, 0, "myzset", 0, 1, false)
      {:ok, ["one", 1.0, "two", 2.0]} = Vdr.TS.zrange(storage, 0, "myzset", 0, 1, true)
  """
  @spec zrange(reference(), non_neg_integer(), binary(), integer(), integer(), boolean()) ::
          {:ok, [binary() | float()]} | {:error, :wrong_type}
  def zrange(storage, db, key, start, stop, with_scores) do
    [result] = tx(storage, [{db, {:zrange, key, start, stop, with_scores}}])
    case result do
      {:ok, tuples} when with_scores ->
        # Convert list of tuples to flat list: [{m1, s1}, {m2, s2}] -> [m1, s1, m2, s2]
        flat_list = Enum.flat_map(tuples, fn
          {member, score} -> [member, score]
          member -> [member]
        end)
        {:ok, flat_list}
      other -> other
    end
  end

  @doc """
  Gets members from the sorted set with scores between min and max (inclusive).

  If with_scores is true, returns flat list: [member1, score1, member2, score2, ...].
  If with_scores is false, returns list of members: [member1, member2, ...].

  Returns `{:ok, elements}` where elements is a list.
  Returns `{:error, :wrong_type}` if the key exists and holds a non-zset value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.zadd(storage, 0, "myzset", [{1.0, "one"}, {2.0, "two"}, {3.0, "three"}])
      {:ok, ["one", "two"]} = Vdr.TS.zrangebyscore(storage, 0, "myzset", 1.0, 2.0, false)
      {:ok, ["one", 1.0, "two", 2.0]} = Vdr.TS.zrangebyscore(storage, 0, "myzset", 1.0, 2.0, true)
  """
  @spec zrangebyscore(reference(), non_neg_integer(), binary(), float(), float(), boolean()) ::
          {:ok, [binary() | float()]} | {:error, :wrong_type}
  def zrangebyscore(storage, db, key, min, max, with_scores) do
    [result] = tx(storage, [{db, {:zrangebyscore, key, min, max, with_scores}}])
    case result do
      {:ok, tuples} when with_scores ->
        # Convert list of tuples to flat list: [{m1, s1}, {m2, s2}] -> [m1, s1, m2, s2]
        flat_list = Enum.flat_map(tuples, fn
          {member, score} -> [member, score]
          member -> [member]
        end)
        {:ok, flat_list}
      other -> other
    end
  end

  @doc """
  Gets the rank (0-based index) of a member in the sorted set (ascending order).

  Returns `{:ok, rank}` if member exists, `{:ok, nil}` if member or key doesn't exist.
  Returns `{:error, :wrong_type}` if the key exists and holds a non-zset value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.zadd(storage, 0, "myzset", [{1.0, "one"}, {2.0, "two"}, {3.0, "three"}])
      {:ok, 0} = Vdr.TS.zrank(storage, 0, "myzset", "one")
      {:ok, 2} = Vdr.TS.zrank(storage, 0, "myzset", "three")
  """
  @spec zrank(reference(), non_neg_integer(), binary(), binary()) ::
          {:ok, non_neg_integer() | nil} | {:error, :wrong_type}
  def zrank(storage, db, key, member) do
    [result] = tx(storage, [{db, {:zrank, key, member}}])
    result
  end

  @doc """
  Gets the reverse rank of a member in the sorted set (descending order).

  Returns `{:ok, rank}` if member exists, `{:ok, nil}` if member or key doesn't exist.
  Returns `{:error, :wrong_type}` if the key exists and holds a non-zset value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.zadd(storage, 0, "myzset", [{1.0, "one"}, {2.0, "two"}, {3.0, "three"}])
      {:ok, 2} = Vdr.TS.zrevrank(storage, 0, "myzset", "one")
      {:ok, 0} = Vdr.TS.zrevrank(storage, 0, "myzset", "three")
  """
  @spec zrevrank(reference(), non_neg_integer(), binary(), binary()) ::
          {:ok, non_neg_integer() | nil} | {:error, :wrong_type}
  def zrevrank(storage, db, key, member) do
    [result] = tx(storage, [{db, {:zrevrank, key, member}}])
    result
  end

  @doc """
  Counts members in the sorted set with scores between min and max (inclusive).

  Returns `{:ok, count}` where count is a non-negative integer.
  Returns `{:error, :wrong_type}` if the key exists and holds a non-zset value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.zadd(storage, 0, "myzset", [{1.0, "one"}, {2.0, "two"}, {3.0, "three"}])
      {:ok, 2} = Vdr.TS.zcount(storage, 0, "myzset", 1.0, 2.0)
  """
  @spec zcount(reference(), non_neg_integer(), binary(), float(), float()) ::
          {:ok, non_neg_integer()} | {:error, :wrong_type}
  def zcount(storage, db, key, min, max) do
    [result] = tx(storage, [{db, {:zcount, key, min, max}}])
    result
  end

  @doc """
  Gets the first (minimum score) member from the sorted set.

  Returns `{:ok, {score, member}}` if the set is not empty, `{:ok, nil}` if the set
  is empty or doesn't exist. Returns `{:error, :wrong_type}` if the key exists and
  holds a non-zset value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.zadd(storage, 0, "myzset", [{1.0, "one"}, {2.0, "two"}, {3.0, "three"}])
      {:ok, {1.0, "one"}} = Vdr.TS.zfirst(storage, 0, "myzset")
      {:ok, nil} = Vdr.TS.zfirst(storage, 0, "nonexistent")
  """
  @spec zfirst(reference(), non_neg_integer(), binary()) ::
          {:ok, {float(), binary()} | nil} | {:error, :wrong_type}
  def zfirst(storage, db, key) do
    [result] = tx(storage, [{db, {:zfirst, key}}])
    result
  end

  @doc """
  Gets the last (maximum score) member from the sorted set.

  Returns `{:ok, {score, member}}` if the set is not empty, `{:ok, nil}` if the set
  is empty or doesn't exist. Returns `{:error, :wrong_type}` if the key exists and
  holds a non-zset value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.zadd(storage, 0, "myzset", [{1.0, "one"}, {2.0, "two"}, {3.0, "three"}])
      {:ok, {3.0, "three"}} = Vdr.TS.zlast(storage, 0, "myzset")
      {:ok, nil} = Vdr.TS.zlast(storage, 0, "nonexistent")
  """
  @spec zlast(reference(), non_neg_integer(), binary()) ::
          {:ok, {float(), binary()} | nil} | {:error, :wrong_type}
  def zlast(storage, db, key) do
    [result] = tx(storage, [{db, {:zlast, key}}])
    result
  end

  @doc """
  Gets the next member after the given (score, member) in the sorted set.

  Returns `{:ok, {score, member}}` if there is a next member, `{:ok, nil}` if there
  is no next member or the set doesn't exist. Returns `{:error, :wrong_type}` if the
  key exists and holds a non-zset value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.zadd(storage, 0, "myzset", [{1.0, "one"}, {2.0, "two"}, {3.0, "three"}])
      {:ok, {2.0, "two"}} = Vdr.TS.znext(storage, 0, "myzset", 1.0, "one")
      {:ok, nil} = Vdr.TS.znext(storage, 0, "myzset", 3.0, "three")
  """
  @spec znext(reference(), non_neg_integer(), binary(), float(), binary()) ::
          {:ok, {float(), binary()} | nil} | {:error, :wrong_type}
  def znext(storage, db, key, score, member) do
    [result] = tx(storage, [{db, {:znext, key, score, member}}])
    result
  end

  @doc """
  Gets the previous member before the given (score, member) in the sorted set.

  Returns `{:ok, {score, member}}` if there is a previous member, `{:ok, nil}` if there
  is no previous member or the set doesn't exist. Returns `{:error, :wrong_type}` if the
  key exists and holds a non-zset value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.zadd(storage, 0, "myzset", [{1.0, "one"}, {2.0, "two"}, {3.0, "three"}])
      {:ok, {2.0, "two"}} = Vdr.TS.zprev(storage, 0, "myzset", 3.0, "three")
      {:ok, nil} = Vdr.TS.zprev(storage, 0, "myzset", 1.0, "one")
  """
  @spec zprev(reference(), non_neg_integer(), binary(), float(), binary()) ::
          {:ok, {float(), binary()} | nil} | {:error, :wrong_type}
  def zprev(storage, db, key, score, member) do
    [result] = tx(storage, [{db, {:zprev, key, score, member}}])
    result
  end

  @doc """
  Compiles a Lua script to bytecode.

  Pre-compiling scripts can improve performance when executing the same script
  multiple times, as the compilation step is done only once.

  Returns `{:ok, bytecode}` where bytecode is a binary that can be passed to `read_tx/3`,
  or `{:error, reason}` if compilation fails.

  ## Examples

      storage = Vdr.TS.create()
      script = "return ts.get('mykey')"
      {:ok, bytecode} = Vdr.TS.lua_load(storage, script)

      # Use the bytecode multiple times
      {:ok, result1} = Vdr.TS.read_tx(storage, 0, bytecode)
      {:ok, result2} = Vdr.TS.read_tx(storage, 1, bytecode)
  """
  @spec lua_load(reference(), binary()) :: {:ok, binary()} | {:error, term()}
  def lua_load(_storage, _script), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Executes a Lua script or bytecode with access to ts.get and ts.hget functions.

  The script is executed atomically under the storage mutex and has access to:
  - `ts.get(key)` - Get a string value
  - `ts.hget(key, field)` - Get a hash field value
  - And all other read-only TS functions

  Accepts either a raw Lua script (binary) or pre-compiled bytecode from `lua_load/2`.

  Returns `{:ok, result}` where result is the script's return value with proper types:
  - Numbers return as integers or floats
  - Booleans return as true/false
  - Strings return as binaries
  - nil returns as nil atom
  - Lua tables (arrays) return as Elixir lists
  - Lua tables (maps) return as Elixir maps
  - Nested tables are recursively converted

  Returns `{:error, reason}` if the script fails.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.tx(storage, [{0, {:set, "key1", "value1"}}])
      Vdr.TS.tx(storage, [{0, {:hset, "hash1", "field1", "value2"}}])

      # String result
      script = "return ts.get('key1')"
      {:ok, "value1"} = Vdr.TS.read_tx(storage, 0, script)

      # Number result
      script = "return 42"
      {:ok, 42} = Vdr.TS.read_tx(storage, 0, script)

      # Boolean result
      script = "return true"
      {:ok, true} = Vdr.TS.read_tx(storage, 0, script)

      # List result
      script = "return {1, 2, 3}"
      {:ok, [1, 2, 3]} = Vdr.TS.read_tx(storage, 0, script)

      # Map result
      script = "return {a = 1, b = 2}"
      {:ok, %{"a" => 1, "b" => 2}} = Vdr.TS.read_tx(storage, 0, script)

      # Pre-compile for better performance
      {:ok, bytecode} = Vdr.TS.lua_load(storage, script)
      {:ok, result} = Vdr.TS.read_tx(storage, 0, bytecode)

  ## Read-Only Command Transactions

  Alternatively, `read_tx/3` can execute a read-only transaction: a list of commands atomically
  under a single mutex lock.

  This is a simpler alternative to Lua-based transactions for cases where you just need
  to read multiple values atomically without complex logic.

  The command tuples do NOT include the db parameter (db is passed separately).
  Each command tuple has the format: `{:command_atom, ...args}`

  Only read-only commands are allowed. Attempting to execute a mutating command will
  return `{:error, :readonly_violation}`.

  Returns `{:ok, [results]}` where results is a list of values returned by each command,
  or `{:error, reason}` if validation fails.

  ## Supported Read-Only Commands

  **String operations:**
  - `{:get, key}` - Get a string value

  **Set operations:**
  - `{:smembers, key}`, `{:sismember, key, member}`, `{:scard, key}`

  **List operations:**
  - `{:llen, key}`, `{:lrange, key, start, stop}`

  **Hash operations:**
  - `{:hget, key, field}`, `{:hmget, key, fields}`, `{:hgetall, key}`
  - `{:hkeys, key}`, `{:hvals, key}`, `{:hlen, key}`, `{:hexists, key, field}`

  **Sorted set operations:**
  - `{:zscore, key, member}`, `{:zcard, key}`, `{:zrank, key, member}`, `{:zrevrank, key, member}`
  - `{:zcount, key, min, max}`, `{:zrange, key, start, stop, with_scores}`
  - `{:zrangebyscore, key, min, max, with_scores}`, `{:zfirst, key}`, `{:zlast, key}`
  - `{:znext, key, score, member}`, `{:zprev, key, score, member}`

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.tx(storage, [{0, {:set, "key1", "value1"}}])
      Vdr.TS.tx(storage, [{0, {:hset, "hash1", "field1", "value2"}}])

      # Read multiple values atomically
      {:ok, ["value1", "value2"]} = Vdr.TS.read_tx(storage, 0, [
        {:get, "key1"},
        {:hget, "hash1", "field1"}
      ])

      # Readonly violation
      {:error, :readonly_violation} = Vdr.TS.read_tx(storage, 0, [
        {:set, "key2", "value2"}  # Not allowed!
      ])
  """
  @spec read_tx(reference(), non_neg_integer(), [tuple()]) :: {:ok, [term()]} | {:error, term()}
  def read_tx(storage, db, commands) when is_list(commands) do
    case validate_readonly_commands(commands) do
      :ok ->
        full_commands = Enum.map(commands, fn cmd -> {db, cmd} end)
        results = tx(storage, full_commands)
        {:ok, unwrap_results(results)}

      {:error, _} = error ->
        error
    end
  end

  @spec read_tx(reference(), non_neg_integer(), binary()) :: {:ok, term()} | {:error, term()}
  def read_tx(_storage, _db, _script_or_bytecode), do: :erlang.nif_error(:nif_not_loaded)

  # Whitelist of read-only commands
  @readonly_commands MapSet.new([
    :get, :smembers, :sismember, :scard,
    :llen, :lrange,
    :hget, :hmget, :hgetall, :hkeys, :hvals, :hlen, :hexists,
    :zscore, :zcard, :zrank, :zrevrank, :zcount, :zrange, :zrangebyscore,
    :zfirst, :zlast, :znext, :zprev
  ])

  defp validate_readonly_commands(commands) do
    Enum.reduce_while(commands, :ok, fn cmd, :ok ->
      if is_tuple(cmd) and tuple_size(cmd) > 0 do
        command_name = elem(cmd, 0)
        if is_atom(command_name) and MapSet.member?(@readonly_commands, command_name) do
          {:cont, :ok}
        else
          {:halt, {:error, :readonly_violation}}
        end
      else
        {:halt, {:error, :invalid_command}}
      end
    end)
  end

  # Unwrap {:ok, value} results, keeping raw values as-is
  defp unwrap_results(results) do
    Enum.map(results, fn
      {:ok, value} -> value
      other -> other
    end)
  end
end