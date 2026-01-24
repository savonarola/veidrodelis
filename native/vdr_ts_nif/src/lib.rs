mod atoms;
mod storage;

use ordered_float::OrderedFloat;
use rustler::types::Binary;
use rustler::{Atom, Encoder, Env, Resource, ResourceArc, Term};
use std::sync::Mutex;

use storage::{Aggregate, Score, StorageInner, ZAddOption};
use std::ops::Bound;

/// Helper function to decode Elixir bound tuples into Rust Bound<Score>
/// Elixir format: :unbounded | {:included, score} | {:excluded, score}
fn decode_score_bound(term: Term) -> Result<Bound<Score>, rustler::Error> {
    // Try to decode as atom first (for :unbounded)
    if let Ok(atom) = term.decode::<rustler::types::Atom>() {
        if atom == atoms::unbounded() {
            return Ok(Bound::Unbounded);
        }
    }

    // Try to decode as tuple {atom, score}
    let tuple = term.decode::<(rustler::types::Atom, f64)>()?;
    let (bound_atom, score) = tuple;

    if bound_atom == atoms::included() {
        Ok(Bound::Included(OrderedFloat(score)))
    } else if bound_atom == atoms::excluded() {
        Ok(Bound::Excluded(OrderedFloat(score)))
    } else {
        Err(rustler::Error::BadArg)
    }
}

/// Helper function to decode Elixir bound tuples into Rust Bound<Bytes>
/// Elixir format: :unbounded | {:included, value} | {:excluded, value}
fn decode_lex_bound(term: Term) -> Result<Bound<storage::Bytes>, rustler::Error> {
    use storage::Bytes;

    // Try to decode as atom first (for :unbounded)
    if let Ok(atom) = term.decode::<rustler::types::Atom>() {
        if atom == atoms::unbounded() {
            return Ok(Bound::Unbounded);
        }
    }

    // Try to decode as tuple {atom, value}
    let tuple = term.decode::<(rustler::types::Atom, Binary)>()?;
    let (bound_atom, value) = tuple;

    if bound_atom == atoms::included() {
        Ok(Bound::Included(Bytes::new(value.as_slice())))
    } else if bound_atom == atoms::excluded() {
        Ok(Bound::Excluded(Bytes::new(value.as_slice())))
    } else {
        Err(rustler::Error::BadArg)
    }
}

/// Helper function to decode a score value which can be either f64 or special atoms
/// Elixir format: float | :pos_inf | :neg_inf | :nan
fn decode_score(term: Term) -> Result<f64, rustler::Error> {
    // IMPORTANT: Check for atoms FIRST! If we try f64 first, atoms decode as 0
    if let Ok(atom) = term.decode::<rustler::types::Atom>() {
        if atom == atoms::pos_inf() {
            return Ok(f64::INFINITY);
        } else if atom == atoms::neg_inf() {
            return Ok(f64::NEG_INFINITY);
        } else if atom == atoms::nan() {
            return Ok(f64::NAN);
        }
        // Fall through if atom doesn't match special values
    }

    // Try to decode as f64
    if let Ok(score) = term.decode::<f64>() {
        return Ok(score);
    }

    Err(rustler::Error::BadArg)
}

/// The term storage resource (wrapper around Mutex to satisfy orphan rule)
pub struct TStorage(Mutex<StorageInner>);

#[rustler::resource_impl(register = false)]
impl Resource for TStorage {}

#[rustler::nif(name = "create")]
fn create_storage() -> ResourceArc<TStorage> {
    ResourceArc::new(TStorage(Mutex::new(StorageInner::new())))
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

// Batch write command execution NIF
// Executes multiple write commands under a single mutex lock
#[rustler::nif(name = "tx")]
fn execute_write_commands<'a>(
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
        let result = execute_single_write_command(env, &mut inner, cmd_term);
        results.push(result);
    }

    results.encode(env)
}

// Batch read command execution NIF
// Executes multiple read-only commands under a single mutex lock
#[rustler::nif(name = "read_tx_commands")]
fn execute_read_commands<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    db: u64,
    commands: Vec<Term<'a>>,
) -> Term<'a> {
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



