### Comprehensive List of ZSET Mutating Commands in Replication Stream

This document provides detailed syntax and replication behavior for all Redis sorted set (ZSET) mutating commands that may appear in the replication stream.

---

#### **Score Range Syntax**

Many ZSET commands accept score ranges with special syntax:

- **Numeric scores**: `10`, `5.5`, `-3.14`
- **Infinity**: `-inf` (negative infinity), `+inf` (positive infinity)
- **Exclusive ranges**: `(5` means "exclusive of 5" (values > 5)
- **Inclusive ranges**: `5` or `[5` means "inclusive of 5" (values >= 5)
- **Examples**:
  - `ZREMRANGEBYSCORE key 0 100` — remove members with score >= 0 and <= 100
  - `ZREMRANGEBYSCORE key (0 (100` — remove members with score > 0 and < 100
  - `ZREMRANGEBYSCORE key -inf +inf` — remove all members
  - `ZREMRANGEBYSCORE key -inf (5` — remove members with score < 5

#### **Lexicographic Range Syntax**

For lexicographic ranges (used when all members have the same score):

- **Minimum/Maximum**: `-` (minimum possible), `+` (maximum possible)
- **Exclusive**: `(member` means "exclusive of member"
- **Inclusive**: `[member` means "inclusive of member"
- **Examples**:
  - `ZREMRANGEBYLEX key - +` — remove all members
  - `ZREMRANGEBYLEX key [a [z` — remove members from "a" to "z" (inclusive)
  - `ZREMRANGEBYLEX key (a (z` — remove members between "a" and "z" (exclusive)

---

#### **Basic Write Operations**

| Command | Syntax | Replication Stream | Notes |
| :--- | :--- | :--- | :--- |
| **ZADD** | `ZADD key score member [score member ...]` | `ZADD key score member [score member ...]` | **No change.** Basic form adds or updates members with scores. |
| **ZADD (with options)** | `ZADD key [NX\|XX] [GT\|LT] [CH] score member [score member ...]` | `ZADD key score member [score member ...]` | **Options removed.** Only the actual modifications are replicated. Conditional options (NX, XX, GT, LT) determine *if* the command is replicated, not *how*. CH (changed count) only affects return value. |
| **ZADD INCR** | `ZADD key INCR score member` | `ZADD key "final_score" "member"` | **Converted to simple ZADD.** The primary calculates the final score (existing score + increment) and replicates as a standard ZADD with the final value. Functionally equivalent to ZINCRBY. |
| **ZREM** | `ZREM key member [member ...]` | `ZREM key member [member ...]` | **No change.** Deterministic removal of specific members. |
| **ZINCRBY** | `ZINCRBY key increment member` | `ZADD key "final_score" "member"` | **Converted to ZADD.** The primary calculates the final score and replicates as a ZADD command with the computed value. This ensures replicas have the exact same numeric result. |

---

#### **Pop Operations**

| Command | Syntax | Replication Stream | Notes |
| :--- | :--- | :--- | :--- |
| **ZPOPMIN** | `ZPOPMIN key [count]` | `ZPOPMIN key [count]` | **No change.** Deterministic removal of member(s) with lowest scores. Order is strict: by score (ascending), then lexicographically by member if scores are tied. |
| **ZPOPMAX** | `ZPOPMAX key [count]` | `ZPOPMAX key [count]` | **No change.** Deterministic removal of member(s) with highest scores. Order is strict: by score (descending), then lexicographically by member if scores are tied. |
| **BZPOPMIN** | `BZPOPMIN key [key ...] timeout` | `ZPOPMIN key` | **Converted to ZPOPMIN.** Blocking is a client-side concern. When the operation succeeds, only the non-blocking ZPOPMIN is replicated (for the specific key that was popped). |
| **BZPOPMAX** | `BZPOPMAX key [key ...] timeout` | `ZPOPMAX key` | **Converted to ZPOPMAX.** Same logic as BZPOPMIN. The blocking and multi-key aspects are resolved by the primary. |
| **ZMPOP** | `ZMPOP numkeys key [key ...] <MIN\|MAX> [COUNT count]` | `ZPOPMIN key count` or `ZPOPMAX key count` | **Converted to ZPOPMIN/ZPOPMAX.** Redis 7.0+. The primary selects the first non-empty key and pops from it. Only the actual pop operation on the selected key is replicated. |
| **BZMPOP** | `BZMPOP timeout numkeys key [key ...] <MIN\|MAX> [COUNT count]` | `ZPOPMIN key count` or `ZPOPMAX key count` | **Converted to ZPOPMIN/ZPOPMAX.** Redis 7.0+. Blocking version of ZMPOP. Replicated as non-blocking pop on the key that satisfied the operation. |

---

#### **Range Removal Operations**

| Command | Syntax | Replication Stream | Notes |
| :--- | :--- | :--- | :--- |
| **ZREMRANGEBYRANK** | `ZREMRANGEBYRANK key start stop` | `ZREMRANGEBYRANK key start stop` | **No change.** Deterministic removal by rank/index positions. Rank is 0-based. Negative indices count from the end (-1 is last element). Examples: `ZREMRANGEBYRANK key 0 10` removes first 11 elements, `ZREMRANGEBYRANK key 0 -1` removes all. |
| **ZREMRANGEBYSCORE** | `ZREMRANGEBYSCORE key min max` | `ZREMRANGEBYSCORE key min max` | **No change.** Deterministic removal by score range. See "Score Range Syntax" above for min/max format. Examples: `ZREMRANGEBYSCORE key 0 100`, `ZREMRANGEBYSCORE key (0 (100`, `ZREMRANGEBYSCORE key -inf 5`. |
| **ZREMRANGEBYLEX** | `ZREMRANGEBYLEX key min max` | `ZREMRANGEBYLEX key min max` | **No change.** Deterministic removal by lexicographic range. **Only valid when all members have the same score.** See "Lexicographic Range Syntax" above. Examples: `ZREMRANGEBYLEX key - +`, `ZREMRANGEBYLEX key [a [z`, `ZREMRANGEBYLEX key (member1 (member2`. |

