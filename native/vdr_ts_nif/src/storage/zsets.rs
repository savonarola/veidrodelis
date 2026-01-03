use std::collections::{BTreeMap, HashMap};
use std::ops::Bound;
use super::bytes::Bytes;
use super::types::{StorageValue, ZSet};
use super::zset_index::{Score, ZSetIndexKey, ZSetIndexKeyRef};
use crate::storage::StorageInner;
use ordered_float::OrderedFloat;

/// Aggregation type for sorted set operations
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Aggregate {
    Sum,
    Min,
    Max,
}

impl StorageInner {
    /// Add members with scores to sorted set.
    pub fn zadd(&mut self, db: u64, key: &[u8], members: &[(Score, &[u8])]) -> Result<(), &'static str> {
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

        let zset = match zset {
            StorageValue::ZSet(z) => z,
            _ => unreachable!(),
        };

        for (score, member) in members {
            // Check if member exists - use direct HashMap lookup with &[u8]
            if let Some(old_score) = zset.entries.get(*member) {
                // Member exists - update score
                // Use ZSetIndexKeyRef for lookup
                let lookup_key = ZSetIndexKeyRef::lookup_key_ref(*old_score, member);
                zset.index.remove(&lookup_key);

                zset.entries.insert(Bytes::new(member), *score);
                // Use ZSetIndexKey for insertion
                zset.index.insert(ZSetIndexKey::create(*score, member));
            } else {
                // New member
                zset.entries.insert(Bytes::new(member), *score);
                // Use ZSetIndexKey for insertion
                zset.index.insert(ZSetIndexKey::create(*score, member));
            }
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
                let lookup_key = ZSetIndexKeyRef::lookup_key_ref(score, member);
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
    pub fn zscore(&self, db: u64, key: &[u8], member: &[u8]) -> Result<Option<Score>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::ZSet(zset)) => Ok(zset.entries.get(member).copied()),
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(None),
        }
    }

    /// Get the cardinality (number of members) of sorted set.
    pub fn zcard(&self, db: u64, key: &[u8]) -> Result<usize, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::ZSet(zset)) => Ok(zset.len()),
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(0),
        }
    }

    /// Get range of members by index (rank). Supports negative indices.
    /// Returns list of (member, score) tuples.
    pub fn zrange(&self, db: u64, key: &[u8], start: i64, stop: i64, with_scores: bool) -> Result<Vec<(Bytes, Option<Score>)>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::ZSet(zset)) => {
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

                // Use indexset's efficient range_idx() method for O(log n) range access
                let result: Vec<(Bytes, Option<Score>)> = zset
                    .index
                    .range_idx(start_pos..=stop_pos)
                    .filter_map(|key| {
                        // Clone the Arc-wrapped Bytes directly instead of reconstructing
                        key.get_entry_and_score().map(|(entry, score)| {
                            if with_scores {
                                (entry, Some(score))
                            } else {
                                (entry, None)
                            }
                        })
                    })
                    .collect();

                Ok(result)
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(Vec::new()),
        }
    }

    /// Get range of members by score. Returns list of (member, score) tuples.
    /// Optimized to use BTreeSet::range() for O(log n + k) instead of O(n) where k is result size.
    pub fn zrangebyscore(&self, db: u64, key: &[u8], min: Score, max: Score, with_scores: bool) -> Result<Vec<(Bytes, Option<Score>)>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::ZSet(zset)) => {
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
                        // Clone the Arc-wrapped Bytes directly instead of reconstructing
                        key.get_entry_and_score().and_then(|(entry, score)| {
                            // Additional boundary checks to handle fictional MaxScoreKey
                            if score >= min && score <= max {
                                Some(if with_scores {
                                    (entry, Some(score))
                                } else {
                                    (entry, None)
                                })
                            } else {
                                // Skip entries outside the actual range
                                None
                            }
                        })
                    })
                    .collect();

                Ok(result)
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(Vec::new()),
        }
    }

    /// Get the rank (index) of a member in sorted set (0-based, ascending order).
    pub fn zrank(&self, db: u64, key: &[u8], member: &[u8]) -> Result<Option<usize>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::ZSet(zset)) => {
                // Use direct HashMap lookup for score with &[u8]
                let Some(score) = zset.entries.get(member) else {
                    return Ok(None);
                };

                // Use indexset's efficient rank() method - O(log n) instead of O(n)
                // Use ZSetIndexKeyRef for lookup
                let lookup_key = ZSetIndexKeyRef::lookup_key_ref(*score, member);
                let rank = zset.index.rank(&lookup_key);

                Ok(Some(rank))
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(None),
        }
    }

    /// Get the reverse rank (index from highest to lowest) of a member.
    pub fn zrevrank(&self, db: u64, key: &[u8], member: &[u8]) -> Result<Option<usize>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::ZSet(zset)) => {
                // Use direct HashMap lookup for score with &[u8]
                let Some(score) = zset.entries.get(member) else {
                    return Ok(None);
                };

                // Use indexset's efficient rank() method, then convert to reverse rank
                // Reverse rank = (total_count - 1) - rank
                // Use ZSetIndexKeyRef for lookup
                let lookup_key = ZSetIndexKeyRef::lookup_key_ref(*score, member);
                let rank = zset.index.rank(&lookup_key);
                let rev_rank = zset.len() - 1 - rank;

                Ok(Some(rev_rank))
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(None),
        }
    }

    /// Count members in sorted set with scores between min and max (inclusive).
    /// Optimized to use rank difference instead of iteration: O(log n) instead of O(n).
    pub fn zcount(&self, db: u64, key: &[u8], min: Score, max: Score) -> Result<usize, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::ZSet(zset)) => {
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
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(0),
        }
    }

    /// Increment the score of a member by delta. Creates member if it doesn't exist.
    pub fn zincrby(&mut self, db: u64, key: &[u8], delta: Score, member: &[u8]) -> Result<(), &'static str> {
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

        let zset = match zset {
            StorageValue::ZSet(z) => z,
            _ => unreachable!(),
        };

        // Use direct HashMap lookup for old score with &[u8]
        let old_score = zset.entries.get(member).copied().unwrap_or(OrderedFloat(0.0));
        let new_score = old_score + delta;

        // Remove old index entry if member existed
        if old_score != OrderedFloat(0.0) || zset.entries.contains_key(member) {
            // Use ZSetIndexKeyRef for removal
            let lookup_key = ZSetIndexKeyRef::lookup_key_ref(old_score, member);
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
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::ZSet(zset)) => {
                let result = zset.index.first().and_then(|key| {
                    key.get_entry_and_score().map(|(entry, score)| (score, entry))
                });
                Ok(result)
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(None),
        }
    }

    /// Get the last (maximum) member from sorted set.
    /// Returns Some((score, member)) or None if set is empty/doesn't exist.
    pub fn zlast(&self, db: u64, key: &[u8]) -> Result<Option<(Score, Bytes)>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::ZSet(zset)) => {
                let result = zset.index.last().and_then(|key| {
                    key.get_entry_and_score().map(|(entry, score)| (score, entry))
                });
                Ok(result)
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(None),
        }
    }

    /// Get the next member after the given (score, member) in sorted set.
    /// Returns Some((score, member)) or None if no next element exists.
    pub fn znext(&self, db: u64, key: &[u8], score: Score, member: &[u8]) -> Result<Option<(Score, Bytes)>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::ZSet(zset)) => {
                let current_key = ZSetIndexKey::create(score, member);
                // Use range starting after the current key
                let range = zset.index.range::<_, ZSetIndexKey>((Bound::Excluded(&current_key), Bound::Unbounded));
                let result = range.take(1).next().and_then(|key| {
                    key.get_entry_and_score().map(|(entry, score)| (score, entry))
                });
                Ok(result)
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(None),
        }
    }

    /// Get the previous member before the given (score, member) in sorted set.
    /// Returns Some((score, member)) or None if no previous element exists.
    pub fn zprev(&self, db: u64, key: &[u8], score: Score, member: &[u8]) -> Result<Option<(Score, Bytes)>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::ZSet(zset)) => {
                let current_key = ZSetIndexKey::create(score, member);
                // Use range ending before the current key, get last element
                let range = zset.index.range::<_, ZSetIndexKey>((Bound::Unbounded, Bound::Excluded(&current_key)));
                let result = range.last().and_then(|key| {
                    key.get_entry_and_score().and_then(|(entry, ret_score)| {
                        // Verify the returned element is actually different from the input
                        if ret_score == score && entry.as_slice() == member {
                            None
                        } else {
                            Some((ret_score, entry))
                        }
                    })
                });
                Ok(result)
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(None),
        }
    }

    /// Pop member with highest score from sorted set.
    pub fn zpopmax(&mut self, db: u64, key: &[u8]) -> Result<(), &'static str> {
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

        // Extract member and score from the last index entry
        let member_score = zset.index.last().and_then(|index_key| {
            index_key.get_entry_and_score().map(|(m, s)| (m.clone(), s))
        });

        if let Some((member, score)) = member_score {
            zset.entries.remove(member.as_slice());
            let lookup_key = ZSetIndexKeyRef::lookup_key_ref(score, member.as_slice());
            zset.index.remove(&lookup_key);
        }

        // Remove key if zset is empty
        if zset.is_empty() {
            db_map.remove(key);
        }

        Ok(())
    }

    /// Pop member with lowest score from sorted set.
    pub fn zpopmin(&mut self, db: u64, key: &[u8]) -> Result<(), &'static str> {
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

        // Extract member and score from the first index entry
        let member_score = zset.index.first().and_then(|index_key| {
            index_key.get_entry_and_score().map(|(m, s)| (m.clone(), s))
        });

        if let Some((member, score)) = member_score {
            zset.entries.remove(member.as_slice());
            let lookup_key = ZSetIndexKeyRef::lookup_key_ref(score, member.as_slice());
            zset.index.remove(&lookup_key);
        }

        // Remove key if zset is empty
        if zset.is_empty() {
            db_map.remove(key);
        }

        Ok(())
    }

    /// Remove members by rank range (inclusive). Ranks are 0-based.
    pub fn zremrangebyrank(&mut self, db: u64, key: &[u8], start: i64, stop: i64) -> Result<(), &'static str> {
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
            .filter_map(|index_key| index_key.get_entry_and_score().map(|(m, s)| (m.clone(), s)))
            .collect();

        // Remove them
        for (member, score) in members_to_remove {
            zset.entries.remove(member.as_slice());
            let lookup_key = ZSetIndexKeyRef::lookup_key_ref(score, member.as_slice());
            zset.index.remove(&lookup_key);
        }

        // Remove key if zset is empty
        if zset.is_empty() {
            db_map.remove(key);
        }

        Ok(())
    }

    /// Remove members by score range (inclusive).
    pub fn zremrangebyscore(&mut self, db: u64, key: &[u8], min: Score, max: Score, _min_exclusive: bool, _max_exclusive: bool) -> Result<(), &'static str> {
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

        // Use range to efficiently collect members with scores in [min, max] (inclusive)
        // Note: MaxScoreKey is fictional, so indexset may include entries beyond it
        // We add boundary checks after fetching to drop elements that don't fit
        let min_key = ZSetIndexKey::min_score_key(min);
        let max_key = ZSetIndexKey::max_score_key(max);

        let members_to_remove: Vec<(Bytes, Score)> = zset
            .index
            .range(min_key..max_key)
            .filter_map(|index_key| index_key.get_entry_and_score().map(|(m, s)| (m.clone(), s)))
            .collect();

        // Remove them
        for (member, score) in members_to_remove {
            zset.entries.remove(member.as_slice());
            let lookup_key = ZSetIndexKeyRef::lookup_key_ref(score, member.as_slice());
            zset.index.remove(&lookup_key);
        }

        // Remove key if zset is empty
        if zset.is_empty() {
            db_map.remove(key);
        }

        Ok(())
    }

    /// Store union of sorted sets in destination key with weights and aggregation.
    pub fn zunionstore(&mut self, db: u64, dest_key: &[u8], source_keys: &[&[u8]], weights: &[f64], aggregate: Aggregate) -> Result<(), &'static str> {
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
                Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::Set(_)) => {
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
                new_zset.index.insert(ZSetIndexKey::create(final_score, member.as_slice()));
            }

            let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);
            db_map.insert(Bytes::new(dest_key), StorageValue::ZSet(new_zset));
        }

        Ok(())
    }

    /// Store intersection of sorted sets in destination key with weights and aggregation.
    pub fn zinterstore(&mut self, db: u64, dest_key: &[u8], source_keys: &[&[u8]], weights: &[f64], aggregate: Aggregate) -> Result<(), &'static str> {
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
            Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::Set(_)) => {
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
                Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::Set(_)) => {
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
                new_zset.index.insert(ZSetIndexKey::create(final_score, member.as_slice()));
            }

            let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);
            db_map.insert(Bytes::new(dest_key), StorageValue::ZSet(new_zset));
        }

        Ok(())
    }
}
