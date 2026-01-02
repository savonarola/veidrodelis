mod atoms;
mod storage;

use ordered_float::OrderedFloat;
use rustler::types::Binary;
use rustler::{Encoder, Env, Resource, ResourceArc, Term};
use std::sync::Mutex;

use storage::{Score, StorageInner};

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

// Batch command execution NIF
// Executes multiple commands under a single mutex lock
#[rustler::nif(name = "commands")]
fn execute_commands<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    commands: Vec<Term<'a>>,
) -> Term<'a> {
    // Lock the storage once for all commands
    let mut inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    let mut results = Vec::new();

    // Execute each command
    for cmd_term in commands {
        let result = execute_single_command(env, &mut inner, cmd_term);
        results.push(result);
    }

    results.encode(env)
}

fn execute_single_command<'a>(
    env: Env<'a>,
    inner: &mut StorageInner,
    cmd_term: Term<'a>,
) -> Term<'a> {
    use rustler::types::tuple;

    // Decode the command tuple: {db, {command_atom, arg1, arg2, ...}}
    // Get outer tuple elements
    let terms: Result<Vec<Term>, _> = tuple::get_tuple(cmd_term);

    if let Ok(terms) = terms {
        if terms.len() != 2 {
            return (atoms::error(), rustler::types::atom::error().encode(env)).encode(env);
        }

        // First element is db (u64)
        let db: Result<u64, _> = terms[0].decode();
        if db.is_err() {
            return (atoms::error(), rustler::types::atom::error().encode(env)).encode(env);
        }
        let db = db.unwrap();

        // Second element is inner tuple {command_atom, arg1, arg2, ...}
        let inner_tuple: Result<Vec<Term>, _> = tuple::get_tuple(terms[1]);

        if let Ok(cmd_terms) = inner_tuple {
            if cmd_terms.len() < 1 {
                return (atoms::error(), rustler::types::atom::error().encode(env)).encode(env);
            }

            // First element of inner tuple is command atom
            let cmd_atom: Result<rustler::types::Atom, _> = cmd_terms[0].decode();

            if let Ok(cmd_atom) = cmd_atom {
                // Rest are arguments from inner tuple
                let args = &cmd_terms[1..];
            // Use direct atom comparison
            if cmd_atom == atoms::set() {
                // {db, {:set, key, value}}
                if args.len() == 2 {
                    if let (Ok(key), Ok(value)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<Binary>()
                    ) {
                        inner.set(db, key.as_slice(), value.as_slice());
                        return atoms::ok().encode(env);
                    }
                }
            } else if cmd_atom == atoms::del() {
                // {db, {:del, keys}} where keys is a list
                if args.len() == 1 {
                    if let Ok(keys) = args[0].decode::<Vec<Binary>>() {
                        for key in keys.iter() {
                            inner.del(db, key.as_slice());
                        }
                        return atoms::ok().encode(env);
                    }
                }
            } else if cmd_atom == atoms::sadd() {
                // {db, {:sadd, key, members}}
                if args.len() == 2 {
                    if let (Ok(key), Ok(members)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<Vec<Binary>>()
                    ) {
                        let members_slices: Vec<&[u8]> = members.iter().map(|b| b.as_slice()).collect();
                        return match inner.sadd(db, key.as_slice(), &members_slices) {
                            Ok(_) => atoms::ok().encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::srem() {
                // {db, {:srem, key, members}}
                if args.len() == 2 {
                    if let (Ok(key), Ok(members)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<Vec<Binary>>()
                    ) {
                        let members_slices: Vec<&[u8]> = members.iter().map(|b| b.as_slice()).collect();
                        return match inner.srem(db, key.as_slice(), &members_slices) {
                            Ok(_) => atoms::ok().encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::smove() {
                // {db, {:smove, source_key, dest_key, member}}
                if args.len() == 3 {
                    if let (Ok(source_key), Ok(dest_key), Ok(member)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<Binary>(),
                        args[2].decode::<Binary>()
                    ) {
                        return match inner.smove(db, source_key.as_slice(), dest_key.as_slice(), member.as_slice()) {
                            Ok(_) => atoms::ok().encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::sunionstore() {
                // {db, {:sunionstore, dest_key, source_keys}}
                if args.len() == 2 {
                    if let (Ok(dest_key), Ok(source_keys)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<Vec<Binary>>()
                    ) {
                        let keys_slices: Vec<&[u8]> = source_keys.iter().map(|b| b.as_slice()).collect();
                        return match inner.sunionstore(db, dest_key.as_slice(), &keys_slices) {
                            Ok(_) => atoms::ok().encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::sinterstore() {
                // {db, {:sinterstore, dest_key, source_keys}}
                if args.len() == 2 {
                    if let (Ok(dest_key), Ok(source_keys)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<Vec<Binary>>()
                    ) {
                        let keys_slices: Vec<&[u8]> = source_keys.iter().map(|b| b.as_slice()).collect();
                        return match inner.sinterstore(db, dest_key.as_slice(), &keys_slices) {
                            Ok(_) => atoms::ok().encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::sdiffstore() {
                // {db, {:sdiffstore, dest_key, source_keys}}
                if args.len() == 2 {
                    if let (Ok(dest_key), Ok(source_keys)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<Vec<Binary>>()
                    ) {
                        let keys_slices: Vec<&[u8]> = source_keys.iter().map(|b| b.as_slice()).collect();
                        return match inner.sdiffstore(db, dest_key.as_slice(), &keys_slices) {
                            Ok(_) => atoms::ok().encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::lpush() {
                // {db, {:lpush, key, values}}
                if args.len() == 2 {
                    if let (Ok(key), Ok(values)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<Vec<Binary>>()
                    ) {
                        let values_slices: Vec<&[u8]> = values.iter().map(|b| b.as_slice()).collect();
                        return match inner.lpush(db, key.as_slice(), &values_slices) {
                            Ok(_) => atoms::ok().encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::rpush() {
                // {db, {:rpush, key, values}}
                if args.len() == 2 {
                    if let (Ok(key), Ok(values)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<Vec<Binary>>()
                    ) {
                        let values_slices: Vec<&[u8]> = values.iter().map(|b| b.as_slice()).collect();
                        return match inner.rpush(db, key.as_slice(), &values_slices) {
                            Ok(_) => atoms::ok().encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::lpop() {
                // {db, {:lpop, key}}
                if args.len() == 1 {
                    if let Ok(key) = args[0].decode::<Binary>() {
                        return match inner.lpop(db, key.as_slice()) {
                            Ok(Some(value)) => {
                                let mut binary = rustler::types::OwnedBinary::new(value.len()).unwrap();
                                binary.as_mut_slice().copy_from_slice(value.as_slice());
                                (atoms::ok(), binary.release(env)).encode(env)
                            }
                            Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::rpop() {
                // {db, {:rpop, key}}
                if args.len() == 1 {
                    if let Ok(key) = args[0].decode::<Binary>() {
                        return match inner.rpop(db, key.as_slice()) {
                            Ok(Some(value)) => {
                                let mut binary = rustler::types::OwnedBinary::new(value.len()).unwrap();
                                binary.as_mut_slice().copy_from_slice(value.as_slice());
                                (atoms::ok(), binary.release(env)).encode(env)
                            }
                            Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::lset() {
                // {db, {:lset, key, index, value}}
                if args.len() == 3 {
                    if let (Ok(key), Ok(index), Ok(value)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<i64>(),
                        args[2].decode::<Binary>()
                    ) {
                        return match inner.lset(db, key.as_slice(), index, value.as_slice()) {
                            Ok(_) => atoms::ok().encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::rpoplpush() {
                // {db, {:rpoplpush, source_key, dest_key}}
                if args.len() == 2 {
                    if let (Ok(source_key), Ok(dest_key)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<Binary>()
                    ) {
                        return match inner.rpoplpush(db, source_key.as_slice(), dest_key.as_slice()) {
                            Ok(Some(value)) => {
                                let mut binary = rustler::types::OwnedBinary::new(value.len()).unwrap();
                                binary.as_mut_slice().copy_from_slice(value.as_slice());
                                (atoms::ok(), binary.release(env)).encode(env)
                            }
                            Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::hset() {
                // {db, {:hset, key, field, value}}
                if args.len() == 3 {
                    if let (Ok(key), Ok(field), Ok(value)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<Binary>(),
                        args[2].decode::<Binary>()
                    ) {
                        return match inner.hset(db, key.as_slice(), field.as_slice(), value.as_slice()) {
                            Ok(_) => atoms::ok().encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::hmset() {
                // {db, {:hmset, key, fields}}
                if args.len() == 2 {
                    if let (Ok(key), Ok(fields)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<Vec<(Binary, Binary)>>()
                    ) {
                        let fields_slices: Vec<(&[u8], &[u8])> = fields
                            .iter()
                            .map(|(f, v)| (f.as_slice(), v.as_slice()))
                            .collect();
                        return match inner.hmset(db, key.as_slice(), &fields_slices) {
                            Ok(_) => atoms::ok().encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::hdel() {
                // {db, {:hdel, key, fields}}
                if args.len() == 2 {
                    if let (Ok(key), Ok(fields)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<Vec<Binary>>()
                    ) {
                        let fields_slices: Vec<&[u8]> = fields.iter().map(|f| f.as_slice()).collect();
                        return match inner.hdel(db, key.as_slice(), &fields_slices) {
                            Ok(deleted) => (atoms::ok(), deleted).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::zadd() {
                // {db, {:zadd, key, members}}  where members is [{score, member}, ...]
                if args.len() == 2 {
                    if let (Ok(key), Ok(members)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<Vec<(f64, Binary)>>()
                    ) {
                        let members_slices: Vec<(Score, &[u8])> = members
                            .iter()
                            .map(|(score, member)| (OrderedFloat(*score), member.as_slice()))
                            .collect();
                        return match inner.zadd(db, key.as_slice(), &members_slices) {
                            Ok(added) => (atoms::ok(), added).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::zrem() {
                // {db, {:zrem, key, members}}
                if args.len() == 2 {
                    if let (Ok(key), Ok(members)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<Vec<Binary>>()
                    ) {
                        let members_slices: Vec<&[u8]> = members.iter().map(|m| m.as_slice()).collect();
                        return match inner.zrem(db, key.as_slice(), &members_slices) {
                            Ok(removed) => (atoms::ok(), removed).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            // READ OPERATIONS
            } else if cmd_atom == atoms::get() {
                // {db, {:get, key}}
                if args.len() == 1 {
                    if let Ok(key) = args[0].decode::<Binary>() {
                        return match inner.get(db, key.as_slice()) {
                            Ok(Some(value)) => {
                                let mut binary = rustler::types::OwnedBinary::new(value.len()).unwrap();
                                binary.as_mut_slice().copy_from_slice(value.as_slice());
                                (atoms::ok(), binary.release(env)).encode(env)
                            }
                            Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::smembers() {
                // {db, {:smembers, key}}
                if args.len() == 1 {
                    if let Ok(key) = args[0].decode::<Binary>() {
                        return match inner.smembers(db, key.as_slice()) {
                            Ok(members) => {
                                let binaries: Vec<Binary> = members.iter().map(|m| {
                                    let mut binary = rustler::types::OwnedBinary::new(m.len()).unwrap();
                                    binary.as_mut_slice().copy_from_slice(m.as_slice());
                                    binary.release(env)
                                }).collect();
                                (atoms::ok(), binaries).encode(env)
                            }
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::sismember() {
                // {db, {:sismember, key, member}}
                if args.len() == 2 {
                    if let (Ok(key), Ok(member)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<Binary>()
                    ) {
                        return match inner.sismember(db, key.as_slice(), member.as_slice()) {
                            Ok(is_member) => (atoms::ok(), is_member).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::scard() {
                // {db, {:scard, key}}
                if args.len() == 1 {
                    if let Ok(key) = args[0].decode::<Binary>() {
                        return match inner.scard(db, key.as_slice()) {
                            Ok(count) => (atoms::ok(), count).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::llen() {
                // {db, {:llen, key}}
                if args.len() == 1 {
                    if let Ok(key) = args[0].decode::<Binary>() {
                        return match inner.llen(db, key.as_slice()) {
                            Ok(len) => (atoms::ok(), len).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::lrange() {
                // {db, {:lrange, key, start, stop}}
                if args.len() == 3 {
                    if let (Ok(key), Ok(start), Ok(stop)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<i64>(),
                        args[2].decode::<i64>()
                    ) {
                        return match inner.lrange(db, key.as_slice(), start, stop) {
                            Ok(elements) => {
                                let binaries: Vec<Binary> = elements.iter().map(|e| {
                                    let mut binary = rustler::types::OwnedBinary::new(e.len()).unwrap();
                                    binary.as_mut_slice().copy_from_slice(e.as_slice());
                                    binary.release(env)
                                }).collect();
                                (atoms::ok(), binaries).encode(env)
                            }
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::hget() {
                // {db, {:hget, key, field}}
                if args.len() == 2 {
                    if let (Ok(key), Ok(field)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<Binary>()
                    ) {
                        return match inner.hget(db, key.as_slice(), field.as_slice()) {
                            Ok(Some(value)) => {
                                let mut binary = rustler::types::OwnedBinary::new(value.len()).unwrap();
                                binary.as_mut_slice().copy_from_slice(value.as_slice());
                                (atoms::ok(), binary.release(env)).encode(env)
                            }
                            Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::hmget() {
                // {db, {:hmget, key, fields}}
                if args.len() == 2 {
                    if let (Ok(key), Ok(fields)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<Vec<Binary>>()
                    ) {
                        let fields_slices: Vec<&[u8]> = fields.iter().map(|f| f.as_slice()).collect();
                        return match inner.hmget(db, key.as_slice(), &fields_slices) {
                            Ok(values) => {
                                let results: Vec<Term> = values.iter().map(|opt_v| {
                                    match opt_v {
                                        Some(v) => {
                                            let mut binary = rustler::types::OwnedBinary::new(v.len()).unwrap();
                                            binary.as_mut_slice().copy_from_slice(v.as_slice());
                                            binary.release(env).encode(env)
                                        }
                                        None => atoms::nil().encode(env)
                                    }
                                }).collect();
                                (atoms::ok(), results).encode(env)
                            }
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::hgetall() {
                // {db, {:hgetall, key}}
                if args.len() == 1 {
                    if let Ok(key) = args[0].decode::<Binary>() {
                        return match inner.hgetall(db, key.as_slice()) {
                            Ok(pairs) => {
                                let tuples: Vec<(Binary, Binary)> = pairs.iter().map(|(f, v)| {
                                    let mut field_bin = rustler::types::OwnedBinary::new(f.len()).unwrap();
                                    field_bin.as_mut_slice().copy_from_slice(f.as_slice());
                                    let mut value_bin = rustler::types::OwnedBinary::new(v.len()).unwrap();
                                    value_bin.as_mut_slice().copy_from_slice(v.as_slice());
                                    (field_bin.release(env), value_bin.release(env))
                                }).collect();
                                (atoms::ok(), tuples).encode(env)
                            }
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::hkeys() {
                // {db, {:hkeys, key}}
                if args.len() == 1 {
                    if let Ok(key) = args[0].decode::<Binary>() {
                        return match inner.hkeys(db, key.as_slice()) {
                            Ok(keys) => {
                                let binaries: Vec<Binary> = keys.iter().map(|k| {
                                    let mut binary = rustler::types::OwnedBinary::new(k.len()).unwrap();
                                    binary.as_mut_slice().copy_from_slice(k.as_slice());
                                    binary.release(env)
                                }).collect();
                                (atoms::ok(), binaries).encode(env)
                            }
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::hvals() {
                // {db, {:hvals, key}}
                if args.len() == 1 {
                    if let Ok(key) = args[0].decode::<Binary>() {
                        return match inner.hvals(db, key.as_slice()) {
                            Ok(vals) => {
                                let binaries: Vec<Binary> = vals.iter().map(|v| {
                                    let mut binary = rustler::types::OwnedBinary::new(v.len()).unwrap();
                                    binary.as_mut_slice().copy_from_slice(v.as_slice());
                                    binary.release(env)
                                }).collect();
                                (atoms::ok(), binaries).encode(env)
                            }
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::hlen() {
                // {db, {:hlen, key}}
                if args.len() == 1 {
                    if let Ok(key) = args[0].decode::<Binary>() {
                        return match inner.hlen(db, key.as_slice()) {
                            Ok(len) => (atoms::ok(), len).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::hexists() {
                // {db, {:hexists, key, field}}
                if args.len() == 2 {
                    if let (Ok(key), Ok(field)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<Binary>()
                    ) {
                        return match inner.hexists(db, key.as_slice(), field.as_slice()) {
                            Ok(exists) => (atoms::ok(), exists).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::zscore() {
                // {db, {:zscore, key, member}}
                if args.len() == 2 {
                    if let (Ok(key), Ok(member)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<Binary>()
                    ) {
                        return match inner.zscore(db, key.as_slice(), member.as_slice()) {
                            Ok(Some(score)) => (atoms::ok(), score.into_inner()).encode(env),
                            Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::zcard() {
                // {db, {:zcard, key}}
                if args.len() == 1 {
                    if let Ok(key) = args[0].decode::<Binary>() {
                        return match inner.zcard(db, key.as_slice()) {
                            Ok(count) => (atoms::ok(), count).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::zrange() {
                // {db, {:zrange, key, start, stop, with_scores}}
                if args.len() == 4 {
                    if let (Ok(key), Ok(start), Ok(stop), Ok(with_scores)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<i64>(),
                        args[2].decode::<i64>(),
                        args[3].decode::<bool>()
                    ) {
                        return match inner.zrange(db, key.as_slice(), start, stop, with_scores) {
                            Ok(members) => {
                                let results: Vec<Term> = members.iter().map(|(member, opt_score)| {
                                    let mut member_bin = rustler::types::OwnedBinary::new(member.len()).unwrap();
                                    member_bin.as_mut_slice().copy_from_slice(member.as_slice());
                                    let member_term = member_bin.release(env);

                                    if with_scores {
                                        if let Some(score) = opt_score {
                                            (member_term, score.into_inner()).encode(env)
                                        } else {
                                            member_term.encode(env)
                                        }
                                    } else {
                                        member_term.encode(env)
                                    }
                                }).collect();
                                (atoms::ok(), results).encode(env)
                            }
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::zrangebyscore() {
                // {db, {:zrangebyscore, key, min, max, with_scores}}
                if args.len() == 4 {
                    if let (Ok(key), Ok(min), Ok(max), Ok(with_scores)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<f64>(),
                        args[2].decode::<f64>(),
                        args[3].decode::<bool>()
                    ) {
                        return match inner.zrangebyscore(db, key.as_slice(), OrderedFloat(min), OrderedFloat(max), with_scores) {
                            Ok(members) => {
                                let results: Vec<Term> = members.iter().map(|(member, opt_score)| {
                                    let mut member_bin = rustler::types::OwnedBinary::new(member.len()).unwrap();
                                    member_bin.as_mut_slice().copy_from_slice(member.as_slice());
                                    let member_term = member_bin.release(env);

                                    if with_scores {
                                        if let Some(score) = opt_score {
                                            (member_term, score.into_inner()).encode(env)
                                        } else {
                                            member_term.encode(env)
                                        }
                                    } else {
                                        member_term.encode(env)
                                    }
                                }).collect();
                                (atoms::ok(), results).encode(env)
                            }
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::zrank() {
                // {db, {:zrank, key, member}}
                if args.len() == 2 {
                    if let (Ok(key), Ok(member)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<Binary>()
                    ) {
                        return match inner.zrank(db, key.as_slice(), member.as_slice()) {
                            Ok(Some(rank)) => (atoms::ok(), rank).encode(env),
                            Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::zrevrank() {
                // {db, {:zrevrank, key, member}}
                if args.len() == 2 {
                    if let (Ok(key), Ok(member)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<Binary>()
                    ) {
                        return match inner.zrevrank(db, key.as_slice(), member.as_slice()) {
                            Ok(Some(rank)) => (atoms::ok(), rank).encode(env),
                            Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::zcount() {
                // {db, {:zcount, key, min, max}}
                if args.len() == 3 {
                    if let (Ok(key), Ok(min), Ok(max)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<f64>(),
                        args[2].decode::<f64>()
                    ) {
                        return match inner.zcount(db, key.as_slice(), OrderedFloat(min), OrderedFloat(max)) {
                            Ok(count) => (atoms::ok(), count).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::zincrby() {
                // {db, {:zincrby, key, delta, member}}
                if args.len() == 3 {
                    if let (Ok(key), Ok(delta), Ok(member)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<f64>(),
                        args[2].decode::<Binary>()
                    ) {
                        return match inner.zincrby(db, key.as_slice(), OrderedFloat(delta), member.as_slice()) {
                            Ok(new_score) => (atoms::ok(), new_score.into_inner()).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::zfirst() {
                // {db, {:zfirst, key}}
                if args.len() == 1 {
                    if let Ok(key) = args[0].decode::<Binary>() {
                        return match inner.zfirst(db, key.as_slice()) {
                            Ok(Some((score, member))) => {
                                let mut member_bin = rustler::types::OwnedBinary::new(member.len()).unwrap();
                                member_bin.as_mut_slice().copy_from_slice(member.as_slice());
                                (atoms::ok(), (score.into_inner(), member_bin.release(env))).encode(env)
                            }
                            Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::zlast() {
                // {db, {:zlast, key}}
                if args.len() == 1 {
                    if let Ok(key) = args[0].decode::<Binary>() {
                        return match inner.zlast(db, key.as_slice()) {
                            Ok(Some((score, member))) => {
                                let mut member_bin = rustler::types::OwnedBinary::new(member.len()).unwrap();
                                member_bin.as_mut_slice().copy_from_slice(member.as_slice());
                                (atoms::ok(), (score.into_inner(), member_bin.release(env))).encode(env)
                            }
                            Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::znext() {
                // {db, {:znext, key, score, member}}
                if args.len() == 3 {
                    if let (Ok(key), Ok(score), Ok(member)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<f64>(),
                        args[2].decode::<Binary>()
                    ) {
                        return match inner.znext(db, key.as_slice(), OrderedFloat(score), member.as_slice()) {
                            Ok(Some((new_score, new_member))) => {
                                let mut member_bin = rustler::types::OwnedBinary::new(new_member.len()).unwrap();
                                member_bin.as_mut_slice().copy_from_slice(new_member.as_slice());
                                (atoms::ok(), (new_score.into_inner(), member_bin.release(env))).encode(env)
                            }
                            Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::zprev() {
                // {db, {:zprev, key, score, member}}
                if args.len() == 3 {
                    if let (Ok(key), Ok(score), Ok(member)) = (
                        args[0].decode::<Binary>(),
                        args[1].decode::<f64>(),
                        args[2].decode::<Binary>()
                    ) {
                        return match inner.zprev(db, key.as_slice(), OrderedFloat(score), member.as_slice()) {
                            Ok(Some((new_score, new_member))) => {
                                let mut member_bin = rustler::types::OwnedBinary::new(new_member.len()).unwrap();
                                member_bin.as_mut_slice().copy_from_slice(new_member.as_slice());
                                (atoms::ok(), (new_score.into_inner(), member_bin.release(env))).encode(env)
                            }
                            Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            }
            }
        }
    }

    // If we get here, the command was malformed or unknown
    (atoms::error(), rustler::types::atom::error().encode(env)).encode(env)
}

#[rustler::nif(name = "lua_load")]
fn lua_load<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    script: Binary,
) -> Term<'a> {
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
fn lua_table_to_term<'a>(env: Env<'a>, table: &mlua::Table) -> Result<Term<'a>, String> {
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
        map = map.map_put(key_term, val_term).map_err(|e| format!("{:?}", e))?;
    }

    Ok(map)
}

// Helper to convert Lua values to Elixir terms
fn lua_value_to_term<'a>(env: Env<'a>, value: mlua::Value) -> Result<Term<'a>, String> {
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

#[rustler::nif(name = "tx")]
fn execute_tx<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    script_or_bytecode: Binary,
) -> Term<'a> {
    // Lock the storage
    let inner = match storage.0.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    // Execute the Lua script or bytecode
    match inner.tx(db, script_or_bytecode.as_slice()) {
        Ok(lua_value) => {
            match lua_value_to_term(env, lua_value) {
                Ok(term) => (atoms::ok(), term).encode(env),
                Err(e) => (atoms::error(), e).encode(env),
            }
        }
        Err(e) => (atoms::error(), e).encode(env),
    }
}

rustler::init!(
    "Elixir.Vdr.TS",
    load = load_nif
);

fn load_nif(env: Env, _: Term) -> bool {
    env.register::<TStorage>().is_ok()
}
