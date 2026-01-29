# Veidrodelis

**Local Read-Only Projection of Redis/Valkey Data**

Veidrodelis connects to Redis or Valkey as a replica and builds a local, read-only projection of the data inside your Erlang/Elixir node. Write commands are issued to the remote Redis via a standard client like Redix, while reads are served from the local projection with near-zero latency.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                      Redis/Valkey                            │
│                      (Primary)                               │
└──────────────┬───────────────────────────────────────────────┘
               │                          ▲
               │ Replication (RO)         │ Commands (RW)
               │                          │
┌──────────────|──────────────────────────|────────────────────┐
│              |   Erlang/Elixir Node     |                    │
│              ▼                          ▼                    │
│  ┌────────────────────────┐    ┌──────────────────────────┐  │
│  │   Veidrodelis          │    │   Redix                  │  │
│  │   (Replica Connection) │    │   (Client Connection)    │  │
│  │   Mode: RO             │    │   Mode: RW               │  │
│  └───────────┬────────────┘    └──────────────────────────┘  │
│              │                                               │
│              │ Builds Local Projection                       │
│              ▼                                               │
│  ┌────────────────────────┐                                  │
│  │   Local Data Store     │                                  │
│  │   (Rust-based)         │                                  │
│  │   • Strings            │                                  │
│  │   • Lists              │                                  │
│  │   • Sets               │                                  │
│  │   • Sorted Sets        │                                  │
│  │   • Hashes             │                                  │
│  └────────────────────────┘                                  │
│                                                              │
│  Your Application: Write via Redix, Read via Veidrodelis     │
└──────────────────────────────────────────────────────────────┘
```

### Multi-Node Deployment

```
                    ┌──────────────────┐
                    │   Redis/Valkey   │
                    │    (Primary)     │
                    └─────────┬────────┘
                              │
              ┌───────────────┼───────────────┐
              │               │               │
         ┌────▼────┐     ┌────▼────┐     ┌────▼────┐
         │ Node 1  │     │ Node 2  │     │ Node 3  │
         │         │     │         │     │         │
         │VDR  RDX │     │VDR  RDX │     │VDR  RDX │
         │(RO) (RW)│     │(RO) (RW)│     │(RO) (RW)│
         │         │     │         │     │         │
         │ [Store] │     │ [Store] │     │ [Store] │
         └─────────┘     └─────────┘     └─────────┘

   VDR = Veidrodelis (reads)
   RDX = Redix (writes)
```

## General Idea

Veidrodelis implements the Redis replication protocol to receive all write operations happening on a Redis/Valkey primary. It builds and maintains a local, in-memory projection of the data using high-performance Rust-based storage.

**Benefits:**
- **Ultra-low latency reads**: Data is local to your Erlang node, no network round-trip
- **Reduced Redis load**: Read traffic doesn't hit Redis
- **Consistent snapshots**: Atomic read transactions across multiple keys
- **Erlang-native**: Seamless integration with OTP applications

**How it works:**
1. Veidrodelis connects to Redis as a replica (read-only)
2. Redis sends the full dataset (RDB) followed by streaming updates
3. All writes still go through Redis via Redix (or any Redis client)
4. Reads are served from the local projection via Veidrodelis

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:veidrodelis, "~> 0.1.0"},
    {:redix, "~> 1.5"}
  ]
end
```

## Usage

### Simple Case: Connect and Use

The most basic setup: connect Veidrodelis for reads, Redix for writes.

```elixir
# Start Veidrodelis (replica connection for reads)
{:ok, vdr} = Veidrodelis.start_link(
  id: :my_cache,
  host: "localhost",
  port: 6379
)

# Start Redix (client connection for writes)
{:ok, rdx} = Redix.start_link(
  host: "localhost",
  port: 6379
)

# Write via Redix
Redix.command!(rdx, ["SET", "user:123:name", "Alice"])
Redix.command!(rdx, ["HSET", "user:123:profile", "age", "30", "city", "NYC"])

# Wait a moment for replication
Process.sleep(100)

# Read via Veidrodelis (from local projection)
{:ok, name} = Veidrodelis.get(:my_cache, 0, "user:123:name")
# => {:ok, "Alice"}

{:ok, age} = Veidrodelis.hget(:my_cache, 0, "user:123:profile", "age")
# => {:ok, "30"}

Redix.command!(rdx, ["LPUSH", "events", "login", "purchase", "logout"])
{:ok, events} = Veidrodelis.lrange(:my_cache, 0, "events", 0, -1)
# => {:ok, ["logout", "purchase", "login"]}

# Clean up
Veidrodelis.stop(vdr)
Redix.stop(rdx)
```

