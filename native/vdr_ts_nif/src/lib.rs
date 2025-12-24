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

// Hash operation NIFs

#[rustler::nif(name = "hset")]
fn hset_field<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
    field: Binary,
    value: Binary,
) -> Term<'a> {
    let mut inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    match inner.hset(db, key.as_slice(), field.as_slice(), value.as_slice()) {
        Ok(_is_new) => atoms::ok().encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "hmset")]
fn hmset_fields<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
    fields: Vec<(Binary, Binary)>,
) -> Term<'a> {
    let mut inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    let fields_vec: Vec<(Vec<u8>, Vec<u8>)> = fields
        .iter()
        .map(|(f, v)| (f.as_slice().to_vec(), v.as_slice().to_vec()))
        .collect();

    match inner.hmset(db, key.as_slice(), &fields_vec) {
        Ok(_count) => atoms::ok().encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "hget")]
fn hget_field<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
    field: Binary,
) -> Term<'a> {
    let inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    match inner.hget(db, key.as_slice(), field.as_slice()) {
        Ok(Some(value)) => {
            let mut binary = rustler::types::OwnedBinary::new(value.len()).unwrap();
            binary.as_mut_slice().copy_from_slice(&value);
            (atoms::ok(), binary.release(env)).encode(env)
        }
        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "hmget")]
fn hmget_fields<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
    fields: Vec<Binary>,
) -> Term<'a> {
    let inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    let fields_vec: Vec<Vec<u8>> = fields.iter().map(|f| f.as_slice().to_vec()).collect();

    match inner.hmget(db, key.as_slice(), &fields_vec) {
        Ok(values) => {
            let terms: Vec<Term> = values
                .iter()
                .map(|opt_val| match opt_val {
                    Some(val) => {
                        let mut binary = rustler::types::OwnedBinary::new(val.len()).unwrap();
                        binary.as_mut_slice().copy_from_slice(val);
                        binary.release(env).encode(env)
                    }
                    None => atoms::nil().encode(env),
                })
                .collect();
            (atoms::ok(), terms).encode(env)
        }
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "hgetall")]
fn hgetall_fields<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
) -> Term<'a> {
    let inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    match inner.hgetall(db, key.as_slice()) {
        Ok(pairs) => {
            let terms: Vec<(Term, Term)> = pairs
                .iter()
                .map(|(k, v)| {
                    let mut key_bin = rustler::types::OwnedBinary::new(k.len()).unwrap();
                    key_bin.as_mut_slice().copy_from_slice(k);
                    let mut val_bin = rustler::types::OwnedBinary::new(v.len()).unwrap();
                    val_bin.as_mut_slice().copy_from_slice(v);
                    (key_bin.release(env).encode(env), val_bin.release(env).encode(env))
                })
                .collect();
            (atoms::ok(), terms).encode(env)
        }
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "hkeys")]
fn hkeys_get<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
) -> Term<'a> {
    let inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    match inner.hkeys(db, key.as_slice()) {
        Ok(keys) => {
            let binaries: Vec<Term> = keys
                .iter()
                .map(|k| {
                    let mut binary = rustler::types::OwnedBinary::new(k.len()).unwrap();
                    binary.as_mut_slice().copy_from_slice(k);
                    binary.release(env).encode(env)
                })
                .collect();
            (atoms::ok(), binaries).encode(env)
        }
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "hvals")]
fn hvals_get<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
) -> Term<'a> {
    let inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    match inner.hvals(db, key.as_slice()) {
        Ok(values) => {
            let binaries: Vec<Term> = values
                .iter()
                .map(|v| {
                    let mut binary = rustler::types::OwnedBinary::new(v.len()).unwrap();
                    binary.as_mut_slice().copy_from_slice(v);
                    binary.release(env).encode(env)
                })
                .collect();
            (atoms::ok(), binaries).encode(env)
        }
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "hlen")]
fn hlen_get<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
) -> Term<'a> {
    let inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    match inner.hlen(db, key.as_slice()) {
        Ok(len) => (atoms::ok(), len).encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "hexists")]
fn hexists_check<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
    field: Binary,
) -> Term<'a> {
    let inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    match inner.hexists(db, key.as_slice(), field.as_slice()) {
        Ok(exists) => (atoms::ok(), exists).encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "hdel")]