---

#### **Store Operations (Set Operations)**

| Command | Syntax | Replication Stream | Notes |
| :--- | :--- | :--- | :--- |
| **ZUNIONSTORE** | `ZUNIONSTORE dest numkeys key [key ...] [WEIGHTS weight [weight ...]] [AGGREGATE <SUM\|MIN\|MAX>]` | `ZUNIONSTORE dest numkeys key [key ...] [WEIGHTS weight [weight ...]] [AGGREGATE <SUM\|MIN\|MAX>]` | **No change.** Deterministic because the primary first handles any expired keys (by sending DEL commands) before computing the union. Default AGGREGATE is SUM. |
| **ZINTERSTORE** | `ZINTERSTORE dest numkeys key [key ...] [WEIGHTS weight [weight ...]] [AGGREGATE <SUM\|MIN\|MAX>]` | `ZINTERSTORE dest numkeys key [key ...] [WEIGHTS weight [weight ...]] [AGGREGATE <SUM\|MIN\|MAX>]` | **No change.** Deterministic for the same reasons as ZUNIONSTORE. Only members present in ALL input sets are included. Default AGGREGATE is SUM. |
| **ZDIFFSTORE** | `ZDIFFSTORE dest numkeys key [key ...]` | `ZDIFFSTORE dest numkeys key [key ...]` | **No change.** Redis 6.2+. Computes the difference: members in first key but not in any of the other keys. Deterministic after expiration resolution. |

**Store Operation Details:**
- `numkeys` specifies how many keys follow
- `WEIGHTS` multiplies each set's scores by the corresponding weight before aggregation
- `AGGREGATE SUM` (default): resulting score is the sum of scores across input sets
- `AGGREGATE MIN`: resulting score is the minimum score across input sets
- `AGGREGATE MAX`: resulting score is the maximum score across input sets
- If a member exists in only one input set, its score is used directly (even with SUM)
- Example: `ZUNIONSTORE out 2 zset1 zset2 WEIGHTS 2 3 AGGREGATE MAX`

---

#### **Special Cases and Non-Replicated Operations**

| Operation | Replication Behavior |
| :--- | :--- |
| **ZADD with NX (member exists)** | **Not replicated.** If NX option prevents the update, nothing is sent to replicas. |
| **ZADD with XX (member doesn't exist)** | **Not replicated.** If XX option prevents the addition, nothing is sent to replicas. |
| **ZADD with GT (new score not greater)** | **Not replicated.** If GT option prevents the update, nothing is sent to replicas. |
| **ZADD with LT (new score not lesser)** | **Not replicated.** If LT option prevents the update, nothing is sent to replicas. |
| **ZPOPMIN/ZPOPMAX (empty set)** | **Not replicated.** If the sorted set is empty, no state change occurs, so nothing is replicated. |
| **ZREM (non-existent members)** | **May be replicated.** Even if some/all members don't exist, ZREM is typically replicated as-is. The command is idempotent. |
| **Range operations (empty range)** | **May be replicated.** Commands like ZREMRANGEBYRANK with no matching elements are typically still replicated. They're no-ops on replicas too. |

---

#### **Command Summary Table**

| Category | Commands |
| :--- | :--- |
| **Basic Modification** | ZADD, ZREM, ZINCRBY |
| **Pop Operations** | ZPOPMIN, ZPOPMAX, BZPOPMIN, BZPOPMAX, ZMPOP, BZMPOP |
| **Range Removal** | ZREMRANGEBYRANK, ZREMRANGEBYSCORE, ZREMRANGEBYLEX |
| **Set Operations** | ZUNIONSTORE, ZINTERSTORE, ZDIFFSTORE |

---

#### **Version Notes**

- **ZDIFFSTORE**: Available in Redis 6.2+
- **ZMPOP, BZMPOP**: Available in Redis 7.0+
- **ZADD GT/LT options**: Available in Redis 6.2+
- All other commands listed are available in Redis 2.x+ with consistent replication behavior

---

#### **Implementation Notes for Veidrodelis**

When processing ZSET commands in the replication stream:

1. **Score precision**: Use `OrderedFloat` in Rust or equivalent to handle float comparison correctly
2. **Lexicographic ranges**: Only apply when all members in range have identical scores
3. **Range inclusivity**: Pay careful attention to `(` prefix for exclusive bounds vs implicit/`[` prefix for inclusive
4. **ZADD INCR**: Arrives as regular `ZADD` with final score, not as increment
5. **ZINCRBY**: Arrives as regular `ZADD` with final score, not as increment
6. **Blocking commands**: Never appear in replication stream; converted to non-blocking equivalents
7. **Conditional options**: Filtered out before replication; only actual modifications are sent
8. **Empty operations**: May still appear in stream but are safe to process (idempotent)
