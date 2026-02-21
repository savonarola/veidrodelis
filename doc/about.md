# Veidrodelis

Veidrodelis keeps a local, read-only replica of your Redis or Valkey data (strings, lists, sets, sorted sets, hashes)
inside the Erlang/Elixir node so your application can write through a standard client (for example, Redix) and read from a fast, in-process projection using the `Veidrodelis` module.

### 1. Simple read/write

```elixir
# On node A
{:ok, vdr} = Veidrodelis.start_link(id: :myid, host: "localhost", port: 6379)

# On node B, maybe different from node A or maybe the same
{:ok, rdx} = Redix.start_link(host: "localhost", port: 6379)
Redix.command!(rdx, ["SET", "user:123:name", "Alice"])

Process.sleep(100)
# On node A, the change is eventually replicated to the local projection.
# No network involved while reading.
{:ok, "Alice"} = Veidrodelis.get(:myid, 0, "user:123:name")

Veidrodelis.stop(vdr)
Redix.stop(rdx)
```

### 2. Sentinel-aware replica

```elixir
{:ok, vdr} =
  Veidrodelis.start_link(
    id: :myid,
    sentinel: [
      sentinels: [[host: "sentinel1", port: 26379], [host: "sentinel2", port: 26379]],
      group: "mymaster",
      role: :primary
    ]
  )
```

The `:sentinel` option (see `Veidrodelis.start_link/1` for every supported sub-option) allows to
discover and connect to the current primary or replica server.

### 3. Transactional writes

Redis/Valkey supports simple write transactions via the `MULTI` and `EXEC` commands. Also, Redis/Valkey supports Lua scripts for more complex atomic write operations. However, replicas receive plain stream of mutating commands, so when reading from a replica, you may see partial transaction state.

To solve this problem, Veidrodelis supports a convention to avoid exposing intermediate transaction state.

Veidrodelis buffers replicated writes between setting and removing the special guard key `__vdr_tx` (e.g., `SET __vdr_tx …` and `DEL __vdr_tx`).

```elixir
Redix.pipeline!(rdx, [
    ["MULTI"],
    ["SETEX", "__vdr_tx", "5", "in_progress"])
    ["SET", "tx:from", "100"],
    ["SET", "tx:to", "200"],
    ["DEL", "__vdr_tx"],
    ["EXEC"]
])
```

Veidrodelis executes every command in the transaction in one batch once `__vdr_tx` is deleted, so reads that follow see the fully committed state.

When using such write transactions, always give the guard key an expiration (e.g., use `SETEX`/`PSETEX`) to guarantee the transaction closes even if the writer crashes.

### 4. Transactional read (lists)

Use `Veidrodelis.read_tx/3` with a list of operations to observe multiple keys atomically.

```elixir
{:ok, results} =
  Veidrodelis.read_tx(:myid, 0, [
    {:lrange, "events", 0, -1},
    {:llen, "events"},
    {:get, "status"}
  ])

# [{:ok, [...]}, {:ok, length}, {:ok, "ok"}] = results
```

Every command in the list sees the same snapshot, so the length will always match the returned list even if writers continue racing.

### 5. Transactional read (Lua)

Lua scripts can orchestrate richer logic while still reading from a consistent snapshot.

```elixir
script = """
local timeline = {}
local batch_size = 10
local batch = ts.zfirst('leaderboard', batch_size)

while #batch > 0 do
  for i = 1, #batch do
    local item = batch[i]
    local score = item[1]
    local member = item[2]
    table.insert(timeline, {member, score})
  end

  local last_member = batch[#batch][2]
  batch = ts.znext('leaderboard', last_member, batch_size)
end
return timeline
"""

{:ok, history} = Veidrodelis.read_tx(:myid, 0, script)
```

Normally, lua scripts are needed only if data schema has some kind of key indirection, i.e. we read keys that are
derived from previously read values:
```elixir
script = """
local owner_id = ts.get('item:456:owner_id')
return ts.hget('user:' .. owner_id, 'name')
"""
```

You can also load the script once with `Veidrodelis.lua_load/2` and reuse the bytecode for faster execution.

### 6. Watches

Watches notify your process about every write that touches a key. They survive reconnections and are cleaned up when the watcher exits.

```elixir
ref = make_ref()
:ok = Veidrodelis.watch(:myid, 0, "user:123:name", ref)

Redix.command!(rdx, ["SET", "user:123:name", "Bob"])

assert_receive {^ref, %Vdr.WatchEvent.Update{command: {:set, "user:123:name", _}}}, 2000

:ok = Veidrodelis.unwatch(:myid, 0, "user:123:name")
```

### 7. Watches for sync writes

Wathches may be used to make "synchronous" writes, i.e, to make a write to Redis and wait till it is visible locally.

```elixir

# helper function
  def wait_min_version(vdr_id, ref, key, min_version) do
    receive do
      {^ref, _command} ->
        {:ok, version} = Veidrodelis.get(vdr_id, 0, key)
        if String.to_integer(version) >= min_version do
          :ok
        else
          wait_min_version(vdr_id, ref, key, min_version)
        end
      after
        1000 -> {:error, :timeout}
    end
  end

#...

# We want to issue a `["LPUSH", "events", "myevent"]` command into Redis
# and block until the command is replicated to the local Veidrodelis instance.
# Here is a way to do it.

# 1. Watch the key
ref = make_ref()
:ok = Veidrodelis.watch(vdr_id(), 0, "events_version", ref)

# 2. Issue the command in a multi transaction together with version increment
["OK", "QUEUED", "QUEUED", [_, version]] = Redix.pipeline!(redis, [
  ["MULTI"],
  ["LPUSH", "events", "myevent"],
  ["INCR", "events_version"],
  ["EXEC"],
])

# 3. Wait for the version to be incremented locally
:ok = wait_min_version(vdr_id(), ref, "events_version", version)

# 4. Here we are sure that `["LPUSH", "events", "myevent"]` is replicated to the local Veidrodelis instance.
end
```
