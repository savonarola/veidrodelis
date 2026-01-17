| Command | Since | Group | Flags | ACL Categories | Implemented | Replica Conversion |
|---------|-------|-------|-------|----------------|-------------|-------------------|
| HDEL | 2.0.0 | hash | WRITE, FAST | FAST, HASH, WRITE | ✅ | `HDel` |
| HEXPIRE | 9.0.0 | hash | WRITE, FAST | FAST, HASH, WRITE | ✅ (ignored) | `HExpire` |
| HEXPIREAT | 9.0.0 | hash | WRITE, FAST | FAST, HASH, WRITE | ✅ (ignored) | `HExpireAt` |
| HGETEX | 9.0.0 | hash | WRITE, FAST | FAST, HASH, WRITE | ✅ (ignored) | `HGetEX` |
| HINCRBY | 2.0.0 | hash | WRITE, DENYOOM, FAST | FAST, HASH, WRITE | ✅ | `HIncrBy` |
| HINCRBYFLOAT | 2.6.0 | hash | WRITE, DENYOOM, FAST | FAST, HASH, WRITE | ✅ | `HSetEX` |
| HMSET | 2.0.0 | hash | WRITE, DENYOOM, FAST | FAST, HASH, WRITE | ✅ | `HMSet` |
| HPERSIST | 9.0.0 | hash | WRITE, FAST | FAST, HASH, WRITE | ✅ (ignored) | `HPersist` |
| HPEXPIRE | 9.0.0 | hash | WRITE, FAST | FAST, HASH, WRITE | ✅ (ignored) | `HPExpire` |
| HPEXPIREAT | 9.0.0 | hash | WRITE, FAST | FAST, HASH, WRITE | ✅ (ignored) | `HPExpireAt` |
| HSET | 2.0.0 | hash | WRITE, DENYOOM, FAST | FAST, HASH, WRITE | ✅ | `HSet` |
| HSETEX | 9.0.0 | hash | WRITE, DENYOOM, FAST | FAST, HASH, WRITE | ✅ | `HSetEX` |
| HSETNX | 2.0.0 | hash | WRITE, DENYOOM, FAST | FAST, HASH, WRITE | ✅ | `HSetNX` |

Note: Expiration-related commands (HEXPIRE, HEXPIREAT, HGETEX, HPERSIST, HPEXPIRE, HPEXPIREAT) are parsed but not applied to TS storage.