### Supported Commands

Veidrodelis implements read operations for basic Redis data types. The local projection is updated automatically as write commands are replicated from Redis.

#### Read Operations

**Strings**: `GET`
**Lists**: `LLEN`, `LRANGE`
**Sets**: `SMEMBERS`, `SCARD`, `SISMEMBER`, `SFIRST`, `SLAST`, `SNEXT`, `SPREV`
**Sorted Sets**: `ZRANGE`, `ZCARD`, `ZSCORE`, `ZRANGEBYSCORE`, `ZRANK`, `ZREVRANK`, `ZCOUNT`
**Hashes**: `HGET`, `HMGET`, `HGETALL`, `HKEYS`, `HVALS`, `HLEN`, `HEXISTS`

#### Write Operations (Replicated from Redis)

Veidrodelis supports replication of the following write commands. For the full list, see:
- [String commands](doc/string-write.md)
- [Hash commands](doc/hash-write.md)
- [List commands](doc/list-write.md)
- [Set commands](doc/set-write.md)
- [Sorted Set commands](doc/sorted-set-write.md)
- [Other commands](doc/other-write.md)

Examples include: `SET`, `SETEX`, `INCR`, `APPEND`, `HSET`, `LPUSH`, `SADD`, `ZADD`, `DEL`, `EXPIRE`, etc.

#### Unsupported Write Commands

Commands not listed in the documentation above are **not supported** and will not be replicated correctly. To prevent data inconsistencies, configure Redis ACLs to deny unsupported write commands.

**Recommended ACL Configuration:**

Reference: [`doc/acl.txt`](doc/acl.txt)

This ensures clients cannot execute commands that Veidrodelis cannot replicate, preventing projection inconsistencies.

### Write Transactions via `SETEX __vdr_tx`

Veidrodelis supports write transactions using a special transaction key pattern. This allows atomic multi-key writes from the perspective of readers.

```elixir
# Start transaction by setting the __vdr_tx key with expiration
# The expiration is CRITICAL - it garantees the end of the transaction
# If you forget to delete __vdr_tx or crash, it will auto-close when it expires
Redix.command!(rdx, ["SETEX", "__vdr_tx", "5", "in_progress"])

# Perform multiple writes
Redix.command!(rdx, ["SET", "account:123:balance", "1000"])
Redix.command!(rdx, ["SET", "account:456:balance", "2000"])
Redix.command!(rdx, ["SET", "transfer:789:amount", "100"])

# End transaction by deleting the __vdr_tx key (or wait for expiration)
Redix.command!(rdx, ["DEL", "__vdr_tx"])
```

**How it works:**
1. When `__vdr_tx` key is set, Veidrodelis starts buffering writes
2. The projection remains active for reads
3. When `__vdr_tx` expires or is deleted, Veidrodelis atomically applies all buffered writes
4. All buffered writes become visible at once

**Important Notes:**
- Always set an expiration on `__vdr_tx` (using `SETEX` or `PSETEX`)
- The expiration acts as a timeout for the transaction
- If you forget to delete `__vdr_tx`, it will auto-close when it expires
- Readers never see partial transaction state

### Read Transactions via Command Lists

Execute multiple read operations atomically under a single lock:

```elixir
# Atomic read of multiple keys
{:ok, results} = Veidrodelis.read_tx(:my_cache, 0, [
  {:get, "user:123:name"},
  {:hget, "user:123:profile", "age"},
  {:llen, "user:123:events"},
  {:zcard, "user:123:scores"}
])

# Results is a list of individual command results
[{:ok, "Alice"}, {:ok, "30"}, {:ok, 5}, {:ok, 10}] = results

# More complex example: reading cart and inventory
{:ok, results} = Veidrodelis.read_tx(:my_cache, 0, [
  {:hgetall, "cart:session123"},
  {:get, "inventory:item456:stock"},
  {:zscore, "product:prices", "item456"}
])

# All reads are atomic - they see a consistent snapshot
```

