| Command | Since | Group | Flags | ACL Categories | Implemented | Replica Conversion |
|---------|-------|-------|-------|----------------|-------------|-------------------|
| COPY | 6.2.0 | generic | WRITE, DENYOOM | KEYSPACE, SLOW, WRITE | ✅ | `Copy` |
| DEL | 1.0.0 | generic | WRITE | KEYSPACE, SLOW, WRITE | ✅ | `Del` |
| EXPIRE | 1.0.0 | generic | WRITE, FAST | FAST, KEYSPACE, WRITE | ✅ (ignored) | `PExpireAt` |
| EXPIREAT | 1.2.0 | generic | WRITE, FAST | FAST, KEYSPACE, WRITE | ✅ (ignored) | `PExpireAt` |
| FLUSHALL | 1.0.0 | server | WRITE, ALL_DBS | DANGEROUS, KEYSPACE, SLOW, WRITE | ✅ | `FlushAll` |
| FLUSHDB | 1.0.0 | server | WRITE | DANGEROUS, KEYSPACE, SLOW, WRITE | ✅ | `FlushDB` |
| MOVE | 1.0.0 | generic | WRITE, FAST | FAST, KEYSPACE, WRITE | ✅ | `Move` |
| PERSIST | 2.2.0 | generic | WRITE, FAST | FAST, KEYSPACE, WRITE | ✅ (ignored) | `Persist` |
| PEXPIRE | 2.6.0 | generic | WRITE, FAST | FAST, KEYSPACE, WRITE | ✅ (ignored) | `PExpireAt` |
| PEXPIREAT | 2.6.0 | generic | WRITE, FAST | FAST, KEYSPACE, WRITE | ✅ (ignored) | `PExpireAt` |
| RENAME | 1.0.0 | generic | WRITE | KEYSPACE, SLOW, WRITE | ✅ | `Rename` |
| RENAMENX | 1.0.0 | generic | WRITE, FAST | FAST, KEYSPACE, WRITE | ✅ | `RenameNX` |
| RESTORE | 2.6.0 | generic | WRITE, DENYOOM | DANGEROUS, KEYSPACE, SLOW, WRITE | 🚫 | `Generic` (serialized RDB payload) |
| SORT | 1.0.0 | generic | WRITE, DENYOOM | DANGEROUS, LIST, SET, SLOW, SORTEDSET, WRITE | 🚫 | `Generic` |
| SWAPDB | 4.0.0 | server | WRITE, FAST | DANGEROUS, FAST, KEYSPACE, WRITE | ✅ | `SwapDB` |
| UNLINK | 4.0.0 | generic | WRITE, FAST | FAST, KEYSPACE, WRITE | ✅ | `Unlink` |
