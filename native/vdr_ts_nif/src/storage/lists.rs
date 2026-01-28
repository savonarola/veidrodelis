use std::collections::BTreeMap;
use im::Vector;
use super::bytes::Bytes;
use super::types::StorageValue;
use crate::storage::StorageInner;

impl StorageInner {
    /// Push elements to the left (head) of the list.
    pub fn lpush(&mut self, db: u64, key: &[u8], values: &[&[u8]]) -> Result<(), &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        // Check if key exists and validate type
        if let Some(value) = db_map.get(key) {
            if !matches!(value, StorageValue::List(_)) {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
            }
        }

        // Get or create the list
        let list = db_map
            .entry(Bytes::new(key))
            .or_insert_with(|| StorageValue::List(Vector::new()));

        // Extract the list from the StorageValue
        let list = match list {
            StorageValue::List(l) => l,
            _ => unreachable!(),
        };

        // Push values to the front in order (each one becomes the new head)
        for value in values {
            list.push_front(Bytes::new(value));
        }

        Ok(())
    }

    /// Push elements to the right (tail) of the list.
    pub fn rpush(&mut self, db: u64, key: &[u8], values: &[&[u8]]) -> Result<(), &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        // Check if key exists and validate type
        if let Some(value) = db_map.get(key) {
            if !matches!(value, StorageValue::List(_)) {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
            }
        }

        // Get or create the list
        let list = db_map
            .entry(Bytes::new(key))
            .or_insert_with(|| StorageValue::List(Vector::new()));

        // Extract the list from the StorageValue
        let list = match list {
            StorageValue::List(l) => l,
            _ => unreachable!(),
        };

        // Push values to the back
        for value in values {
            list.push_back(Bytes::new(value));
        }

        Ok(())
    }

    /// Pop element from the left (head) of the list.
    pub fn lpop(&mut self, db: u64, key: &[u8]) -> Result<(), &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        let Some(value) = db_map.get_mut(key) else {
            return Ok(());
        };

        let list = match value {
            StorageValue::List(list) => list,
            _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
        };

        if !list.is_empty() {
            *list = list.skip(1);  // Remove first element
        }

        // Remove key if list is empty
        if list.is_empty() {
            db_map.remove(key);
        }

        Ok(())
    }

    /// Pop element from the right (tail) of the list.
    pub fn rpop(&mut self, db: u64, key: &[u8]) -> Result<(), &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        let Some(value) = db_map.get_mut(key) else {
            return Ok(());
        };

        let list = match value {
            StorageValue::List(list) => list,
            _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
        };

        if !list.is_empty() {
            list.pop_back();
        }

        // Remove key if list is empty
        if list.is_empty() {
            db_map.remove(key);
        }

        Ok(())
    }

    /// Push elements to the left (head) of the list only if list exists.
    pub fn lpushx(&mut self, db: u64, key: &[u8], values: &[&[u8]]) -> Result<(), &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        let Some(storage_value) = db_map.get_mut(key) else {
            return Ok(());
        };

        let list = match storage_value {
            StorageValue::List(list) => list,
            _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
        };

        // Push values to the front in order (each one becomes the new head)
        for value in values {
            list.push_front(Bytes::new(value));
        }

        Ok(())
    }

    /// Push elements to the right (tail) of the list only if list exists.
    pub fn rpushx(&mut self, db: u64, key: &[u8], values: &[&[u8]]) -> Result<(), &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        let Some(storage_value) = db_map.get_mut(key) else {
            return Ok(());
        };

        let list = match storage_value {
            StorageValue::List(list) => list,
            _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
        };

        // Push values to the back
        for value in values {
            list.push_back(Bytes::new(value));
        }

        Ok(())
    }

    /// Remove elements from list.
    /// count > 0: Remove elements equal to value moving from head to tail.
    /// count < 0: Remove elements equal to value moving from tail to head.
    /// count = 0: Remove all elements equal to value.
    pub fn lrem(&mut self, db: u64, key: &[u8], count: i64, value: &[u8]) -> Result<(), &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        let Some(storage_value) = db_map.get_mut(key) else {
            return Ok(());
        };

        let list = match storage_value {
            StorageValue::List(list) => list,
            _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
        };

        let value_bytes = Bytes::new(value);

        if count == 0 {
            // Remove all occurrences
            *list = list.iter().filter(|v| *v != &value_bytes).cloned().collect();
        } else if count > 0 {
            // Remove from head to tail
            let max_remove = count as usize;
            let mut new_list = Vector::new();
            let mut removed = 0;
            for item in list.iter() {
                if removed < max_remove && item == &value_bytes {
                    removed += 1;
                } else {
                    new_list.push_back(item.clone());
                }
            }
            *list = new_list;
        } else {
            // Remove from tail to head (count < 0)
            let max_remove = (-count) as usize;
            let mut new_list = Vector::new();
            let mut removed = 0;
            for item in list.iter().rev() {
                if removed < max_remove && item == &value_bytes {
                    removed += 1;
                } else {
                    new_list.push_front(item.clone());
                }
            }
            *list = new_list;
        }

        // Remove key if list is empty
        if list.is_empty() {
            db_map.remove(key);
        }

        Ok(())
    }

    /// Trim list to the specified range. Both start and stop are inclusive.
    pub fn ltrim(&mut self, db: u64, key: &[u8], start: i64, stop: i64) -> Result<(), &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        let Some(storage_value) = db_map.get_mut(key) else {
            return Ok(());
        };

        let list = match storage_value {
            StorageValue::List(list) => list,
            _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
        };

        let len = list.len() as i64;

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

        // If range is invalid, delete the key
        if start_pos > stop_pos || start_pos >= len as usize {
            db_map.remove(key);
            return Ok(());
        }

        // Trim from front using skip, then trim from back to desired length
        let desired_len = stop_pos - start_pos + 1;
        *list = list.skip(start_pos).take(desired_len);

        // Remove key if list is empty
        if list.is_empty() {
            db_map.remove(key);
        }

        Ok(())
    }

    /// Insert element before or after pivot element in list.
    pub fn linsert(&mut self, db: u64, key: &[u8], before: bool, pivot: &[u8], value: &[u8]) -> Result<(), &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        let Some(storage_value) = db_map.get_mut(key) else {
            return Ok(());
        };

        let list = match storage_value {
            StorageValue::List(list) => list,
            _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
        };

        let pivot_bytes = Bytes::new(pivot);
        let value_bytes = Bytes::new(value);

        // Find the pivot and insert
        for i in 0..list.len() {
            if list.get(i) == Some(&pivot_bytes) {
                let insert_pos = if before { i } else { i + 1 };
                list.insert(insert_pos, value_bytes);
                break;
            }
        }

        Ok(())
    }

    /// Get the length of a list.
    pub fn llen(&self, db: u64, key: &[u8]) -> Result<usize, &'static str> {
        let Some(db_map) = self.map.get(&db) else {
            return Ok(0);
        };

        let Some(value) = db_map.get(key) else {
            return Ok(0);
        };

        let StorageValue::List(list) = value else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        Ok(list.len())
    }

    /// Get a range of elements from the list.
    /// Both start and stop are inclusive and support negative indices.
    pub fn lrange(&self, db: u64, key: &[u8], start: i64, stop: i64) -> Result<Vec<Bytes>, &'static str> {
        let Some(db_map) = self.map.get(&db) else {
            return Ok(Vec::new());
        };

        let Some(value) = db_map.get(key) else {
            return Ok(Vec::new());
        };

        let StorageValue::List(list) = value else {
            return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
        };

        let len = list.len() as i64;

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

        let result: Vec<Bytes> = list
            .iter()
            .skip(start_pos)
            .take(stop_pos - start_pos + 1)
            .cloned()
            .collect();

        Ok(result)
    }

    /// Set the list element at index to value.
    pub fn lset(&mut self, db: u64, key: &[u8], index: i64, value: &[u8]) -> Result<(), &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        let Some(storage_value) = db_map.get_mut(key) else {
            return Ok(());
        };

        let list = match storage_value {
            StorageValue::List(list) => list,
            _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
        };

        let len = list.len() as i64;

        // Normalize index
        let pos = if index < 0 {
            len + index
        } else {
            index
        };

        if pos >= 0 && pos < len {
            *list = list.update(pos as usize, Bytes::new(value));
        }

        Ok(())
    }

    /// Atomically pop from the right of source and push to the left of destination.
    pub fn rpoplpush(&mut self, db: u64, source_key: &[u8], dest_key: &[u8]) -> Result<(), &'static str> {
        // Special case: same key means rotate
        if source_key == dest_key {
            let Some(db_map) = self.map.get_mut(&db) else {
                return Ok(());
            };

            let Some(value) = db_map.get_mut(source_key) else {
                return Ok(());
            };

            let list = match value {
                StorageValue::List(list) => list,
                _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            };

            if !list.is_empty() {
                let popped = list.pop_back().unwrap();
                list.push_front(popped);
            }
            return Ok(());
        }

        // Different keys: pop from source
        let popped = {
            let Some(db_map) = self.map.get_mut(&db) else {
                return Ok(());
            };

            let Some(value) = db_map.get_mut(source_key) else {
                return Ok(());
            };

            let list = match value {
                StorageValue::List(list) => list,
                _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            };

            if list.is_empty() {
                return Ok(());
            }

            let popped = list.pop_back().unwrap();

            // Remove source key if list is empty
            let should_delete = list.is_empty();
            if should_delete {
                db_map.remove(source_key);
            }

            popped
        };

        // Push to destination
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        // Check destination type
        if let Some(value) = db_map.get(dest_key) {
            if !matches!(value, StorageValue::List(_)) {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
            }
        }

        let dest_list = db_map
            .entry(Bytes::new(dest_key))
            .or_insert_with(|| StorageValue::List(Vector::new()));

        let dest_list = match dest_list {
            StorageValue::List(l) => l,
            _ => unreachable!(),
        };

        dest_list.push_front(popped);

        Ok(())
    }

    /// Pop multiple elements from the left (head) of the list.
    pub fn lpop_count(&mut self, db: u64, key: &[u8], count: usize) -> Result<(), &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        let Some(value) = db_map.get_mut(key) else {
            return Ok(());
        };

        let list = match value {
            StorageValue::List(list) => list,
            _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
        };

        // Remove up to 'count' elements from the front
        let to_remove = count.min(list.len());
        for _ in 0..to_remove {
            *list = list.skip(1);
        }

        // Remove key if list is empty
        if list.is_empty() {
            db_map.remove(key);
        }

        Ok(())
    }

    /// Pop multiple elements from the right (tail) of the list.
    pub fn rpop_count(&mut self, db: u64, key: &[u8], count: usize) -> Result<(), &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        let Some(value) = db_map.get_mut(key) else {
            return Ok(());
        };

        let list = match value {
            StorageValue::List(list) => list,
            _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
        };

        // Remove up to 'count' elements from the back
        let to_remove = count.min(list.len());
        for _ in 0..to_remove {
            list.pop_back();
        }

        // Remove key if list is empty
        if list.is_empty() {
            db_map.remove(key);
        }

        Ok(())
    }

    /// Atomically move element from source to destination list.
    /// from_left: true = pop from left, false = pop from right
    /// to_left: true = push to left, false = push to right
    pub fn lmove(&mut self, db: u64, source_key: &[u8], dest_key: &[u8], from_left: bool, to_left: bool) -> Result<(), &'static str> {
        // Special case: same key means rotate
        if source_key == dest_key {
            let Some(db_map) = self.map.get_mut(&db) else {
                return Ok(());
            };

            let Some(value) = db_map.get_mut(source_key) else {
                return Ok(());
            };

            let list = match value {
                StorageValue::List(list) => list,
                _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            };

            if !list.is_empty() {
                if from_left {
                    let popped = list.head().cloned().unwrap();
                    *list = list.skip(1);
                    if to_left {
                        list.push_front(popped);
                    } else {
                        list.push_back(popped);
                    }
                } else {
                    let popped = list.pop_back().unwrap();
                    if to_left {
                        list.push_front(popped);
                    } else {
                        list.push_back(popped);
                    }
                }
            }
            return Ok(());
        }

        // Different keys: pop from source
        let popped = {
            let Some(db_map) = self.map.get_mut(&db) else {
                return Ok(());
            };

            let Some(value) = db_map.get_mut(source_key) else {
                return Ok(());
            };

            let list = match value {
                StorageValue::List(list) => list,
                _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            };

            if list.is_empty() {
                return Ok(());
            }

            let popped = if from_left {
                let popped = list.head().cloned().unwrap();
                *list = list.skip(1);
                popped
            } else {
                list.pop_back().unwrap()
            };

            // Remove source key if list is empty
            let should_delete = list.is_empty();
            if should_delete {
                db_map.remove(source_key);
            }

            popped
        };

        // Push to destination
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        // Check destination type
        if let Some(value) = db_map.get(dest_key) {
            if !matches!(value, StorageValue::List(_)) {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
            }
        }

        let dest_list = db_map
            .entry(Bytes::new(dest_key))
            .or_insert_with(|| StorageValue::List(Vector::new()));

        let dest_list = match dest_list {
            StorageValue::List(l) => l,
            _ => unreachable!(),
        };

        if to_left {
            dest_list.push_front(popped);
        } else {
            dest_list.push_back(popped);
        }

        Ok(())
    }
}
