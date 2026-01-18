# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Veidrodelis is an Elixir library that replicates Redis data into an in-process storage for instant, low-latency access.

The project is implemented in **Elixir** with **Rust NIFs** for critical parts:
- **vdr_ts_nif**: High-performance, thread-safe Term Storage (TS) for all Redis data types
- **vdr_redis_nif**: Streaming RDB parser and replication protocol handler

### Key Features
- Full Redis replication protocol support (PSYNC)
- High-performance Rust-based storage backend (TSProj)
- Replica-side transaction support via `__vdr_tx` marker protocol
- Batch command execution for atomic multi-operation updates
- Direct NIF access for high-performance reads (TSProj)
- Support for all Redis data types: strings, lists, sets, sorted sets, hashes
- Efficient sorted set iteration without loading entire sets
- Automatic reconnection with exponential backoff
- SSL/TLS support for secure replication

## Build and Development Commands

### Building
```bash
# Fetch dependencies and compile everything (including Rust NIFs)
mix deps.get
mix compile

# The compile step automatically builds:
# - Rust NIF: vdr_redis_nif (RDB and replication parser)
# - Rust NIF: vdr_ts_nif (Term Storage)
# - C code: LZF compression (legacy, wrapped by vdr_redis_nif)
```

### Benchmarking
```bash
# Run benchmarks
mix benchmark

# Benchmarks test replication performance with different scenarios
# See benchmark/ directory for scenario definitions
```

### Testing
```bash
# Run all ExUnit tests
mix test

# Run tests with verbose output
mix test --trace

# Run a specific test file
mix test test/veidrodelis/rdb_test.exs
```

### Code Formatting
```bash
# Format Elixir code
mix format

# Check if code is formatted
mix format --check-formatted
```

## Project Structure

```
/home/av/dev/veidrodelis/
├── lib/                          # Elixir source code
│   ├── veidrodelis.ex            # Main API entry point
│   ├── veidrodelis/
│   │   ├── application.ex        # OTP Application (starts Registry)
│   │   ├── handle.ex             # Handle struct for registry lookups
│   │   ├── registry.ex           # ETS-based instance registry
│   │   ├── ts.ex                 # Rust-based Term Storage (TS) NIF interface
│   │   ├── ts_proj.ex            # TS-based projection implementation
│   │   ├── redis_stream/         # Redis replication stream components
│   │   │   ├── callback.ex       # Behavior definition for callbacks
│   │   │   ├── replica.ex        # Main replica client (GenServer)
│   │   │   ├── replica_command.ex # Command wrapper with context
│   │   │   ├── parser.ex         # Rust NIF wrapper for parsing
│   │   │   ├── rdb.ex            # RDB parsing interface
│   │   │   ├── command.ex        # Command structs
│   │   │   ├── command_parser.ex # Command parsing utilities
│   │   │   └── command_filter.ex # Command filtering
│   │   └── benchmark/            # Benchmarking infrastructure
│   └── mix/tasks/
│       └── benchmark.ex          # Mix task for benchmarking
├── native/                       # Rust NIFs (2 crates)
│   ├── vdr_redis_nif/           # Redis parsing NIF
│   │   ├── c_src/               # LZF compression (C code)
│   │   └── src/
│   │       ├── rdb.rs           # RDB parser
│   │       └── replica.rs       # Replica parser
│   └── vdr_ts_nif/              # Term Storage NIF
│       └── src/
│           ├── lib.rs           # Main NIF entry point
│           └── storage.rs       # Core storage implementation
├── test/                         # Test suite
│   ├── veidrodelis/
│   │   ├── transaction_test.exs  # Transaction tests
│   │   ├── ts_test.exs           # TS tests
│   │   ├── rdb_test.exs          # RDB parser tests
│   │   ├── replica_test.exs      # Replica client tests
│   │   └── ts_proj/              # TS-based store tests
│   └── support/                  # Test helpers
└── benchmark/                    # Benchmark scenarios
```

## Architecture

Veidrodelis uses a Rust-based storage backend (TSProj) for high-performance, thread-safe data access.

### Replication Flow

