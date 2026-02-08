use super::bytes::Bytes;
use super::types::{StorageValue, ZAddOption, ZSet};
use super::zset_index::{Score, ZSetIndexKey};
use crate::storage::StorageInner;
use ordered_float::OrderedFloat;
use std::collections::{BTreeMap, HashMap};
use std::ops::Bound;

/// Aggregation type for sorted set operations
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Aggregate {
    Sum,
    Min,
    Max,
}

impl StorageInner {
    /// Add members with scores to sorted set.
    /// Supports NX, XX, GT, LT, CH, and INCR options.
    pub fn zadd(
        &mut self,
        db: u64,
        key: &[u8],
        members: &[(Score, &[u8])],
        options: &[ZAddOption],
    ) -> Result<(), &'static str> {
        // Parse options
        let mut nx = false;
        let mut xx = false;
        let mut gt = false;
        let mut lt = false;
        let mut incr = false;

        for opt in options {
            match opt {
                ZAddOption::NX => nx = true,
                ZAddOption::XX => xx = true,
                ZAddOption::GT => gt = true,
                ZAddOption::LT => lt = true,
                ZAddOption::CH => {} // CH only affects return value, ignore in replication
                ZAddOption::INCR => incr = true,
            }
        }

        // Validate: NX and XX are mutually exclusive
        if nx && xx {
            return Err("ERR NX and XX options at the same time are not compatible");
        }

        // Validate: GT/LT conflict with NX
        if (gt || lt) && nx {
            return Err("ERR GT, LT, and/or NX options at the same time are not compatible");
        }

        // INCR requires exactly one score-member pair
        if incr && members.len() != 1 {
            return Err("ERR INCR option supports a single increment-element pair");
        }

        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        // Check if key exists and validate type
        if let Some(val) = db_map.get(key) {
            if !matches!(val, StorageValue::ZSet(_)) {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
            }
        }

        // Get or create the zset
        let zset = db_map
            .entry(Bytes::new(key))
            .or_insert_with(|| StorageValue::ZSet(ZSet::new()));

        let StorageValue::ZSet(zset) = zset else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        for (score, member) in members {
            // Fetch old score once and reuse it
            let old_score = zset.entries.get(*member).copied();
            let exists = old_score.is_some();

            // NX: only add if NOT exists
            if nx && exists {
                continue;
            }

            // XX: only update if exists
            if xx && !exists {
                continue;
            }

            // INCR: increment score
            let final_score = if incr {
                old_score.unwrap_or(OrderedFloat(0.0)) + *score
            } else {
                *score
            };

            // GT/LT: conditional update based on score comparison
            if let Some(old_score) = old_score {
                // GT: only update if new score > old score
                if gt && final_score <= old_score {
                    continue;
                }

                // LT: only update if new score < old score
                if lt && final_score >= old_score {
                    continue;
                }

                // Remove old index entry
                let lookup_key = ZSetIndexKey::create_ref(old_score, member);
                zset.index.remove(&lookup_key);
            }

            // Add new entries
            zset.entries.insert(Bytes::new(member), final_score);
            zset.index.insert(ZSetIndexKey::create(final_score, member));
        }

