| Command | Since | Group | Flags | ACL Categories | Implemented | Replica Conversion |
|---------|-------|-------|-------|----------------|-------------|-------------------|
| BLMOVE | 6.2.0 | list | WRITE, DENYOOM, BLOCKING | LIST | ✅ | `LMove` |
| BLMPOP | 7.0.0 | list | WRITE, BLOCKING | LIST | ✅ | `LPop` with count |
| BLPOP | 2.0.0 | list | WRITE, BLOCKING | LIST | ✅ | `LPop` |
| BRPOP | 2.0.0 | list | WRITE, BLOCKING | LIST | ✅ | `RPop` |
| BRPOPLPUSH | 2.2.0 | list | WRITE, DENYOOM, BLOCKING | LIST | ✅ | `RPopLPush` |
| LINSERT | 2.2.0 | list | WRITE, DENYOOM | LIST | ✅ | `LInsert` |
| LMOVE | 6.2.0 | list | WRITE, DENYOOM | LIST | ✅ | `LMove` |
| LMPOP | 7.0.0 | list | WRITE | LIST | ✅ (via LPOP) | `LPop` with count |
| LPOP | 1.0.0 | list | WRITE, FAST | LIST | ✅ | `LPop` |
| LPUSH | 1.0.0 | list | WRITE, DENYOOM, FAST | LIST | ✅ | `LPush` |
| LPUSHX | 2.2.0 | list | WRITE, DENYOOM, FAST | LIST | ✅ | `LPushX` |
| LREM | 1.0.0 | list | WRITE | LIST | ✅ | `LRem` |
| LSET | 1.0.0 | list | WRITE, DENYOOM | LIST | ✅ | `LSet` |
| LTRIM | 1.0.0 | list | WRITE | LIST | ✅ | `LTrim` |
| RPOP | 1.0.0 | list | WRITE, FAST | LIST | ✅ | `RPop` |
| RPOPLPUSH | 1.2.0 | list | WRITE, DENYOOM | LIST | ✅ | `RPopLPush` |
| RPUSH | 1.0.0 | list | WRITE, DENYOOM, FAST | LIST | ✅ | `RPush` |
| RPUSHX | 2.2.0 | list | WRITE, DENYOOM, FAST | LIST | ✅ | `RPushX` |