```
Redis Master → TCP/SSL → Vdr.RedisStream.Replica →
  RDB/Command Stream → Vdr.RedisStream.Parser (Rust) →
  Commands → Callback (TSProj) →
  Storage (TS Rust NIF)
```

### Read Path

```
Veidrodelis API → Registry Lookup →
  TSProj.get(ts_storage, db, key) →
  Vdr.TS.get(ts_storage, db, key) (direct NIF call, no GenServer)
```

### Core Components

**Vdr.TS - Term Storage ([lib/veidrodelis/ts.ex](lib/veidrodelis/ts.ex))**
- High-performance, thread-safe Rust-native storage for all Redis data types
- NIF implementation: [native/vdr_ts_nif/src/lib.rs](native/vdr_ts_nif/src/lib.rs)
- Storage implementation: [native/vdr_ts_nif/src/storage.rs](native/vdr_ts_nif/src/storage.rs)
- Multi-database support (db parameter)
- **Batch command execution** via `tx/2` - executes multiple write commands under single mutex lock
- Direct read operations (no GenServer overhead)
- Arc-based reference counting for efficient memory management
- **Lua transaction interface** via `read_tx/3` and `lua_load/2`:
  - Embedded LuaJIT VM initialized once per storage instance
  - All read-only functions exposed to Lua via `ts.*` namespace
  - Script compilation to bytecode for performance via `lua_load/2`
  - Atomic execution under storage mutex
  - Lua functions initialized once during storage creation for zero overhead
- **Write operations** (via `tx/2` only):
  - **Strings**: `{:set, key, value}`, `{:del, keys}`
  - **Lists**: `{:lpush, key, values}`, `{:rpush, key, values}`, `{:lpop, key}`, `{:rpop, key}`, `{:lset, key, index, value}`, `{:rpoplpush, source_key, dest_key}`
  - **Sets**: `{:sadd, key, members}`, `{:srem, key, members}`, `{:smove, source_key, dest_key, member}`, `{:sunionstore, dest_key, source_keys}`, `{:sinterstore, dest_key, source_keys}`, `{:sdiffstore, dest_key, source_keys}`
  - **Hashes**: `{:hset, key, field, value}`, `{:hmset, key, fields}`, `{:hdel, key, fields}`
  - **Sorted Sets**: `{:zadd, key, members}`, `{:zrem, key, members}`, `{:zincrby, key, delta, member}`
- **Read operations** (direct function calls):
  - **Strings**: `get/3`
  - **Lists**: `llen/3`, `lrange/5`
  - **Sets**: `smembers/3`, `sismember/4`, `scard/3`
  - **Hashes**: `hget/4`, `hmget/4`, `hgetall/3`, `hkeys/3`, `hvals/3`, `hlen/3`, `hexists/4`
  - **Sorted Sets**: `zscore/4`, `zcard/3`, `zrange/6`, `zrangebyscore/6`, `zrank/4`, `zrevrank/4`, `zcount/5`
  - **Sorted Set Iteration**: `zfirst/3`, `zlast/3`, `znext/5`, `zprev/5` - efficient iteration without loading entire set
- Rust dependencies: `im` (immutable data structures), `indexset`, `ordered-float`, `ouroboros`, `mlua` (LuaJIT)

**Vdr.TSProj - TS-based Projection ([lib/veidrodelis/ts_proj.ex](lib/veidrodelis/ts_proj.ex))**
- Redis replication processor using Rust-native TS storage
- **Replica-side transaction support** via `__vdr_tx` marker key protocol:
  - Transaction start: `SET __vdr_tx <value>` - begins buffering commands
  - Commands buffered during transaction
  - Transaction end: `DEL __vdr_tx` - atomically applies all buffered commands via `Vdr.TS.tx/2`
- Double-buffering during RDB transfer (new_ts_storage/ts_storage swap)
- Direct TS storage access for reads (no GenServer calls)
- All Redis command types supported

**Vdr.RedisStream.Replica - Replication Client ([lib/veidrodelis/redis_stream/replica.ex](lib/veidrodelis/redis_stream/replica.ex))**
- GenServer implementing Redis replication protocol (PSYNC)
- Full and partial resync support
- Automatic reconnection with exponential backoff
- ACL and legacy authentication
- SSL/TLS support
- Periodic REPLCONF ACK
- State machine: init → auth → ping → replconf → psync → replication
- Callbacks: `init`, `handle_replication_start`, `handle_streaming_start`, `handle_command`, `handle_call`, `handle_destroy`

