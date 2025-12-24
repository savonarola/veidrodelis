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
end
