| Command | Since | Group | Flags | ACL Categories | Implemented | Replica Conversion |
|---------|-------|-------|-------|----------------|-------------|-------------------|
| APPEND | 2.0.0 | string | WRITE, DENYOOM, FAST | FAST, STRING, WRITE | ✅ | `Append` |
| DECR | 1.0.0 | string | WRITE, DENYOOM, FAST | FAST, STRING, WRITE | ✅ | `Decr` |
| DECRBY | 1.0.0 | string | WRITE, DENYOOM, FAST | FAST, STRING, WRITE | ✅ | `DecrBy` |
| DELIFEQ | 9.0.0 | string | FAST, WRITE | FAST, STRING, WRITE | ✅ (Valkey) | `Del` |
| GETDEL | 6.2.0 | string | WRITE, FAST | FAST, STRING, WRITE | ✅ | `Del` |
| GETEX | 6.2.0 | string | WRITE, FAST | FAST, STRING, WRITE | ✅ | `Set` + `PExpireAt` |
| GETSET | 1.0.0 | string | WRITE, DENYOOM, FAST | FAST, STRING, WRITE | ✅ | `Set` |
| INCR | 1.0.0 | string | WRITE, DENYOOM, FAST | FAST, STRING, WRITE | ✅ | `Incr` |
| INCRBY | 1.0.0 | string | WRITE, DENYOOM, FAST | FAST, STRING, WRITE | ✅ | `IncrBy` |
| INCRBYFLOAT | 2.6.0 | string | WRITE, DENYOOM, FAST | FAST, STRING, WRITE | ✅ | `Set` |
| MSET | 1.0.1 | string | WRITE, DENYOOM | SLOW, STRING, WRITE | ✅ | `MSet` |
| MSETNX | 1.0.1 | string | WRITE, DENYOOM | SLOW, STRING, WRITE | ✅ | `MSetNX` |
| PSETEX | 2.6.0 | string | WRITE, DENYOOM | SLOW, STRING, WRITE | ✅ | `Set` |
| SET | 1.0.0 | string | WRITE, DENYOOM | SLOW, STRING, WRITE | ✅ | `Set` |
| SETEX | 2.0.0 | string | WRITE, DENYOOM | SLOW, STRING, WRITE | ✅ | `Set` |
| SETNX | 1.0.0 | string | WRITE, DENYOOM, FAST | FAST, STRING, WRITE | ✅ | `SetNX` |
| SETRANGE | 2.2.0 | string | WRITE, DENYOOM | SLOW, STRING, WRITE | ✅ | `SetRange` |

Note: Commands marked with multiple types (e.g., `Set` + `PExpireAt`) indicate the command is replicated as multiple separate commands.
