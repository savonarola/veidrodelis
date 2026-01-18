| Command | Since | Group | Flags | ACL Categories | Implemented | Replica Conversion |
|---------|-------|-------|-------|----------------|-------------|-------------------|
| BLMOVE | 6.2.0 | list | WRITE, DENYOOM, BLOCKING | LIST | `No` | LMOVE |
| BLMPOP | 7.0.0 | list | WRITE, BLOCKING | LIST | `No` | LPOP with count |
| BLPOP | 2.0.0 | list | WRITE, BLOCKING | LIST | `No` | LPOP |
| BRPOP | 2.0.0 | list | WRITE, BLOCKING | LIST | `No` | RPOP |
| BRPOPLPUSH | 2.2.0 | list | WRITE, DENYOOM, BLOCKING | LIST | `No` | RPOPLPUSH |
| LINSERT | 2.2.0 | list | WRITE, DENYOOM | LIST | ✅ | LINSERT |
| LMOVE | 6.2.0 | list | WRITE, DENYOOM | LIST | ✅ | LMOVE |
| LMPOP | 7.0.0 | list | WRITE | LIST | ✅ (via LPOP) | LPOP with count |
| LPOP | 1.0.0 | list | WRITE, FAST | LIST | ✅ | LPOP |
| LPUSH | 1.0.0 | list | WRITE, DENYOOM, FAST | LIST | ✅ | LPUSH |
| LPUSHX | 2.2.0 | list | WRITE, DENYOOM, FAST | LIST | ✅ | LPUSHX |
| LREM | 1.0.0 | list | WRITE | LIST | ✅ | LREM |
| LSET | 1.0.0 | list | WRITE, DENYOOM | LIST | ✅ | LSET |
| LTRIM | 1.0.0 | list | WRITE | LIST | ✅ | LTRIM |
| RPOP | 1.0.0 | list | WRITE, FAST | LIST | ✅ | RPOP |
| RPOPLPUSH | 1.2.0 | list | WRITE, DENYOOM | LIST | ✅ | RPOPLPUSH |
| RPUSH | 1.0.0 | list | WRITE, DENYOOM, FAST | LIST | ✅ | RPUSH |
| RPUSHX | 2.2.0 | list | WRITE, DENYOOM, FAST | LIST | ✅ | RPUSHX |
