| Command | Since | Group | Flags | ACL Categories | Implemented | Replica Conversion |
|---------|-------|-------|-------|----------------|-------------|-------------------|
| SADD | 1.0.0 | set | WRITE, DENYOOM, FAST | FAST, SET, WRITE | ✅ | SADD |
| SDIFFSTORE | 1.0.0 | set | WRITE, DENYOOM | SET, SLOW, WRITE | ✅ | SDIFFSTORE |
| SINTERSTORE | 1.0.0 | set | WRITE, DENYOOM | SET, SLOW, WRITE | ✅ | SINTERSTORE |
| SMOVE | 1.0.0 | set | WRITE, FAST | FAST, SET, WRITE | ✅ | SMOVE |
| SPOP | 1.0.0 | set | WRITE, FAST | FAST, SET, WRITE | ✅ | SREM |
| SREM | 1.0.0 | set | WRITE, FAST | FAST, SET, WRITE | ✅ | SREM |
| SUNIONSTORE | 1.0.0 | set | WRITE, DENYOOM | SET, SLOW, WRITE | ✅ | SUNIONSTORE |