fn execute_single_write_command<'a>(
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

            let arg_count = args.len();

            // Use direct atom comparison
            if cmd_atom == atoms::set() && arg_count == 2 {
                // {db, {:set, key, value}}
                if let (Ok(key), Ok(value)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Binary>()
                ) {
                    inner.set(db, key.as_slice(), value.as_slice());
                    return atoms::ok().encode(env);
                }
            } else if cmd_atom == atoms::del() && arg_count == 1 {
                // {db, {:del, keys}} where keys is a list
                if let Ok(keys) = args[0].decode::<Vec<Binary>>() {
                    for key in keys.iter() {
                        inner.del(db, key.as_slice());
                    }
                    return atoms::ok().encode(env);
                }
            } else if cmd_atom == atoms::mset() && arg_count == 1 {
                // {db, {:mset, pairs}} where pairs is [{key, value}, ...]
                if let Ok(pairs) = args[0].decode::<Vec<(Binary, Binary)>>() {
                    let pairs_slices: Vec<(&[u8], &[u8])> = pairs
                        .iter()
                        .map(|(k, v)| (k.as_slice(), v.as_slice()))
                        .collect();
                    inner.mset(db, &pairs_slices);
                    return atoms::ok().encode(env);
                }
            } else if cmd_atom == atoms::pexpireat() {
                // {db, {:pexpireat, key, timestamp}} - null handler, just return ok
                return atoms::ok().encode(env);
            } else if cmd_atom == atoms::persist() {
                // {db, {:persist, key}} - null handler, just return ok
                return atoms::ok().encode(env);
            } else if cmd_atom == atoms::copy() && arg_count == 3 {
                // {db, {:copy, source, destination, replace}}
                if let (Ok(source), Ok(destination), Ok(replace)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Binary>(),
                    args[2].decode::<bool>()
                ) {
                    return match inner.copy_key(db, source.as_slice(), destination.as_slice(), replace) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::rename() && arg_count == 2 {
                // {db, {:rename, old_key, new_key}}
                if let (Ok(old_key), Ok(new_key)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Binary>()
                ) {
                    return match inner.rename(db, old_key.as_slice(), new_key.as_slice()) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::renamenx() && arg_count == 2 {
                // {db, {:renamenx, old_key, new_key}}
                if let (Ok(old_key), Ok(new_key)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Binary>()
                ) {
                    return match inner.renamenx(db, old_key.as_slice(), new_key.as_slice()) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::move_key() && arg_count == 2 {
                // {db, {:move_key, key, target_db}}
                if let (Ok(key), Ok(target_db)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<u64>()
                ) {
                    return match inner.move_key(db, target_db, key.as_slice()) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::append() && arg_count == 2 {
                // {db, {:append, key, value}}
                if let (Ok(key), Ok(value)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Binary>()
                ) {
                    return match inner.append(db, key.as_slice(), value.as_slice()) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::setrange() && arg_count == 3 {
                // {db, {:setrange, key, offset, value}}
                if let (Ok(key), Ok(offset), Ok(value)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<usize>(),
                    args[2].decode::<Binary>()
                ) {
                    return match inner.setrange(db, key.as_slice(), offset, value.as_slice()) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::incr() && arg_count == 1 {
                // {db, {:incr, key}}
                if let Ok(key) = args[0].decode::<Binary>() {
                    return match inner.incr(db, key.as_slice()) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::incrby() && arg_count == 2 {
                // {db, {:incrby, key, increment}}
                if let (Ok(key), Ok(increment)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<i64>()
                ) {
                    return match inner.incrby(db, key.as_slice(), increment) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::decr() && arg_count == 1 {
                // {db, {:decr, key}}
                if let Ok(key) = args[0].decode::<Binary>() {
                    return match inner.decr(db, key.as_slice()) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::decrby() && arg_count == 2 {
                // {db, {:decrby, key, decrement}}
                if let (Ok(key), Ok(decrement)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<i64>()
                ) {
                    return match inner.decrby(db, key.as_slice(), decrement) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::setnx() && arg_count == 2 {
                // {db, {:setnx, key, value}} - treat as set (only replicated if successful)
                if let (Ok(key), Ok(value)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Binary>()
                ) {
                    inner.set(db, key.as_slice(), value.as_slice());
                    return atoms::ok().encode(env);
                }
            } else if cmd_atom == atoms::msetnx() && arg_count == 1 {
                // {db, {:msetnx, pairs}} - treat as mset (only replicated if successful)
                if let Ok(pairs) = args[0].decode::<Vec<(Binary, Binary)>>() {
                    let pairs_slices: Vec<(&[u8], &[u8])> = pairs
                        .iter()
                        .map(|(k, v)| (k.as_slice(), v.as_slice()))
                        .collect();
                    inner.mset(db, &pairs_slices);
                    return atoms::ok().encode(env);
                }
            } else if cmd_atom == atoms::getset() && arg_count == 2 {
                // {db, {:getset, key, value}} - treat as set (ignore the get part)
                if let (Ok(key), Ok(value)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Binary>()
                ) {
                    inner.set(db, key.as_slice(), value.as_slice());
                    return atoms::ok().encode(env);
                }
            } else if cmd_atom == atoms::getdel() && arg_count == 1 {
                // {db, {:getdel, key}} - treat as del (ignore the get part)
                if let Ok(key) = args[0].decode::<Binary>() {
                    inner.del(db, key.as_slice());
                    return atoms::ok().encode(env);
                }
            } else if cmd_atom == atoms::sadd() && arg_count == 2 {
                // {db, {:sadd, key, members}}
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
            } else if cmd_atom == atoms::srem() && arg_count == 2 {
                // {db, {:srem, key, members}}
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
            } else if cmd_atom == atoms::smove() && arg_count == 3 {
                // {db, {:smove, source_key, dest_key, member}}
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
            } else if cmd_atom == atoms::sunionstore() && arg_count == 2 {
                // {db, {:sunionstore, dest_key, source_keys}}
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
            } else if cmd_atom == atoms::sinterstore() && arg_count == 2 {
                // {db, {:sinterstore, dest_key, source_keys}}
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
            } else if cmd_atom == atoms::sdiffstore() && arg_count == 2 {
                // {db, {:sdiffstore, dest_key, source_keys}}
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
            } else if cmd_atom == atoms::lpush() && arg_count == 2 {
                // {db, {:lpush, key, values}}
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
            } else if cmd_atom == atoms::rpush() && arg_count == 2 {
                // {db, {:rpush, key, values}}
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
            } else if cmd_atom == atoms::lpop() && arg_count == 1 {
                // {db, {:lpop, key}}
                if let Ok(key) = args[0].decode::<Binary>() {
                    return match inner.lpop(db, key.as_slice()) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::rpop() && arg_count == 1 {
                // {db, {:rpop, key}}
                if let Ok(key) = args[0].decode::<Binary>() {
                    return match inner.rpop(db, key.as_slice()) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::lset() && arg_count == 3 {
                // {db, {:lset, key, index, value}}
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
            } else if cmd_atom == atoms::rpoplpush() && arg_count == 2 {
                // {db, {:rpoplpush, source_key, dest_key}}
                if let (Ok(source_key), Ok(dest_key)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Binary>()
                ) {
                    return match inner.rpoplpush(db, source_key.as_slice(), dest_key.as_slice()) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::lpop_count() && arg_count == 2 {
                // {db, {:lpop_count, key, count}}
                if let (Ok(key), Ok(count)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<u64>()
                ) {
                    return match inner.lpop_count(db, key.as_slice(), count as usize) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::rpop_count() && arg_count == 2 {
                // {db, {:rpop_count, key, count}}
                if let (Ok(key), Ok(count)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<u64>()
                ) {
                    return match inner.rpop_count(db, key.as_slice(), count as usize) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::lmove() && arg_count == 4 {
                // {db, {:lmove, source_key, dest_key, wherefrom, whereto}}
                let source_key: Result<Binary, _> = args[0].decode();
                let dest_key: Result<Binary, _> = args[1].decode();
                let wherefrom: Result<Atom, _> = args[2].decode();
                let whereto: Result<Atom, _> = args[3].decode();
                if let (Ok(source_key), Ok(dest_key), Ok(wherefrom), Ok(whereto)) = (source_key, dest_key, wherefrom, whereto) {
                    let from_left = wherefrom == atoms::left();
                    let to_left = whereto == atoms::left();
                    return match inner.lmove(db, source_key.as_slice(), dest_key.as_slice(), from_left, to_left) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::lpushx() && arg_count == 2 {
                // {db, {:lpushx, key, values}}
                if let (Ok(key), Ok(values)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Vec<Binary>>()
                ) {
                    let values_slices: Vec<&[u8]> = values.iter().map(|b| b.as_slice()).collect();
                    return match inner.lpushx(db, key.as_slice(), &values_slices) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::rpushx() && arg_count == 2 {
                // {db, {:rpushx, key, values}}
                if let (Ok(key), Ok(values)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Vec<Binary>>()
                ) {
                    let values_slices: Vec<&[u8]> = values.iter().map(|b| b.as_slice()).collect();
                    return match inner.rpushx(db, key.as_slice(), &values_slices) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::lrem() && arg_count == 3 {
                // {db, {:lrem, key, count, value}}
                if let (Ok(key), Ok(count), Ok(value)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<i64>(),
                    args[2].decode::<Binary>()
                ) {
                    return match inner.lrem(db, key.as_slice(), count, value.as_slice()) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::ltrim() && arg_count == 3 {
                // {db, {:ltrim, key, start, stop}}
                if let (Ok(key), Ok(start), Ok(stop)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<i64>(),
                    args[2].decode::<i64>()
                ) {
                    return match inner.ltrim(db, key.as_slice(), start, stop) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::linsert() && arg_count == 4 {
                // {db, {:linsert, key, direction, pivot, value}}
                // direction is :before or :after atom
                if let (Ok(key), Ok(direction), Ok(pivot), Ok(value)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<rustler::types::Atom>(),
                    args[2].decode::<Binary>(),
                    args[3].decode::<Binary>()
                ) {
                    let before = if direction == atoms::before() {
                        true
                    } else if direction == atoms::after() {
                        false
                    } else {
                        return (atoms::error(), rustler::types::atom::error().encode(env)).encode(env);
                    };
                    return match inner.linsert(db, key.as_slice(), before, pivot.as_slice(), value.as_slice()) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hset() && arg_count == 3 {
                // {db, {:hset, key, field, value}}
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
            } else if cmd_atom == atoms::hmset() && arg_count == 2 {
                // {db, {:hmset, key, fields}}
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
            } else if cmd_atom == atoms::hdel() && arg_count == 2 {
                // {db, {:hdel, key, fields}}
                if let (Ok(key), Ok(fields)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Vec<Binary>>()
                ) {
                    let fields_slices: Vec<&[u8]> = fields.iter().map(|f| f.as_slice()).collect();
                    return match inner.hdel(db, key.as_slice(), &fields_slices) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hsetnx() && arg_count == 3 {
                // {db, {:hsetnx, key, field, value}}
                if let (Ok(key), Ok(field), Ok(value)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Binary>(),
                    args[2].decode::<Binary>()
                ) {
                    return match inner.hsetnx(db, key.as_slice(), field.as_slice(), value.as_slice()) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hincrby() && arg_count == 3 {
                // {db, {:hincrby, key, field, delta}}
                if let (Ok(key), Ok(field), Ok(delta)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Binary>(),
                    args[2].decode::<i64>()
                ) {
                    return match inner.hincrby(db, key.as_slice(), field.as_slice(), delta) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hincrbyfloat() && arg_count == 3 {
                // {db, {:hincrbyfloat, key, field, delta}}
                if let (Ok(key), Ok(field), Ok(delta)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Binary>(),
                    args[2].decode::<f64>()
                ) {
                    return match inner.hincrbyfloat(db, key.as_slice(), field.as_slice(), delta) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hsetex() && arg_count == 3 {
                // {db, {:hsetex, key, mode, fields}}
                // where mode is :nx, :xx, or :nil
                // fields is [{field, value}, ...]
                if let (Ok(key), Ok(fields_list)) = (
                    args[0].decode::<Binary>(),
                    args[2].decode::<Vec<(Binary, Binary)>>()
                ) {
                    // Decode mode
                    let mode_term = args[1];
                    let mode = if mode_term == atoms::nil().to_term(env) {
                        None
                    } else if mode_term == atoms::nx().to_term(env) {
                        Some(storage::types::HSetEXMode::NX)
                    } else if mode_term == atoms::xx().to_term(env) {
                        Some(storage::types::HSetEXMode::XX)
                    } else {
                        None
                    };

                    // Convert fields to slice references
                    let fields: Vec<(&[u8], &[u8])> = fields_list
                        .iter()
                        .map(|(f, v)| (f.as_slice(), v.as_slice()))
                        .collect();

                    return match inner.hsetex(db, key.as_slice(), mode, &fields) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if (cmd_atom == atoms::zadd()) && (args.len() == 2 || args.len() == 3) {
                // {db, {:zadd, key, members}} or {db, {:zadd, key, members, options}}
                // where members is [{score, member}, ...], options is list of atoms
                // Scores can be f64, :pos_inf, :neg_inf, or :nan
                if let Ok(key) = args[0].decode::<Binary>() {
                    // Manually decode members list to handle special score atoms
                    let members_result: Result<Vec<(f64, Binary)>, rustler::Error> =
                        args[1].decode::<Vec<Term>>()
                            .and_then(|terms| {
                                terms.iter().map(|term| {
                                    let tuple = term.decode::<(Term, Binary)>()?;
                                    let score = decode_score(tuple.0)?;
                                    Ok((score, tuple.1))
                                }).collect()
                            });

                    if let Ok(members) = members_result {
                        let options = if args.len() == 3 {
                            // Decode atoms and convert to ZAddOption enum
                            args[2].decode::<Vec<rustler::types::Atom>>()
                                .map(|atoms| {
                                    atoms.iter().filter_map(|atom| {
                                        if *atom == atoms::nx() {
                                            Some(ZAddOption::NX)
                                        } else if *atom == atoms::xx() {
                                            Some(ZAddOption::XX)
                                        } else if *atom == atoms::gt() {
                                            Some(ZAddOption::GT)
                                        } else if *atom == atoms::lt() {
                                            Some(ZAddOption::LT)
                                        } else if *atom == atoms::ch() {
                                            Some(ZAddOption::CH)
                                        } else if *atom == atoms::incr() {
                                            Some(ZAddOption::INCR)
                                        } else {
                                            None
                                        }
                                    }).collect()
                                })
                                .unwrap_or_default()
                        } else {
                            vec![]
                        };

                        let members_slices: Vec<(Score, &[u8])> = members
                            .iter()
                            .map(|(score, member)| (OrderedFloat(*score), member.as_slice()))
                            .collect();
                        return match inner.zadd(db, key.as_slice(), &members_slices, &options) {
                            Ok(_) => atoms::ok().encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::zrem() && arg_count == 2 {
                // {db, {:zrem, key, members}}
                if let (Ok(key), Ok(members)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Vec<Binary>>()
                ) {
                    let members_slices: Vec<&[u8]> = members.iter().map(|m| m.as_slice()).collect();
                    return match inner.zrem(db, key.as_slice(), &members_slices) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::zpopmax() && arg_count == 2 {
                // {db, {:zpopmax, key, count}}
                if let (Ok(key), Ok(count)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<usize>()
                ) {
                    return match inner.zpopmax(db, key.as_slice(), count) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::zpopmin() && arg_count == 2 {
                // {db, {:zpopmin, key, count}}
                if let (Ok(key), Ok(count)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<usize>()
                ) {
                    return match inner.zpopmin(db, key.as_slice(), count) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::zremrangebyrank() && arg_count == 3 {
                // {db, {:zremrangebyrank, key, start, stop}}
                if let (Ok(key), Ok(start), Ok(stop)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<i64>(),
                    args[2].decode::<i64>()
                ) {
                    return match inner.zremrangebyrank(db, key.as_slice(), start, stop) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::zremrangebyscore() && arg_count == 3 {
                // {db, {:zremrangebyscore, key, min_bound, max_bound}}
                // Bounds: :unbounded | {:included, score} | {:excluded, score}
                if let Ok(key) = args[0].decode::<Binary>() {
                    if let (Ok(min_bound), Ok(max_bound)) = (
                        decode_score_bound(args[1]),
                        decode_score_bound(args[2])
                    ) {
                        return match inner.zremrangebyscore(db, key.as_slice(), min_bound, max_bound) {
                            Ok(_) => atoms::ok().encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::zremrangebylex() && arg_count == 3 {
                // {db, {:zremrangebylex, key, min_bound, max_bound}}
                // Bounds: :unbounded | {:included, value} | {:excluded, value}
                if let Ok(key) = args[0].decode::<Binary>() {
                    if let (Ok(min_bound), Ok(max_bound)) = (
                        decode_lex_bound(args[1]),
                        decode_lex_bound(args[2])
                    ) {
                        return match inner.zremrangebylex(db, key.as_slice(), min_bound, max_bound) {
                            Ok(_) => atoms::ok().encode(env),
                            Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                        };
                    }
                }
            } else if cmd_atom == atoms::zunionstore() && arg_count == 4 {
                // {db, {:zunionstore, dest_key, source_keys, weights, aggregate}}
                // aggregate is :sum, :min, or :max atom
                if let (Ok(dest_key), Ok(source_keys), Ok(weights), Ok(aggregate_atom)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Vec<Binary>>(),
                    args[2].decode::<Vec<f64>>(),
                    args[3].decode::<rustler::types::Atom>()
                ) {
                    // Convert atom to Aggregate enum
                    let aggregate = if aggregate_atom == atoms::sum() {
                        Aggregate::Sum
                    } else if aggregate_atom == atoms::min() {
                        Aggregate::Min
                    } else if aggregate_atom == atoms::max() {
                        Aggregate::Max
                    } else {
                        return (atoms::error(), rustler::types::atom::error().encode(env)).encode(env);
                    };

                    let keys_slices: Vec<&[u8]> = source_keys.iter().map(|k| k.as_slice()).collect();
                    return match inner.zunionstore(db, dest_key.as_slice(), &keys_slices, &weights, aggregate) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::zinterstore() && arg_count == 4 {
                // {db, {:zinterstore, dest_key, source_keys, weights, aggregate}}
                // aggregate is :sum, :min, or :max atom
                if let (Ok(dest_key), Ok(source_keys), Ok(weights), Ok(aggregate_atom)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Vec<Binary>>(),
                    args[2].decode::<Vec<f64>>(),
                    args[3].decode::<rustler::types::Atom>()
                ) {
                    // Convert atom to Aggregate enum
                    let aggregate = if aggregate_atom == atoms::sum() {
                        Aggregate::Sum
                    } else if aggregate_atom == atoms::min() {
                        Aggregate::Min
                    } else if aggregate_atom == atoms::max() {
                        Aggregate::Max
                    } else {
                        return (atoms::error(), rustler::types::atom::error().encode(env)).encode(env);
                    };

                    let keys_slices: Vec<&[u8]> = source_keys.iter().map(|k| k.as_slice()).collect();
                    return match inner.zinterstore(db, dest_key.as_slice(), &keys_slices, &weights, aggregate) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::zdiffstore() && arg_count == 2 {
                // {db, {:zdiffstore, dest_key, source_keys}}
                if let (Ok(dest_key), Ok(source_keys)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Vec<Binary>>()
                ) {
                    let keys_slices: Vec<&[u8]> = source_keys.iter().map(|k| k.as_slice()).collect();
                    return match inner.zdiffstore(db, dest_key.as_slice(), &keys_slices) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::zrangestore() && arg_count == 5 {
                // {db, {:zrangestore, dest_key, source_key, min, max, options}}
                if let (Ok(dest_key), Ok(source_key), Ok(min_str), Ok(max_str), Ok(options)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Binary>(),
                    args[2].decode::<String>(),
                    args[3].decode::<String>(),
                    args[4].decode::<Vec<String>>()
                ) {
                    // Parse options: BYSCORE, BYLEX, REV, LIMIT offset count
                    let mut by_score = false;
                    let mut by_lex = false;
                    let mut rev = false;
                    let mut limit: Option<(i64, i64)> = None;

                    let mut i = 0;
                    while i < options.len() {
                        match options[i].as_str() {
                            "BYSCORE" => by_score = true,
                            "BYLEX" => by_lex = true,
                            "REV" => rev = true,
                            "LIMIT" => {
                                if i + 2 < options.len() {
                                    if let (Ok(offset), Ok(count)) = (
                                        options[i + 1].parse::<i64>(),
                                        options[i + 2].parse::<i64>()
                                    ) {
                                        limit = Some((offset, count));
                                        i += 2;
                                    }
                                }
                            }
                            _ => {}
                        }
                        i += 1;
                    }

                    return match inner.zrangestore(
                        db,
                        dest_key.as_slice(),
                        source_key.as_slice(),
                        &min_str,
                        &max_str,
                        by_score,
                        by_lex,
                        rev,
                        limit
                    ) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::flushall() {
                // {db, {:flushall}} - db is ignored, clears all databases
                return match inner.flushall() {
                    Ok(_) => atoms::ok().encode(env),
                    Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                };
            } else if cmd_atom == atoms::flushdb() {
                // {db, {:flushdb}} - clears the specified database
                return match inner.flushdb(db) {
                    Ok(_) => atoms::ok().encode(env),
                    Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                };
            } else if cmd_atom == atoms::swapdb() && arg_count == 2 {
                // {db, {:swapdb, db1, db2}} - db parameter is ignored, uses db1 and db2 from args
                if let (Ok(db1), Ok(db2)) = (
                    args[0].decode::<u64>(),
                    args[1].decode::<u64>()
                ) {
                    return match inner.swapdb(db1, db2) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::zincrby() && arg_count == 3 {
                // {db, {:zincrby, key, delta, member}}
                if let (Ok(key), Ok(delta), Ok(member)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<f64>(),
                    args[2].decode::<Binary>()
                ) {
                    return match inner.zincrby(db, key.as_slice(), OrderedFloat(delta), member.as_slice()) {
                        Ok(_) => atoms::ok().encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            }
            }
        }
    }

    // If we get here, the command was malformed or unknown
    (atoms::error(), rustler::types::atom::error().encode(env)).encode(env)
}

// Execute a single read-only command
fn execute_single_read_command<'a>(
    env: Env<'a>,
    inner: &StorageInner,
    db: u64,
    cmd_term: Term<'a>,
) -> Term<'a> {
    use rustler::types::tuple;

    // Decode the command tuple: {command_atom, arg1, arg2, ...}
    let cmd_terms: Result<Vec<Term>, _> = tuple::get_tuple(cmd_term);

    if let Ok(cmd_terms) = cmd_terms {
        if cmd_terms.is_empty() {
            return (atoms::error(), atoms::readonly_violation()).encode(env);
        }

        // First element is command atom
        let cmd_atom: Result<rustler::types::Atom, _> = cmd_terms[0].decode();

        if let Ok(cmd_atom) = cmd_atom {
            // Rest are arguments
            let args = &cmd_terms[1..];

            let arg_count = args.len();

            // READ OPERATIONS ONLY
            if cmd_atom == atoms::get() && arg_count == 1 {
                // {:get, key}
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
            } else if cmd_atom == atoms::smembers() && arg_count == 1 {
                // {:smembers, key}
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
            } else if cmd_atom == atoms::sismember() && arg_count == 2 {
                // {:sismember, key, member}
                if let (Ok(key), Ok(member)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Binary>()
                ) {
                    return match inner.sismember(db, key.as_slice(), member.as_slice()) {
                        Ok(is_member) => (atoms::ok(), is_member).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::scard() && arg_count == 1 {
                // {:scard, key}
                if let Ok(key) = args[0].decode::<Binary>() {
                    return match inner.scard(db, key.as_slice()) {
                        Ok(count) => (atoms::ok(), count).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::sfirst() && arg_count == 1 {
                // {:sfirst, key}
                if let Ok(key) = args[0].decode::<Binary>() {
                    return match inner.sfirst(db, key.as_slice()) {
                        Ok(Some(member)) => {
                            let mut member_bin = rustler::types::OwnedBinary::new(member.len()).unwrap();
                            member_bin.as_mut_slice().copy_from_slice(member.as_slice());
                            (atoms::ok(), member_bin.release(env)).encode(env)
                        }
                        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::slast() && arg_count == 1 {
                // {:slast, key}
                if let Ok(key) = args[0].decode::<Binary>() {
                    return match inner.slast(db, key.as_slice()) {
                        Ok(Some(member)) => {
                            let mut member_bin = rustler::types::OwnedBinary::new(member.len()).unwrap();
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
                    args[0].decode::<Binary>(),
                    args[1].decode::<Binary>()
                ) {
                    return match inner.snext(db, key.as_slice(), member.as_slice()) {
                        Ok(Some(next_member)) => {
                            let mut member_bin = rustler::types::OwnedBinary::new(next_member.len()).unwrap();
                            member_bin.as_mut_slice().copy_from_slice(next_member.as_slice());
                            (atoms::ok(), member_bin.release(env)).encode(env)
                        }
                        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::sprev() && arg_count == 2 {
                // {:sprev, key, member}
                if let (Ok(key), Ok(member)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Binary>()
                ) {
                    return match inner.sprev(db, key.as_slice(), member.as_slice()) {
                        Ok(Some(prev_member)) => {
                            let mut member_bin = rustler::types::OwnedBinary::new(prev_member.len()).unwrap();
                            member_bin.as_mut_slice().copy_from_slice(prev_member.as_slice());
                            (atoms::ok(), member_bin.release(env)).encode(env)
                        }
                        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::smismember() && arg_count == 2 {
                // {:smismember, key, members}
                if let (Ok(key), Ok(members_list)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Vec<Binary>>()
                ) {
                    let members: Vec<&[u8]> = members_list.iter().map(|b| b.as_slice()).collect();
                    return match inner.smismember(db, key.as_slice(), &members) {
                        Ok(results) => (atoms::ok(), results).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::srandmember() && arg_count == 2 {
                // {:srandmember, key, count}
                if let (Ok(key), Ok(count)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<i64>()
                ) {
                    return match inner.srandmember(db, key.as_slice(), count) {
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
            } else if cmd_atom == atoms::sunion() && arg_count == 1 {
                // {:sunion, keys}
                if let Ok(keys_list) = args[0].decode::<Vec<Binary>>() {
                    let keys: Vec<&[u8]> = keys_list.iter().map(|b| b.as_slice()).collect();
                    return match inner.sunion(db, &keys) {
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
            } else if cmd_atom == atoms::sinter() && arg_count == 1 {
                // {:sinter, keys}
                if let Ok(keys_list) = args[0].decode::<Vec<Binary>>() {
                    let keys: Vec<&[u8]> = keys_list.iter().map(|b| b.as_slice()).collect();
                    return match inner.sinter(db, &keys) {
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
            } else if cmd_atom == atoms::sdiff() && arg_count == 1 {
                // {:sdiff, keys}
                if let Ok(keys_list) = args[0].decode::<Vec<Binary>>() {
                    let keys: Vec<&[u8]> = keys_list.iter().map(|b| b.as_slice()).collect();
                    return match inner.sdiff(db, &keys) {
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
            } else if cmd_atom == atoms::sintercard() && arg_count == 1 {
                // {:sintercard, keys}
                if let Ok(keys_list) = args[0].decode::<Vec<Binary>>() {
                    let keys: Vec<&[u8]> = keys_list.iter().map(|b| b.as_slice()).collect();
                    return match inner.sintercard(db, &keys) {
                        Ok(count) => (atoms::ok(), count).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::llen() && arg_count == 1 {
                // {:llen, key}
                if let Ok(key) = args[0].decode::<Binary>() {
                    return match inner.llen(db, key.as_slice()) {
                        Ok(len) => (atoms::ok(), len).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::lrange() && arg_count == 3 {
                // {:lrange, key, start, stop}
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
            } else if cmd_atom == atoms::hget() && arg_count == 2 {
                // {:hget, key, field}
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
            } else if cmd_atom == atoms::hmget() && arg_count == 2 {
                // {:hmget, key, fields}
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
            } else if cmd_atom == atoms::hgetall() && arg_count == 1 {
                // {:hgetall, key}
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
            } else if cmd_atom == atoms::hkeys() && arg_count == 1 {
                // {:hkeys, key}
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
            } else if cmd_atom == atoms::hvals() && arg_count == 1 {
                // {:hvals, key}
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
            } else if cmd_atom == atoms::hlen() && arg_count == 1 {
                // {:hlen, key}
                if let Ok(key) = args[0].decode::<Binary>() {
                    return match inner.hlen(db, key.as_slice()) {
                        Ok(len) => (atoms::ok(), len).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hexists() && arg_count == 2 {
                // {:hexists, key, field}
                if let (Ok(key), Ok(field)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Binary>()
                ) {
                    return match inner.hexists(db, key.as_slice(), field.as_slice()) {
                        Ok(exists) => (atoms::ok(), exists).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hfirst() && arg_count == 1 {
                // {:hfirst, key}
                if let Ok(key) = args[0].decode::<Binary>() {
                    return match inner.hfirst(db, key.as_slice()) {
                        Ok(Some((field, value))) => {
                            let mut field_bin = rustler::types::OwnedBinary::new(field.len()).unwrap();
                            field_bin.as_mut_slice().copy_from_slice(field.as_slice());
                            let mut value_bin = rustler::types::OwnedBinary::new(value.len()).unwrap();
                            value_bin.as_mut_slice().copy_from_slice(value.as_slice());
                            (atoms::ok(), (field_bin.release(env), value_bin.release(env))).encode(env)
                        }
                        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hlast() && arg_count == 1 {
                // {:hlast, key}
                if let Ok(key) = args[0].decode::<Binary>() {
                    return match inner.hlast(db, key.as_slice()) {
                        Ok(Some((field, value))) => {
                            let mut field_bin = rustler::types::OwnedBinary::new(field.len()).unwrap();
                            field_bin.as_mut_slice().copy_from_slice(field.as_slice());
                            let mut value_bin = rustler::types::OwnedBinary::new(value.len()).unwrap();
                            value_bin.as_mut_slice().copy_from_slice(value.as_slice());
                            (atoms::ok(), (field_bin.release(env), value_bin.release(env))).encode(env)
                        }
                        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hnext() && arg_count == 2 {
                // {:hnext, key, field}
                if let (Ok(key), Ok(field)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Binary>()
                ) {
                    return match inner.hnext(db, key.as_slice(), field.as_slice()) {
                        Ok(Some((next_field, value))) => {
                            let mut field_bin = rustler::types::OwnedBinary::new(next_field.len()).unwrap();
                            field_bin.as_mut_slice().copy_from_slice(next_field.as_slice());
                            let mut value_bin = rustler::types::OwnedBinary::new(value.len()).unwrap();
                            value_bin.as_mut_slice().copy_from_slice(value.as_slice());
                            (atoms::ok(), (field_bin.release(env), value_bin.release(env))).encode(env)
                        }
                        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hprev() && arg_count == 2 {
                // {:hprev, key, field}
                if let (Ok(key), Ok(field)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Binary>()
                ) {
                    return match inner.hprev(db, key.as_slice(), field.as_slice()) {
                        Ok(Some((prev_field, value))) => {
                            let mut field_bin = rustler::types::OwnedBinary::new(prev_field.len()).unwrap();
                            field_bin.as_mut_slice().copy_from_slice(prev_field.as_slice());
                            let mut value_bin = rustler::types::OwnedBinary::new(value.len()).unwrap();
                            value_bin.as_mut_slice().copy_from_slice(value.as_slice());
                            (atoms::ok(), (field_bin.release(env), value_bin.release(env))).encode(env)
                        }
                        Ok(None) => (atoms::ok(), atoms::nil()).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hstrlen() && arg_count == 2 {
                // {:hstrlen, key, field}
                if let (Ok(key), Ok(field)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<Binary>()
                ) {
                    return match inner.hstrlen(db, key.as_slice(), field.as_slice()) {
                        Ok(len) => (atoms::ok(), len).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::hrandfield() && arg_count == 3 {
                // {:hrandfield, key, count, with_values}
                if let (Ok(key), Ok(count), Ok(with_values)) = (
                    args[0].decode::<Binary>(),
                    args[1].decode::<i64>(),
                    args[2].decode::<bool>()
                ) {
                    return match inner.hrandfield(db, key.as_slice(), count, with_values) {
                        Ok(results) => {
                            let elems: Vec<Term> = results.iter().map(|(field, opt_value)| {
                                let mut field_bin = rustler::types::OwnedBinary::new(field.len()).unwrap();
                                field_bin.as_mut_slice().copy_from_slice(field.as_slice());

                                if with_values {
                                    if let Some(value) = opt_value {
                                        let mut value_bin = rustler::types::OwnedBinary::new(value.len()).unwrap();
                                        value_bin.as_mut_slice().copy_from_slice(value.as_slice());
                                        (field_bin.release(env), value_bin.release(env)).encode(env)
                                    } else {
                                        field_bin.release(env).encode(env)
                                    }
                                } else {
                                    field_bin.release(env).encode(env)
                                }
                            }).collect();
                            (atoms::ok(), elems).encode(env)
                        }
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::zscore() && arg_count == 2 {
                // {:zscore, key, member}
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
            } else if cmd_atom == atoms::zcard() && arg_count == 1 {
                // {:zcard, key}
                if let Ok(key) = args[0].decode::<Binary>() {
                    return match inner.zcard(db, key.as_slice()) {
                        Ok(count) => (atoms::ok(), count).encode(env),
                        Err(_) => (atoms::error(), atoms::wrong_type()).encode(env),
                    };
                }
            } else if cmd_atom == atoms::zrange() && arg_count == 4 {
                // {:zrange, key, start, stop, with_scores}
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
            } else if cmd_atom == atoms::zrangebyscore() && arg_count == 4 {
                // {:zrangebyscore, key, min, max, with_scores}
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
            } else if cmd_atom == atoms::zrank() && arg_count == 2 {
                // {:zrank, key, member}
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
            } else if cmd_atom == atoms::zrevrank() && arg_count == 2 {
                // {:zrevrank, key, member}
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
            } else if cmd_atom == atoms::zcount() && arg_count == 3 {
                // {:zcount, key, min, max}
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
            } else if cmd_atom == atoms::zfirst() && arg_count == 1 {
                // {:zfirst, key}
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
            } else if cmd_atom == atoms::zlast() && arg_count == 1 {
                // {:zlast, key}
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
            } else if cmd_atom == atoms::znext() && arg_count == 3 {
                // {:znext, key, score, member}
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
            } else if cmd_atom == atoms::zprev() && arg_count == 3 {
                // {:zprev, key, score, member}
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

    // If we get here, the command is not a valid read command
    (atoms::error(), atoms::readonly_violation()).encode(env)
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

#[rustler::nif(name = "read_tx_lua")]
fn execute_tx_lua<'a>(
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
