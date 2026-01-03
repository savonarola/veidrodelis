use std::collections::{BTreeMap, BTreeSet as StdBTreeSet};
use std::collections::btree_map::Entry as BTreeEntry;
use super::bytes::Bytes;
use super::types::StorageValue;
use crate::storage::StorageInner;

impl StorageInner {
    /// Add members to a set.
    pub fn sadd(&mut self, db: u64, key: &[u8], members: &[&[u8]]) -> Result<(), &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

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
            StorageValue::String(_) | StorageValue::List(_) | StorageValue::Hash(_) | StorageValue::ZSet(_) => {
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
    pub fn smove(&mut self, db: u64, source_key: &[u8], dest_key: &[u8], member: &[u8]) -> Result<(), &'static str> {
        // Get mutable access to database
        let db_map = match self.map.get_mut(&db) {
            Some(map) => map,
            None => return Ok(()),
        };

        // Check source type
        match db_map.get(source_key) {
            Some(StorageValue::Set(_)) => {},
            Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) => {
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
            Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) | None => false,
        };

        // Delete source if empty
        if should_delete_source {
            db_map.remove(source_key);
        }

        // Add member to destination set
        match db_map.entry(Bytes::new(dest_key)) {
            BTreeEntry::Occupied(mut e) => {
                match e.get_mut() {
                    StorageValue::Set(set) => {
                        set.insert(member_arc);
                    }
                    StorageValue::String(_) | StorageValue::List(_) | StorageValue::Hash(_) | StorageValue::ZSet(_) => {
                        return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
                    }
                }
            }
            BTreeEntry::Vacant(e) => {
                let mut new_set = StdBTreeSet::new();
                new_set.insert(member_arc);
                e.insert(StorageValue::Set(new_set));
            }
        }

        Ok(())
    }

    /// Store union of multiple sets in destination key.
    pub fn sunionstore(&mut self, db: u64, dest_key: &[u8], source_keys: &[&[u8]]) -> Result<(), &'static str> {
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
                        StorageValue::String(_) | StorageValue::List(_) | StorageValue::Hash(_) | StorageValue::ZSet(_) => {
                            return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
                        }
                    }
                }
            }
        }

        // Store result if non-empty
        if !union_set.is_empty() {
            let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);
            db_map.insert(Bytes::new(dest_key), StorageValue::Set(union_set));
        }

        Ok(())
    }

    /// Store intersection of multiple sets in destination key.
    pub fn sinterstore(&mut self, db: u64, dest_key: &[u8], source_keys: &[&[u8]]) -> Result<(), &'static str> {
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
            Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) => {
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
                Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) => {
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
            let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);
            db_map.insert(Bytes::new(dest_key), StorageValue::Set(intersection_set));
        }

        Ok(())
    }

    /// Store difference of sets in destination key.
    pub fn sdiffstore(&mut self, db: u64, dest_key: &[u8], source_keys: &[&[u8]]) -> Result<(), &'static str> {
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
            Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) => {
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
                Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) => {
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
            let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);
            db_map.insert(Bytes::new(dest_key), StorageValue::Set(diff_set));
        }

        Ok(())
    }

    /// Get all members of a set.
    pub fn smembers(&self, db: u64, key: &[u8]) -> Result<Vec<Bytes>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Set(set)) => Ok(set.iter().cloned().collect()),
            Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) => {
                Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => Ok(Vec::new()),
        }
    }

    /// Check if member exists in set.
    pub fn sismember(&self, db: u64, key: &[u8], member: &[u8]) -> Result<bool, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Set(set)) => Ok(set.contains(member)),
            Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) => {
                Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => Ok(false),
        }
    }

    /// Get the number of members in a set.
    pub fn scard(&self, db: u64, key: &[u8]) -> Result<usize, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Set(set)) => Ok(set.len()),
            Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) => {
                Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => Ok(0),
        }
    }
}
