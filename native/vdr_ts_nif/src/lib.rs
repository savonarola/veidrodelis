mod atoms;
mod read_commands;
mod storage;
mod write_commands;

// for Encoder trait (.encode())
use rustler::Encoder;
use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::Mutex;

use storage::StorageInner;

/// The term storage resource (wrapper around Mutex to satisfy orphan rule)
pub struct TStorage(Mutex<StorageInner>);

#[rustler::resource_impl(register = false)]
impl rustler::Resource for TStorage {}

#[derive(Default)]
struct RadixNode {
    watchers: BTreeSet<i64>,
    children: BTreeMap<u8, RadixNode>,
}

impl RadixNode {
    fn insert(&mut self, prefix: &[u8], idx: i64) {
        let mut node = self;

        for byte in prefix {
            node = node.children.entry(*byte).or_default();
        }

        node.watchers.insert(idx);
    }

    fn delete(&mut self, prefix: &[u8], idx: i64) -> bool {
        self.delete_at(prefix, idx, 0);
        self.is_empty()
    }

    fn delete_at(&mut self, prefix: &[u8], idx: i64, offset: usize) -> bool {
        if offset == prefix.len() {
            self.watchers.remove(&idx);
        } else if let Some(child) = self.children.get_mut(&prefix[offset]) {
            if child.delete_at(prefix, idx, offset + 1) {
                self.children.remove(&prefix[offset]);
            }
        }

        self.is_empty()
    }

    fn lookup(&self, key: &[u8], out: &mut BTreeSet<i64>) {
        out.extend(self.watchers.iter().copied());

        let mut node = self;

        for byte in key {
            match node.children.get(byte) {
                Some(child) => {
                    node = child;
                    out.extend(node.watchers.iter().copied());
                }
                None => break,
            }
        }
    }

    fn is_empty(&self) -> bool {
        self.watchers.is_empty() && self.children.is_empty()
    }
}

pub struct PrefixWatchTree {
    roots: RefCell<HashMap<u64, RadixNode>>,
}

// The owning Elixir process serializes access to this resource. The RefCell keeps
// mutation lock-free while Rustler still requires resource thread-safety markers.
unsafe impl Send for PrefixWatchTree {}
unsafe impl Sync for PrefixWatchTree {}
impl std::panic::RefUnwindSafe for PrefixWatchTree {}
impl std::panic::UnwindSafe for PrefixWatchTree {}

#[rustler::resource_impl(register = false)]
impl rustler::Resource for PrefixWatchTree {}

#[rustler::nif(name = "create")]
fn create_storage() -> rustler::ResourceArc<TStorage> {
    rustler::ResourceArc::new(TStorage(Mutex::new(StorageInner::new())))
}

#[rustler::nif(name = "watch_prefix_tree_create")]
fn watch_prefix_tree_create() -> rustler::ResourceArc<PrefixWatchTree> {
    rustler::ResourceArc::new(PrefixWatchTree {
        roots: RefCell::new(HashMap::new()),
    })
}

#[rustler::nif(name = "watch_prefix_tree_insert")]
fn watch_prefix_tree_insert(
    tree: rustler::ResourceArc<PrefixWatchTree>,
    db: u64,
    prefix: rustler::Binary,
    idx: i64,
) -> rustler::Atom {
    let mut roots = tree.roots.borrow_mut();
    roots.entry(db).or_default().insert(prefix.as_slice(), idx);

    atoms::ok()
}

#[rustler::nif(name = "watch_prefix_tree_delete")]
fn watch_prefix_tree_delete(
    tree: rustler::ResourceArc<PrefixWatchTree>,
    db: u64,
    prefix: rustler::Binary,
    idx: i64,
) -> rustler::Atom {
    let mut roots = tree.roots.borrow_mut();

    if let Some(root) = roots.get_mut(&db) {
        if root.delete(prefix.as_slice(), idx) {
            roots.remove(&db);
        }
    }

    atoms::ok()
}

#[rustler::nif(name = "watch_prefix_tree_lookup")]
fn watch_prefix_tree_lookup(
    tree: rustler::ResourceArc<PrefixWatchTree>,
    db: u64,
    key: rustler::Binary,
) -> Vec<i64> {
    let roots = tree.roots.borrow();
    let mut result = BTreeSet::new();

    if let Some(root) = roots.get(&db) {
        root.lookup(key.as_slice(), &mut result);
    }

    result.into_iter().collect()
}

#[rustler::nif(name = "destroy")]
fn destroy_storage<'a>(
    env: rustler::Env<'a>,
    storage: rustler::ResourceArc<TStorage>,
) -> rustler::Term<'a> {
    // Lock the storage
    let mut inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    // Clear all entries using encapsulated method
    inner.clear();

    // Return :ok
    atoms::ok().encode(env)
}