        Ok(())
    }

    /// Remove members from sorted set.
    pub fn zrem(&mut self, db: u64, key: &[u8], members: &[&[u8]]) -> Result<(), &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        let Some(value) = db_map.get_mut(key) else {
            return Ok(());
        };

        let zset = match value {
            StorageValue::ZSet(zset) => zset,
            _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
        };

        for member in members {
            // Use direct HashMap removal with &[u8]
            if let Some(score) = zset.entries.remove(*member) {
                // Use ZSetIndexKeyRef for removal
                let lookup_key = ZSetIndexKey::create_ref(score, member);
                zset.index.remove(&lookup_key);
            }
        }

        // Remove key if zset is empty
        if zset.is_empty() {
            db_map.remove(key);
        }

        Ok(())
    }

    /// Get the score of a member in sorted set.
    pub fn zscore(
        &self,
        db: u64,
        key: &[u8],
        member: &[u8],
    ) -> Result<Option<Score>, &'static str> {
        let Some(db_map) = self.map.get(&db) else {
            return Ok(None);
        };

        let Some(value) = db_map.get(key) else {
            return Ok(None);
        };

        let StorageValue::ZSet(zset) = value else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        Ok(zset.entries.get(member).copied())
    }

    /// Get the cardinality (number of members) of sorted set.
    pub fn zcard(&self, db: u64, key: &[u8]) -> Result<usize, &'static str> {
        let Some(db_map) = self.map.get(&db) else {
            return Ok(0);
        };

        let Some(value) = db_map.get(key) else {
            return Ok(0);
        };

        let StorageValue::ZSet(zset) = value else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        Ok(zset.len())
    }

    /// Get range of members by index (rank). Supports negative indices.
    /// Returns list of (member, score) tuples.
    pub fn zrange(
        &self,
        db: u64,
        key: &[u8],
        start: i64,
        stop: i64,
        with_scores: bool,
    ) -> Result<Vec<(Bytes, Option<Score>)>, &'static str> {
        let Some(db_map) = self.map.get(&db) else {
            return Ok(Vec::new());
        };

        let Some(value) = db_map.get(key) else {
            return Ok(Vec::new());
        };

        let StorageValue::ZSet(zset) = value else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        let len = zset.len() as i64;

        if len == 0 {
            return Ok(Vec::new());
        }

        // Normalize negative indices
        let start_pos = if start < 0 {
            (len + start).max(0) as usize
        } else {
            start.min(len - 1).max(0) as usize
        };

        let stop_pos = if stop < 0 {
            (len + stop).max(0) as usize
        } else {
            stop.min(len - 1).max(0) as usize
        };

        if start_pos > stop_pos || start_pos >= len as usize {
            return Ok(Vec::new());
        }

        let result: Vec<(Bytes, Option<Score>)> = zset
            .index
            .range_idx(start_pos..=stop_pos)
            .map(|key| {
                let (score, entry) = key.unwrap_key();
                if with_scores {
                    (entry.clone(), Some(*score))
                } else {
                    (entry.clone(), None)
                }
            })
            .collect();

        Ok(result)
    }

    /// Get range of members by score. Returns list of (member, score) tuples.
    /// Optimized to use BTreeSet::range() for O(log n + k) instead of O(n) where k is result size.
    pub fn zrangebyscore(
        &self,
        db: u64,
        key: &[u8],
        min: Score,
        max: Score,
        with_scores: bool,
    ) -> Result<Vec<(Bytes, Option<Score>)>, &'static str> {
        let Some(db_map) = self.map.get(&db) else {
            return Ok(Vec::new());
        };

        let Some(value) = db_map.get(key) else {
            return Ok(Vec::new());
        };

        let StorageValue::ZSet(zset) = value else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        // Create boundary keys for efficient range query
        let min_key = ZSetIndexKey::min_score_key(min);
        let max_key = ZSetIndexKey::max_score_key(max);

        // Use range() for O(log n) seek + O(k) iteration, avoiding full tree scan
        // Note: MaxScoreKey is fictional, so indexset may include entries beyond it
        // We add boundary checks to drop elements that don't fit
        let result: Vec<(Bytes, Option<Score>)> = zset
            .index
            .range::<_, ZSetIndexKey>((Bound::Included(&min_key), Bound::Included(&max_key)))
            .filter_map(|key| {
                let (s, entry) = key.unwrap_key();
                if *s >= min && *s <= max {
                    if with_scores {
                        Some((entry.clone(), Some(*s)))
                    } else {
                        Some((entry.clone(), None))
                    }
                } else {
                    None
                }
            })
            .collect();

        Ok(result)
    }

    /// Get the rank (index) of a member in sorted set (0-based, ascending order).
    pub fn zrank(&self, db: u64, key: &[u8], member: &[u8]) -> Result<Option<usize>, &'static str> {
        let Some(db_map) = self.map.get(&db) else {
            return Ok(None);
        };

        let Some(value) = db_map.get(key) else {
            return Ok(None);
        };

        let StorageValue::ZSet(zset) = value else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        // Use direct HashMap lookup for score with &[u8]
        let Some(score) = zset.entries.get(member) else {
            return Ok(None);
        };

        // Use indexset's efficient rank() method - O(log n) instead of O(n)
        // Use ZSetIndexKeyRef for lookup
        let lookup_key = ZSetIndexKey::create_ref(*score, member);
        let rank = zset.index.rank(&lookup_key);

        Ok(Some(rank))
    }

    /// Get the reverse rank (index from highest to lowest) of a member.
    pub fn zrevrank(
        &self,
        db: u64,
        key: &[u8],
        member: &[u8],
    ) -> Result<Option<usize>, &'static str> {
        let Some(db_map) = self.map.get(&db) else {
            return Ok(None);
        };

        let Some(value) = db_map.get(key) else {
            return Ok(None);
        };

        let StorageValue::ZSet(zset) = value else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        // Use direct HashMap lookup for score with &[u8]
        let Some(score) = zset.entries.get(member) else {
            return Ok(None);
        };

        // Use indexset's efficient rank() method, then convert to reverse rank
        // Reverse rank = (total_count - 1) - rank
        // Use ZSetIndexKeyRef for lookup
        let lookup_key = ZSetIndexKey::create_ref(*score, member);
        let rank = zset.index.rank(&lookup_key);
        let rev_rank = zset.len() - 1 - rank;

        Ok(Some(rev_rank))
    }

    /// Count members in sorted set with scores between min and max (inclusive).
    /// Optimized to use rank difference instead of iteration: O(log n) instead of O(n).
    pub fn zcount(
        &self,
        db: u64,
        key: &[u8],
        min: Score,
        max: Score,
    ) -> Result<usize, &'static str> {
        let Some(db_map) = self.map.get(&db) else {
            return Ok(0);
        };

        let Some(value) = db_map.get(key) else {
            return Ok(0);
        };

        let StorageValue::ZSet(zset) = value else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        // Create boundary keys for the score range
        let min_key = ZSetIndexKey::min_score_key(min);
        let max_key = ZSetIndexKey::max_score_key(max);

        // Get ranks: min_rank is where first element >= min starts,
        // max_rank is where last element <= max ends
        let min_rank = zset.index.rank(&min_key);
        let max_rank = zset.index.rank(&max_key);

        // Count is the difference of ranks
        // Handle inverted range (min > max) by returning 0
        if max_rank < min_rank {
            Ok(0)
        } else {
            Ok(max_rank - min_rank)
        }
    }

    /// Increment the score of a member by delta. Creates member if it doesn't exist.
    pub fn zincrby(
        &mut self,
        db: u64,
        key: &[u8],
        delta: Score,
        member: &[u8],
    ) -> Result<(), &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        // Check if key exists and validate type
        if let Some(val) = db_map.get(key) {
            if !matches!(val, StorageValue::ZSet(_)) {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
            }
        }

        // Get or create the zset
        let zset = db_map
            .entry(Bytes::new(key))
            .or_insert_with(|| StorageValue::ZSet(ZSet::new()));

        let StorageValue::ZSet(zset) = zset else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        // Use direct HashMap lookup for old score with &[u8]
        let old_score = zset
            .entries
            .get(member)
            .copied()
            .unwrap_or(OrderedFloat(0.0));
        let new_score = old_score + delta;

        // Remove old index entry if member existed
        if old_score != OrderedFloat(0.0) || zset.entries.contains_key(member) {
            // Use ZSetIndexKeyRef for removal
            let lookup_key = ZSetIndexKey::create_ref(old_score, member);
            zset.index.remove(&lookup_key);
        }

        // Add new entries
        zset.entries.insert(Bytes::new(member), new_score);
        // Use ZSetIndexKey for insertion
        zset.index.insert(ZSetIndexKey::create(new_score, member));

        Ok(())
    }

    /// Get the first (minimum) member from sorted set.
    /// Returns Some((score, member)) or None if set is empty/doesn't exist.
    pub fn zfirst(&self, db: u64, key: &[u8]) -> Result<Option<(Score, Bytes)>, &'static str> {
        let Some(db_map) = self.map.get(&db) else {
            return Ok(None);
        };

        let Some(value) = db_map.get(key) else {
            return Ok(None);
        };

        let StorageValue::ZSet(zset) = value else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        let result = zset.index.first().and_then(|key| {
            let (score, entry) = key.unwrap_key();
            Some((*score, entry.clone()))
        });
        Ok(result)
    }

    /// Get the last (maximum) member from sorted set.
    /// Returns Some((score, member)) or None if set is empty/doesn't exist.
    pub fn zlast(&self, db: u64, key: &[u8]) -> Result<Option<(Score, Bytes)>, &'static str> {
        let Some(db_map) = self.map.get(&db) else {
            return Ok(None);
        };

        let Some(value) = db_map.get(key) else {
            return Ok(None);
        };

        let StorageValue::ZSet(zset) = value else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        let result = zset.index.last().and_then(|key| {
            let (score, entry) = key.unwrap_key();
            Some((*score, entry.clone()))
        });
        Ok(result)
    }

    /// Get the next member after the given (score, member) in sorted set.
    /// Returns Some((score, member)) or None if no next element exists.
    pub fn znext(
        &self,
        db: u64,
        key: &[u8],
        score: Score,
        member: &[u8],
    ) -> Result<Option<(Score, Bytes)>, &'static str> {
        let Some(db_map) = self.map.get(&db) else {
            return Ok(None);
        };

        let Some(value) = db_map.get(key) else {
            return Ok(None);
        };

        let StorageValue::ZSet(zset) = value else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        let current_key = ZSetIndexKey::create(score, member);
        // Use range starting after the current key
        let range = zset
            .index
            .range::<_, ZSetIndexKey>((Bound::Excluded(&current_key), Bound::Unbounded));
        let result = range.take(1).next().and_then(|key| {
            let (score, entry) = key.unwrap_key();
            Some((*score, entry.clone()))
        });
        Ok(result)
    }

    /// Get the previous member before the given (score, member) in sorted set.
    /// Returns Some((score, member)) or None if no previous element exists.
    pub fn zprev(
        &self,
        db: u64,
        key: &[u8],
        score: Score,
        member: &[u8],
    ) -> Result<Option<(Score, Bytes)>, &'static str> {
        let Some(db_map) = self.map.get(&db) else {
            return Ok(None);
        };

        let Some(value) = db_map.get(key) else {
            return Ok(None);
        };

        let StorageValue::ZSet(zset) = value else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        let current_key = ZSetIndexKey::create(score, member);
        // Use range ending before the current key, get last element
        let range = zset
            .index
            .range::<_, ZSetIndexKey>((Bound::Unbounded, Bound::Excluded(&current_key)));
        let result = range.last().and_then(|key| {
            let (sc, entry) = key.unwrap_key();
            if *sc == score && entry.as_slice() == member {
                None
            } else {
                Some((*sc, entry.clone()))
            }
        });
        Ok(result)
    }

    /// Pop member(s) with highest score from sorted set.
    /// Pops up to `count` members. If count is 0 or greater than set size, pops all available.
    pub fn zpopmax(&mut self, db: u64, key: &[u8], count: usize) -> Result<(), &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        let Some(value) = db_map.get_mut(key) else {
            return Ok(());
        };

        let zset = match value {
            StorageValue::ZSet(zset) => zset,
            _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
        };

        // Pop up to count elements from the end (highest scores)
        for _ in 0..count {
            // Use pop_last to remove the highest score element
            if let Some(index_key) = zset.index.pop_last() {
                let (_, entry) = index_key.unwrap_key();
                // Remove from entries map
                zset.entries.remove(entry.as_slice());
            } else {
                // No more elements
                break;
            }
        }

        // Remove key if zset is empty
        if zset.is_empty() {
            db_map.remove(key);
        }

        Ok(())
    }

    /// Pop member(s) with lowest score from sorted set.
    /// Pops up to `count` members. If count is 0 or greater than set size, pops all available.
    pub fn zpopmin(&mut self, db: u64, key: &[u8], count: usize) -> Result<(), &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        let Some(value) = db_map.get_mut(key) else {
            return Ok(());
        };

        let zset = match value {
            StorageValue::ZSet(zset) => zset,
            _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
        };

        // Pop up to count elements from the beginning (lowest scores)
        for _ in 0..count {
            // Use pop_first to remove the lowest score element
            if let Some(index_key) = zset.index.pop_first() {
                let (_, entry) = index_key.unwrap_key();
                // Remove from entries map
                zset.entries.remove(entry.as_slice());
            } else {
                // No more elements
                break;
            }
        }

        // Remove key if zset is empty
        if zset.is_empty() {
            db_map.remove(key);
        }

        Ok(())
    }

    /// Remove members by rank range (inclusive). Ranks are 0-based.
    pub fn zremrangebyrank(
        &mut self,
        db: u64,
        key: &[u8],
        start: i64,
        stop: i64,
    ) -> Result<(), &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        let Some(value) = db_map.get_mut(key) else {
            return Ok(());
        };

        let zset = match value {
            StorageValue::ZSet(zset) => zset,
            _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
        };

        let len = zset.len() as i64;
        if len == 0 {
            return Ok(());
        }

        // Normalize negative indices
        let start_pos = if start < 0 {
            (len + start).max(0) as usize
        } else {
            start.min(len - 1).max(0) as usize
        };

        let stop_pos = if stop < 0 {
            (len + stop).max(0) as usize
        } else {
            stop.min(len - 1).max(0) as usize
        };

        if start_pos > stop_pos {
            return Ok(());
        }

        // Collect members and scores to remove using range_idx
        let members_to_remove: Vec<(Bytes, Score)> = zset
            .index
            .range_idx(start_pos..=stop_pos)
            .map(|index_key| {
                let (score, entry) = index_key.unwrap_key();
                (entry.clone(), *score)
            })
            .collect();

        // Remove them
        for (member, score) in members_to_remove {
            zset.entries.remove(member.as_slice());
            let lookup_key = ZSetIndexKey::create_ref(score, member.as_slice());
            zset.index.remove(&lookup_key);
        }

        // Remove key if zset is empty
        if zset.is_empty() {
            db_map.remove(key);
        }

        Ok(())
    }

    /// Remove members by score range with flexible bounds (inclusive, exclusive, or unbounded).
    /// Bounds use std::ops::Bound: Unbounded, Included(score), or Excluded(score).
    pub fn zremrangebyscore(
        &mut self,
        db: u64,
        key: &[u8],
        min_bound: std::ops::Bound<Score>,
        max_bound: std::ops::Bound<Score>,
    ) -> Result<(), &'static str> {
        use std::ops::Bound;

        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        let Some(value) = db_map.get_mut(key) else {
            return Ok(());
        };

        let zset = match value {
            StorageValue::ZSet(zset) => zset,
            _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
        };

        // Create boundary keys for efficient range query (similar to zrangebyscore)
        let min_key = match &min_bound {
            Bound::Unbounded => None,
            Bound::Included(score) | Bound::Excluded(score) => {
                Some(ZSetIndexKey::min_score_key(*score))
            }
        };

        let max_key = match &max_bound {
            Bound::Unbounded => None,
            Bound::Included(score) | Bound::Excluded(score) => {
                Some(ZSetIndexKey::max_score_key(*score))
            }
        };

        let start_bound = match &min_key {
            Some(key) => Bound::Included(key),
            None => Bound::Unbounded,
        };

        let end_bound = match &max_key {
            Some(key) => Bound::Included(key),
            None => Bound::Unbounded,
        };

        // Collect members to remove with additional filtering based on actual bounds
        let members_to_remove: Vec<(Bytes, Score)> = zset
            .index
            .range::<_, ZSetIndexKey>((start_bound, end_bound))
            .filter_map(|index_key| {
                let (s, entry) = index_key.unwrap_key();
                // Apply actual bound checks based on the original min/max bounds
                let min_ok = match min_bound {
                    Bound::Unbounded => true,
                    Bound::Included(min) => *s >= min,
                    Bound::Excluded(min) => *s > min,
                };

                let max_ok = match max_bound {
                    Bound::Unbounded => true,
                    Bound::Included(max) => *s <= max,
                    Bound::Excluded(max) => *s < max,
                };

                if min_ok && max_ok {
                    Some((entry.clone(), *s))
                } else {
                    None
                }
            })
            .collect();

        // Remove them
        for (member, score) in members_to_remove {
            zset.entries.remove(member.as_slice());
            let lookup_key = ZSetIndexKey::create_ref(score, member.as_slice());
            zset.index.remove(&lookup_key);
        }

        // Remove key if zset is empty
        if zset.is_empty() {
            db_map.remove(key);
        }

        Ok(())
    }

    /// Remove members by lexicographic range with flexible bounds (inclusive, exclusive, or unbounded).
    /// Bounds use std::ops::Bound: Unbounded, Included(value), or Excluded(value).
    pub fn zremrangebylex(
        &mut self,
        db: u64,
        key: &[u8],
        min_bound: std::ops::Bound<Bytes>,
        max_bound: std::ops::Bound<Bytes>,
    ) -> Result<(), &'static str> {
        use std::ops::Bound;

        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        let Some(value) = db_map.get_mut(key) else {
            return Ok(());
        };

        let zset = match value {
            StorageValue::ZSet(zset) => zset,
            _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
        };

        // Convert Bytes bounds to &[u8] bounds for BTreeMap range query
        let start_bound = match &min_bound {
            Bound::Unbounded => Bound::Unbounded,
            Bound::Included(val) => Bound::Included(val.as_slice()),
            Bound::Excluded(val) => Bound::Excluded(val.as_slice()),
        };

        let end_bound = match &max_bound {
            Bound::Unbounded => Bound::Unbounded,
            Bound::Included(val) => Bound::Included(val.as_slice()),
            Bound::Excluded(val) => Bound::Excluded(val.as_slice()),
        };

        // Collect members to remove using BTreeMap range query on entries
        let members_to_remove: Vec<(Bytes, Score)> = zset
            .entries
            .range::<[u8], _>((start_bound, end_bound))
            .map(|(member, score)| (member.clone(), *score))
            .collect();

        // Remove from both entries and index
        for (member, score) in members_to_remove {
            zset.entries.remove(member.as_slice());
            let lookup_key = ZSetIndexKey::create_ref(score, member.as_slice());
            zset.index.remove(&lookup_key);
        }

        // Remove key if zset is empty
        if zset.is_empty() {
            db_map.remove(key);
        }

        Ok(())
    }

    /// Store union of sorted sets in destination key with weights and aggregation.
    pub fn zunionstore(
        &mut self,
        db: u64,
        dest_key: &[u8],
        source_keys: &[&[u8]],
        weights: &[f64],
        aggregate: Aggregate,
    ) -> Result<(), &'static str> {
        // First delete destination
        self.del(db, dest_key);

        if source_keys.is_empty() {
            return Ok(());
        }

        let Some(db_map) = self.map.get(&db) else {
            return Ok(());
        };

        // Use default weights if not provided
        let default_weights = vec![1.0; source_keys.len()];
        let weights = if weights.is_empty() {
            &default_weights
        } else {
            weights
        };

        // Collect all member-score pairs with weights applied
        let mut union_map: HashMap<Bytes, Vec<Score>> = HashMap::new();

        for (i, source_key) in source_keys.iter().enumerate() {
            let weight = OrderedFloat(*weights.get(i).unwrap_or(&1.0));

            match db_map.get(*source_key) {
                Some(StorageValue::ZSet(zset)) => {
                    for (member, score) in &zset.entries {
                        let weighted_score = *score * weight;
                        union_map
                            .entry(member.clone())
                            .or_insert_with(Vec::new)
                            .push(weighted_score);
                    }
                }
                Some(StorageValue::String(_))
                | Some(StorageValue::List(_))
                | Some(StorageValue::Hash(_))
                | Some(StorageValue::Set(_)) => {
                    return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
                }
                None => continue,
            }
        }

        if !union_map.is_empty() {
            let mut new_zset = ZSet::new();
            for (member, scores) in union_map {
                let final_score = match aggregate {
                    Aggregate::Sum => scores.iter().sum(),
                    Aggregate::Min => *scores.iter().min().unwrap(),
                    Aggregate::Max => *scores.iter().max().unwrap(),
                };
                new_zset.entries.insert(member.clone(), final_score);
                new_zset
                    .index
                    .insert(ZSetIndexKey::create(final_score, member.as_slice()));
            }

            let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);
            db_map.insert(Bytes::new(dest_key), StorageValue::ZSet(new_zset));
        }

        Ok(())
    }

    /// Store intersection of sorted sets in destination key with weights and aggregation.
    pub fn zinterstore(
        &mut self,
        db: u64,
        dest_key: &[u8],
        source_keys: &[&[u8]],
        weights: &[f64],
        aggregate: Aggregate,
    ) -> Result<(), &'static str> {
        // First delete destination
        self.del(db, dest_key);

        if source_keys.is_empty() {
            return Ok(());
        }

        let Some(db_map) = self.map.get(&db) else {
            return Ok(());
        };

        // Use default weights if not provided
        let default_weights = vec![1.0; source_keys.len()];
        let weights = if weights.is_empty() {
            &default_weights
        } else {
            weights
        };

        // Start with first zset
        let first_zset = match db_map.get(source_keys[0]) {
            Some(StorageValue::ZSet(zset)) => zset,
            Some(StorageValue::String(_))
            | Some(StorageValue::List(_))
            | Some(StorageValue::Hash(_))
            | Some(StorageValue::Set(_)) => {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => return Ok(()),
        };

        let weight0 = OrderedFloat(*weights.get(0).unwrap_or(&1.0));
        let mut intersection_map: HashMap<Bytes, Vec<Score>> = first_zset
            .entries
            .iter()
            .map(|(member, score)| (member.clone(), vec![*score * weight0]))
            .collect();

        // Intersect with remaining zsets
        for (i, source_key) in source_keys[1..].iter().enumerate() {
            let weight = OrderedFloat(*weights.get(i + 1).unwrap_or(&1.0));

            match db_map.get(*source_key) {
                Some(StorageValue::ZSet(zset)) => {
                    // Keep only members that exist in both
                    intersection_map.retain(|member, scores| {
                        if let Some(score) = zset.entries.get(member) {
                            scores.push(*score * weight);
                            true
                        } else {
                            false
                        }
                    });
                }
                Some(StorageValue::String(_))
                | Some(StorageValue::List(_))
                | Some(StorageValue::Hash(_))
                | Some(StorageValue::Set(_)) => {
                    return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
                }
                None => {
                    // Intersection with empty set is empty
                    return Ok(());
                }
            }

            if intersection_map.is_empty() {
                return Ok(());
            }
        }

        if !intersection_map.is_empty() {
            let mut new_zset = ZSet::new();
            for (member, scores) in intersection_map {
                let final_score = match aggregate {
                    Aggregate::Sum => scores.iter().sum(),
                    Aggregate::Min => *scores.iter().min().unwrap(),
                    Aggregate::Max => *scores.iter().max().unwrap(),
                };
                new_zset.entries.insert(member.clone(), final_score);
                new_zset
                    .index
                    .insert(ZSetIndexKey::create(final_score, member.as_slice()));
            }

            let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);
            db_map.insert(Bytes::new(dest_key), StorageValue::ZSet(new_zset));
        }

        Ok(())
    }

    /// Store difference of sorted sets in destination key (members in first set but not in others).
    pub fn zdiffstore(
        &mut self,
        db: u64,
        dest_key: &[u8],
        source_keys: &[&[u8]],
    ) -> Result<(), &'static str> {
        // First delete destination
        self.del(db, dest_key);

        if source_keys.is_empty() {
            return Ok(());
        }

        let Some(db_map) = self.map.get(&db) else {
            return Ok(());
        };

        // Start with first zset
        let first_zset = match db_map.get(source_keys[0]) {
            Some(StorageValue::ZSet(zset)) => zset,
            Some(StorageValue::String(_))
            | Some(StorageValue::List(_))
            | Some(StorageValue::Hash(_))
            | Some(StorageValue::Set(_)) => {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => return Ok(()),
        };

        // Clone members from first set
        let mut diff_map: HashMap<Bytes, Score> = first_zset
            .entries
            .iter()
            .map(|(member, score)| (member.clone(), *score))
            .collect();

        // Remove members that exist in any of the other sets
        for source_key in source_keys.iter().skip(1) {
            match db_map.get(*source_key) {
                Some(StorageValue::ZSet(zset)) => {
                    // Remove any member that exists in this zset
                    for member in zset.entries.keys() {
                        diff_map.remove(member);
                    }
                }
                Some(StorageValue::String(_))
                | Some(StorageValue::List(_))
                | Some(StorageValue::Hash(_))
                | Some(StorageValue::Set(_)) => {
                    return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
                }
                None => continue,
            }
        }

        if !diff_map.is_empty() {
            let mut new_zset = ZSet::new();
            for (member, score) in diff_map {
                new_zset.entries.insert(member.clone(), score);
                new_zset
                    .index
                    .insert(ZSetIndexKey::create(score, member.as_slice()));
            }

            let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);
            db_map.insert(Bytes::new(dest_key), StorageValue::ZSet(new_zset));
        }

        Ok(())
    }

    /// Store a range of members from a sorted set into destination key.
    /// Supports BYRANK (default), BYSCORE, BYLEX, REV, and LIMIT options.
    pub fn zrangestore(
        &mut self,
        db: u64,
        dest_key: &[u8],
        source_key: &[u8],
        min_str: &str,
        max_str: &str,
        by_score: bool,
        by_lex: bool,
        rev: bool,
        limit: Option<(i64, i64)>, // (offset, count)
    ) -> Result<(), &'static str> {
        // First delete destination
        self.del(db, dest_key);

        let Some(db_map) = self.map.get(&db) else {
            return Ok(());
        };

        let source_zset = match db_map.get(source_key) {
            Some(StorageValue::ZSet(zset)) => zset,
            Some(StorageValue::String(_))
            | Some(StorageValue::List(_))
            | Some(StorageValue::Hash(_))
            | Some(StorageValue::Set(_)) => {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => return Ok(()),
        };

        if source_zset.is_empty() {
            return Ok(());
        }

        let mut new_zset = ZSet::new();

        if by_lex {
            // BYLEX: lexicographic range using entries.range() for efficiency
            let min_bound = self.parse_lex_bound(min_str)?;
            let max_bound = self.parse_lex_bound(max_str)?;

            // Convert Bytes bounds to &[u8] bounds for range query
            let start_bound = match &min_bound {
                std::ops::Bound::Unbounded => std::ops::Bound::Unbounded,
                std::ops::Bound::Included(val) => std::ops::Bound::Included(val.as_slice()),
                std::ops::Bound::Excluded(val) => std::ops::Bound::Excluded(val.as_slice()),
            };

            let end_bound = match &max_bound {
                std::ops::Bound::Unbounded => std::ops::Bound::Unbounded,
                std::ops::Bound::Included(val) => std::ops::Bound::Included(val.as_slice()),
                std::ops::Bound::Excluded(val) => std::ops::Bound::Excluded(val.as_slice()),
            };

            let mut collected: Vec<(Bytes, Score)> = source_zset
                .entries
                .range::<[u8], _>((start_bound, end_bound))
                .map(|(member, score)| (member.clone(), *score))
                .collect();

            if rev {
                collected.reverse();
            }

            // Apply LIMIT if specified
            let collected = self.apply_limit(collected, limit);

            for (member, score) in collected {
                new_zset.entries.insert(member.clone(), score);
                new_zset
                    .index
                    .insert(ZSetIndexKey::create(score, member.as_slice()));
            }
        } else if by_score {
            // BYSCORE: score range using index.range() for efficiency
            let min_bound = self.parse_score_bound(min_str)?;
            let max_bound = self.parse_score_bound(max_str)?;

            // Create boundary keys for efficient range query
            let min_key = match &min_bound {
                std::ops::Bound::Unbounded => None,
                std::ops::Bound::Included(score) | std::ops::Bound::Excluded(score) => {
                    Some(ZSetIndexKey::min_score_key(*score))
                }
            };

            let max_key = match &max_bound {
                std::ops::Bound::Unbounded => None,
                std::ops::Bound::Included(score) | std::ops::Bound::Excluded(score) => {
                    Some(ZSetIndexKey::max_score_key(*score))
                }
            };

            let start_key_bound: std::ops::Bound<&ZSetIndexKey> = match &min_key {
                Some(key) => std::ops::Bound::Included(key),
                None => std::ops::Bound::Unbounded,
            };

            let end_key_bound: std::ops::Bound<&ZSetIndexKey> = match &max_key {
                Some(key) => std::ops::Bound::Included(key),
                None => std::ops::Bound::Unbounded,
            };

            let mut collected: Vec<(Bytes, Score)> = source_zset
                .index
                .range::<_, ZSetIndexKey>((start_key_bound, end_key_bound))
                .filter_map(|key| {
                    let (score, entry) = key.unwrap_key();
                    if self.score_in_range(*score, &min_bound, &max_bound) {
                        Some((entry.clone(), *score))
                    } else {
                        None
                    }
                })
                .collect();

            if rev {
                collected.reverse();
            }

            // Apply LIMIT if specified
            let collected = self.apply_limit(collected, limit);

            for (member, score) in collected {
                new_zset.entries.insert(member.clone(), score);
                new_zset
                    .index
                    .insert(ZSetIndexKey::create(score, member.as_slice()));
            }
        } else {
            // BYRANK (default): rank-based range
            let min_rank = min_str.parse::<i64>().map_err(|_| "invalid min rank")?;
            let max_rank = max_str.parse::<i64>().map_err(|_| "invalid max rank")?;

            let len = source_zset.len() as i64;

            // Normalize negative indices
            let start = if min_rank < 0 {
                ((len + min_rank).max(0)) as usize
            } else {
                min_rank.min(len) as usize
            };
            let stop = if max_rank < 0 {
                ((len + max_rank).max(0)) as usize
            } else {
                max_rank.min(len - 1) as usize
            };

            if start <= stop && start < source_zset.len() {
                let range_iter: Box<dyn Iterator<Item = &ZSetIndexKey>> = if rev {
                    Box::new(source_zset.index.range_idx(start..=stop).rev())
                } else {
                    Box::new(source_zset.index.range_idx(start..=stop))
                };

                let mut collected: Vec<(Bytes, Score)> = Vec::new();
                for key in range_iter {
                    let (score, entry) = key.unwrap_key();
                    collected.push((entry.clone(), *score));
                }

                // Apply LIMIT if specified
                let collected = self.apply_limit(collected, limit);

                for (member, score) in collected {
                    new_zset.entries.insert(member.clone(), score);
                    new_zset
                        .index
                        .insert(ZSetIndexKey::create(score, member.as_slice()));
                }
            }
        }

        if !new_zset.is_empty() {
            let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);
            db_map.insert(Bytes::new(dest_key), StorageValue::ZSet(new_zset));
        }

        Ok(())
    }

    fn apply_limit(
        &self,
        items: Vec<(Bytes, Score)>,
        limit: Option<(i64, i64)>,
    ) -> Vec<(Bytes, Score)> {
        if let Some((offset, count)) = limit {
            let offset = offset.max(0) as usize;
            let count = count.max(0) as usize;

            items.into_iter().skip(offset).take(count).collect()
        } else {
            items
        }
    }

    fn parse_score_bound(&self, s: &str) -> Result<std::ops::Bound<Score>, &'static str> {
        use std::ops::Bound;

        if s == "-inf" {
            Ok(Bound::Unbounded)
        } else if s == "+inf" {
            Ok(Bound::Unbounded)
        } else if let Some(stripped) = s.strip_prefix('(') {
            // Exclusive bound
            let score = stripped.parse::<f64>().map_err(|_| "invalid score")?;
            Ok(Bound::Excluded(OrderedFloat(score)))
        } else {
            // Inclusive bound
            let score = s.parse::<f64>().map_err(|_| "invalid score")?;
            Ok(Bound::Included(OrderedFloat(score)))
        }
    }

    fn parse_lex_bound(&self, s: &str) -> Result<std::ops::Bound<Bytes>, &'static str> {
        use std::ops::Bound;

        if s == "-" {
            Ok(Bound::Unbounded)
        } else if s == "+" {
            Ok(Bound::Unbounded)
        } else if let Some(stripped) = s.strip_prefix('[') {
            // Inclusive bound
            Ok(Bound::Included(Bytes::new(stripped.as_bytes())))
        } else if let Some(stripped) = s.strip_prefix('(') {
            // Exclusive bound
            Ok(Bound::Excluded(Bytes::new(stripped.as_bytes())))
        } else {
            Err("invalid lex bound")
        }
    }

    fn score_in_range(
        &self,
        score: Score,
        min: &std::ops::Bound<Score>,
        max: &std::ops::Bound<Score>,
    ) -> bool {
        use std::ops::Bound;

        let min_ok = match min {
            Bound::Unbounded => true,
            Bound::Included(s) => score >= *s,
            Bound::Excluded(s) => score > *s,
        };

        let max_ok = match max {
            Bound::Unbounded => true,
            Bound::Included(s) => score <= *s,
            Bound::Excluded(s) => score < *s,
        };

        min_ok && max_ok
    }
}