**Supported commands in read transactions:**
- `{:get, key}`
- `{:hget, key, field}`, `{:hmget, key, fields}`, `{:hgetall, key}`, `{:hkeys, key}`, `{:hvals, key}`, `{:hlen, key}`
- `{:llen, key}`, `{:lrange, key, start, stop}`
- `{:smembers, key}`, `{:sismember, key, member}`, `{:scard, key}`
- `{:zscore, key, member}`, `{:zcard, key}`, `{:zrange, key, start, stop, with_scores}`, `{:zrangebyscore, key, min, max, with_scores}`, `{:zrank, key, member}`, `{:zrevrank, key, member}`, `{:zcount, key, min, max}`

### Read Transactions via Lua

For more complex read logic, use Lua scripts with atomic execution:

```elixir
# Simple Lua script
script = """
local name = ts.get('user:123:name')
local age = ts.hget('user:123:profile', 'age')
return {name, age}
"""

{:ok, ["Alice", "30"]} = Veidrodelis.read_tx(:my_cache, 0, script)

# More complex: key indirection
# Impossible to do with list-based transactions
script = """
local owner_id = ts.get('item:456')
return ts.hget('user:' .. owner_id, 'name')
"""

{:ok, owner_name} = Veidrodelis.read_tx(:my_cache, 0, script)

# Iterate over sorted set
script = """
local results = {}
local first_score, first_member = ts.zfirst('leaderboard')
if first_score then
  table.insert(results, {first_member, first_score})
  
  local next_score, next_member = ts.znext('leaderboard', first_score, first_member)
  while next_score do
    table.insert(results, {next_member, next_score})
    next_score, next_member = ts.znext('leaderboard', next_score, next_member)
  end
end
return results
"""

{:ok, leaderboard} = Veidrodelis.read_tx(:my_cache, 0, script)
```

**Available Lua functions:**

**String:**
- `ts.get(key)` - Get string value

**Hash:**
- `ts.hget(key, field)` - Get field value
- `ts.hmget(key, fields)` - Get multiple field values (fields is a Lua table)
- `ts.hgetall(key)` - Get all field-value pairs as Lua table
- `ts.hkeys(key)` - Get all field names
- `ts.hvals(key)` - Get all values
- `ts.hlen(key)` - Get number of fields
- `ts.hexists(key, field)` - Check if field exists
- `ts.hstrlen(key, field)` - Get length of field value
- `ts.hrandfield(key, count, with_values)` - Get random fields (with_values is boolean)
- `ts.hfirst(key)`, `ts.hlast(key)`, `ts.hnext(key, field)`, `ts.hprev(key, field)` - Hash iteration

**List:**
- `ts.llen(key)` - Get list length
- `ts.lrange(key, start, stop)` - Get list elements by index range

**Set:**
- `ts.smembers(key)` - Get all members
- `ts.sismember(key, member)` - Check if member exists
- `ts.smismember(key, members)` - Check multiple members (members is a Lua table)
- `ts.scard(key)` - Get set size
- `ts.srandmember(key, count)` - Get random members
- `ts.sunion(keys)`, `ts.sinter(keys)`, `ts.sdiff(keys)` - Set operations (keys is a Lua table)
- `ts.sintercard(keys)` - Get intersection size
- `ts.sfirst(key)`, `ts.slast(key)`, `ts.snext(key, member)`, `ts.sprev(key, member)` - Set iteration

**Sorted Set:**
- `ts.zscore(key, member)` - Get member score
- `ts.zcard(key)` - Get sorted set size
- `ts.zrange(key, start, stop)` - Get members by rank range (returns table of {member, score})
- `ts.zrangebyscore(key, min, max)` - Get members by score range (returns table of {member, score})
- `ts.zrank(key, member)`, `ts.zrevrank(key, member)` - Get member rank
- `ts.zcount(key, min, max)` - Count members in score range
- `ts.zfirst(key)`, `ts.zlast(key)`, `ts.znext(key, score, member)`, `ts.zprev(key, score, member)` - Sorted set iteration

**Performance tip:** Compile scripts once, reuse many times:

```elixir
# Compile script to bytecode
script = "return ts.get('user:123:name')"
{:ok, bytecode} = Veidrodelis.lua_load(:my_cache, script)

# Reuse bytecode for faster execution
{:ok, result1} = Veidrodelis.read_tx(:my_cache, 0, bytecode)
{:ok, result2} = Veidrodelis.read_tx(:my_cache, 0, bytecode)
```

### Key Watches

Subscribe to real-time notifications when specific keys are modified. Watchers receive messages for every write operation affecting the watched key.

