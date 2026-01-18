| Command | Since | Group | Flags | ACL Categories | Implemented | Replica Conversion |
|---------|-------|-------|-------|----------------|-------------|-------------------|
| BZMPOP | 7.0.0 | sorted_set | WRITE, BLOCKING | BLOCKING, SLOW, SORTEDSET, WRITE | ✅ | `ZPopMax` or `ZPopMin` |
| BZPOPMAX | 5.0.0 | sorted_set | WRITE, FAST, BLOCKING | BLOCKING, FAST, SORTEDSET, WRITE | ✅ | `ZPopMax` |
| BZPOPMIN | 5.0.0 | sorted_set | WRITE, FAST, BLOCKING | BLOCKING, FAST, SORTEDSET, WRITE | ✅ | `ZPopMin` |
| ZADD | 1.2.0 | sorted_set | WRITE, DENYOOM, FAST | FAST, SORTEDSET, WRITE | ✅ | `ZAdd` |
| ZDIFFSTORE | 6.2.0 | sorted_set | WRITE, DENYOOM | SLOW, SORTEDSET, WRITE | ✅ | `ZDiffStore` |
| ZINCRBY | 1.2.0 | sorted_set | WRITE, DENYOOM, FAST | FAST, SORTEDSET, WRITE | ✅ | `ZAdd` (final score) |
| ZINTERSTORE | 2.0.0 | sorted_set | WRITE, DENYOOM | SLOW, SORTEDSET, WRITE | ✅ | `ZInterStore` |
| ZMPOP | 7.0.0 | sorted_set | WRITE | SLOW, SORTEDSET, WRITE | ✅ | `ZPopMax` or `ZPopMin` |
| ZPOPMAX | 5.0.0 | sorted_set | WRITE, FAST | FAST, SORTEDSET, WRITE | ✅ | `ZPopMax` |
| ZPOPMIN | 5.0.0 | sorted_set | WRITE, FAST | FAST, SORTEDSET, WRITE | ✅ | `ZPopMin` |
| ZRANGESTORE | 6.2.0 | sorted_set | WRITE, DENYOOM | SLOW, SORTEDSET, WRITE | ✅ | `ZRangeStore` |
| ZREM | 1.2.0 | sorted_set | WRITE, FAST | FAST, SORTEDSET, WRITE | ✅ | `ZRem` |
| ZREMRANGEBYLEX | 2.8.9 | sorted_set | WRITE | SLOW, SORTEDSET, WRITE | ✅ | `ZRemRangeByLex` |
| ZREMRANGEBYRANK | 2.0.0 | sorted_set | WRITE | SLOW, SORTEDSET, WRITE | ✅ | `ZRemRangeByRank` |
| ZREMRANGEBYSCORE | 1.2.0 | sorted_set | WRITE | SLOW, SORTEDSET, WRITE | ✅ | `ZRemRangeByScore` |
| ZUNIONSTORE | 2.0.0 | sorted_set | WRITE, DENYOOM | SLOW, SORTEDSET, WRITE | ✅ | `ZUnionStore` |