**Vdr.RedisStream.Parser - Rust-based Parser ([lib/veidrodelis/redis_stream/parser.ex](lib/veidrodelis/redis_stream/parser.ex))**
- Rust NIF wrapper for streaming parser
- NIF implementation: [native/vdr_redis_nif/src/replica.rs](native/vdr_redis_nif/src/replica.rs)
- Handles RDB + command stream parsing
- States: WaitingRdb → ReadingRdb → Streaming
- Returns parsed commands via callbacks

**RDB Parser ([lib/veidrodelis/redis_stream/rdb.ex](lib/veidrodelis/redis_stream/rdb.ex))**
- Rust-based RDB parser with Elixir wrapper
- NIF implementation: [native/vdr_redis_nif/src/rdb.rs](native/vdr_redis_nif/src/rdb.rs)
- Entry point: `Vdr.RedisStream.RDB.create()` and `Vdr.RedisStream.RDB.data(parser, chunk)`
- Stateless streaming parser that processes opcodes sequentially
- Supports all Redis data types: strings, lists, sets, sorted sets, hashes
- Handles multiple encoding formats: ziplist, listpack, intset, quicklist variants
- Comprehensive documentation and examples
- Type specifications for better tooling support

**RedisStream Callback Behavior ([lib/veidrodelis/redis_stream/callback.ex](lib/veidrodelis/redis_stream/callback.ex))**
- Defines callbacks for replication lifecycle events
- Main callback: `on_command/3` - called for each parsed Redis command
- Returns: `{:ok, new_state}` or `{:error, reason}`

**Command Structs ([lib/veidrodelis/redis_stream/command.ex](lib/veidrodelis/redis_stream/command.ex))**
- Represents Redis write commands that would have created the RDB data
- `%Command.Set{key, value}` - SET command for string values
- `%Command.RPush{key, value}` - RPUSH command for list elements
- `%Command.SAdd{key, member}` - SADD command for set members
- `%Command.ZAdd{key, score, member}` - ZADD command for sorted set members
- `%Command.HSet{key, field, value}` - HSET command for hash fields
- And many more command types for all Redis operations

**LZF Compression NIF ([native/vdr_redis_nif/c_src/](native/vdr_redis_nif/c_src/))**
- C implementation for LZF compression/decompression (legacy)
- Used by RDB parser for compressed strings
- Functions exposed via Rust NIF wrapper
- Files: `lzf_c.c`, `lzf_d.c`, `lzf.h`, `lzfP.h`

**Vdr.Registry ([lib/veidrodelis/registry.ex](lib/veidrodelis/registry.ex))**
- ETS-based registry for Veidrodelis instances
- Instance registration by ID, process monitoring, cleanup on crash
- Used for looking up projection processes by handle


## Implementation Notes

### Working with TS Storage
- TS (Term Storage) is a Rust NIF providing thread-safe storage with internal locking
- For atomic multi-command operations, always use `Vdr.TS.tx/2` to execute under a single mutex lock
- TS storage uses Arc-based reference counting - no need to manually manage memory
- Direct NIF calls bypass GenServer overhead for maximum read performance
- Multi-database support via the `db` parameter (defaults to 0)
- **CRITICAL**: All mutating functions (write operations) should return `Result<(), &'static str>` (i.e., `Ok(())` on success). They are only used for replication where return values are not needed. Only read operations should return meaningful data (counts, values, etc.)

### Working with Transactions
- Transactions are detected via the `__vdr_tx` marker key
- Transaction protocol:
  1. `SET __vdr_tx <value>` starts buffering commands
  2. All subsequent commands are buffered (not applied)
  3. `DEL __vdr_tx` triggers atomic application via `Vdr.TS.tx/2`
- Transaction state is tracked in the projection GenServer (buffer list)

### Working with the RDB parser
- Binary parsing uses little-endian for most integers (Redis convention)
- Ziplist/listpack entries contain back-length fields for reverse traversal
- Sorted set scores can be float, NaN, or infinity values
- Hash and sorted set entries are always paired (field/value or member/score)
- The parser is stateful (WaitingRdb → ReadingRdb → Streaming)

