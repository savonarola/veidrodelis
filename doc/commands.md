### Full List of Replicated Commands

Here is the comprehensive list of how write commands for Strings, Lists, Hashes, Sets, and ZSETs, including expirations and deletions, appear in the replication stream (the "channel").

#### **Generic and Key-Level Commands**

| Client Command | Replication Stream Command / Explanation |
| :--- | :--- |
| `DEL key1 key2 ...` | `DEL key1 key2 ...` | **No change.** This is a fundamental, deterministic write command. |
| *(Key Expiration)* | `DEL key` | **Synthesized `DEL` command.** This is a critical concept. When a key with a TTL expires on the primary (due to its internal clock), the primary does not just let the key vanish. It actively generates a `DEL key` command and sends it down the replication channel. This ensures replicas delete the key at the exact same logical point in the stream, preventing data divergence. |
| `EXPIRE key 60` <br> `PEXPIRE key 60000` | `PEXPIREAT key <timestamp_ms>` | **Converted to absolute time.** All relative expirations are converted to an absolute Unix timestamp in milliseconds to prevent inconsistencies due to clock drift between servers. |
| `EXPIREAT key <timestamp_sec>` <br> `PEXPIREAT key <timestamp_ms>` | `PEXPIREAT key <timestamp_ms>` | **Normalized to milliseconds.** All absolute time expirations are normalized to the millisecond-precision version of the command. |
| `RENAME key newkey` | `RENAME key newkey` | **No change.** Deterministic. |
| `RENAMENX key newkey` | `RENAMENX key newkey` | **No change.** Deterministic (conditional). |
| `MOVE key db` | `MOVE key db` | **No change.** Deterministic. |

#### **Strings**

| Client Command | Replication Stream Command / Explanation |
| :--- | :--- |
| `SET key "value"` | `SET key "value"` | **No change.** |
| `SET key "v" EX 60` <br> `SETEX key 60 "v"` <br> `PSETEX key 60000 "v"` | `SET key "v"` <br> `PEXPIREAT key <timestamp_ms>` | **Split and converted.** The command is split. The `SET` is replicated, and the relative expiry is converted into a separate, absolute `PEXPIREAT` command. |
| `SETNX key "value"` | `SET key "value"` | **Replicated as `SET` (if successful).** If the operation succeeds on the primary, a simple `SET` is sent. If it fails (key already exists), nothing is replicated. |
| `MSET k1 "v1" k2 "v2"` | `MSET k1 "v1" k2 "v2"` | **No change.** |
| `INCR key` <br> `DECR key` | `SET key "final_value"` | **Converted to `SET`.** The primary calculates the final numeric value and sends a `SET` command to ensure all replicas have the identical result. |
| `INCRBY key 10` <br> `DECRBY key 10` <br> `INCRBYFLOAT key 1.5` | `SET key "final_value"` | **Converted to `SET`.** Same logic as `INCR`. |
| `GETSET key "new_value"` | `SET key "new_value"` | **Replicated as `SET`.** The `GET` part is a client reply; the state change is just a `SET`, which is what gets replicated. |
| `APPEND key "data"` | `APPEND key "data"` | **No change.** |
| `SETRANGE key offset "v"` | `SETRANGE key offset "v"` | **No change.** |
| `SETBIT key offset 1` | `SETBIT key offset 1` | **No change.** |

#### **Lists**

| Client Command | Replication Stream Command / Explanation |
| :--- | :--- |
| `LPUSH key e1 e2` <br> `RPUSH key e1 e2` | `LPUSH key e1 e2` <br> `RPUSH key e1 e2` | **No change.** |
| `LPUSHX key e1` <br> `RPUSHX key e1` | `LPUSHX key e1` <br> `RPUSHX key e1` | **No change.** |
| `LPOP key` <br> `RPOP key` | `LPOP key` <br> `RPOP key` | **No change.** Deterministic removal from ends. |
| `LREM key count "value"` | `LREM key count "value"` | **No change.** |
| `LTRIM key start stop` | `LTRIM key start stop` | **No change.** |
| `LSET key index "value"` | `LSET key index "value"` | **No change.** |
| `LINSERT key BEFORE p e` | `LINSERT key BEFORE p e` | **No change.** |
| `RPOPLPUSH src dest` | `RPOPLPUSH src dest` | **No change.** |

#### **Hashes**

| Client Command | Replication Stream Command / Explanation |
| :--- | :--- |
| `HSET key f1 v1 f2 v2` | `HSET key f1 v1 f2 v2` | **No change.** |
| `HDEL key f1 f2` | `HDEL key f1 f2` | **No change.** |
| `HINCRBY key field 5` <br> `HINCRBYFLOAT key f 1.5` | `HSET key field "final_value"` | **Converted to `HSET`.** The primary calculates the final value and sends a deterministic `HSET` to update the field on replicas. |
| `HSETNX key field "value"` | `HSET key field "value"` | **Replicated as `HSET` (if successful).** If the field is newly set, a standard `HSET` is replicated. |

#### **Sets**

| Client Command | Replication Stream Command / Explanation |
| :--- | :--- |
| `SADD key m1 m2` | `SADD key m1 m2` | **No change.** |
| `SREM key m1 m2` | `SREM key m1 m2` | **No change.** |
| `SPOP key count` | `SREM key "chosen_m1" "chosen_m2"` | **Converted to `SREM`.** `SPOP` is non-deterministic. The primary randomly selects member(s), then sends a deterministic `SREM` command with the *specific members it chose* to the replicas. |
| `SMOVE source dest member` | `SMOVE source dest member` | **No change.** |
| `SINTERSTORE dest k1 k2` <br> `SUNIONSTORE dest k1 k2` <br> `SDIFFSTORE dest k1 k2` | `SINTERSTORE dest k1 k2` <br> `SUNIONSTORE dest k1 k2` <br> `SDIFFSTORE dest k1 k2` | **No change.** These are deterministic because the primary first resolves any key expirations (by sending `DEL` commands) before sending the store command itself. |

#### **Sorted Sets (ZSETs)**

| Client Command | Replication Stream Command / Explanation |
| :--- | :--- |
| `ZADD key s1 m1 s2 m2` | `ZADD key s1 m1 s2 m2` | **No change.** |
| `ZREM key m1 m2` | `ZREM key m1 m2` | **No change.** |
| `ZINCRBY key inc member` | `ZADD key "final_score" "member"` | **Converted to `ZADD`.** The primary calculates the final score and sends a `ZADD` (which also updates) with that specific score. |
| `ZPOPMAX key` <br> `ZPOPMIN key` | `ZPOPMAX key` <br> `ZPOPMIN key` | **No change.** These are deterministic. The order is strictly defined by score, then by the lexicographical order of members if scores are tied. |
| `ZREMRANGEBYRANK key s stop` | `ZREMRANGEBYRANK key s stop` | **No change.** |
| `ZREMRANGEBYSCORE key min max` | `ZREMRANGEBYSCORE key min max` | **No change.** |
| `ZREMRANGEBYLEX key min max` | `ZREMRANGEBYLEX key min max` | **No change.** |
| `ZUNIONSTORE dest ...` <br> `ZINTERSTORE dest ...` | `ZUNIONSTORE dest ...` <br> `ZINTERSTORE dest ...` | **No change.** Deterministic for the same reasons as set-store operations. |
