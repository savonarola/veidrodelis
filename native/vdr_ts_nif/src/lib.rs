mod atoms;
mod storage;
mod write_commands;

use ordered_float::OrderedFloat;
use rustler::types::tuple;
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
        let result = execute_single_read_command(env, &inner, db, cmd_term);
        results.push(result);
    }

    (atoms::ok(), results).encode(env)
}

// Execute a single read-only command
fn execute_single_read_command<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    cmd_term: rustler::Term<'a>,
) -> rustler::Term<'a> {
    // Decode the command tuple: {command_atom, arg1, arg2, ...}
    let cmd_terms: Result<Vec<rustler::Term>, _> = tuple::get_tuple(cmd_term);

    if let Ok(cmd_terms) = cmd_terms {
        if cmd_terms.is_empty() {
            return (atoms::error(), atoms::readonly_violation()).encode(env);
        }

        // First element is command atom
        let cmd_atom: Result<rustler::Atom, _> = cmd_terms[0].decode();

        if let Ok(cmd_atom) = cmd_atom {
            // Rest are arguments
            let args = &cmd_terms[1..];

            let arg_count = args.len();

            // READ OPERATIONS ONLY
            if cmd_atom == atoms::get() && arg_count == 1 {
                // {:get, key}
                if let Ok(key) = args[0].decode::<rustler::Binary>() {
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
            } else if cmd_atom == atoms::smembers() && arg_count == 1 {
                // {:smembers, key}
                if let Ok(key) = args[0].decode::<rustler::Binary>() {
                    return match inner.smembers(db, key.as_slice()) {
                        Ok(members) => {
                            let binaries: Vec<rustler::Binary> = members
                                .iter()
                                .map(|m| {
                                    let mut binary =
                                        rustler::types::OwnedBinary::new(m.len()).unwrap();
                                    binary.as_mut_slice().copy_from_slice(m.as_slice());
                                    binary.release(env)
                                })
                                .collect();
                            (atoms::ok(), binaries).encode(env)
                        }
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::sismember() && arg_count == 2 {
                // {:sismember, key, member}
                if let (Ok(key), Ok(member)) = (
                    args[0].decode::<rustler::Binary>(),
                    args[1].decode::<rustler::Binary>(),
                ) {
                    return match inner.sismember(db, key.as_slice(), member.as_slice()) {
                        Ok(is_member) => (atoms::ok(), is_member).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::scard() && arg_count == 1 {
                // {:scard, key}
                if let Ok(key) = args[0].decode::<rustler::Binary>() {
                    return match inner.scard(db, key.as_slice()) {
                        Ok(count) => (atoms::ok(), count).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::sfirst() && arg_count == 1 {
                // {:sfirst, key}
                if let Ok(key) = args[0].decode::<rustler::Binary>() {
                    return match inner.sfirst(db, key.as_slice()) {
                        Ok(Some(member)) => {
                            let mut member_bin =
                                rustler::types::OwnedBinary::new(member.len()).unwrap();
                            member_bin.as_mut_slice().copy_from_slice(member.as_slice());
                            (atoms::ok(), member_bin.release(env)).encode(env)
                        }
                        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::slast() && arg_count == 1 {
                // {:slast, key}
                if let Ok(key) = args[0].decode::<rustler::Binary>() {
                    return match inner.slast(db, key.as_slice()) {
                        Ok(Some(member)) => {
                            let mut member_bin =
                                rustler::types::OwnedBinary::new(member.len()).unwrap();
                            member_bin.as_mut_slice().copy_from_slice(member.as_slice());
                            (atoms::ok(), member_bin.release(env)).encode(env)
                        }
                        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::snext() && arg_count == 2 {
                // {:snext, key, member}
                if let (Ok(key), Ok(member)) = (
                    args[0].decode::<rustler::Binary>(),
                    args[1].decode::<rustler::Binary>(),
                ) {
                    return match inner.snext(db, key.as_slice(), member.as_slice()) {
                        Ok(Some(next_member)) => {
                            let mut member_bin =
                                rustler::types::OwnedBinary::new(next_member.len()).unwrap();
                            member_bin
                                .as_mut_slice()
                                .copy_from_slice(next_member.as_slice());
                            (atoms::ok(), member_bin.release(env)).encode(env)
                        }
                        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::sprev() && arg_count == 2 {
                // {:sprev, key, member}
                if let (Ok(key), Ok(member)) = (
                    args[0].decode::<rustler::Binary>(),
                    args[1].decode::<rustler::Binary>(),
                ) {
                    return match inner.sprev(db, key.as_slice(), member.as_slice()) {
                        Ok(Some(prev_member)) => {
                            let mut member_bin =
                                rustler::types::OwnedBinary::new(prev_member.len()).unwrap();
                            member_bin
                                .as_mut_slice()
                                .copy_from_slice(prev_member.as_slice());
                            (atoms::ok(), member_bin.release(env)).encode(env)
                        }
                        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::smismember() && arg_count == 2 {
                // {:smismember, key, members}
                if let (Ok(key), Ok(members_list)) = (
                    args[0].decode::<rustler::Binary>(),
                    args[1].decode::<Vec<rustler::Binary>>(),
                ) {
                    let members: Vec<&[u8]> = members_list.iter().map(|b| b.as_slice()).collect();
                    return match inner.smismember(db, key.as_slice(), &members) {
                        Ok(results) => (atoms::ok(), results).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::srandmember() && arg_count == 2 {
                // {:srandmember, key, count}
                if let (Ok(key), Ok(count)) =
                    (args[0].decode::<rustler::Binary>(), args[1].decode::<i64>())
                {
                    return match inner.srandmember(db, key.as_slice(), count) {
                        Ok(members) => {
                            let binaries: Vec<rustler::Binary> = members
                                .iter()
                                .map(|m| {
                                    let mut binary =
                                        rustler::types::OwnedBinary::new(m.len()).unwrap();
                                    binary.as_mut_slice().copy_from_slice(m.as_slice());
                                    binary.release(env)
                                })
                                .collect();
                            (atoms::ok(), binaries).encode(env)
                        }
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::sunion() && arg_count == 1 {
                // {:sunion, keys}
                if let Ok(keys_list) = args[0].decode::<Vec<rustler::Binary>>() {
                    let keys: Vec<&[u8]> = keys_list.iter().map(|b| b.as_slice()).collect();
                    return match inner.sunion(db, &keys) {
                        Ok(members) => {
                            let binaries: Vec<rustler::Binary> = members
                                .iter()
                                .map(|m| {
                                    let mut binary =
                                        rustler::types::OwnedBinary::new(m.len()).unwrap();
                                    binary.as_mut_slice().copy_from_slice(m.as_slice());
                                    binary.release(env)
                                })
                                .collect();
                            (atoms::ok(), binaries).encode(env)
                        }
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::sinter() && arg_count == 1 {
                // {:sinter, keys}
                if let Ok(keys_list) = args[0].decode::<Vec<rustler::Binary>>() {
                    let keys: Vec<&[u8]> = keys_list.iter().map(|b| b.as_slice()).collect();
                    return match inner.sinter(db, &keys) {
                        Ok(members) => {
                            let binaries: Vec<rustler::Binary> = members
                                .iter()
                                .map(|m| {
                                    let mut binary =
                                        rustler::types::OwnedBinary::new(m.len()).unwrap();
                                    binary.as_mut_slice().copy_from_slice(m.as_slice());
                                    binary.release(env)
                                })
                                .collect();
                            (atoms::ok(), binaries).encode(env)
                        }
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::sdiff() && arg_count == 1 {
                // {:sdiff, keys}
                if let Ok(keys_list) = args[0].decode::<Vec<rustler::Binary>>() {
                    let keys: Vec<&[u8]> = keys_list.iter().map(|b| b.as_slice()).collect();
                    return match inner.sdiff(db, &keys) {
                        Ok(members) => {
                            let binaries: Vec<rustler::Binary> = members
                                .iter()
                                .map(|m| {
                                    let mut binary =
                                        rustler::types::OwnedBinary::new(m.len()).unwrap();
                                    binary.as_mut_slice().copy_from_slice(m.as_slice());
                                    binary.release(env)
                                })
                                .collect();
                            (atoms::ok(), binaries).encode(env)
                        }
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::sintercard() && arg_count == 1 {
                // {:sintercard, keys}
                if let Ok(keys_list) = args[0].decode::<Vec<rustler::Binary>>() {
                    let keys: Vec<&[u8]> = keys_list.iter().map(|b| b.as_slice()).collect();
                    return match inner.sintercard(db, &keys) {
                        Ok(count) => (atoms::ok(), count).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::llen() && arg_count == 1 {
                // {:llen, key}
                if let Ok(key) = args[0].decode::<rustler::Binary>() {
                    return match inner.llen(db, key.as_slice()) {
                        Ok(len) => (atoms::ok(), len).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::lrange() && arg_count == 3 {
                // {:lrange, key, start, stop}
                if let (Ok(key), Ok(start), Ok(stop)) = (
                    args[0].decode::<rustler::Binary>(),
                    args[1].decode::<i64>(),
                    args[2].decode::<i64>(),
                ) {
                    return match inner.lrange(db, key.as_slice(), start, stop) {
                        Ok(elements) => {
                            let binaries: Vec<rustler::Binary> = elements
                                .iter()
                                .map(|e| {
                                    let mut binary =
                                        rustler::types::OwnedBinary::new(e.len()).unwrap();
                                    binary.as_mut_slice().copy_from_slice(e.as_slice());
                                    binary.release(env)
                                })
                                .collect();
                            (atoms::ok(), binaries).encode(env)
                        }
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hget() && arg_count == 2 {
                // {:hget, key, field}
                if let (Ok(key), Ok(field)) = (
                    args[0].decode::<rustler::Binary>(),
                    args[1].decode::<rustler::Binary>(),
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
            } else if cmd_atom == atoms::hmget() && arg_count == 2 {
                // {:hmget, key, fields}
                if let (Ok(key), Ok(fields)) = (
                    args[0].decode::<rustler::Binary>(),
                    args[1].decode::<Vec<rustler::Binary>>(),
                ) {
                    let fields_slices: Vec<&[u8]> = fields.iter().map(|f| f.as_slice()).collect();
                    return match inner.hmget(db, key.as_slice(), &fields_slices) {
                        Ok(values) => {
                            let results: Vec<rustler::Term> = values
                                .iter()
                                .map(|opt_v| match opt_v {
                                    Some(v) => {
                                        let mut binary =
                                            rustler::types::OwnedBinary::new(v.len()).unwrap();
                                        binary.as_mut_slice().copy_from_slice(v.as_slice());
                                        binary.release(env).encode(env)
                                    }
                                    None => atoms::nil().encode(env),
                                })
                                .collect();
                            (atoms::ok(), results).encode(env)
                        }
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hgetall() && arg_count == 1 {
                // {:hgetall, key}
                if let Ok(key) = args[0].decode::<rustler::Binary>() {
                    return match inner.hgetall(db, key.as_slice()) {
                        Ok(pairs) => {
                            let tuples: Vec<(rustler::Binary, rustler::Binary)> = pairs
                                .iter()
                                .map(|(f, v)| {
                                    let mut field_bin =
                                        rustler::types::OwnedBinary::new(f.len()).unwrap();
                                    field_bin.as_mut_slice().copy_from_slice(f.as_slice());
                                    let mut value_bin =
                                        rustler::types::OwnedBinary::new(v.len()).unwrap();
                                    value_bin.as_mut_slice().copy_from_slice(v.as_slice());
                                    (field_bin.release(env), value_bin.release(env))
                                })
                                .collect();
                            (atoms::ok(), tuples).encode(env)
                        }
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hkeys() && arg_count == 1 {
                // {:hkeys, key}
                if let Ok(key) = args[0].decode::<rustler::Binary>() {
                    return match inner.hkeys(db, key.as_slice()) {
                        Ok(keys) => {
                            let binaries: Vec<rustler::Binary> = keys
                                .iter()
                                .map(|k| {
                                    let mut binary =
                                        rustler::types::OwnedBinary::new(k.len()).unwrap();
                                    binary.as_mut_slice().copy_from_slice(k.as_slice());
                                    binary.release(env)
                                })
                                .collect();
                            (atoms::ok(), binaries).encode(env)
                        }
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hvals() && arg_count == 1 {
                // {:hvals, key}
                if let Ok(key) = args[0].decode::<rustler::Binary>() {
                    return match inner.hvals(db, key.as_slice()) {
                        Ok(vals) => {
                            let binaries: Vec<rustler::Binary> = vals
                                .iter()
                                .map(|v| {
                                    let mut binary =
                                        rustler::types::OwnedBinary::new(v.len()).unwrap();
                                    binary.as_mut_slice().copy_from_slice(v.as_slice());
                                    binary.release(env)
                                })
                                .collect();
                            (atoms::ok(), binaries).encode(env)
                        }
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hlen() && arg_count == 1 {
                // {:hlen, key}
                if let Ok(key) = args[0].decode::<rustler::Binary>() {
                    return match inner.hlen(db, key.as_slice()) {
                        Ok(len) => (atoms::ok(), len).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hexists() && arg_count == 2 {
                // {:hexists, key, field}
                if let (Ok(key), Ok(field)) = (
                    args[0].decode::<rustler::Binary>(),
                    args[1].decode::<rustler::Binary>(),
                ) {
                    return match inner.hexists(db, key.as_slice(), field.as_slice()) {
                        Ok(exists) => (atoms::ok(), exists).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hfirst() && arg_count == 1 {
                // {:hfirst, key}
                if let Ok(key) = args[0].decode::<rustler::Binary>() {
                    return match inner.hfirst(db, key.as_slice()) {
                        Ok(Some((field, value))) => {
                            let mut field_bin =
                                rustler::types::OwnedBinary::new(field.len()).unwrap();
                            field_bin.as_mut_slice().copy_from_slice(field.as_slice());
                            let mut value_bin =
                                rustler::types::OwnedBinary::new(value.len()).unwrap();
                            value_bin.as_mut_slice().copy_from_slice(value.as_slice());
                            (
                                atoms::ok(),
                                (field_bin.release(env), value_bin.release(env)),
                            )
                                .encode(env)
                        }
                        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hlast() && arg_count == 1 {
                // {:hlast, key}
                if let Ok(key) = args[0].decode::<rustler::Binary>() {
                    return match inner.hlast(db, key.as_slice()) {
                        Ok(Some((field, value))) => {
                            let mut field_bin =
                                rustler::types::OwnedBinary::new(field.len()).unwrap();
                            field_bin.as_mut_slice().copy_from_slice(field.as_slice());
                            let mut value_bin =
                                rustler::types::OwnedBinary::new(value.len()).unwrap();
                            value_bin.as_mut_slice().copy_from_slice(value.as_slice());
                            (
                                atoms::ok(),
                                (field_bin.release(env), value_bin.release(env)),
                            )
                                .encode(env)
                        }
                        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hnext() && arg_count == 2 {
                // {:hnext, key, field}
                if let (Ok(key), Ok(field)) = (
                    args[0].decode::<rustler::Binary>(),
                    args[1].decode::<rustler::Binary>(),
                ) {
                    return match inner.hnext(db, key.as_slice(), field.as_slice()) {
                        Ok(Some((next_field, value))) => {
                            let mut field_bin =
                                rustler::types::OwnedBinary::new(next_field.len()).unwrap();
                            field_bin
                                .as_mut_slice()
                                .copy_from_slice(next_field.as_slice());
                            let mut value_bin =
                                rustler::types::OwnedBinary::new(value.len()).unwrap();
                            value_bin.as_mut_slice().copy_from_slice(value.as_slice());
                            (
                                atoms::ok(),
                                (field_bin.release(env), value_bin.release(env)),
                            )
                                .encode(env)
                        }
                        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hprev() && arg_count == 2 {
                // {:hprev, key, field}
                if let (Ok(key), Ok(field)) = (
                    args[0].decode::<rustler::Binary>(),
                    args[1].decode::<rustler::Binary>(),
                ) {
                    return match inner.hprev(db, key.as_slice(), field.as_slice()) {
                        Ok(Some((prev_field, value))) => {
                            let mut field_bin =
                                rustler::types::OwnedBinary::new(prev_field.len()).unwrap();
                            field_bin
                                .as_mut_slice()
                                .copy_from_slice(prev_field.as_slice());
                            let mut value_bin =
                                rustler::types::OwnedBinary::new(value.len()).unwrap();
                            value_bin.as_mut_slice().copy_from_slice(value.as_slice());
                            (
                                atoms::ok(),
                                (field_bin.release(env), value_bin.release(env)),
                            )
                                .encode(env)
                        }
                        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hstrlen() && arg_count == 2 {
                // {:hstrlen, key, field}
                if let (Ok(key), Ok(field)) = (
                    args[0].decode::<rustler::Binary>(),
                    args[1].decode::<rustler::Binary>(),
                ) {
                    return match inner.hstrlen(db, key.as_slice(), field.as_slice()) {
                        Ok(len) => (atoms::ok(), len).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hrandfield() && arg_count == 3 {
                // {:hrandfield, key, count, with_values}
                if let (Ok(key), Ok(count), Ok(with_values)) = (
                    args[0].decode::<rustler::Binary>(),
                    args[1].decode::<i64>(),
                    args[2].decode::<bool>(),
                ) {
                    return match inner.hrandfield(db, key.as_slice(), count, with_values) {
                        Ok(results) => {
                            let elems: Vec<rustler::Term> = results
                                .iter()
                                .map(|(field, opt_value)| {
                                    let mut field_bin =
                                        rustler::types::OwnedBinary::new(field.len()).unwrap();
                                    field_bin.as_mut_slice().copy_from_slice(field.as_slice());

                                    if with_values {
                                        if let Some(value) = opt_value {
                                            let mut value_bin =
                                                rustler::types::OwnedBinary::new(value.len())
                                                    .unwrap();
                                            value_bin
                                                .as_mut_slice()
                                                .copy_from_slice(value.as_slice());
                                            (field_bin.release(env), value_bin.release(env))
                                                .encode(env)
                                        } else {
                                            field_bin.release(env).encode(env)
                                        }
                                    } else {
                                        field_bin.release(env).encode(env)
                                    }
                                })
                                .collect();
                            (atoms::ok(), elems).encode(env)
                        }
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::zscore() && arg_count == 2 {
                // {:zscore, key, member}
                if let (Ok(key), Ok(member)) = (
                    args[0].decode::<rustler::Binary>(),
                    args[1].decode::<rustler::Binary>(),
                ) {
                    return match inner.zscore(db, key.as_slice(), member.as_slice()) {
                        Ok(Some(score)) => (atoms::ok(), score.into_inner()).encode(env),
                        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::zcard() && arg_count == 1 {
                // {:zcard, key}
                if let Ok(key) = args[0].decode::<rustler::Binary>() {
                    return match inner.zcard(db, key.as_slice()) {
                        Ok(count) => (atoms::ok(), count).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::zrange() && arg_count == 4 {
                // {:zrange, key, start, stop, with_scores}
                if let (Ok(key), Ok(start), Ok(stop), Ok(with_scores)) = (
                    args[0].decode::<rustler::Binary>(),
                    args[1].decode::<i64>(),
                    args[2].decode::<i64>(),
                    args[3].decode::<bool>(),
                ) {
                    return match inner.zrange(db, key.as_slice(), start, stop, with_scores) {
                        Ok(members) => {
                            let results: Vec<rustler::Term> = members
                                .iter()
                                .map(|(member, opt_score)| {
                                    let mut member_bin =
                                        rustler::types::OwnedBinary::new(member.len()).unwrap();
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
                                })
                                .collect();
                            (atoms::ok(), results).encode(env)
                        }
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::zrangebyscore() && arg_count == 4 {
                // {:zrangebyscore, key, min, max, with_scores}
                if let (Ok(key), Ok(min), Ok(max), Ok(with_scores)) = (
                    args[0].decode::<rustler::Binary>(),
                    args[1].decode::<f64>(),
                    args[2].decode::<f64>(),
                    args[3].decode::<bool>(),
                ) {
                    return match inner.zrangebyscore(
                        db,
                        key.as_slice(),
                        OrderedFloat(min),
                        OrderedFloat(max),
                        with_scores,
                    ) {
                        Ok(members) => {
                            let results: Vec<rustler::Term> = members
                                .iter()
                                .map(|(member, opt_score)| {
                                    let mut member_bin =
                                        rustler::types::OwnedBinary::new(member.len()).unwrap();
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
                                })
                                .collect();
                            (atoms::ok(), results).encode(env)
                        }
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::zrank() && arg_count == 2 {
                // {:zrank, key, member}
                if let (Ok(key), Ok(member)) = (
                    args[0].decode::<rustler::Binary>(),
                    args[1].decode::<rustler::Binary>(),
                ) {
                    return match inner.zrank(db, key.as_slice(), member.as_slice()) {
                        Ok(Some(rank)) => (atoms::ok(), rank).encode(env),
                        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::zrevrank() && arg_count == 2 {
                // {:zrevrank, key, member}
                if let (Ok(key), Ok(member)) = (
                    args[0].decode::<rustler::Binary>(),
                    args[1].decode::<rustler::Binary>(),
                ) {
                    return match inner.zrevrank(db, key.as_slice(), member.as_slice()) {
                        Ok(Some(rank)) => (atoms::ok(), rank).encode(env),
                        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::zcount() && arg_count == 3 {
                // {:zcount, key, min, max}
                if let (Ok(key), Ok(min), Ok(max)) = (
                    args[0].decode::<rustler::Binary>(),
                    args[1].decode::<f64>(),
                    args[2].decode::<f64>(),
                ) {
                    return match inner.zcount(
                        db,
                        key.as_slice(),
                        OrderedFloat(min),
                        OrderedFloat(max),
                    ) {
                        Ok(count) => (atoms::ok(), count).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::zfirst() && arg_count == 1 {
                // {:zfirst, key}
                if let Ok(key) = args[0].decode::<rustler::Binary>() {
                    return match inner.zfirst(db, key.as_slice()) {
                        Ok(Some((score, member))) => {
                            let mut member_bin =
                                rustler::types::OwnedBinary::new(member.len()).unwrap();
                            member_bin.as_mut_slice().copy_from_slice(member.as_slice());
                            (atoms::ok(), (score.into_inner(), member_bin.release(env))).encode(env)
                        }
                        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::zlast() && arg_count == 1 {
                // {:zlast, key}
                if let Ok(key) = args[0].decode::<rustler::Binary>() {
                    return match inner.zlast(db, key.as_slice()) {
                        Ok(Some((score, member))) => {
                            let mut member_bin =
                                rustler::types::OwnedBinary::new(member.len()).unwrap();
                            member_bin.as_mut_slice().copy_from_slice(member.as_slice());
                            (atoms::ok(), (score.into_inner(), member_bin.release(env))).encode(env)
                        }
                        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::znext() && arg_count == 3 {
                // {:znext, key, score, member}
                if let (Ok(key), Ok(score), Ok(member)) = (
                    args[0].decode::<rustler::Binary>(),
                    args[1].decode::<f64>(),
                    args[2].decode::<rustler::Binary>(),
                ) {
                    return match inner.znext(
                        db,
                        key.as_slice(),
                        OrderedFloat(score),
                        member.as_slice(),
                    ) {
                        Ok(Some((new_score, new_member))) => {
                            let mut member_bin =
                                rustler::types::OwnedBinary::new(new_member.len()).unwrap();
                            member_bin
                                .as_mut_slice()
                                .copy_from_slice(new_member.as_slice());
                            (
                                atoms::ok(),
                                (new_score.into_inner(), member_bin.release(env)),
                            )
                                .encode(env)
                        }
                        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::zprev() && arg_count == 3 {
                // {:zprev, key, score, member}
                if let (Ok(key), Ok(score), Ok(member)) = (
                    args[0].decode::<rustler::Binary>(),
                    args[1].decode::<f64>(),
                    args[2].decode::<rustler::Binary>(),
                ) {
                    return match inner.zprev(
                        db,
                        key.as_slice(),
                        OrderedFloat(score),
                        member.as_slice(),
                    ) {
                        Ok(Some((new_score, new_member))) => {
                            let mut member_bin =
                                rustler::types::OwnedBinary::new(new_member.len()).unwrap();
                            member_bin
                                .as_mut_slice()
                                .copy_from_slice(new_member.as_slice());
                            (
                                atoms::ok(),
                                (new_score.into_inner(), member_bin.release(env)),
                            )
                                .encode(env)
                        }
                        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            }
        }
    }

    // If we get here, the command is not a valid read command
    (atoms::error(), atoms::readonly_violation()).encode(env)
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
