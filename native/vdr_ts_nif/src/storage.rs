use std::collections::{BTreeMap, BTreeSet as StdBTreeSet, HashMap};
use std::collections::btree_map::Entry as BTreeEntry;
use std::cmp::Ordering;
use std::sync::Arc;
use im::Vector;
use indexset::BTreeSet;
use ordered_float::OrderedFloat;
use ouroboros::self_referencing;
use std::borrow::Borrow;
use std::ops::Bound;
use mlua::{Lua, Value as LuaValue};


pub type Score = OrderedFloat<f64>;

/// Aggregation type for sorted set operations
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Aggregate {
    Sum,
    Min,
    Max,
}

#[derive(Clone, Debug)]
pub struct Bytes(Arc<Vec<u8>>);

impl Bytes {
    fn new(data: &[u8]) -> Self {
        Bytes(Arc::new(data.to_vec()))
    }

    pub fn as_slice(&self) -> &[u8] {
        &self.0
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    #[allow(dead_code)]
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl Borrow<[u8]> for Bytes {
    fn borrow(&self) -> &[u8] {
        &self.0
    }
}

impl PartialEq for Bytes {
    fn eq(&self, other: &Self) -> bool {
        self.0.as_slice() == other.0.as_slice()
    }
}

impl Eq for Bytes {}

impl PartialOrd for Bytes {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Bytes {
    fn cmp(&self, other: &Self) -> Ordering {
        self.0.as_slice().cmp(other.0.as_slice())
    }
}

impl std::hash::Hash for Bytes {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.0.as_slice().hash(state);
    }
}

enum ZSetIndexKeyRef<'a> {
    #[allow(dead_code)]
    MinKey,
    #[allow(dead_code)]
    MaxKey,
    MinScoreKey(Score),
    MaxScoreKey(Score),
    Key { score: Score, entry: &'a [u8] },
}

enum ZSetIndexKeyData {
    #[allow(dead_code)]
    MinKey,
    #[allow(dead_code)]
    MaxKey,
    MinScoreKey(Score),
    MaxScoreKey(Score),
    Key{ score: Score, entry: Bytes },
}

#[self_referencing]
struct ZSetIndexKey {
    data: ZSetIndexKeyData,
    #[borrows(data)]
    #[covariant]
    ref_view: ZSetIndexKeyRef<'this>,
}

impl ZSetIndexKey {
    fn create(score: Score, data: &[u8]) -> Self {
        ZSetIndexKeyBuilder {
            data: ZSetIndexKeyData::Key { score: score, entry: Bytes::new(data)},
            ref_view_builder: |data: &ZSetIndexKeyData| match data {
                ZSetIndexKeyData::Key { score, entry } => ZSetIndexKeyRef::Key { score: *score, entry: entry.borrow() },
                _ => unreachable!(),
            },
        }
        .build()
    }

    fn min_score_key(score: Score) -> Self {
        ZSetIndexKeyBuilder {
            data: ZSetIndexKeyData::MinScoreKey(score),
            ref_view_builder: |data: &ZSetIndexKeyData| match data {
                ZSetIndexKeyData::MinScoreKey(score) => ZSetIndexKeyRef::MinScoreKey(*score),
                _ => unreachable!(),
            },
        }
        .build()
    }

    fn max_score_key(score: Score) -> Self {
        ZSetIndexKeyBuilder {
            data: ZSetIndexKeyData::MaxScoreKey(score),
            ref_view_builder: |data: &ZSetIndexKeyData| match data {
                ZSetIndexKeyData::MaxScoreKey(score) => ZSetIndexKeyRef::MaxScoreKey(*score),
                _ => unreachable!(),
            },
        }
        .build()
    }

    fn get_entry_and_score(&self) -> Option<(Bytes, Score)> {
        self.with_data(|data| {
            if let ZSetIndexKeyData::Key { score, entry } = data {
                Some((entry.clone(), *score))
            } else {
                None
            }
        })
    }
}

impl Borrow<ZSetIndexKeyRef<'static>> for ZSetIndexKey {
    fn borrow(&self) -> &ZSetIndexKeyRef<'static> {
        unsafe { std::mem::transmute(self.borrow_ref_view()) }
    }
}

