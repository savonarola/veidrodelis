use super::bytes::Bytes;
use super::types::StorageValue;
use crate::storage::StorageInner;
use std::collections::btree_map::Entry as BTreeEntry;
use std::collections::BTreeSet as StdBTreeSet;

impl StorageInner {
    /// Add members to a set.
    pub fn sadd(&mut self, db: u64, key: &[u8], members: &[&[u8]]) -> Result<(), &'static str> {
        let db_map = self.map.entry(db).or_default();

        // Check if key exists and validate type
        if let Some(value) = db_map.get(key) {
            if !matches!(value, StorageValue::Set(_)) {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
            }
        }

        // Get or create the set
        let set = db_map
            .entry(Bytes::new(key))
            .or_insert_with(|| StorageValue::Set(StdBTreeSet::new()));

        // Extract the set from the StorageValue
        let set = match set {
            StorageValue::Set(s) => s,
            _ => unreachable!(), // We already validated the type above
        };

        for member in members {
            set.insert(Bytes::new(member));
        }

        Ok(())
    }

    /// Remove members from a set. Removes key if set becomes empty.
    pub fn srem(&mut self, db: u64, key: &[u8], members: &[&[u8]]) -> Result<(), &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        let Some(value) = db_map.get_mut(key) else {
            return Ok(());
        };

        let set = match value {
            StorageValue::Set(set) => set,
            StorageValue::String(_)
            | StorageValue::List(_)
            | StorageValue::Hash(_)
            | StorageValue::ZSet(_) => {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
        };

        for member in members {
            set.remove(*member);
        }

        // Remove key if set is empty
        if set.is_empty() {
            db_map.remove(key);
        }

        Ok(())
    }

    /// Move a member from source to destination set. Deletes source if it becomes empty.
    pub fn smove(
        &mut self,
        db: u64,
        source_key: &[u8],
        dest_key: &[u8],
        member: &[u8],
    ) -> Result<(), &'static str> {
        // Get mutable access to database
        let db_map = match self.map.get_mut(&db) {
            Some(map) => map,
            None => return Ok(()),
        };

        // Check source type
        match db_map.get(source_key) {
            Some(StorageValue::Set(_)) => {}
            Some(StorageValue::String(_))
            | Some(StorageValue::List(_))
            | Some(StorageValue::Hash(_))
            | Some(StorageValue::ZSet(_)) => {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => return Ok(()),
        };

        // Remove from source using take() which returns the Arc if it exists
        let member_arc = match db_map.get_mut(source_key) {
            Some(StorageValue::Set(set)) => set.take(member),
            _ => None,
        };

        let Some(member_arc) = member_arc else {
            return Ok(());
        };

        // Check if source set is now empty and should be deleted
        let should_delete_source = match db_map.get(source_key) {
            Some(StorageValue::Set(set)) => set.is_empty(),
            Some(StorageValue::String(_))
            | Some(StorageValue::List(_))
            | Some(StorageValue::Hash(_))
            | Some(StorageValue::ZSet(_))
            | None => false,
        };

        // Delete source if empty
        if should_delete_source {
            db_map.remove(source_key);
        }

        // Add member to destination set
        match db_map.entry(Bytes::new(dest_key)) {
            BTreeEntry::Occupied(mut e) => match e.get_mut() {
                StorageValue::Set(set) => {
                    set.insert(member_arc);
                }
                StorageValue::String(_)
                | StorageValue::List(_)
                | StorageValue::Hash(_)
                | StorageValue::ZSet(_) => {
                    return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
                }
            },
            BTreeEntry::Vacant(e) => {
                let mut new_set = StdBTreeSet::new();
                new_set.insert(member_arc);
                e.insert(StorageValue::Set(new_set));
            }
        }

        Ok(())
    }

    /// Store union of multiple sets in destination key.
    pub fn sunionstore(
        &mut self,
        db: u64,
        dest_key: &[u8],
        source_keys: &[&[u8]],
    ) -> Result<(), &'static str> {
        // First delete destination
        self.del(db, dest_key);

        // Collect all unique members from source sets
        let mut union_set = StdBTreeSet::new();

        if let Some(db_map) = self.map.get(&db) {
            for source_key in source_keys {
                if let Some(value) = db_map.get(*source_key) {
                    match value {
                        StorageValue::Set(set) => {
                            union_set.extend(set.iter().cloned());
                        }
                        StorageValue::String(_)
                        | StorageValue::List(_)
                        | StorageValue::Hash(_)
                        | StorageValue::ZSet(_) => {
                            return Err(
                                "WRONGTYPE Operation against a key holding the wrong kind of value",
                            )
                        }
                    }
                }
            }
        }

        // Store result if non-empty
        if !union_set.is_empty() {
            let db_map = self.map.entry(db).or_default();
            db_map.insert(Bytes::new(dest_key), StorageValue::Set(union_set));
        }

        Ok(())
    }

    /// Store intersection of multiple sets in destination key.
    pub fn sinterstore(
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

        // Start with first set - collect into a new set
        let mut intersection_set = match db_map.get(source_keys[0]) {
            Some(StorageValue::Set(set)) => set.iter().cloned().collect(),
            Some(StorageValue::String(_))
            | Some(StorageValue::List(_))
            | Some(StorageValue::Hash(_))
            | Some(StorageValue::ZSet(_)) => {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => StdBTreeSet::new(),
        };

        // Intersect with remaining sets
        for source_key in &source_keys[1..] {
            match db_map.get(*source_key) {
                Some(StorageValue::Set(set)) => {
                    intersection_set = intersection_set.intersection(set).cloned().collect();
                }
                Some(StorageValue::String(_))
                | Some(StorageValue::List(_))
                | Some(StorageValue::Hash(_))
                | Some(StorageValue::ZSet(_)) => {
                    return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
                }
                None => {
                    // Intersection with empty set is empty
                    intersection_set.clear();
                    break;
                }
            }
        }

        // Store result if non-empty
        if !intersection_set.is_empty() {
            let db_map = self.map.entry(db).or_default();
            db_map.insert(Bytes::new(dest_key), StorageValue::Set(intersection_set));
        }

        Ok(())
    }

    /// Store difference of sets in destination key.
    pub fn sdiffstore(
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

        // Start with first set - collect into a new set
        let mut diff_set = match db_map.get(source_keys[0]) {
            Some(StorageValue::Set(set)) => set.iter().cloned().collect(),
            Some(StorageValue::String(_))
            | Some(StorageValue::List(_))
            | Some(StorageValue::Hash(_))
            | Some(StorageValue::ZSet(_)) => {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => StdBTreeSet::new(),
        };

        // Subtract remaining sets
        for source_key in &source_keys[1..] {
            match db_map.get(*source_key) {
                Some(StorageValue::Set(set)) => {
                    diff_set = diff_set.difference(set).cloned().collect();
                }
                Some(StorageValue::String(_))
                | Some(StorageValue::List(_))
                | Some(StorageValue::Hash(_))
                | Some(StorageValue::ZSet(_)) => {
                    return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
                }
                None => {
                    // Difference with empty set doesn't change result
                    continue;
                }
            }
        }

        // Store result if non-empty
        if !diff_set.is_empty() {
            let db_map = self.map.entry(db).or_default();
            db_map.insert(Bytes::new(dest_key), StorageValue::Set(diff_set));
        }

        Ok(())
    }

    /// Get all members of a set.
    pub fn smembers(&self, db: u64, key: &[u8]) -> Result<Vec<Bytes>, &'static str> {
        let Some(db_map) = self.map.get(&db) else {
            return Ok(Vec::new());
        };

        let Some(value) = db_map.get(key) else {
            return Ok(Vec::new());
        };

        let StorageValue::Set(set) = value else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        Ok(set.iter().cloned().collect())
    }

    /// Check if member exists in set.
    pub fn sismember(&self, db: u64, key: &[u8], member: &[u8]) -> Result<bool, &'static str> {
        let Some(db_map) = self.map.get(&db) else {
            return Ok(false);
        };

        let Some(value) = db_map.get(key) else {
            return Ok(false);
        };

        let StorageValue::Set(set) = value else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        Ok(set.contains(member))
    }

    /// Get the number of members in a set.
    pub fn scard(&self, db: u64, key: &[u8]) -> Result<usize, &'static str> {
        let Some(db_map) = self.map.get(&db) else {
            return Ok(0);
        };

        let Some(value) = db_map.get(key) else {
            return Ok(0);
        };

        let StorageValue::Set(set) = value else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        Ok(set.len())
    }

    /// Get the first (minimum) member from set.
    /// Returns Some(member) or None if set is empty/doesn't exist.
    pub fn sfirst(&self, db: u64, key: &[u8]) -> Result<Option<Bytes>, &'static str> {
        let Some(db_map) = self.map.get(&db) else {
            return Ok(None);
        };

        let Some(value) = db_map.get(key) else {
            return Ok(None);
        };

        let StorageValue::Set(set) = value else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        Ok(set.iter().next().cloned())
    }

    /// Get the last (maximum) member from set.
    /// Returns Some(member) or None if set is empty/doesn't exist.
    pub fn slast(&self, db: u64, key: &[u8]) -> Result<Option<Bytes>, &'static str> {
        let Some(db_map) = self.map.get(&db) else {
            return Ok(None);
        };

        let Some(value) = db_map.get(key) else {
            return Ok(None);
        };

        let StorageValue::Set(set) = value else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        Ok(set.iter().next_back().cloned())
    }

    /// Get the next member after the given member in set.
    /// Returns Some(member) or None if no next element exists.
    pub fn snext(&self, db: u64, key: &[u8], member: &[u8]) -> Result<Option<Bytes>, &'static str> {
        use std::ops::Bound;

        let Some(db_map) = self.map.get(&db) else {
            return Ok(None);
        };

        let Some(value) = db_map.get(key) else {
            return Ok(None);
        };

        let StorageValue::Set(set) = value else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        // Use range starting after the current member
        let range = set.range::<[u8], _>((Bound::Excluded(member), Bound::Unbounded));
        Ok(range.take(1).next().cloned())
    }

    /// Get the previous member before the given member in set.
    /// Returns Some(member) or None if no previous element exists.
    pub fn sprev(&self, db: u64, key: &[u8], member: &[u8]) -> Result<Option<Bytes>, &'static str> {
        use std::ops::Bound;

        let Some(db_map) = self.map.get(&db) else {
            return Ok(None);
        };

        let Some(value) = db_map.get(key) else {
            return Ok(None);
        };

        let StorageValue::Set(set) = value else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        // Use range ending before the current member, get last element
        let range = set.range::<[u8], _>((Bound::Unbounded, Bound::Excluded(member)));
        Ok(range.last().cloned())
    }

    /// Check if multiple members exist in set.
    /// Returns a vector of booleans, one for each member.
    pub fn smismember(
        &self,
        db: u64,
        key: &[u8],
        members: &[&[u8]],
    ) -> Result<Vec<bool>, &'static str> {
        let Some(db_map) = self.map.get(&db) else {
            return Ok(vec![false; members.len()]);
        };

        let Some(value) = db_map.get(key) else {
            return Ok(vec![false; members.len()]);
        };

        let StorageValue::Set(set) = value else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        Ok(members.iter().map(|member| set.contains(*member)).collect())
    }

    /// Get random member(s) from set without removing them.
    /// If count > 0: returns up to count unique members
    /// If count < 0: returns abs(count) members, allowing duplicates
    /// If count == 0: returns empty vector
    pub fn srandmember(&self, db: u64, key: &[u8], count: i64) -> Result<Vec<Bytes>, &'static str> {
        use rand::seq::SliceRandom;
        use rand::thread_rng;

        let Some(db_map) = self.map.get(&db) else {
            return Ok(Vec::new());
        };

        let Some(value) = db_map.get(key) else {
            return Ok(Vec::new());
        };

        let StorageValue::Set(set) = value else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        if count == 0 || set.is_empty() {
            return Ok(Vec::new());
        }

        let members: Vec<Bytes> = set.iter().cloned().collect();
        let mut rng = thread_rng();

        if count > 0 {
            // Return up to count unique random members
            let take_count = std::cmp::min(count as usize, members.len());
            let mut result = members.clone();
            result.shuffle(&mut rng);
            result.truncate(take_count);
            Ok(result)
        } else {
            // Return abs(count) members, allowing duplicates
            let count = count.unsigned_abs() as usize;
            Ok((0..count)
                .map(|_| members.choose(&mut rng).unwrap().clone())
                .collect())
        }
    }

    /// Return union of multiple sets (without storing).
    pub fn sunion(&self, db: u64, source_keys: &[&[u8]]) -> Result<Vec<Bytes>, &'static str> {
        let mut union_set = StdBTreeSet::new();

        if let Some(db_map) = self.map.get(&db) {
            for source_key in source_keys {
                if let Some(value) = db_map.get(*source_key) {
                    match value {
                        StorageValue::Set(set) => {
                            union_set.extend(set.iter().cloned());
                        }
                        StorageValue::String(_)
                        | StorageValue::List(_)
                        | StorageValue::Hash(_)
                        | StorageValue::ZSet(_) => {
                            return Err(
                                "WRONGTYPE Operation against a key holding the wrong kind of value",
                            )
                        }
                    }
                }
            }
        }

        Ok(union_set.into_iter().collect())
    }

    /// Return intersection of multiple sets (without storing).
    pub fn sinter(&self, db: u64, source_keys: &[&[u8]]) -> Result<Vec<Bytes>, &'static str> {
        if source_keys.is_empty() {
            return Ok(Vec::new());
        }

        let Some(db_map) = self.map.get(&db) else {
            return Ok(Vec::new());
        };

        // Start with first set - collect into a new set
        let mut intersection_set = match db_map.get(source_keys[0]) {
            Some(StorageValue::Set(set)) => set.iter().cloned().collect(),
            Some(StorageValue::String(_))
            | Some(StorageValue::List(_))
            | Some(StorageValue::Hash(_))
            | Some(StorageValue::ZSet(_)) => {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => StdBTreeSet::new(),
        };

        // Intersect with remaining sets
        for source_key in &source_keys[1..] {
            match db_map.get(*source_key) {
                Some(StorageValue::Set(set)) => {
                    intersection_set = intersection_set.intersection(set).cloned().collect();
                }
                Some(StorageValue::String(_))
                | Some(StorageValue::List(_))
                | Some(StorageValue::Hash(_))
                | Some(StorageValue::ZSet(_)) => {
                    return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
                }
                None => {
                    // Intersection with empty set is empty
                    return Ok(Vec::new());
                }
            }
        }

        Ok(intersection_set.into_iter().collect())
    }

    /// Return difference of multiple sets (without storing).
    pub fn sdiff(&self, db: u64, source_keys: &[&[u8]]) -> Result<Vec<Bytes>, &'static str> {
        if source_keys.is_empty() {
            return Ok(Vec::new());
        }

        let Some(db_map) = self.map.get(&db) else {
            return Ok(Vec::new());
        };

        // Start with first set - collect into a new set
        let mut diff_set = match db_map.get(source_keys[0]) {
            Some(StorageValue::Set(set)) => set.iter().cloned().collect(),
            Some(StorageValue::String(_))
            | Some(StorageValue::List(_))
            | Some(StorageValue::Hash(_))
            | Some(StorageValue::ZSet(_)) => {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => StdBTreeSet::new(),
        };

        // Subtract remaining sets
        for source_key in &source_keys[1..] {
            match db_map.get(*source_key) {
                Some(StorageValue::Set(set)) => {
                    diff_set = diff_set.difference(set).cloned().collect();
                }
                Some(StorageValue::String(_))
                | Some(StorageValue::List(_))
                | Some(StorageValue::Hash(_))
                | Some(StorageValue::ZSet(_)) => {
                    return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
                }
                None => {
                    // Difference with empty set doesn't change result
                    continue;
                }
            }
        }

        Ok(diff_set.into_iter().collect())
    }

    /// Return cardinality of intersection of multiple sets.
    pub fn sintercard(&self, db: u64, source_keys: &[&[u8]]) -> Result<usize, &'static str> {
        if source_keys.is_empty() {
            return Ok(0);
        }

        let Some(db_map) = self.map.get(&db) else {
            return Ok(0);
        };

        // Start with first set - collect into a new set
        let mut intersection_set = match db_map.get(source_keys[0]) {
            Some(StorageValue::Set(set)) => set.iter().cloned().collect(),
            Some(StorageValue::String(_))
            | Some(StorageValue::List(_))
            | Some(StorageValue::Hash(_))
            | Some(StorageValue::ZSet(_)) => {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => StdBTreeSet::new(),
        };

        // Intersect with remaining sets
        for source_key in &source_keys[1..] {
            match db_map.get(*source_key) {
                Some(StorageValue::Set(set)) => {
                    intersection_set = intersection_set.intersection(set).cloned().collect();
                }
                Some(StorageValue::String(_))
                | Some(StorageValue::List(_))
                | Some(StorageValue::Hash(_))
                | Some(StorageValue::ZSet(_)) => {
                    return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
                }
                None => {
                    // Intersection with empty set is empty
                    return Ok(0);
                }
            }
        }

        Ok(intersection_set.len())
    }
}
