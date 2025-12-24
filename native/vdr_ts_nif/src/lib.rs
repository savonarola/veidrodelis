mod atoms;
mod storage;

use rustler::types::Binary;
use rustler::{Encoder, Env, Resource, ResourceArc, Term};
use std::sync::Mutex;

use storage::StorageInner;

/// The term storage resource (wrapper around Mutex to satisfy orphan rule)
pub struct TStorage(Mutex<StorageInner>);

#[rustler::resource_impl(register = false)]
impl Resource for TStorage {}

#[rustler::nif(name = "create")]
fn create_storage() -> ResourceArc<TStorage> {
    ResourceArc::new(TStorage(Mutex::new(StorageInner::new())))
}

#[rustler::nif(name = "set")]
fn set_value<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
    value: Binary,
) -> Term<'a> {
    // Lock the storage to get mutable access
    let mut inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    // Set the value using encapsulated method
    inner.set(db, key.as_slice(), value.as_slice());

    // Return :ok
    atoms::ok().encode(env)
}

#[rustler::nif(name = "get")]
fn get_value<'a>(env: Env<'a>, storage: ResourceArc<TStorage>, db: u64, key: Binary) -> Term<'a> {
    // Lock the storage
    let inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    // Get the value using encapsulated method
    match inner.get(db, key.as_slice()) {
        Ok(Some(value)) => {
            // Return the binary value
            let mut binary = rustler::types::OwnedBinary::new(value.len()).unwrap();
            binary.as_mut_slice().copy_from_slice(value);
            binary.release(env).encode(env)
        }
        Ok(None) => {
            // Return nil for missing keys
            atoms::nil().encode(env)
        }
        Err(_err_msg) => {
            // Return {:error, :wrong_type}
            (atoms::error(), atoms::wrong_type()).encode(env)
        }
    }
}

#[rustler::nif(name = "del")]
fn delete_value<'a>(env: Env<'a>, storage: ResourceArc<TStorage>, db: u64, key: Binary) -> Term<'a> {
    // Lock the storage
    let mut inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    // Delete the key using encapsulated method
    inner.del(db, key.as_slice());

    // Always return :ok
    atoms::ok().encode(env)
}

#[rustler::nif(name = "destroy")]
fn destroy_storage<'a>(env: Env<'a>, storage: ResourceArc<TStorage>) -> Term<'a> {
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

// Set operation NIFs

#[rustler::nif(name = "sadd")]
fn sadd_members<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
    members: Vec<Binary>,
) -> Term<'a> {
    let mut inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    let members_vec: Vec<Vec<u8>> = members.iter().map(|b| b.as_slice().to_vec()).collect();

    match inner.sadd(db, key.as_slice(), &members_vec) {
        Ok(_added) => atoms::ok().encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "srem")]
fn srem_members<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
    members: Vec<Binary>,
) -> Term<'a> {
    let mut inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    let members_vec: Vec<Vec<u8>> = members.iter().map(|b| b.as_slice().to_vec()).collect();

    match inner.srem(db, key.as_slice(), &members_vec) {
        Ok(_removed) => atoms::ok().encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "smove")]
fn smove_member<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    source_key: Binary,
    dest_key: Binary,
    member: Binary,
) -> Term<'a> {
    let mut inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    match inner.smove(db, source_key.as_slice(), dest_key.as_slice(), member.as_slice()) {
        Ok(_moved) => atoms::ok().encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "sunionstore")]
fn sunionstore_sets<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    dest_key: Binary,
    source_keys: Vec<Binary>,
) -> Term<'a> {
    let mut inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    let keys_vec: Vec<Vec<u8>> = source_keys.iter().map(|b| b.as_slice().to_vec()).collect();

    match inner.sunionstore(db, dest_key.as_slice(), &keys_vec) {
        Ok(_cardinality) => atoms::ok().encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "sinterstore")]
fn sinterstore_sets<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    dest_key: Binary,
    source_keys: Vec<Binary>,
) -> Term<'a> {
    let mut inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    let keys_vec: Vec<Vec<u8>> = source_keys.iter().map(|b| b.as_slice().to_vec()).collect();

    match inner.sinterstore(db, dest_key.as_slice(), &keys_vec) {
        Ok(_cardinality) => atoms::ok().encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "sdiffstore")]
