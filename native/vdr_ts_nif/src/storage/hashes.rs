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

    /// Set field in hash only if it doesn't exist.
    pub fn hsetnx(&mut self, db: u64, key: &[u8], field: &[u8], value: &[u8]) -> Result<(), &'static str> {
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

        // Only set if field doesn't exist
        if !hash.contains_key(field) {
            hash.insert(Bytes::new(field), Bytes::new(value));
        }

        Ok(())
    }

    /// Increment integer field value in hash.
    pub fn hincrby(&mut self, db: u64, key: &[u8], field: &[u8], delta: i64) -> Result<(), &'static str> {
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

        // Get current value (default to 0)
        let current_value = if let Some(existing_bytes) = hash.get(field) {
            // Parse as integer
            let value_str = std::str::from_utf8(existing_bytes.as_slice())
                .map_err(|_| "ERR hash value is not an integer or out of range")?;
            value_str.parse::<i64>()
                .map_err(|_| "ERR hash value is not an integer or out of range")?
        } else {
            0
        };

        // Calculate new value with overflow check
        let new_value = current_value.checked_add(delta)
            .ok_or("ERR hash value is not an integer or out of range")?;

        // Store result as string
        let result_bytes = new_value.to_string().into_bytes();
        hash.insert(Bytes::new(field), Bytes::new(&result_bytes));

        Ok(())
    }

    /// Increment float field value in hash.
    pub fn hincrbyfloat(&mut self, db: u64, key: &[u8], field: &[u8], delta: f64) -> Result<(), &'static str> {
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

        // Get current value (default to 0.0)
        let current_value = if let Some(existing_bytes) = hash.get(field) {
            // Parse as float
            let value_str = std::str::from_utf8(existing_bytes.as_slice())
                .map_err(|_| "ERR hash value is not a float")?;
            value_str.parse::<f64>()
                .map_err(|_| "ERR hash value is not a float")?
        } else {
            0.0
        };

        // Calculate new value
        let new_value = current_value + delta;

        // Store result as string
        let result_bytes = new_value.to_string().into_bytes();
        hash.insert(Bytes::new(field), Bytes::new(&result_bytes));

        Ok(())
    }

    /// HSETEX - Extended HSET with field existence options.
    /// Used in replication for HINCRBYFLOAT operations.
    ///
    /// Mode options:
    /// - None: Set all fields unconditionally
    /// - Some(HSetEXMode::NX): Only succeed if NONE of the fields exist (FNX)
    /// - Some(HSetEXMode::XX): Only succeed if ALL fields exist (FXX)
    pub fn hsetex(&mut self, db: u64, key: &[u8], mode: Option<crate::storage::types::HSetEXMode>, fields: &[(&[u8], &[u8])]) -> Result<(), &'static str> {
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

        // Apply mode logic
        match mode {
            None => {
                // No option: set all fields unconditionally
                for (field, value) in fields {
                    hash.insert(Bytes::new(field), Bytes::new(value));
                }
            }
            Some(crate::storage::types::HSetEXMode::NX) => {
                // FNX: only set if NONE of the fields exist
                let all_fields_missing = fields.iter().all(|(field, _)| !hash.contains_key(*field));
                if all_fields_missing {
                    for (field, value) in fields {
                        hash.insert(Bytes::new(field), Bytes::new(value));
                    }
                }
            }
            Some(crate::storage::types::HSetEXMode::XX) => {
                // FXX: only set if ALL fields exist
                let all_exist = fields.iter().all(|(field, _)| hash.contains_key(*field));
                if all_exist {
                    for (field, value) in fields {
                        hash.insert(Bytes::new(field), Bytes::new(value));
                    }
                }
            }
        }

        Ok(())
    }

    /// Get the string length of the value stored at field in hash.
    /// Returns 0 if field doesn't exist.
    pub fn hstrlen(&self, db: u64, key: &[u8], field: &[u8]) -> Result<usize, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => {
                Ok(hash.get(field).map(|v| v.len()).unwrap_or(0))
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(0),
        }
    }

    /// Get random field(s) from hash.
    /// If count is 1, returns a single field (or None if hash is empty).
    /// If count > 1, returns up to count fields (may be less if hash has fewer fields).
    /// If count is negative, allows returning the same field multiple times.
    pub fn hrandfield(&self, db: u64, key: &[u8], count: i64, with_values: bool) -> Result<Vec<(Bytes, Option<Bytes>)>, &'static str> {
        use rand::seq::SliceRandom;
        use rand::thread_rng;

        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => {
                if hash.is_empty() {
                    return Ok(Vec::new());
                }

                let mut rng = thread_rng();
                let fields: Vec<_> = hash.iter().collect();

                if count == 1 {
                    // Return single random field
                    if let Some((field, value)) = fields.choose(&mut rng) {
                        let val = if with_values {
                            Some((*value).clone())
                        } else {
                            None
                        };
                        Ok(vec![((*field).clone(), val)])
                    } else {
                        Ok(Vec::new())
                    }
                } else if count > 1 {
                    // Return multiple unique random fields (up to count)
                    let sample_size = (count as usize).min(fields.len());
                    let samples = fields.choose_multiple(&mut rng, sample_size);
                    Ok(samples.map(|(field, value)| {
                        let val = if with_values {
                            Some((*value).clone())
                        } else {
                            None
                        };
                        ((*field).clone(), val)
                    }).collect())
                } else if count < 0 {
                    // Return |count| fields with repetition allowed
                    let sample_size = (-count) as usize;
                    let mut results = Vec::with_capacity(sample_size);
                    for _ in 0..sample_size {
                        if let Some((field, value)) = fields.choose(&mut rng) {
                            let val = if with_values {
                                Some((*value).clone())
                            } else {
                                None
                            };
                            results.push(((*field).clone(), val));
                        }
                    }
                    Ok(results)
                } else {
                    // count == 0
                    Ok(Vec::new())
                }
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(Vec::new()),
        }
    }
}