fn hdel_fields<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
    fields: Vec<Binary>,
) -> Term<'a> {
    let mut inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    let fields_vec: Vec<Vec<u8>> = fields.iter().map(|f| f.as_slice().to_vec()).collect();

    match inner.hdel(db, key.as_slice(), &fields_vec) {
        Ok(deleted) => (atoms::ok(), deleted).encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

// Sorted set (zset) operation NIFs

#[rustler::nif(name = "zadd")]
fn zadd_members<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
    members: Vec<(f64, Binary)>,
) -> Term<'a> {
    let mut inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    let members_vec: Vec<(f64, Vec<u8>)> = members
        .iter()
        .map(|(score, member)| (*score, member.as_slice().to_vec()))
        .collect();

    match inner.zadd(db, key.as_slice(), &members_vec) {
        Ok(added) => (atoms::ok(), added).encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "zrem")]
fn zrem_members<'a>(
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

    let members_vec: Vec<Vec<u8>> = members.iter().map(|m| m.as_slice().to_vec()).collect();

    match inner.zrem(db, key.as_slice(), &members_vec) {
        Ok(removed) => (atoms::ok(), removed).encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "zscore")]
fn zscore_get<'a>(
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

    match inner.zscore(db, key.as_slice(), member.as_slice()) {
        Ok(Some(score)) => (atoms::ok(), score).encode(env),
        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "zcard")]
fn zcard_get<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
) -> Term<'a> {
    let inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    match inner.zcard(db, key.as_slice()) {
        Ok(count) => (atoms::ok(), count).encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "zrange")]
fn zrange_get<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
    start: i64,
    stop: i64,
    with_scores: bool,
) -> Term<'a> {
    let inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    match inner.zrange(db, key.as_slice(), start, stop, with_scores) {
        Ok(results) => {
            let terms: Vec<Term> = results
                .iter()
                .flat_map(|(member, score_opt)| {
                    let mut member_bin = rustler::types::OwnedBinary::new(member.len()).unwrap();
                    member_bin.as_mut_slice().copy_from_slice(member);
                    let member_term = member_bin.release(env).encode(env);

                    if let Some(score) = score_opt {
                        vec![member_term, score.encode(env)]
                    } else {
                        vec![member_term]
                    }
                })
                .collect();
            (atoms::ok(), terms).encode(env)
        }
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "zrangebyscore")]
fn zrangebyscore_get<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
    min: f64,
    max: f64,
    with_scores: bool,
) -> Term<'a> {
    let inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    match inner.zrangebyscore(db, key.as_slice(), min, max, with_scores) {
        Ok(results) => {
            let terms: Vec<Term> = results
                .iter()
                .flat_map(|(member, score_opt)| {
                    let mut member_bin = rustler::types::OwnedBinary::new(member.len()).unwrap();
                    member_bin.as_mut_slice().copy_from_slice(member);
                    let member_term = member_bin.release(env).encode(env);

                    if let Some(score) = score_opt {
                        vec![member_term, score.encode(env)]
                    } else {
                        vec![member_term]
                    }
                })
                .collect();
            (atoms::ok(), terms).encode(env)
        }
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "zrank")]
fn zrank_get<'a>(
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

    match inner.zrank(db, key.as_slice(), member.as_slice()) {
        Ok(Some(rank)) => (atoms::ok(), rank).encode(env),
        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "zrevrank")]
fn zrevrank_get<'a>(
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

    match inner.zrevrank(db, key.as_slice(), member.as_slice()) {
        Ok(Some(rank)) => (atoms::ok(), rank).encode(env),
        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "zcount")]
fn zcount_get<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
    min: f64,
    max: f64,
) -> Term<'a> {
    let inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    match inner.zcount(db, key.as_slice(), min, max) {
        Ok(count) => (atoms::ok(), count).encode(env),
        Err(_err_msg) => (atoms::error(), atoms::wrong_type()).encode(env),
    }
}

#[rustler::nif(name = "zincrby")]
fn zincrby_score<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    key: Binary,
    delta: f64,
    member: Binary,
) -> Term<'a> {
    let mut inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    match inner.zincrby(db, key.as_slice(), delta, member.as_slice()) {
        Ok(new_score) => (atoms::ok(), new_score).encode(env),
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