impl<'a> ZSetIndexKeyRef<'a> {
    fn lookup_key_ref(score: Score, member: &'a [u8]) -> ZSetIndexKeyRef<'static> {
        unsafe { ZSetIndexKeyRef::Key { score, entry: std::mem::transmute(member) } }
    }
}

impl ZSetIndexKey {
    fn as_ref<'a>(&'a self) -> &'a ZSetIndexKeyRef<'a> {
        self.borrow_ref_view()
    }
}

// Implement ordering traits by delegating to the contained ZSetIndexKeyRef
impl PartialEq for ZSetIndexKey {
    fn eq(&self, other: &Self) -> bool {
        self.as_ref() == other.as_ref()
    }
}

impl Eq for ZSetIndexKey {}

impl PartialOrd for ZSetIndexKey {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for ZSetIndexKey {
    fn cmp(&self, other: &Self) -> Ordering {
        self.as_ref().cmp(other.as_ref())
    }
}


impl<'a> PartialEq for ZSetIndexKeyRef<'a> {
    fn eq(&self, other: &Self) -> bool {
        matches!(self.cmp(other), Ordering::Equal)
    }
}

impl<'a> Eq for ZSetIndexKeyRef<'a> {}

impl<'a> PartialOrd for ZSetIndexKeyRef<'a> {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl<'a> Ord for ZSetIndexKeyRef<'a> {
    fn cmp(&self, other: &Self) -> Ordering {
        use ZSetIndexKeyRef::*;

        match (self, other) {
            // MinKey is less than everything except itself
            (MinKey, MinKey) => Ordering::Equal,
            (MinKey, _) => Ordering::Less,
            (_, MinKey) => Ordering::Greater,

            // MaxKey is greater than everything except itself
            (MaxKey, MaxKey) => Ordering::Equal,
            (MaxKey, _) => Ordering::Greater,
            (_, MaxKey) => Ordering::Less,

            // MinScoreKey comparisons
            (MinScoreKey(s1), MinScoreKey(s2)) => s1.cmp(s2),
            (MinScoreKey(s1), MaxScoreKey(s2)) => {
                match s1.cmp(s2) {
                    Ordering::Equal => Ordering::Less,  // MinScore < MaxScore for same score
                    other => other,
                }
            }
            (MinScoreKey(s1), Key { score: s2, .. }) => {
                match s1.cmp(s2) {
                    Ordering::Equal => Ordering::Less,  // MinScore < Key for same score
                    other => other,
                }
            }

            // MaxScoreKey comparisons
            (MaxScoreKey(s1), MinScoreKey(s2)) => {
                match s1.cmp(s2) {
                    Ordering::Equal => Ordering::Greater,  // MaxScore > MinScore for same score
                    other => other,
                }
            }
            (MaxScoreKey(s1), MaxScoreKey(s2)) => s1.cmp(s2),
            (MaxScoreKey(s1), Key { score: s2, .. }) => {
                match s1.cmp(s2) {
                    Ordering::Equal => Ordering::Greater,  // MaxScore > Key for same score
                    other => other,
                }
            }

            // Key comparisons
            (Key { score: s1, .. }, MinScoreKey(s2)) => {
                match s1.cmp(s2) {
                    Ordering::Equal => Ordering::Greater,  // Key > MinScore for same score
                    other => other,
                }
            }
            (Key { score: s1, .. }, MaxScoreKey(s2)) => {
                match s1.cmp(s2) {
                    Ordering::Equal => Ordering::Less,  // Key < MaxScore for same score
                    other => other,
                }
            }
            (Key { score: s1, entry: e1 }, Key { score: s2, entry: e2 }) => {
                // First compare scores, then entries lexicographically
                match s1.cmp(s2) {
                    Ordering::Equal => e1.cmp(e2),
                    other => other,
                }
            }
        }
    }
}

/// Sorted set (zset) data structure
/// Maintains both a sorted index and a member->score map for efficient operations
pub struct ZSet {
    /// Sorted index for range queries and sorted iteration
    /// Uses indexset::BTreeSet for efficient rank and range operations
    /// Ordered by ZSetIndexKey which contains ZSetIndexKeyRef for zero-copy lookups
    index: BTreeSet<ZSetIndexKey>,
    /// Member to score mapping for quick lookups
    /// Uses HashMap for O(1) average case lookups
    /// Keys are Bytes which implement Borrow<[u8]> for zero-copy lookups
    entries: HashMap<Bytes, Score>,
}

impl ZSet {
    fn new() -> Self {
        ZSet {
            index: BTreeSet::new(),
            entries: HashMap::new(),
        }
    }

    fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    fn len(&self) -> usize {
        self.entries.len()
    }
}

/// Storage value types
pub enum StorageValue {
    String(Bytes),
    Set(StdBTreeSet<Bytes>),
    List(Vector<Bytes>),
    Hash(BTreeMap<Bytes, Bytes>),
    ZSet(ZSet),
}

/// Inner storage structure
pub struct StorageInner {
    map: BTreeMap<u64, BTreeMap<Bytes, StorageValue>>,
    lua: Lua,
}

// Helper function to extract storage and db from Lua context
fn get_tx_ctx(lua_ctx: &mlua::Lua) -> mlua::Result<(&StorageInner, u64)> {
    let db: u64 = lua_ctx.globals().get("__db")?;
    let storage_ptr: mlua::LightUserData = lua_ctx.globals().get("__storage_ptr")?;
    // SAFETY: The pointer is valid for the duration of tx() call
    let storage = unsafe { &*(storage_ptr.0 as *const StorageInner) };
    Ok((storage, db))
}

impl StorageInner {
    /// Create a new empty storage
    pub fn new() -> Self {
        let lua = Lua::new();

        // Initialize globals once
        lua.globals().set("__db", 0u64).expect("Failed to set __db global");
        lua.globals().set("__storage_ptr", mlua::LightUserData(std::ptr::null_mut())).expect("Failed to set __storage_ptr");

        // Create ts.get function once
        let get_fn = lua.create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            let key_bytes = key.as_bytes();

            match storage.get(db, &key_bytes) {
                Ok(Some(value)) => {
                    let bytes = value.as_slice();
                    Ok(Some(lua_ctx.create_string(bytes)?))
                }
                Ok(None) => Ok(None),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create get function");

        // Create ts.hget function once
        let hget_fn = lua.create_function(|lua_ctx, (key, field): (mlua::String, mlua::String)| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            let key_bytes = key.as_bytes();
            let field_bytes = field.as_bytes();

            match storage.hget(db, &key_bytes, &field_bytes) {
                Ok(Some(value)) => {
                    let bytes = value.as_slice();
                    Ok(Some(lua_ctx.create_string(bytes)?))
                }
                Ok(None) => Ok(None),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create hget function");

        // List functions
        let llen_fn = lua.create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            match storage.llen(db, &key.as_bytes()) {
                Ok(len) => Ok(len as i64),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create llen");

        let lrange_fn = lua.create_function(|lua_ctx, (key, start, stop): (mlua::String, i64, i64)| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            match storage.lrange(db, &key.as_bytes(), start, stop) {
                Ok(elements) => {
                    let table = lua_ctx.create_table()?;
                    for (i, elem) in elements.iter().enumerate() {
                        table.set(i + 1, lua_ctx.create_string(elem.as_slice())?)?;
                    }
                    Ok(table)
                }
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create lrange");

        // Set functions
        let smembers_fn = lua.create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            match storage.smembers(db, &key.as_bytes()) {
                Ok(members) => {
                    let table = lua_ctx.create_table()?;
                    for (i, member) in members.iter().enumerate() {
                        table.set(i + 1, lua_ctx.create_string(member.as_slice())?)?;
                    }
                    Ok(table)
                }
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create smembers");

        let sismember_fn = lua.create_function(|lua_ctx, (key, member): (mlua::String, mlua::String)| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            match storage.sismember(db, &key.as_bytes(), &member.as_bytes()) {
                Ok(is_member) => Ok(is_member),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create sismember");

        let scard_fn = lua.create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            match storage.scard(db, &key.as_bytes()) {
                Ok(count) => Ok(count as i64),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create scard");

        // Hash functions
        let hmget_fn = lua.create_function(|lua_ctx, (key, fields): (mlua::String, mlua::Table)| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            let mut field_vec = Vec::new();
            for pair in fields.pairs::<i64, mlua::String>() {
                let (_, field) = pair?;
                field_vec.push(field.as_bytes().to_vec());
            }
            let field_refs: Vec<&[u8]> = field_vec.iter().map(|v| v.as_slice()).collect();

            match storage.hmget(db, &key.as_bytes(), &field_refs) {
                Ok(values) => {
                    let table = lua_ctx.create_table()?;
                    for (i, value) in values.iter().enumerate() {
                        if let Some(v) = value {
                            table.set(i + 1, lua_ctx.create_string(v.as_slice())?)?;
                        } else {
                            table.set(i + 1, mlua::Value::Nil)?;
                        }
                    }
                    Ok(table)
                }
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create hmget");

        let hgetall_fn = lua.create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            match storage.hgetall(db, &key.as_bytes()) {
                Ok(pairs) => {
                    let table = lua_ctx.create_table()?;
                    for (field, value) in pairs {
                        table.set(
                            lua_ctx.create_string(field.as_slice())?,
                            lua_ctx.create_string(value.as_slice())?
                        )?;
                    }
                    Ok(table)
                }
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create hgetall");

        let hkeys_fn = lua.create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            match storage.hkeys(db, &key.as_bytes()) {
                Ok(keys) => {
                    let table = lua_ctx.create_table()?;
                    for (i, k) in keys.iter().enumerate() {
                        table.set(i + 1, lua_ctx.create_string(k.as_slice())?)?;
                    }
                    Ok(table)
                }
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create hkeys");

        let hvals_fn = lua.create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            match storage.hvals(db, &key.as_bytes()) {
                Ok(values) => {
                    let table = lua_ctx.create_table()?;
                    for (i, v) in values.iter().enumerate() {
                        table.set(i + 1, lua_ctx.create_string(v.as_slice())?)?;
                    }
                    Ok(table)
                }
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create hvals");

        let hlen_fn = lua.create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            match storage.hlen(db, &key.as_bytes()) {
                Ok(len) => Ok(len as i64),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create hlen");

        let hexists_fn = lua.create_function(|lua_ctx, (key, field): (mlua::String, mlua::String)| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            match storage.hexists(db, &key.as_bytes(), &field.as_bytes()) {
                Ok(exists) => Ok(exists),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create hexists");

        // Sorted set functions
        let zscore_fn = lua.create_function(|lua_ctx, (key, member): (mlua::String, mlua::String)| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            match storage.zscore(db, &key.as_bytes(), &member.as_bytes()) {
                Ok(Some(score)) => Ok(Some(score.into_inner())),
                Ok(None) => Ok(None),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create zscore");

        let zcard_fn = lua.create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            match storage.zcard(db, &key.as_bytes()) {
                Ok(count) => Ok(count as i64),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create zcard");

        let zrange_fn = lua.create_function(|lua_ctx, (key, start, stop): (mlua::String, i64, i64)| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            match storage.zrange(db, &key.as_bytes(), start, stop, true) {
                Ok(results) => {
                    let table = lua_ctx.create_table()?;
                    for (i, (member, score_opt)) in results.iter().enumerate() {
                        let item = lua_ctx.create_table()?;
                        item.set(1, lua_ctx.create_string(member.as_slice())?)?;
                        if let Some(score) = score_opt {
                            item.set(2, score.into_inner())?;
                        }
                        table.set(i + 1, item)?;
                    }
                    Ok(table)
                }
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create zrange");

        let zrangebyscore_fn = lua.create_function(|lua_ctx, (key, min, max): (mlua::String, f64, f64)| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            match storage.zrangebyscore(db, &key.as_bytes(), OrderedFloat(min), OrderedFloat(max), true) {
                Ok(results) => {
                    let table = lua_ctx.create_table()?;
                    for (i, (member, score_opt)) in results.iter().enumerate() {
                        let item = lua_ctx.create_table()?;
                        item.set(1, lua_ctx.create_string(member.as_slice())?)?;
                        if let Some(score) = score_opt {
                            item.set(2, score.into_inner())?;
                        }
                        table.set(i + 1, item)?;
                    }
                    Ok(table)
                }
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create zrangebyscore");

        let zrank_fn = lua.create_function(|lua_ctx, (key, member): (mlua::String, mlua::String)| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            match storage.zrank(db, &key.as_bytes(), &member.as_bytes()) {
                Ok(Some(rank)) => Ok(Some(rank as i64)),
                Ok(None) => Ok(None),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create zrank");

        let zrevrank_fn = lua.create_function(|lua_ctx, (key, member): (mlua::String, mlua::String)| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            match storage.zrevrank(db, &key.as_bytes(), &member.as_bytes()) {
                Ok(Some(rank)) => Ok(Some(rank as i64)),
                Ok(None) => Ok(None),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create zrevrank");

        let zcount_fn = lua.create_function(|lua_ctx, (key, min, max): (mlua::String, f64, f64)| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            match storage.zcount(db, &key.as_bytes(), OrderedFloat(min), OrderedFloat(max)) {
                Ok(count) => Ok(count as i64),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create zcount");

        let zfirst_fn = lua.create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            match storage.zfirst(db, &key.as_bytes()) {
                Ok(Some((score, member))) => {
                    Ok((Some(score.into_inner()), Some(lua_ctx.create_string(member.as_slice())?)))
                }
                Ok(None) => Ok((None::<f64>, None::<mlua::String>)),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create zfirst");

        let zlast_fn = lua.create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            match storage.zlast(db, &key.as_bytes()) {
                Ok(Some((score, member))) => {
                    Ok((Some(score.into_inner()), Some(lua_ctx.create_string(member.as_slice())?)))
                }
                Ok(None) => Ok((None::<f64>, None::<mlua::String>)),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create zlast");

        let znext_fn = lua.create_function(|lua_ctx, (key, score, member): (mlua::String, f64, mlua::String)| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            match storage.znext(db, &key.as_bytes(), OrderedFloat(score), &member.as_bytes()) {
                Ok(Some((next_score, next_member))) => {
                    Ok((Some(next_score.into_inner()), Some(lua_ctx.create_string(next_member.as_slice())?)))
                }
                Ok(None) => Ok((None::<f64>, None::<mlua::String>)),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create znext");

        let zprev_fn = lua.create_function(|lua_ctx, (key, score, member): (mlua::String, f64, mlua::String)| {
            let (storage, db) = get_tx_ctx(&lua_ctx)?;
            match storage.zprev(db, &key.as_bytes(), OrderedFloat(score), &member.as_bytes()) {
                Ok(Some((prev_score, prev_member))) => {
                    Ok((Some(prev_score.into_inner()), Some(lua_ctx.create_string(prev_member.as_slice())?)))
                }
                Ok(None) => Ok((None::<f64>, None::<mlua::String>)),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        }).expect("Failed to create zprev");

        // Create the ts table once with all functions
        let ts_table = lua.create_table().expect("Failed to create ts table");

        // String functions
        ts_table.set("get", get_fn).expect("Failed to set get");

        // List functions
        ts_table.set("llen", llen_fn).expect("Failed to set llen");
        ts_table.set("lrange", lrange_fn).expect("Failed to set lrange");

        // Set functions
        ts_table.set("smembers", smembers_fn).expect("Failed to set smembers");
        ts_table.set("sismember", sismember_fn).expect("Failed to set sismember");
        ts_table.set("scard", scard_fn).expect("Failed to set scard");

        // Hash functions
        ts_table.set("hget", hget_fn).expect("Failed to set hget");
        ts_table.set("hmget", hmget_fn).expect("Failed to set hmget");
        ts_table.set("hgetall", hgetall_fn).expect("Failed to set hgetall");
        ts_table.set("hkeys", hkeys_fn).expect("Failed to set hkeys");
        ts_table.set("hvals", hvals_fn).expect("Failed to set hvals");
        ts_table.set("hlen", hlen_fn).expect("Failed to set hlen");
        ts_table.set("hexists", hexists_fn).expect("Failed to set hexists");

        // Sorted set functions
        ts_table.set("zscore", zscore_fn).expect("Failed to set zscore");
        ts_table.set("zcard", zcard_fn).expect("Failed to set zcard");
        ts_table.set("zrange", zrange_fn).expect("Failed to set zrange");
        ts_table.set("zrangebyscore", zrangebyscore_fn).expect("Failed to set zrangebyscore");
        ts_table.set("zrank", zrank_fn).expect("Failed to set zrank");
        ts_table.set("zrevrank", zrevrank_fn).expect("Failed to set zrevrank");
        ts_table.set("zcount", zcount_fn).expect("Failed to set zcount");
        ts_table.set("zfirst", zfirst_fn).expect("Failed to set zfirst");
        ts_table.set("zlast", zlast_fn).expect("Failed to set zlast");
        ts_table.set("znext", znext_fn).expect("Failed to set znext");
        ts_table.set("zprev", zprev_fn).expect("Failed to set zprev");

        lua.globals().set("ts", ts_table).expect("Failed to set ts global");

        StorageInner {
            map: BTreeMap::new(),
            lua,
        }
    }

    /// Set a key-value pair in a specific database
    pub fn set(&mut self, db: u64, key: &[u8], value: &[u8]) {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);
        db_map.insert(Bytes::new(key), StorageValue::String(Bytes::new(value)));
    }

    /// Set multiple key-value pairs atomically in a specific database
    pub fn mset(&mut self, db: u64, pairs: &[(&[u8], &[u8])]) {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);
        for (key, value) in pairs {
            db_map.insert(Bytes::new(key), StorageValue::String(Bytes::new(value)));
        }
    }

    /// Get a value by key from a specific database
    pub fn get(&self, db: u64, key: &[u8]) -> Result<Option<Bytes>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::String(value)) => Ok(Some(value.clone())),
            Some(StorageValue::Set(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) => {
                Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => Ok(None),
        }
    }

    /// Delete a key from a specific database
    pub fn del(&mut self, db: u64, key: &[u8]) {
        if let Some(db_map) = self.map.get_mut(&db) {
            db_map.remove(key);
        }
    }

    /// Null handler for PEXPIREAT - accepts but ignores expiration timestamp
    /// In future, this could store expiration metadata and trigger background cleanup
    pub fn pexpireat(&mut self, _db: u64, _key: &[u8], _timestamp_ms: i64) -> Result<(), &'static str> {
        // For now, just accept and ignore the expiration
        // TODO: Implement actual expiration tracking and background cleanup
        Ok(())
    }

    /// Rename a key. Overwrites destination key if it exists.
    pub fn rename(&mut self, db: u64, old_key: &[u8], new_key: &[u8]) -> Result<(), &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        // Remove old key and get its value
        let Some(value) = db_map.remove(old_key) else {
            return Ok(());
        };

        // Insert at new key (overwrites if exists)
        db_map.insert(Bytes::new(new_key), value);
        Ok(())
    }

    /// Rename a key only if the new key doesn't exist.
    pub fn renamenx(&mut self, db: u64, old_key: &[u8], new_key: &[u8]) -> Result<(), &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        // Check if destination already exists
        if db_map.contains_key(new_key) {
            return Ok(());
        }

        // Remove old key and get its value
        let Some(value) = db_map.remove(old_key) else {
            return Ok(());
        };

        // Insert at new key
        db_map.insert(Bytes::new(new_key), value);
        Ok(())
    }

    /// Move a key from one database to another. Overwrites destination key if it exists.
    pub fn move_key(&mut self, source_db: u64, dest_db: u64, key: &[u8]) -> Result<(), &'static str> {
        // Get value from source db
        let value = {
            let Some(source_map) = self.map.get_mut(&source_db) else {
                return Ok(());
            };

            let Some(value) = source_map.remove(key) else {
                return Ok(());
            };

            value
        };

        // Insert into destination db
        let dest_map = self.map.entry(dest_db).or_insert_with(BTreeMap::new);
        dest_map.insert(Bytes::new(key), value);

        Ok(())
    }

    /// Append value to an existing string. Creates key if it doesn't exist.
    pub fn append(&mut self, db: u64, key: &[u8], value: &[u8]) -> Result<(), &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        match db_map.entry(Bytes::new(key)) {
            BTreeEntry::Occupied(mut e) => {
                match e.get_mut() {
                    StorageValue::String(existing) => {
                        // Create new concatenated value
                        let mut new_bytes = existing.as_slice().to_vec();
                        new_bytes.extend_from_slice(value);
                        *existing = Bytes::new(&new_bytes);
                        Ok(())
                    }
                    _ => Err("WRONGTYPE Operation against a key holding the wrong kind of value")
                }
            }
            BTreeEntry::Vacant(e) => {
                // Key doesn't exist, create it
                e.insert(StorageValue::String(Bytes::new(value)));
                Ok(())
            }
        }
    }

    /// Clear all entries from all databases
    pub fn clear(&mut self) {
        self.map.clear();
    }

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

    // List operations

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

        // Extract the range
        let trimmed: Vector<Bytes> = list
            .iter()
            .skip(start_pos)
            .take(stop_pos - start_pos + 1)
            .cloned()
            .collect();

        *list = trimmed;

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
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::List(list)) => Ok(list.len()),
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(0),
        }
    }

    /// Get a range of elements from the list.
    /// Both start and stop are inclusive and support negative indices.
    pub fn lrange(&self, db: u64, key: &[u8], start: i64, stop: i64) -> Result<Vec<Bytes>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::List(list)) => {
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
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(Vec::new()),
        }
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

    // Hash operations

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

    // Sorted set (zset) operations

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
    pub fn zremrangebyscore(&mut self, db: u64, key: &[u8], min: Score, max: Score, min_exclusive: bool, max_exclusive: bool) -> Result<(), &'static str> {
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

    /// Execute a Lua script with access to ts.get and ts.hget functions.
    /// The script has access to ts.get(key) and ts.hget(key, field).
    pub fn lua_load(&self, script: &[u8]) -> Result<Vec<u8>, String> {
        // Compile the script to bytecode
        let func = self.lua.load(script).into_function().map_err(|e| e.to_string())?;
        Ok(func.dump(false))
    }

    pub fn tx(&self, db: u64, script_or_bytecode: &[u8]) -> Result<LuaValue, String> {
        // Set the current database and storage pointer in global variables
        self.lua.globals().set("__db", db).map_err(|e| e.to_string())?;
        self.lua.globals().set("__storage_ptr", mlua::LightUserData(self as *const _ as *mut _)).map_err(|e| e.to_string())?;

        // Execute the script or bytecode (mlua's load() handles both)
        let result: LuaValue = self.lua.load(script_or_bytecode).eval().map_err(|e| e.to_string())?;

        // Clear the storage pointer for safety
        self.lua.globals().set("__storage_ptr", mlua::LightUserData(std::ptr::null_mut())).map_err(|e| e.to_string())?;

        Ok(result)
    }
}