```elixir
# Subscribe to key updates
:ok = Veidrodelis.watch(:my_cache, 0, "user:123:name", :my_watch_ref)

# Perform writes via Redix
Redix.command!(rdx, ["SET", "user:123:name", "Alice"])

# Receive notifications in your process
receive do
  {:my_watch_ref, %Vdr.WatchEvent.Update{command: cmd, db: db}} ->
    IO.inspect({:key_updated, cmd, db})
    # => {:key_updated, [...], 0}
end

# Unsubscribe when done
:ok = Veidrodelis.unwatch(:my_cache, 0, "user:123:name")
```

**Event types:**

- **Update event**: `{ref, %Vdr.WatchEvent.Update{command: cmd, db: db}}`
  Sent when the watched key is modified. Contains the full command that modified it.

- **Init event**: `{ref, %Vdr.WatchEvent.Init{}}`
  Sent when Veidrodelis transitions to streaming mode (after RDB transfer completes).

**Important notes:**

- Each process can watch the same key only once
- Watches survive reconnections (automatically re-registered)
- Watches are cleaned up when the watching process terminates
- The `command` field contains the full Redis command as a list (e.g., `["SET", "key", "value"]`)

### Reconnection and Projection Caching

Veidrodelis handles Redis disconnections gracefully with automatic reconnection and intelligent projection caching.

**How it works:**

1. **Disconnection Detected**: Network failure or Redis restart
2. **Old Projection Cached**: The current local projection remains available for reads
3. **Reconnection Initiated**: Automatic reconnection with exponential backoff
4. **New Projection Built**: Full RDB transfer + streaming updates to a new storage
5. **Atomic Switch**: Once streaming starts, old projection is replaced with new one
6. **Reads Never Block**: During the entire process, reads continue from the cached projection

```elixir
# Start Veidrodelis with reconnection enabled (default)
{:ok, vdr} = Veidrodelis.start_link(
  id: :my_cache,
  host: "localhost",
  port: 6379,
  reconnect: true,
  reconnect_delay_ms: 1000,          # Initial delay: 1 second
  max_reconnect_delay_ms: 30_000     # Max delay: 30 seconds
)

# Reads work normally
{:ok, value} = Veidrodelis.get(:my_cache, 0, "mykey")

# >>> Redis goes down <<<
# Veidrodelis detects disconnection, keeps serving reads from cached projection

{:ok, value} = Veidrodelis.get(:my_cache, 0, "mykey")
# Still works! Uses cached projection

# >>> Redis comes back up <<<
# Veidrodelis automatically reconnects, starts building new projection
# Meanwhile, reads still served from cached projection

# >>> New projection ready <<<
# Atomic switch: new projection replaces old one
# Application sees no downtime

{:ok, new_value} = Veidrodelis.get(:my_cache, 0, "mykey")
# Now reading from fresh, up-to-date projection
```

**Reconnection behavior:**

- **Exponential backoff**: Starts at `reconnect_delay_ms`, doubles on each failure, up to `max_reconnect_delay_ms`
- **Infinite retries**: Veidrodelis keeps trying until Redis is available
- **No read disruption**: Old projection serves reads during entire reconnection process
- **Atomic updates**: New projection is complete before switching

**Monitoring replication state:**

```elixir
state = Veidrodelis.get_replication_state(:my_cache)
# Possible states:
# :initializing - Just started, no projection yet
# :replicating  - Receiving RDB transfer
# :streaming    - Fully synced, receiving live updates
# :reconnecting - Disconnected, attempting to reconnect
```

### Sentinel Support

For high-availability setups, connect via Redis Sentinel:

```elixir
{:ok, vdr} = Veidrodelis.start_link(
  id: :my_cache,
  sentinel: [
    sentinels: [
      [host: "sentinel1.example.com", port: 26379],
      [host: "sentinel2.example.com", port: 26379],
      [host: "sentinel3.example.com", port: 26379]
    ],
    group: "mymaster",
    role: :primary,
    timeout: 1000
  ],
  username: "my_user",  # Optional: ACL username
  password: "secret"    # Optional: auth password
)

```
Veidrodelis automatically:
* Discovers primary via Sentinel
* Handles failover when primary changes
* Reconnects to new primary seamlessly
* Maintains read availability during failover

## Project name

The project name is a diacritic-less form of the Lithuanian word "veidrodėlis", meaning "a small/pocket mirror."

## License

Copyright © 2026