// Batch write command execution NIF
// Executes multiple write commands under a single mutex lock
#[rustler::nif(name = "tx")]
fn execute_write_commands<'a>(
    env: rustler::Env<'a>,
    storage: rustler::ResourceArc<TStorage>,
    commands: Vec<rustler::Term<'a>>,
) -> rustler::Term<'a> {
    // Lock the storage once for all commands
    let mut inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    let mut results = Vec::new();

    // Execute each command
    for cmd_term in commands {
        let result = write_commands::execute(env, &mut inner, cmd_term);
        results.push(result);
    }

    results.encode(env)
}

// Batch read command execution NIF
// Executes multiple read-only commands under a single mutex lock
#[rustler::nif(name = "read_tx_commands")]
fn execute_read_commands<'a>(
    env: rustler::Env<'a>,
    storage: rustler::ResourceArc<TStorage>,
    db: u64,
    commands: Vec<rustler::Term<'a>>,
) -> rustler::Term<'a> {
    // Lock the storage once for all commands
    let inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    let mut results = Vec::new();

    // Execute each command
    for cmd_term in commands {
        let result = read_commands::execute(env, &inner, db, cmd_term);
        results.push(result);
    }

    (atoms::ok(), results).encode(env)
}

#[rustler::nif(name = "lua_load")]
fn lua_load<'a>(
    env: rustler::Env<'a>,
    storage: rustler::ResourceArc<TStorage>,
    script: rustler::Binary,
) -> rustler::Term<'a> {
    // Lock the storage
    let inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    // Compile the script to bytecode
    match inner.lua_load(script.as_slice()) {
        Ok(bytecode) => {
            let mut binary = rustler::types::OwnedBinary::new(bytecode.len()).unwrap();
            binary.as_mut_slice().copy_from_slice(&bytecode);
            (atoms::ok(), binary.release(env)).encode(env)
        }
        Err(e) => (atoms::error(), e).encode(env),
    }
}

// Helper to convert Lua tables to Elixir terms
fn lua_table_to_term<'a>(
    env: rustler::Env<'a>,
    table: &mlua::Table,
) -> Result<rustler::Term<'a>, String> {
    // Check if it's a list (sequential integer keys starting from 1)
    let len = table.len().map_err(|e| e.to_string())?;

    if len > 0 {
        // Try to read as array (1-indexed)
        let mut is_array = true;
        for i in 1..=len {
            if !table.contains_key(i).map_err(|e| e.to_string())? {
                is_array = false;
                break;
            }
        }

        if is_array {
            // Convert to Elixir list
            let mut list_items = Vec::new();
            for i in 1..=len {
                let value: mlua::Value = table.get(i).map_err(|e| e.to_string())?;
                list_items.push(lua_value_to_term(env, value)?);
            }
            return Ok(list_items.encode(env));
        }
    }

    // Convert to Elixir map
    let mut map = rustler::types::map::map_new(env);
    for pair in table.pairs::<mlua::Value, mlua::Value>() {
        let (k, v) = pair.map_err(|e| e.to_string())?;
        let key_term = lua_value_to_term(env, k)?;
        let val_term = lua_value_to_term(env, v)?;
        map = map
            .map_put(key_term, val_term)
            .map_err(|e| format!("{:?}", e))?;
    }

    Ok(map)
}

// Helper to convert Lua values to Elixir terms
fn lua_value_to_term<'a>(
    env: rustler::Env<'a>,
    value: mlua::Value,
) -> Result<rustler::Term<'a>, String> {
    match value {
        mlua::Value::Nil => Ok(atoms::nil().encode(env)),
        mlua::Value::Boolean(b) => Ok(b.encode(env)),
        mlua::Value::Integer(i) => Ok(i.encode(env)),
        mlua::Value::Number(n) => Ok(n.encode(env)),
        mlua::Value::String(s) => {
            let bytes = s.as_bytes();
            let mut binary = rustler::types::OwnedBinary::new(bytes.len()).unwrap();
            binary.as_mut_slice().copy_from_slice(&bytes);
            Ok(binary.release(env).encode(env))
        }
        mlua::Value::Table(t) => lua_table_to_term(env, &t),
        _ => Err("Unsupported Lua type".to_string()),
    }
}

#[rustler::nif(name = "read_tx_lua")]
fn execute_tx_lua<'a>(
    env: rustler::Env<'a>,
    storage: rustler::ResourceArc<TStorage>,
    db: u64,
    script_or_bytecode: rustler::Binary,
) -> rustler::Term<'a> {
    // Lock the storage
    let inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    // Execute the Lua script or bytecode
    match inner.tx(db, script_or_bytecode.as_slice()) {
        Ok(lua_value) => match lua_value_to_term(env, lua_value) {
            Ok(term) => (atoms::ok(), term).encode(env),
            Err(e) => (atoms::error(), e).encode(env),
        },
        Err(e) => (atoms::error(), e).encode(env),
    }
}

rustler::init!("Elixir.Vdr.TS", load = load_nif);

fn load_nif(env: rustler::Env, _: rustler::Term) -> bool {
    env.register::<TStorage>().is_ok() && env.register::<PrefixWatchTree>().is_ok()
}
