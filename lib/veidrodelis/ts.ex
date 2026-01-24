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
    mode: if(Mix.env() == :test, do: :debug, else: :release)

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

  **String operations:**
  - `{db, {:set, key, value}}` - Set a string value
  - `{db, {:mset, pairs}}` - Set multiple key-value pairs (pairs is `[{key, value}, ...]`)
  - `{db, {:del, keys}}` - Delete keys (keys is a list)
  - `{db, {:pexpireat, key, timestamp}}` - Set expiration (null handler - ignored)
  - `{db, {:rename, old_key, new_key}}` - Rename a key
  - `{db, {:renamenx, old_key, new_key}}` - Rename only if new key doesn't exist
  - `{db, {:move_key, key, target_db}}` - Move key to another database
  - `{db, {:append, key, value}}` - Append value to a string

  **Set operations:**
  - `{db, {:sadd, key, members}}` - Add members to a set
  - `{db, {:srem, key, members}}` - Remove members from a set
  - `{db, {:smove, source_key, dest_key, member}}` - Move member between sets
  - `{db, {:sunionstore, dest_key, source_keys}}` - Store union of sets
  - `{db, {:sinterstore, dest_key, source_keys}}` - Store intersection of sets
  - `{db, {:sdiffstore, dest_key, source_keys}}` - Store difference of sets

  **List operations:**
  - `{db, {:lpush, key, values}}` - Push values to list head
  - `{db, {:rpush, key, values}}` - Push values to list tail
  - `{db, {:lpushx, key, values}}` - Push to list head only if list exists
  - `{db, {:rpushx, key, values}}` - Push to list tail only if list exists
  - `{db, {:lpop, key}}` - Pop value from list head
  - `{db, {:rpop, key}}` - Pop value from list tail
  - `{db, {:lset, key, index, value}}` - Set list element at index
  - `{db, {:lrem, key, count, value}}` - Remove elements from list
  - `{db, {:ltrim, key, start, stop}}` - Trim list to range
  - `{db, {:linsert, key, direction, pivot, value}}` - Insert before/after pivot (direction is `:before` or `:after`)
  - `{db, {:rpoplpush, source_key, dest_key}}` - Pop from source and push to dest

  **Hash operations:**
  - `{db, {:hset, key, field, value}}` - Set hash field
  - `{db, {:hmset, key, fields}}` - Set multiple hash fields (fields is `[{field, value}, ...]`)
  - `{db, {:hdel, key, fields}}` - Delete hash fields

  **Sorted set operations:**
  - `{db, {:zadd, key, members, options}}` - Add members to sorted set (members is `[{score, member}, ...]`, options is `[:nx, :xx, :gt, :lt, :ch, :incr]`)
  - `{db, {:zrem, key, members}}` - Remove members from sorted set
  - `{db, {:zincrby, key, delta, member}}` - Increment member's score
  - `{db, {:zpopmax, key}}` - Remove and return member with highest score
  - `{db, {:zpopmin, key}}` - Remove and return member with lowest score
  - `{db, {:zremrangebyrank, key, start, stop}}` - Remove members by rank range
  - `{db, {:zremrangebyscore, key, min_bound, max_bound}}` - Remove members by score range (bounds: `:unbounded` | `{:included, score}` | `{:excluded, score}`)
  - `{db, {:zremrangebylex, key, min_bound, max_bound}}` - Remove members by lexicographic range (bounds: `:unbounded` | `{:included, value}` | `{:excluded, value}`)
  - `{db, {:zunionstore, dest_key, source_keys, weights, aggregate}}` - Store union (aggregate is `:sum`, `:min`, or `:max`)
  - `{db, {:zinterstore, dest_key, source_keys, weights, aggregate}}` - Store intersection (aggregate is `:sum`, `:min`, or `:max`)

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
    read_tx_commands(storage, db, commands)
  end

  def read_tx(storage, db, script) when is_binary(script) do
    read_tx_lua(storage, db, script)
  end

  @spec read_tx_lua(reference(), non_neg_integer(), binary()) :: {:ok, term()} | {:error, term()}
  defp read_tx_lua(_storage, _db, _script_or_bytecode),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec read_tx_commands(reference(), non_neg_integer(), [tuple()]) ::
          {:ok, [term()]} | {:error, term()}
  defp read_tx_commands(_storage, _db, _commands),
    do: :erlang.nif_error(:nif_not_loaded)
end