### Working with the Lua Interface
- **Architecture**: Each TS storage instance contains an embedded LuaJIT VM
- **Initialization**: Lua VM and all `ts.*` functions are created once during `StorageInner::new()` in [native/vdr_ts_nif/src/storage.rs](native/vdr_ts_nif/src/storage.rs)
- **Function exposure**: All read-only TS functions are exposed to Lua via the `ts` global table
- **Execution model**:
  - Scripts/bytecode execute atomically under the storage mutex
  - Storage pointer passed via `LightUserData` in Lua globals
  - Database ID passed via `__db` global variable
  - Functions use `get_tx_ctx()` helper to extract storage and db
- **Performance optimizations**:
  - Lua functions created once (not per-execution)
  - Zero overhead function calls from Lua
  - Bytecode compilation via `lua_load/2` for script reuse
- **Adding new Lua functions**: When adding new read-only TS operations:
  1. Create the Lua function in `StorageInner::new()` following the pattern
  2. Use `get_tx_ctx(&lua_ctx)` to get storage and db
  3. Call the underlying storage method
  4. Convert result to appropriate Lua type
  5. Register function in the `ts` table
  6. Add corresponding test in `ts_test.exs` (both direct and via `read_tx`)
- **Function naming**: Lua functions should match Elixir function names (e.g., `ts.get`, `ts.hget`, `ts.zfirst`)
- **Return values from Lua scripts** (types preserved):
  - Strings: Return as Elixir binary
  - Numbers: Return as Elixir integer or float
  - Booleans: Return as Elixir boolean (true/false)
  - nil: Return as Elixir nil atom
  - Lua tables (array-like, 1-indexed): Return as Elixir list
  - Lua tables (key-value): Return as Elixir map (string keys)
  - Nested tables: Recursively converted to nested lists/maps
  - Example: `{1, 2, {a=10}}` → `[1, 2, %{"a" => 10}]`
- **Dependencies**: Uses `mlua` crate with features: `["luajit", "vendored", "send"]`

### When adding new features
- Implement in Elixir in `lib/veidrodelis/*.ex`
- If adding to TS storage, also update Rust code in `native/vdr_ts_nif/src/storage.rs` and `native/vdr_ts_nif/src/lib.rs`
- **CRITICAL**: When adding new read-only TS functions, ALWAYS add corresponding Lua function in `StorageInner::new()`:
  - Follow the existing pattern using `get_tx_ctx()` helper
  - Register the function in the `ts` table
  - Add tests in `ts_proj/` for both direct call and Lua execution via `tx`
  - This ensures feature parity between direct access and Lua transactions
  - Add smoke `integration/` tests
- **CRITICAL**: When adding mutating ts functions:
  - Do not add `ts_proj/` tests. Instead, add `integration/` tetst.
- Add comprehensive documentation with `@doc` and examples
- Add tests in `test/veidrodelis/*_test.exs` (ExUnit). Do not start ad-hoc elixir scripts for testing, add a proper test module instead.
- Ensure proper typespecs for better tooling support
- In ExUnit setup method, do not stop processes started with `start_link`, with `on_exit` callback. They will be shutdown by the test framework.
- **CRITICAL** When adding logging to the tests, do not forget to set appropriate logging level in `test/test_helper.exs`
- **CRITICAL** When adding new commands to the test suite,
  -- first add them to the `issue_diverse_commands` and `verify_streaming_commands` functions in `test/veidrodelis/integration_test.exs`.
  -- Verify how the commands appear in the replica stream
  -- To figure out how the commands appear in the replica stream, use the `CollectorCallback` module in `test/veidrodelis/integration_test.exs` and lookup the commands in the `commands` list by uses key/keys.

### Working with Rust NIFs
- Two Rust crates: `vdr_redis_nif` (parsing) and `vdr_ts_nif` (storage)
- Both use Rustler for Elixir-Rust interop
- Compile automatically via `mix compile` (handled by Rustler)
- LZF compression uses legacy C code, wrapped by Rust NIF
- Rust code should handle errors gracefully and return proper Elixir error tuples