fn sdiffstore_sets<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    dest_key: Binary,
    source_keys: Vec<Binary>,
) -> Term<'a> {
    let mut inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    let keys_vec: Vec<Vec<u8>> = source_keys.iter().map(|b| b.as_slice().to_vec()).collect();

    match inner.sdiffstore(db, dest_key.as_slice(), &keys_vec) {
        Ok(_cardinality) => atoms::ok().encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "smembers")]
fn smembers_get<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
) -> Term<'a> {
    let inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    match inner.smembers(db, key.as_slice()) {
        Ok(members) => {
            let binaries: Vec<Term> = members
                .iter()
                .map(|m| {
                    let mut binary = rustler::types::OwnedBinary::new(m.len()).unwrap();
                    binary.as_mut_slice().copy_from_slice(m);
                    binary.release(env).encode(env)
                })
                .collect();
            (atoms::ok(), binaries).encode(env)
        }
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "sismember")]
fn sismember_check<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
    member: Binary,
) -> Term<'a> {
    let inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    match inner.sismember(db, key.as_slice(), member.as_slice()) {
        Ok(is_member) => (atoms::ok(), is_member).encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "scard")]
fn scard_get<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
) -> Term<'a> {
    let inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    match inner.scard(db, key.as_slice()) {
        Ok(count) => (atoms::ok(), count).encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

// List operation NIFs

#[rustler::nif(name = "lpush")]
fn lpush_values<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
    values: Vec<Binary>,
) -> Term<'a> {
    let mut inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    let values_vec: Vec<Vec<u8>> = values.iter().map(|b| b.as_slice().to_vec()).collect();

    match inner.lpush(db, key.as_slice(), &values_vec) {
        Ok(_len) => atoms::ok().encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "rpush")]
fn rpush_values<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
    values: Vec<Binary>,
) -> Term<'a> {
    let mut inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    let values_vec: Vec<Vec<u8>> = values.iter().map(|b| b.as_slice().to_vec()).collect();

    match inner.rpush(db, key.as_slice(), &values_vec) {
        Ok(_len) => atoms::ok().encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "lpop")]
fn lpop_value<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
) -> Term<'a> {
    let mut inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    match inner.lpop(db, key.as_slice()) {
        Ok(Some(value)) => {
            let mut binary = rustler::types::OwnedBinary::new(value.len()).unwrap();
            binary.as_mut_slice().copy_from_slice(&value);
            (atoms::ok(), binary.release(env)).encode(env)
        }
        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "rpop")]
fn rpop_value<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
) -> Term<'a> {
    let mut inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    match inner.rpop(db, key.as_slice()) {
        Ok(Some(value)) => {
            let mut binary = rustler::types::OwnedBinary::new(value.len()).unwrap();
            binary.as_mut_slice().copy_from_slice(&value);
            (atoms::ok(), binary.release(env)).encode(env)
        }
        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "llen")]
fn llen_get<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
) -> Term<'a> {
    let inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    match inner.llen(db, key.as_slice()) {
        Ok(len) => (atoms::ok(), len).encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "lrange")]
fn lrange_get<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
    start: i64,
    stop: i64,
) -> Term<'a> {
    let inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    match inner.lrange(db, key.as_slice(), start, stop) {
        Ok(elements) => {
            let binaries: Vec<Term> = elements
                .iter()
                .map(|e| {
                    let mut binary = rustler::types::OwnedBinary::new(e.len()).unwrap();
                    binary.as_mut_slice().copy_from_slice(e);
                    binary.release(env).encode(env)
                })
                .collect();
            (atoms::ok(), binaries).encode(env)
        }
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "lset")]
fn lset_value<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
    index: i64,
    value: Binary,
) -> Term<'a> {
    let mut inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    match inner.lset(db, key.as_slice(), index, value.as_slice()) {
        Ok(true) => atoms::ok().encode(env),
        Ok(false) => atoms::ok().encode(env), // Redis LSET returns error on out of range, but we return :ok for now
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "rpoplpush")]
fn rpoplpush_value<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    source_key: Binary,
    dest_key: Binary,
) -> Term<'a> {
    let mut inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    match inner.rpoplpush(db, source_key.as_slice(), dest_key.as_slice()) {
        Ok(Some(value)) => {
            let mut binary = rustler::types::OwnedBinary::new(value.len()).unwrap();
            binary.as_mut_slice().copy_from_slice(&value);
            (atoms::ok(), binary.release(env)).encode(env)
        }
        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

rustler::init!(
    "Elixir.Vdr.TS",
    load = load_nif
);

fn load_nif(env: Env, _: Term) -> bool {
    env.register::<TStorage>().is_ok()
}
