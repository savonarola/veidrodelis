# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Veidrodelis is an Elixir library for parsing Redis RDB (Redis Database) files. It implements a complete RDB parser supporting format versions 1-12, with a callback-based architecture for extensible data processing.

The project is implemented in **pure Elixir** with C NIFs for LZF compression/decompression performance.

## Build and Development Commands

### Building
```bash
# Fetch dependencies and compile everything (including C NIFs)
mix deps.get
mix compile

# The compile step automatically builds the C NIF via elixir_make
```

### Running
```bash
# Start IEx with the application loaded
iex -S mix
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
lib/                          # Elixir source code
├── veidrodelis.ex           # Main module with documentation
├── veidrodelis/
│   ├── application.ex       # OTP application
│   ├── redis_stream/
│   │   ├── rdb.ex          # RDB parser implementation
│   │   ├── command.ex      # Redis command structs
│   │   ├── nif.ex          # Rust NIF interface
│   │   ├── parser.ex       # Replica parser (replication stream)
│   │   ├── callback.ex     # RedisStream callback behaviour
│   │   └── replica.ex      # Replica client
│   └── lzf.ex              # LZF NIF wrapper and interface

c_src/                        # C source for NIFs
├── Makefile                 # C build configuration
├── vdr_lzf_nif.c           # LZF NIF implementation
├── lzf_c.c, lzf_d.c        # LZF algorithm
└── lzf.h, lzfP.h           # LZF headers

test/                         # ExUnit tests
├── test_helper.exs          # Test configuration
├── veidrodelis/
│   ├── rdb_test.exs        # RDB parser tests
│   └── lzf_test.exs        # LZF compression tests
└── assets/
    └── dump.rdb             # Test RDB file
```

## Architecture

### Pure Elixir Design

The project is implemented entirely in Elixir, leveraging the language's excellent binary pattern matching and functional programming capabilities for efficient RDB parsing.

### Core Components

**RDB Parser ([lib/veidrodelis/redis_stream/rdb.ex](lib/veidrodelis/redis_stream/rdb.ex))**
- Rust-based RDB parser with Elixir wrapper
- Entry point: `Vdr.RedisStream.RDB.create()` and `Vdr.RedisStream.RDB.data(parser, chunk)`
- Stateless streaming parser that processes opcodes sequentially
- Supports all Redis data types: strings, lists, sets, sorted sets, hashes
- Handles multiple encoding formats: ziplist, listpack, intset, quicklist variants
- Comprehensive documentation and examples
- Type specifications for better tooling support

**RedisStream Callback Behavior ([lib/veidrodelis/redis_stream/callback.ex](lib/veidrodelis/redis_stream/callback.ex))**
- Defines a single callback: `on_command/3`
- Called for each parsed Redis command with command structs
- Returns: `{:ok, new_state}` or `{:error, reason}`

**Command Structs ([lib/veidrodelis/redis_stream/command.ex](lib/veidrodelis/redis_stream/command.ex))**
- Represents Redis write commands that would have created the RDB data
- `%Command.Set{key, value}` - SET command for string values
- `%Command.RPush{key, value}` - RPUSH command for list elements
- `%Command.SAdd{key, member}` - SADD command for set members
- `%Command.ZAdd{key, score, member}` - ZADD command for sorted set members
- `%Command.HSet{key, field, value}` - HSET command for hash fields

**LZF Compression NIF ([lib/veidrodelis/lzf.ex](lib/veidrodelis/lzf.ex))**
- Native Implemented Function for LZF compression/decompression
- Elixir module with C implementation in [c_src/](c_src/) directory
- Functions: `compress/1`, `decompress/2`
- Automatically loaded on module initialization via `@on_load`
- Uses NIFs for maximum performance on compression/decompression operations

### Design Patterns

**Command-Based Callback Interface**
Instead of separate callbacks for each data type, the parser uses a single `on_command/3` callback that receives Redis command structs. Each parsed element is represented as the Redis command that would have created it:
- `SET` for strings
- `RPUSH` for list elements (one command per element)
- `SADD` for set members (one command per member)
- `ZADD` for sorted set members (one command per member)
- `HSET` for hash fields (one command per field)

This design provides:
- A unified, intuitive interface
- Direct mapping to Redis operations
- Pattern matching on command types in callbacks
- Memory-efficient streaming of large RDB files

**Binary Pattern Matching**
Heavy use of Elixir's binary pattern matching (via the Bitwise module) for efficient parsing of various encoding formats (length encoding, string encoding, ziplist, listpack, intset).

**Error Handling**
- Parser uses `try/catch` for control flow on errors
- Unsupported types are skipped gracefully when possible
- All user callbacks can return `{:error, reason}` to halt parsing

### C NIF Integration

The NIF is compiled using `elixir_make`:
- Root [Makefile](Makefile) delegates to [c_src/Makefile](c_src/Makefile)
- Automatically invoked during `mix compile`
- Output: `priv/vdr_lzf_nif.so`

## Redis RDB Format Details

The parser handles:
- **Opcodes**: EOF, SELECTDB, EXPIRETIME, EXPIRETIME_MS, RESIZEDB, AUX
- **Value Types**: STRING, LIST, SET, ZSET, ZSET_2, HASH, and their encoded variants
- **Encodings**: Integer encoding (8/16/32-bit), LZF compression
- **Compressed Structures**: ZIPLIST, LISTPACK, INTSET, QUICKLIST, QUICKLIST_2

Expire times and auxiliary fields are currently skipped during parsing.

## Testing

### Test Structure
- ExUnit tests in [test/veidrodelis/](test/veidrodelis/)
- Test assets (sample RDB files) in [test/assets/](test/assets/)
- Tests demonstrate callback implementation patterns

### Running Tests
```bash
# Run all tests
mix test

# Run with coverage
mix test --cover

# Run only RDB parser tests
mix test test/veidrodelis/rdb_test.exs

# Run only LZF tests
mix test test/veidrodelis/lzf_test.exs
```

## Implementation Notes

When working with the RDB parser:
- Binary parsing uses little-endian for most integers (Redis convention)
- Ziplist/listpack entries contain back-length fields for reverse traversal
- Sorted set scores can be float, NaN, or infinity values
- Hash and sorted set entries are always paired (field/value or member/score)

When adding new features:
- Implement in Elixir in `lib/veidrodelis/*.ex`
- Update the callback behavior if changing the interface
- Add comprehensive documentation with `@doc` and examples
- Add tests in `test/veidrodelis/*_test.exs` (ExUnit)
- Ensure proper typespecs for better tooling support
