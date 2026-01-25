mod atoms;
mod read_commands;
mod storage;
mod write_commands;

// for Encoder trait (.encode())
use rustler::Encoder;
use std::sync::Mutex;

use storage::StorageInner;

/// The term storage resource (wrapper around Mutex to satisfy orphan rule)
pub struct TStorage(Mutex<StorageInner>);

#[rustler::resource_impl(register = false)]
impl rustler::Resource for TStorage {}

#[rustler::nif(name = "create")]
fn create_storage() -> rustler::ResourceArc<TStorage> {
    rustler::ResourceArc::new(TStorage(Mutex::new(StorageInner::new())))
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
            if table.contains_key(i).map_err(|e| e.to_string())? == false {
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
    env.register::<TStorage>().is_ok()
}
