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

      :ok = Vdr.TS.set(storage, "user:1", "Alice")
      :ok = Vdr.TS.set(storage, "user:2", "Bob")

      "Alice" = Vdr.TS.get(storage, "user:1")
      nil = Vdr.TS.get(storage, "missing")

      :ok = Vdr.TS.del(storage, "user:1")
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
      Vdr.TS.set(storage1, "key", "value1")
      Vdr.TS.set(storage2, "key", "value2")
      Vdr.TS.get(storage1, "key")
      #=> "value1"
      Vdr.TS.get(storage2, "key")
      #=> "value2"
  """
  @spec create() :: reference()
  def create(), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Stores a binary value with the given binary key in a specific database.

  Both keys and values must be binaries. If the key already exists,
  its value is overwritten.

  ## Examples

      storage = Vdr.TS.create()

      # Store binary values in database 0
      :ok = Vdr.TS.set(storage, 0, "key", "value")
      :ok = Vdr.TS.set(storage, 0, "data", <<1, 2, 3, 4>>)

      # Store in different database
      :ok = Vdr.TS.set(storage, 1, "key", "other_value")

      # Overwrite existing key
      :ok = Vdr.TS.set(storage, 0, "key", "new_value")
  """
  @spec set(reference(), non_neg_integer(), binary(), binary()) :: :ok
  def set(_storage, _db, _key, _value), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Retrieves a binary value by key from a specific database.

  Returns the stored binary, or `nil` if the key doesn't exist.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.set(storage, 0, "key", "value")

      Vdr.TS.get(storage, 0, "key")
      #=> "value"

      Vdr.TS.get(storage, 0, "missing")
      #=> nil

      # Different databases are isolated
      Vdr.TS.set(storage, 0, "key", "value0")
      Vdr.TS.set(storage, 1, "key", "value1")
      Vdr.TS.get(storage, 0, "key")
      #=> "value0"
      Vdr.TS.get(storage, 1, "key")
      #=> "value1"

      # Binary data is preserved exactly
      data = <<0, 1, 2, 255, 254, 253>>
      Vdr.TS.set(storage, 0, "binary", data)
      Vdr.TS.get(storage, 0, "binary")
      #=> <<0, 1, 2, 255, 254, 253>>
  """
  @spec get(reference(), non_neg_integer(), binary()) :: binary() | nil
  def get(_storage, _db, _key), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Deletes a key from a specific database.

  Always returns `:ok`, even if the key doesn't exist. This makes
  deletion idempotent.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.set(storage, 0, "key", "value")

      :ok = Vdr.TS.del(storage, 0, "key")
      Vdr.TS.get(storage, 0, "key")
      #=> nil

      # Deleting non-existent key still returns :ok
      :ok = Vdr.TS.del(storage, 0, "missing")

      # Deleting from one database doesn't affect others
      Vdr.TS.set(storage, 0, "key", "value0")
      Vdr.TS.set(storage, 1, "key", "value1")
      :ok = Vdr.TS.del(storage, 0, "key")
      Vdr.TS.get(storage, 1, "key")
      #=> "value1"
  """
  @spec del(reference(), non_neg_integer(), binary()) :: :ok
  def del(_storage, _db, _key), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Destroys a storage instance, clearing all data.

  This clears the key-value map, freeing all stored binary data.

  After calling `destroy/1`, the storage can still be used (it will
  be empty), but it's generally better to create a new storage if
  you need one.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.set(storage, "key1", "value1")
      Vdr.TS.set(storage, "key2", "value2")

      :ok = Vdr.TS.destroy(storage)

      Vdr.TS.get(storage, "key1")
      #=> nil
      Vdr.TS.get(storage, "key2")
      #=> nil
  """
  @spec destroy(reference()) :: :ok
  def destroy(_storage), do: :erlang.nif_error(:nif_not_loaded)

  # Set operations

  @doc """
  Adds one or more members to the set stored at key.

  Returns `:ok` on success. Returns `{:error, :wrong_type}` if the key
  exists and holds a non-set value.

  ## Examples

      storage = Vdr.TS.create()
      :ok = Vdr.TS.sadd(storage, 0, "myset", ["a", "b", "c"])
      :ok = Vdr.TS.sadd(storage, 0, "myset", ["b", "d"])  # "b" already exists

      # Type checking
      Vdr.TS.set(storage, 0, "mystring", "value")
      {:error, :wrong_type} = Vdr.TS.sadd(storage, 0, "mystring", ["a"])
  """
  @spec sadd(reference(), non_neg_integer(), binary(), [binary()]) ::
          :ok | {:error, :wrong_type}
  def sadd(_storage, _db, _key, _members), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Removes one or more members from the set stored at key.

  Returns `:ok` on success, even if members don't exist in the set.
  Returns `{:error, :wrong_type}` if the key exists and holds a non-set value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.sadd(storage, 0, "myset", ["a", "b", "c"])
      :ok = Vdr.TS.srem(storage, 0, "myset", ["a", "b"])
      :ok = Vdr.TS.srem(storage, 0, "myset", ["x", "y"])  # non-existent members
  """
  @spec srem(reference(), non_neg_integer(), binary(), [binary()]) ::
          :ok | {:error, :wrong_type}
  def srem(_storage, _db, _key, _members), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Moves a member from the source set to the destination set.

  Returns `:ok` on success, even if the member doesn't exist in the source set.
  Returns `{:error, :wrong_type}` if either key exists and holds a non-set value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.sadd(storage, 0, "set1", ["a", "b", "c"])
      Vdr.TS.sadd(storage, 0, "set2", ["x", "y"])
      :ok = Vdr.TS.smove(storage, 0, "set1", "set2", "b")
      :ok = Vdr.TS.smove(storage, 0, "set1", "set2", "z")  # doesn't exist
  """
  @spec smove(reference(), non_neg_integer(), binary(), binary(), binary()) ::
          :ok | {:error, :wrong_type}
  def smove(_storage, _db, _source_key, _dest_key, _member),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Stores the union of multiple sets in the destination key.

  Returns `:ok` on success. Returns `{:error, :wrong_type}` if any source key
  exists and holds a non-set value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.sadd(storage, 0, "set1", ["a", "b"])
      Vdr.TS.sadd(storage, 0, "set2", ["b", "c"])
      :ok = Vdr.TS.sunionstore(storage, 0, "result", ["set1", "set2"])
      # result contains: ["a", "b", "c"]
  """
  @spec sunionstore(reference(), non_neg_integer(), binary(), [binary()]) ::
          :ok | {:error, :wrong_type}
  def sunionstore(_storage, _db, _dest_key, _source_keys),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Stores the intersection of multiple sets in the destination key.

  Returns `:ok` on success. Returns `{:error, :wrong_type}` if any source key
  exists and holds a non-set value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.sadd(storage, 0, "set1", ["a", "b", "c"])
      Vdr.TS.sadd(storage, 0, "set2", ["b", "c", "d"])
      :ok = Vdr.TS.sinterstore(storage, 0, "result", ["set1", "set2"])
      # result contains: ["b", "c"]
  """
  @spec sinterstore(reference(), non_neg_integer(), binary(), [binary()]) ::
          :ok | {:error, :wrong_type}
  def sinterstore(_storage, _db, _dest_key, _source_keys),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Stores the difference of sets in the destination key.

  The difference is computed as: first_set - second_set - third_set - ...

  Returns `:ok` on success. Returns `{:error, :wrong_type}` if any source key
  exists and holds a non-set value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.sadd(storage, 0, "set1", ["a", "b", "c", "d"])
      Vdr.TS.sadd(storage, 0, "set2", ["b", "d"])
      :ok = Vdr.TS.sdiffstore(storage, 0, "result", ["set1", "set2"])
      # result contains: ["a", "c"]
  """
  @spec sdiffstore(reference(), non_neg_integer(), binary(), [binary()]) ::
          :ok | {:error, :wrong_type}
  def sdiffstore(_storage, _db, _dest_key, _source_keys),
    do: :erlang.nif_error(:nif_not_loaded)

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
  def smembers(_storage, _db, _key), do: :erlang.nif_error(:nif_not_loaded)

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
  def sismember(_storage, _db, _key, _member), do: :erlang.nif_error(:nif_not_loaded)

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
  def scard(_storage, _db, _key), do: :erlang.nif_error(:nif_not_loaded)

  # List operations

  @doc """
  Pushes one or more values to the head (left) of the list.

  Returns `:ok` on success. Returns `{:error, :wrong_type}` if the key
  exists and holds a non-list value.

  ## Examples

      storage = Vdr.TS.create()
      :ok = Vdr.TS.lpush(storage, 0, "mylist", ["a", "b", "c"])
      # List now contains: ["c", "b", "a"]

      # Type checking
      Vdr.TS.set(storage, 0, "mystring", "value")
      {:error, :wrong_type} = Vdr.TS.lpush(storage, 0, "mystring", ["a"])
  """
  @spec lpush(reference(), non_neg_integer(), binary(), [binary()]) ::
          :ok | {:error, :wrong_type}
  def lpush(_storage, _db, _key, _values), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Pushes one or more values to the tail (right) of the list.

  Returns `:ok` on success. Returns `{:error, :wrong_type}` if the key
  exists and holds a non-list value.

  ## Examples

      storage = Vdr.TS.create()
      :ok = Vdr.TS.rpush(storage, 0, "mylist", ["a", "b", "c"])
      # List now contains: ["a", "b", "c"]

      # Type checking
      Vdr.TS.set(storage, 0, "mystring", "value")
      {:error, :wrong_type} = Vdr.TS.rpush(storage, 0, "mystring", ["a"])
  """
  @spec rpush(reference(), non_neg_integer(), binary(), [binary()]) ::
          :ok | {:error, :wrong_type}
  def rpush(_storage, _db, _key, _values), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Removes and returns the first element from the head (left) of the list.

  Returns `{:ok, value}` if an element was popped, `{:ok, nil}` if the list
  is empty or doesn't exist. Returns `{:error, :wrong_type}` if the key
  exists and holds a non-list value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.rpush(storage, 0, "mylist", ["a", "b", "c"])
      {:ok, "a"} = Vdr.TS.lpop(storage, 0, "mylist")
      {:ok, nil} = Vdr.TS.lpop(storage, 0, "nonexistent")
  """
  @spec lpop(reference(), non_neg_integer(), binary()) ::
          {:ok, binary() | nil} | {:error, :wrong_type}
  def lpop(_storage, _db, _key), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Removes and returns the last element from the tail (right) of the list.

  Returns `{:ok, value}` if an element was popped, `{:ok, nil}` if the list
  is empty or doesn't exist. Returns `{:error, :wrong_type}` if the key
  exists and holds a non-list value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.rpush(storage, 0, "mylist", ["a", "b", "c"])
      {:ok, "c"} = Vdr.TS.rpop(storage, 0, "mylist")
      {:ok, nil} = Vdr.TS.rpop(storage, 0, "nonexistent")
  """
  @spec rpop(reference(), non_neg_integer(), binary()) ::
          {:ok, binary() | nil} | {:error, :wrong_type}
  def rpop(_storage, _db, _key), do: :erlang.nif_error(:nif_not_loaded)

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
  def llen(_storage, _db, _key), do: :erlang.nif_error(:nif_not_loaded)

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
  def lrange(_storage, _db, _key, _start, _stop), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Sets the list element at index to value.

  Returns `:ok` on success. Returns `{:error, :wrong_type}` if the key exists
  and holds a non-list value. Index can be negative (counting from the end).

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.rpush(storage, 0, "mylist", ["a", "b", "c"])
      :ok = Vdr.TS.lset(storage, 0, "mylist", 1, "x")
      {:ok, ["a", "x", "c"]} = Vdr.TS.lrange(storage, 0, "mylist", 0, -1)
  """
  @spec lset(reference(), non_neg_integer(), binary(), integer(), binary()) ::
          :ok | {:error, :wrong_type}
  def lset(_storage, _db, _key, _index, _value), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Atomically pops the last element from source list and pushes it to the head of destination list.

  Returns `{:ok, value}` if an element was moved, `{:ok, nil}` if the source list
  is empty or doesn't exist. Returns `{:error, :wrong_type}` if either key exists
  and holds a non-list value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.rpush(storage, 0, "list1", ["a", "b", "c"])
      Vdr.TS.rpush(storage, 0, "list2", ["x", "y"])
      {:ok, "c"} = Vdr.TS.rpoplpush(storage, 0, "list1", "list2")
      # list1: ["a", "b"], list2: ["c", "x", "y"]
  """
  @spec rpoplpush(reference(), non_neg_integer(), binary(), binary()) ::
          {:ok, binary() | nil} | {:error, :wrong_type}
  def rpoplpush(_storage, _db, _source_key, _dest_key),
    do: :erlang.nif_error(:nif_not_loaded)

  # Hash operations

  @doc """
  Sets field in the hash stored at key to value.

  Returns `:ok` on success. Returns `{:error, :wrong_type}` if the key
  exists and holds a non-hash value.

  ## Examples

      storage = Vdr.TS.create()
      :ok = Vdr.TS.hset(storage, 0, "myhash", "field1", "value1")
      {:ok, "value1"} = Vdr.TS.hget(storage, 0, "myhash", "field1")

      # Type checking
      Vdr.TS.set(storage, 0, "mystring", "value")
      {:error, :wrong_type} = Vdr.TS.hset(storage, 0, "mystring", "field", "value")
  """
  @spec hset(reference(), non_neg_integer(), binary(), binary(), binary()) ::
          :ok | {:error, :wrong_type}
  def hset(_storage, _db, _key, _field, _value), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Sets multiple fields in the hash stored at key.

  Returns `:ok` on success. Returns `{:error, :wrong_type}` if the key
  exists and holds a non-hash value.

  ## Examples

      storage = Vdr.TS.create()
      :ok = Vdr.TS.hmset(storage, 0, "myhash", [{"field1", "value1"}, {"field2", "value2"}])
  """
  @spec hmset(reference(), non_neg_integer(), binary(), [{binary(), binary()}]) ::
          :ok | {:error, :wrong_type}
  def hmset(_storage, _db, _key, _fields), do: :erlang.nif_error(:nif_not_loaded)

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
  def hget(_storage, _db, _key, _field), do: :erlang.nif_error(:nif_not_loaded)

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
  def hmget(_storage, _db, _key, _fields), do: :erlang.nif_error(:nif_not_loaded)

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
  def hgetall(_storage, _db, _key), do: :erlang.nif_error(:nif_not_loaded)

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
  def hkeys(_storage, _db, _key), do: :erlang.nif_error(:nif_not_loaded)

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
  def hvals(_storage, _db, _key), do: :erlang.nif_error(:nif_not_loaded)

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
  def hlen(_storage, _db, _key), do: :erlang.nif_error(:nif_not_loaded)

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
  def hexists(_storage, _db, _key, _field), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Deletes one or more fields from the hash stored at key.

  Returns `{:ok, count}` where count is the number of fields deleted.
  Returns `{:error, :wrong_type}` if the key exists and holds a non-hash value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.hmset(storage, 0, "myhash", [{"f1", "v1"}, {"f2", "v2"}, {"f3", "v3"}])
      {:ok, 2} = Vdr.TS.hdel(storage, 0, "myhash", ["f1", "f2"])
      {:ok, 0} = Vdr.TS.hdel(storage, 0, "nonexistent", ["f1"])
  """
  @spec hdel(reference(), non_neg_integer(), binary(), [binary()]) ::
          {:ok, non_neg_integer()} | {:error, :wrong_type}
  def hdel(_storage, _db, _key, _fields), do: :erlang.nif_error(:nif_not_loaded)

  # Sorted set (zset) operations

  @doc """
  Adds members with scores to the sorted set stored at key.

  Returns `{:ok, count}` where count is the number of new members added.
  Returns `{:error, :wrong_type}` if the key exists and holds a non-zset value.

  ## Examples

      storage = Vdr.TS.create()
      {:ok, 3} = Vdr.TS.zadd(storage, 0, "myzset", [{1.0, "one"}, {2.0, "two"}, {3.0, "three"}])
      {:ok, 0} = Vdr.TS.zadd(storage, 0, "myzset", [{1.5, "one"}])  # Updates score, returns 0
  """
  @spec zadd(reference(), non_neg_integer(), binary(), [{float(), binary()}]) ::
          {:ok, non_neg_integer()} | {:error, :wrong_type}
  def zadd(_storage, _db, _key, _members), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Removes members from the sorted set stored at key.

  Returns `{:ok, count}` where count is the number of members removed.
  Returns `{:error, :wrong_type}` if the key exists and holds a non-zset value.

  ## Examples

      storage = Vdr.TS.create()
      Vdr.TS.zadd(storage, 0, "myzset", [{1.0, "one"}, {2.0, "two"}])
      {:ok, 1} = Vdr.TS.zrem(storage, 0, "myzset", ["one"])
  """
  @spec zrem(reference(), non_neg_integer(), binary(), [binary()]) ::
          {:ok, non_neg_integer()} | {:error, :wrong_type}
  def zrem(_storage, _db, _key, _members), do: :erlang.nif_error(:nif_not_loaded)

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
  def zscore(_storage, _db, _key, _member), do: :erlang.nif_error(:nif_not_loaded)

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
  def zcard(_storage, _db, _key), do: :erlang.nif_error(:nif_not_loaded)

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
  def zrange(_storage, _db, _key, _start, _stop, _with_scores),
    do: :erlang.nif_error(:nif_not_loaded)

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
  def zrangebyscore(_storage, _db, _key, _min, _max, _with_scores),
    do: :erlang.nif_error(:nif_not_loaded)

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
  def zrank(_storage, _db, _key, _member), do: :erlang.nif_error(:nif_not_loaded)

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
  def zrevrank(_storage, _db, _key, _member), do: :erlang.nif_error(:nif_not_loaded)

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
  def zcount(_storage, _db, _key, _min, _max), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Increments the score of a member in the sorted set by delta.

  Creates the member with score delta if it doesn't exist.
  Returns `{:ok, new_score}` with the new score.
  Returns `{:error, :wrong_type}` if the key exists and holds a non-zset value.

  ## Examples

      storage = Vdr.TS.create()
      {:ok, 1.5} = Vdr.TS.zincrby(storage, 0, "myzset", 1.5, "member")
      {:ok, 3.0} = Vdr.TS.zincrby(storage, 0, "myzset", 1.5, "member")
  """
  @spec zincrby(reference(), non_neg_integer(), binary(), float(), binary()) ::
          {:ok, float()} | {:error, :wrong_type}
  def zincrby(_storage, _db, _key, _delta, _member), do: :erlang.nif_error(:nif_not_loaded)
end
