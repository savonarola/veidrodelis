use std::collections::BTreeMap;
use super::bytes::Bytes;
use super::types::StorageValue;
use crate::storage::StorageInner;

impl StorageInner {
    /// Set field in hash to value. Creates hash if it doesn't exist.
    pub fn hset(&mut self, db: u64, key: &[u8], field: &[u8], value: &[u8]) -> Result<(), &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        // Check if key exists and validate type
        if let Some(val) = db_map.get(key) {
            if !matches!(val, StorageValue::Hash(_)) {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
            }
        }

        // Get or create the hash
        let hash = db_map
            .entry(Bytes::new(key))
            .or_insert_with(|| StorageValue::Hash(BTreeMap::new()));

        let hash = match hash {
            StorageValue::Hash(h) => h,
            _ => unreachable!(),
        };

        hash.insert(Bytes::new(field), Bytes::new(value));
        Ok(())
    }

    /// Set multiple fields in hash.
    pub fn hmset(&mut self, db: u64, key: &[u8], fields: &[(&[u8], &[u8])]) -> Result<(), &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        // Check if key exists and validate type
        if let Some(val) = db_map.get(key) {
            if !matches!(val, StorageValue::Hash(_)) {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
            }
        }

        // Get or create the hash
        let hash = db_map
            .entry(Bytes::new(key))
            .or_insert_with(|| StorageValue::Hash(BTreeMap::new()));

        let hash = match hash {
            StorageValue::Hash(h) => h,
            _ => unreachable!(),
        };

        for (field, value) in fields {
            hash.insert(Bytes::new(field), Bytes::new(value));
        }

        Ok(())
    }

    /// Get field value from hash. Returns None if key or field doesn't exist.
    pub fn hget(&self, db: u64, key: &[u8], field: &[u8]) -> Result<Option<Bytes>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => Ok(hash.get(field).cloned()),
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(None),
        }
    }

    /// Get multiple field values from hash.
    pub fn hmget(&self, db: u64, key: &[u8], fields: &[&[u8]]) -> Result<Vec<Option<Bytes>>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => {
                let values = fields.iter().map(|field| hash.get(*field).cloned()).collect();
                Ok(values)
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => {
                // Return vec of None for each field
                Ok(vec![None; fields.len()])
            }
        }
    }

    /// Get all field-value pairs from hash.
    pub fn hgetall(&self, db: u64, key: &[u8]) -> Result<Vec<(Bytes, Bytes)>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => {
                let pairs = hash.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
                Ok(pairs)
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(Vec::new()),
        }
    }

    /// Get all field names from hash.
    pub fn hkeys(&self, db: u64, key: &[u8]) -> Result<Vec<Bytes>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => Ok(hash.keys().cloned().collect()),
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(Vec::new()),
        }
    }

    /// Get all values from hash.
    pub fn hvals(&self, db: u64, key: &[u8]) -> Result<Vec<Bytes>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => Ok(hash.values().cloned().collect()),
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(Vec::new()),
        }
    }

    /// Get number of fields in hash.
    pub fn hlen(&self, db: u64, key: &[u8]) -> Result<usize, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => Ok(hash.len()),
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(0),
        }
    }

    /// Check if field exists in hash.
    pub fn hexists(&self, db: u64, key: &[u8], field: &[u8]) -> Result<bool, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => Ok(hash.contains_key(field)),
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(false),
        }
    }

    /// Delete fields from hash.
    pub fn hdel(&mut self, db: u64, key: &[u8], fields: &[&[u8]]) -> Result<(), &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        let Some(value) = db_map.get_mut(key) else {
            return Ok(());
        };

        let hash = match value {
            StorageValue::Hash(hash) => hash,
            _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
        };

        for field in fields {
            hash.remove(*field);
        }

        // Remove key if hash is empty
        if hash.is_empty() {
            db_map.remove(key);
        }

        Ok(())
    }

    /// Get the first (minimum) field from hash.
    /// Returns Some((field, value)) or None if hash is empty/doesn't exist.
    pub fn hfirst(&self, db: u64, key: &[u8]) -> Result<Option<(Bytes, Bytes)>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => {
                let result = hash.first_key_value().map(|(field, value)| (field.clone(), value.clone()));
                Ok(result)
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(None),
        }
    }

    /// Get the last (maximum) field from hash.
    /// Returns Some((field, value)) or None if hash is empty/doesn't exist.
    pub fn hlast(&self, db: u64, key: &[u8]) -> Result<Option<(Bytes, Bytes)>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => {
                let result = hash.last_key_value().map(|(field, value)| (field.clone(), value.clone()));
                Ok(result)
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(None),
        }
    }

    /// Get the next field after the given field in hash.
    /// Returns Some((field, value)) or None if no next element exists.
    pub fn hnext(&self, db: u64, key: &[u8], field: &[u8]) -> Result<Option<(Bytes, Bytes)>, &'static str> {
        use std::ops::Bound;

        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => {
                // Use range starting after the current field
                let range = hash.range::<[u8], _>((Bound::Excluded(field), Bound::Unbounded));
                let result = range.take(1).next().map(|(f, v)| (f.clone(), v.clone()));
                Ok(result)
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(None),
        }
    }

    /// Get the previous field before the given field in hash.
    /// Returns Some((field, value)) or None if no previous element exists.
    pub fn hprev(&self, db: u64, key: &[u8], field: &[u8]) -> Result<Option<(Bytes, Bytes)>, &'static str> {
        use std::ops::Bound;

        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => {
                // Use range ending before the current field, get last element
                let range = hash.range::<[u8], _>((Bound::Unbounded, Bound::Excluded(field)));
                let result = range.last().map(|(f, v)| (f.clone(), v.clone()));
                Ok(result)
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(None),
        }
    }
}
