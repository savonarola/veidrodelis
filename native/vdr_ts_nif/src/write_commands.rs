use crate::atoms;
use crate::storage;
use crate::storage::{Aggregate, Score, StorageInner, ZAddOption};
use ordered_float::OrderedFloat;
use rustler::types::tuple;
use rustler::Encoder;
use std::ops::Bound;

fn encode_error<'a>(env: rustler::Env<'a>, error: &str) -> rustler::Term<'a> {
    (atoms::error(), error).encode(env)
}

pub fn execute<'a>(
    env: rustler::Env<'a>,
    inner: &mut StorageInner,
    cmd_term: rustler::Term<'a>,
) -> rustler::Term<'a> {
    // Decode the command tuple: {db, {command_atom, arg1, arg2, ...}}
    // Get outer tuple elements
    let Ok(terms) = tuple::get_tuple(cmd_term) else {
        return encode_error(env, "Command must be a tuple");
    };

    if terms.len() != 2 {
        return encode_error(
            env,
            "Command tuple must have exactly 2 elements: {db, {command_atom, ...}}",
        );
    }

    // First element is db (u64)
    let Ok(db) = terms[0].decode::<u64>() else {
        return encode_error(env, "Database index must be an unsigned integer");
    };

    // Second element is inner tuple {command_atom, arg1, arg2, ...}
    let inner_tuple: Result<Vec<rustler::Term>, _> = tuple::get_tuple(terms[1]);

    let Ok(cmd_terms) = inner_tuple else {
        return encode_error(env, "Inner command must be a tuple");
    };

    if cmd_terms.len() < 1 {
        return encode_error(env, "Command tuple cannot be empty");
    }

    // First element of inner tuple is command atom
    let Ok(cmd_atom) = cmd_terms[0].decode::<rustler::Atom>() else {
        return encode_error(env, "Command name must be an atom");
    };

    // Rest are arguments from inner tuple
    let args = &cmd_terms[1..];

    // Use direct atom comparison and dispatch to handlers
    let result = dispatch_write_command(inner, db, cmd_atom, args);

    result.encode(env)
}

fn dispatch_write_command<'a>(
    inner: &mut StorageInner,
    db: u64,
    cmd_atom: rustler::Atom,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    if cmd_atom == atoms::set() {
        handle_set(inner, db, args)
    } else if cmd_atom == atoms::del() {
        handle_del(inner, db, args)
    } else if cmd_atom == atoms::mset() {
        handle_mset(inner, db, args)
    } else if cmd_atom == atoms::pexpireat() {
        handle_pexpireat()
    } else if cmd_atom == atoms::persist() {
        handle_persist()
    } else if cmd_atom == atoms::copy() {
        handle_copy(inner, db, args)
    } else if cmd_atom == atoms::rename() {
        handle_rename(inner, db, args)
    } else if cmd_atom == atoms::renamenx() {
        handle_renamenx(inner, db, args)
    } else if cmd_atom == atoms::move_key() {
        handle_move_key(inner, db, args)
    } else if cmd_atom == atoms::append() {
        handle_append(inner, db, args)
    } else if cmd_atom == atoms::setrange() {
        handle_setrange(inner, db, args)
    } else if cmd_atom == atoms::incr() {
        handle_incr(inner, db, args)
    } else if cmd_atom == atoms::incrby() {
        handle_incrby(inner, db, args)
    } else if cmd_atom == atoms::decr() {
        handle_decr(inner, db, args)
    } else if cmd_atom == atoms::decrby() {
        handle_decrby(inner, db, args)
    } else if cmd_atom == atoms::setnx() {
        handle_setnx(inner, db, args)
    } else if cmd_atom == atoms::msetnx() {
        handle_msetnx(inner, db, args)
    } else if cmd_atom == atoms::getset() {
        handle_getset(inner, db, args)
    } else if cmd_atom == atoms::getdel() {
        handle_getdel(inner, db, args)
    } else if cmd_atom == atoms::sadd() {
        handle_sadd(inner, db, args)
    } else if cmd_atom == atoms::srem() {
        handle_srem(inner, db, args)
    } else if cmd_atom == atoms::smove() {
        handle_smove(inner, db, args)
    } else if cmd_atom == atoms::sunionstore() {
        handle_sunionstore(inner, db, args)
    } else if cmd_atom == atoms::sinterstore() {
        handle_sinterstore(inner, db, args)
    } else if cmd_atom == atoms::sdiffstore() {
        handle_sdiffstore(inner, db, args)
    } else if cmd_atom == atoms::lpush() {
        handle_lpush(inner, db, args)
    } else if cmd_atom == atoms::rpush() {
        handle_rpush(inner, db, args)
    } else if cmd_atom == atoms::lpop() {
        handle_lpop(inner, db, args)
    } else if cmd_atom == atoms::rpop() {
        handle_rpop(inner, db, args)
    } else if cmd_atom == atoms::lset() {
        handle_lset(inner, db, args)
    } else if cmd_atom == atoms::rpoplpush() {
        handle_rpoplpush(inner, db, args)
    } else if cmd_atom == atoms::lpop_count() {
        handle_lpop_count(inner, db, args)
    } else if cmd_atom == atoms::rpop_count() {
        handle_rpop_count(inner, db, args)
    } else if cmd_atom == atoms::lmove() {
        handle_lmove(inner, db, args)
    } else if cmd_atom == atoms::lpushx() {
        handle_lpushx(inner, db, args)
    } else if cmd_atom == atoms::rpushx() {
        handle_rpushx(inner, db, args)
    } else if cmd_atom == atoms::lrem() {
        handle_lrem(inner, db, args)
    } else if cmd_atom == atoms::ltrim() {
        handle_ltrim(inner, db, args)
    } else if cmd_atom == atoms::linsert() {
        handle_linsert(inner, db, args)
    } else if cmd_atom == atoms::hset() {
        handle_hset(inner, db, args)
    } else if cmd_atom == atoms::hmset() {
        handle_hmset(inner, db, args)
    } else if cmd_atom == atoms::hdel() {
        handle_hdel(inner, db, args)
    } else if cmd_atom == atoms::hsetnx() {
        handle_hsetnx(inner, db, args)
    } else if cmd_atom == atoms::hincrby() {
        handle_hincrby(inner, db, args)
    } else if cmd_atom == atoms::hincrbyfloat() {
        handle_hincrbyfloat(inner, db, args)
    } else if cmd_atom == atoms::hsetex() {
        handle_hsetex(inner, db, args)
    } else if cmd_atom == atoms::zadd() {
        handle_zadd(inner, db, args)
    } else if cmd_atom == atoms::zrem() {
        handle_zrem(inner, db, args)
    } else if cmd_atom == atoms::zpopmax() {
        handle_zpopmax(inner, db, args)
    } else if cmd_atom == atoms::zpopmin() {
        handle_zpopmin(inner, db, args)
    } else if cmd_atom == atoms::zremrangebyrank() {
        handle_zremrangebyrank(inner, db, args)
    } else if cmd_atom == atoms::zremrangebyscore() {
        handle_zremrangebyscore(inner, db, args)
    } else if cmd_atom == atoms::zremrangebylex() {
        handle_zremrangebylex(inner, db, args)
    } else if cmd_atom == atoms::zunionstore() {
        handle_zunionstore(inner, db, args)
    } else if cmd_atom == atoms::zinterstore() {
        handle_zinterstore(inner, db, args)
    } else if cmd_atom == atoms::zdiffstore() {
        handle_zdiffstore(inner, db, args)
    } else if cmd_atom == atoms::zrangestore() {
        handle_zrangestore(inner, db, args)
    } else if cmd_atom == atoms::zincrby() {
        handle_zincrby(inner, db, args)
    } else if cmd_atom == atoms::flushall() {
        handle_flushall(inner)
    } else if cmd_atom == atoms::flushdb() {
        handle_flushdb(inner, db)
    } else if cmd_atom == atoms::swapdb() {
        handle_swapdb(inner, args)
    } else {
        Err("Unknown write command")
    }
}

// Helper functions for command handling - String commands
fn handle_set<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(value)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
    ) else {
        return Err("SET requires 2 arguments: key and value must be binaries");
    };
    inner.set(db, key.as_slice(), value.as_slice());
    Ok(())
}

fn handle_del<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let Ok(keys) = args[0].decode::<Vec<rustler::Binary>>() else {
        return Err("DEL requires 1 argument: keys must be a list of binaries");
    };
    for key in keys.iter() {
        inner.del(db, key.as_slice());
    }
    Ok(())
}

fn handle_mset<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let Ok(pairs) = args[0].decode::<Vec<(rustler::Binary, rustler::Binary)>>() else {
        return Err("MSET requires 1 argument: pairs must be a list of {key, value} tuples");
    };
    let pairs_slices: Vec<(&[u8], &[u8])> = pairs
        .iter()
        .map(|(k, v)| (k.as_slice(), v.as_slice()))
        .collect();
    inner.mset(db, &pairs_slices);
    Ok(())
}

fn handle_pexpireat() -> Result<(), &'static str> {
    Ok(())
}

fn handle_persist() -> Result<(), &'static str> {
    Ok(())
}

// Key management commands
fn handle_copy<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(source), Ok(destination), Ok(replace)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
        args[2].decode::<bool>(),
    ) else {
        return Err("COPY requires 3 arguments: source and destination must be binaries, replace must be a boolean");
    };
    inner.copy_key(db, source.as_slice(), destination.as_slice(), replace)
}

fn handle_rename<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(old_key), Ok(new_key)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
    ) else {
        return Err("RENAME requires 2 arguments: old_key and new_key must be binaries");
    };
    inner.rename(db, old_key.as_slice(), new_key.as_slice())
}

fn handle_renamenx<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(old_key), Ok(new_key)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
    ) else {
        return Err("RENAMENX requires 2 arguments: old_key and new_key must be binaries");
    };
    inner.renamenx(db, old_key.as_slice(), new_key.as_slice())
}

fn handle_move_key<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(target_db)) = (args[0].decode::<rustler::Binary>(), args[1].decode::<u64>())
    else {
        return Err(
            "MOVE requires 2 arguments: key must be a binary, target_db must be an integer",
        );
    };
    inner.move_key(db, target_db, key.as_slice())
}

// String manipulation commands
fn handle_append<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(value)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
    ) else {
        return Err("APPEND requires 2 arguments: key and value must be binaries");
    };
    inner.append(db, key.as_slice(), value.as_slice())
}

fn handle_setrange<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(offset), Ok(value)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<usize>(),
        args[2].decode::<rustler::Binary>(),
    ) else {
        return Err("SETRANGE requires 3 arguments: key and value must be binaries, offset must be an integer");
    };
    inner.setrange(db, key.as_slice(), offset, value.as_slice())
}

fn handle_incr<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("INCR requires 1 argument: key must be a binary");
    };
    inner.incr(db, key.as_slice())
}

fn handle_incrby<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(increment)) = (args[0].decode::<rustler::Binary>(), args[1].decode::<i64>())
    else {
        return Err(
            "INCRBY requires 2 arguments: key must be a binary, increment must be an integer",
        );
    };
    inner.incrby(db, key.as_slice(), increment)
}

fn handle_decr<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("DECR requires 1 argument: key must be a binary");
    };
    inner.decr(db, key.as_slice())
}

fn handle_decrby<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(decrement)) = (args[0].decode::<rustler::Binary>(), args[1].decode::<i64>())
    else {
        return Err(
            "DECRBY requires 2 arguments: key must be a binary, decrement must be an integer",
        );
    };
    inner.decrby(db, key.as_slice(), decrement)
}

fn handle_setnx<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(value)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
    ) else {
        return Err("SETNX requires 2 arguments: key and value must be binaries");
    };
    inner.set(db, key.as_slice(), value.as_slice());
    Ok(())
}

fn handle_msetnx<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let Ok(pairs) = args[0].decode::<Vec<(rustler::Binary, rustler::Binary)>>() else {
        return Err("MSETNX requires 1 argument: pairs must be a list of {key, value} tuples");
    };
    let pairs_slices: Vec<(&[u8], &[u8])> = pairs
        .iter()
        .map(|(k, v)| (k.as_slice(), v.as_slice()))
        .collect();
    inner.mset(db, &pairs_slices);
    Ok(())
}

fn handle_getset<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(value)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
    ) else {
        return Err("GETSET requires 2 arguments: key and value must be binaries");
    };
    inner.set(db, key.as_slice(), value.as_slice());
    Ok(())
}

fn handle_getdel<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("GETDEL requires 1 argument: key must be a binary");
    };
    inner.del(db, key.as_slice());
    Ok(())
}

// Set commands
fn handle_sadd<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(members)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<Vec<rustler::Binary>>(),
    ) else {
        return Err(
            "SADD requires 2 arguments: key must be a binary, members must be a list of binaries",
        );
    };
    let members_slices: Vec<&[u8]> = members.iter().map(|b| b.as_slice()).collect();
    inner.sadd(db, key.as_slice(), &members_slices)
}

fn handle_srem<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(members)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<Vec<rustler::Binary>>(),
    ) else {
        return Err(
            "SREM requires 2 arguments: key must be a binary, members must be a list of binaries",
        );
    };
    let members_slices: Vec<&[u8]> = members.iter().map(|b| b.as_slice()).collect();
    inner.srem(db, key.as_slice(), &members_slices)
}

fn handle_smove<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(source_key), Ok(dest_key), Ok(member)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
        args[2].decode::<rustler::Binary>(),
    ) else {
        return Err(
            "SMOVE requires 3 arguments: source_key, dest_key, and member must be binaries",
        );
    };
    inner.smove(
        db,
        source_key.as_slice(),
        dest_key.as_slice(),
        member.as_slice(),
    )
}

fn handle_sunionstore<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(dest_key), Ok(source_keys)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<Vec<rustler::Binary>>(),
    ) else {
        return Err("SUNIONSTORE requires 2 arguments: dest_key must be a binary, source_keys must be a list of binaries");
    };
    let keys_slices: Vec<&[u8]> = source_keys.iter().map(|b| b.as_slice()).collect();
    inner.sunionstore(db, dest_key.as_slice(), &keys_slices)
}

fn handle_sinterstore<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(dest_key), Ok(source_keys)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<Vec<rustler::Binary>>(),
    ) else {
        return Err("SINTERSTORE requires 2 arguments: dest_key must be a binary, source_keys must be a list of binaries");
    };
    let keys_slices: Vec<&[u8]> = source_keys.iter().map(|b| b.as_slice()).collect();
    inner.sinterstore(db, dest_key.as_slice(), &keys_slices)
}

fn handle_sdiffstore<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(dest_key), Ok(source_keys)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<Vec<rustler::Binary>>(),
    ) else {
        return Err("SDIFFSTORE requires 2 arguments: dest_key must be a binary, source_keys must be a list of binaries");
    };
    let keys_slices: Vec<&[u8]> = source_keys.iter().map(|b| b.as_slice()).collect();
    inner.sdiffstore(db, dest_key.as_slice(), &keys_slices)
}

// List commands
fn handle_lpush<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(values)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<Vec<rustler::Binary>>(),
    ) else {
        return Err(
            "LPUSH requires 2 arguments: key must be a binary, values must be a list of binaries",
        );
    };
    let values_slices: Vec<&[u8]> = values.iter().map(|b| b.as_slice()).collect();
    inner.lpush(db, key.as_slice(), &values_slices)
}

fn handle_rpush<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(values)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<Vec<rustler::Binary>>(),
    ) else {
        return Err(
            "RPUSH requires 2 arguments: key must be a binary, values must be a list of binaries",
        );
    };
    let values_slices: Vec<&[u8]> = values.iter().map(|b| b.as_slice()).collect();
    inner.rpush(db, key.as_slice(), &values_slices)
}

fn handle_lpop<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("LPOP requires 1 argument: key must be a binary");
    };
    inner.lpop(db, key.as_slice())
}

fn handle_rpop<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("RPOP requires 1 argument: key must be a binary");
    };
    inner.rpop(db, key.as_slice())
}

fn handle_lset<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(index), Ok(value)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<i64>(),
        args[2].decode::<rustler::Binary>(),
    ) else {
        return Err(
            "LSET requires 3 arguments: key and value must be binaries, index must be an integer",
        );
    };
    inner.lset(db, key.as_slice(), index, value.as_slice())
}

fn handle_rpoplpush<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(source_key), Ok(dest_key)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
    ) else {
        return Err("RPOPLPUSH requires 2 arguments: source_key and dest_key must be binaries");
    };
    inner.rpoplpush(db, source_key.as_slice(), dest_key.as_slice())
}

fn handle_lpop_count<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(count)) = (args[0].decode::<rustler::Binary>(), args[1].decode::<u64>())
    else {
        return Err("LPOP requires 2 arguments: key must be a binary, count must be an integer");
    };
    inner.lpop_count(db, key.as_slice(), count as usize)
}

fn handle_rpop_count<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(count)) = (args[0].decode::<rustler::Binary>(), args[1].decode::<u64>())
    else {
        return Err("RPOP requires 2 arguments: key must be a binary, count must be an integer");
    };
    inner.rpop_count(db, key.as_slice(), count as usize)
}

fn handle_lmove<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(source_key), Ok(dest_key), Ok(wherefrom), Ok(whereto)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
        args[2].decode::<rustler::Atom>(),
        args[3].decode::<rustler::Atom>(),
    ) else {
        return Err("LMOVE requires 4 arguments: source_key and dest_key must be binaries, wherefrom and whereto must be atoms");
    };
    let from_left = wherefrom == atoms::left();
    let to_left = whereto == atoms::left();
    inner.lmove(
        db,
        source_key.as_slice(),
        dest_key.as_slice(),
        from_left,
        to_left,
    )
}

fn handle_lpushx<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(values)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<Vec<rustler::Binary>>(),
    ) else {
        return Err(
            "LPUSHX requires 2 arguments: key must be a binary, values must be a list of binaries",
        );
    };
    let values_slices: Vec<&[u8]> = values.iter().map(|b| b.as_slice()).collect();
    inner.lpushx(db, key.as_slice(), &values_slices)
}

fn handle_rpushx<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(values)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<Vec<rustler::Binary>>(),
    ) else {
        return Err(
            "RPUSHX requires 2 arguments: key must be a binary, values must be a list of binaries",
        );
    };
    let values_slices: Vec<&[u8]> = values.iter().map(|b| b.as_slice()).collect();
    inner.rpushx(db, key.as_slice(), &values_slices)
}

fn handle_lrem<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(count), Ok(value)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<i64>(),
        args[2].decode::<rustler::Binary>(),
    ) else {
        return Err(
            "LREM requires 3 arguments: key and value must be binaries, count must be an integer",
        );
    };
    inner.lrem(db, key.as_slice(), count, value.as_slice())
}

fn handle_ltrim<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(start), Ok(stop)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<i64>(),
        args[2].decode::<i64>(),
    ) else {
        return Err(
            "LTRIM requires 3 arguments: key must be a binary, start and stop must be integers",
        );
    };
    inner.ltrim(db, key.as_slice(), start, stop)
}

fn handle_linsert<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(direction), Ok(pivot), Ok(value)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Atom>(),
        args[2].decode::<rustler::Binary>(),
        args[3].decode::<rustler::Binary>(),
    ) else {
        return Err("LINSERT requires 4 arguments: key, pivot, and value must be binaries, direction must be an atom");
    };
    let before = if direction == atoms::before() {
        true
    } else if direction == atoms::after() {
        false
    } else {
        return Err("LINSERT direction must be :before or :after");
    };
    inner.linsert(
        db,
        key.as_slice(),
        before,
        pivot.as_slice(),
        value.as_slice(),
    )
}

// Hash commands
fn handle_hset<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(field), Ok(value)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
        args[2].decode::<rustler::Binary>(),
    ) else {
        return Err("HSET requires 3 arguments: key, field, and value must be binaries");
    };
    inner.hset(db, key.as_slice(), field.as_slice(), value.as_slice())
}

fn handle_hmset<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(fields)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<Vec<(rustler::Binary, rustler::Binary)>>(),
    ) else {
        return Err("HMSET requires 2 arguments: key must be a binary, fields must be a list of {field, value} tuples");
    };
    let fields_slices: Vec<(&[u8], &[u8])> = fields
        .iter()
        .map(|(f, v)| (f.as_slice(), v.as_slice()))
        .collect();
    inner.hmset(db, key.as_slice(), &fields_slices)
}

fn handle_hdel<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(fields)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<Vec<rustler::Binary>>(),
    ) else {
        return Err(
            "HDEL requires 2 arguments: key must be a binary, fields must be a list of binaries",
        );
    };
    let fields_slices: Vec<&[u8]> = fields.iter().map(|f| f.as_slice()).collect();
    inner.hdel(db, key.as_slice(), &fields_slices)
}

fn handle_hsetnx<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(field), Ok(value)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
        args[2].decode::<rustler::Binary>(),
    ) else {
        return Err("HSETNX requires 3 arguments: key, field, and value must be binaries");
    };
    inner.hsetnx(db, key.as_slice(), field.as_slice(), value.as_slice())
}

fn handle_hincrby<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(field), Ok(delta)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
        args[2].decode::<i64>(),
    ) else {
        return Err("HINCRBY requires 3 arguments: key and field must be binaries, delta must be an integer");
    };
    inner.hincrby(db, key.as_slice(), field.as_slice(), delta)
}

fn handle_hincrbyfloat<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(field), Ok(delta)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
        args[2].decode::<f64>(),
    ) else {
        return Err("HINCRBYFLOAT requires 3 arguments: key and field must be binaries, delta must be a float");
    };
    inner.hincrbyfloat(db, key.as_slice(), field.as_slice(), delta)
}

fn handle_hsetex<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(fields_list)) = (
        args[0].decode::<rustler::Binary>(),
        args[2].decode::<Vec<(rustler::Binary, rustler::Binary)>>(),
    ) else {
        return Err("HSETEX requires 3 arguments: key must be a binary, mode must be an atom, fields must be a list of {field, value} tuples");
    };

    let mode_term = args[1];

    let Ok(mode_atom) = mode_term.decode::<rustler::Atom>() else {
        return Err("HSETEX mode must be an atom (:nil, :nx, or :xx)");
    };

    let mode = if mode_atom == atoms::nil() {
        None
    } else if mode_atom == atoms::nx() {
        Some(storage::types::HSetEXMode::NX)
    } else if mode_atom == atoms::xx() {
        Some(storage::types::HSetEXMode::XX)
    } else {
        None
    };

    let fields: Vec<(&[u8], &[u8])> = fields_list
        .iter()
        .map(|(f, v)| (f.as_slice(), v.as_slice()))
        .collect();

    inner.hsetex(db, key.as_slice(), mode, &fields)
}

// Sorted set commands
fn handle_zadd<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("ZADD requires at least 2 arguments: key must be a binary");
    };

    let members_result: Result<Vec<(f64, rustler::Binary)>, rustler::Error> =
        args[1].decode::<Vec<rustler::Term>>().and_then(|terms| {
            terms
                .iter()
                .map(|term| {
                    let tuple = term.decode::<(rustler::Term, rustler::Binary)>()?;
                    let score = decode_score(tuple.0)?;
                    Ok((score, tuple.1))
                })
                .collect()
        });

    let Ok(members) = members_result else {
        return Err("ZADD members must be a list of {score, member} tuples");
    };

    let options = if args.len() == 3 {
        args[2]
            .decode::<Vec<rustler::Atom>>()
            .map(|atoms_vec| {
                atoms_vec
                    .iter()
                    .filter_map(|atom| {
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
                    })
                    .collect()
            })
            .unwrap_or_default()
    } else {
        vec![]
    };

    let members_slices: Vec<(Score, &[u8])> = members
        .iter()
        .map(|(score, member)| (OrderedFloat(*score), member.as_slice()))
        .collect();
    inner.zadd(db, key.as_slice(), &members_slices, &options)
}

fn handle_zrem<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(members)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<Vec<rustler::Binary>>(),
    ) else {
        return Err(
            "ZREM requires 2 arguments: key must be a binary, members must be a list of binaries",
        );
    };
    let members_slices: Vec<&[u8]> = members.iter().map(|m| m.as_slice()).collect();
    inner.zrem(db, key.as_slice(), &members_slices)
}

fn handle_zpopmax<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(count)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<usize>(),
    ) else {
        return Err("ZPOPMAX requires 2 arguments: key must be a binary, count must be an integer");
    };
    inner.zpopmax(db, key.as_slice(), count)
}

fn handle_zpopmin<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(count)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<usize>(),
    ) else {
        return Err("ZPOPMIN requires 2 arguments: key must be a binary, count must be an integer");
    };
    inner.zpopmin(db, key.as_slice(), count)
}

fn handle_zremrangebyrank<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(start), Ok(stop)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<i64>(),
        args[2].decode::<i64>(),
    ) else {
        return Err("ZREMRANGEBYRANK requires 3 arguments: key must be a binary, start and stop must be integers");
    };
    inner.zremrangebyrank(db, key.as_slice(), start, stop)
}

fn handle_zremrangebyscore<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("ZREMRANGEBYSCORE requires 3 arguments: key must be a binary");
    };
    let (Ok(min_bound), Ok(max_bound)) = (decode_score_bound(args[1]), decode_score_bound(args[2]))
    else {
        return Err("ZREMRANGEBYSCORE min and max must be valid score bounds (:unbounded, {:included, score}, or {:excluded, score})");
    };
    inner.zremrangebyscore(db, key.as_slice(), min_bound, max_bound)
}

fn handle_zremrangebylex<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("ZREMRANGEBYLEX requires 3 arguments: key must be a binary");
    };
    let (Ok(min_bound), Ok(max_bound)) = (decode_lex_bound(args[1]), decode_lex_bound(args[2]))
    else {
        return Err("ZREMRANGEBYLEX min and max must be valid lex bounds (:unbounded, {:included, value}, or {:excluded, value})");
    };
    inner.zremrangebylex(db, key.as_slice(), min_bound, max_bound)
}

fn handle_zunionstore<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(dest_key), Ok(source_keys), Ok(weights), Ok(aggregate_atom)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<Vec<rustler::Binary>>(),
        args[2].decode::<Vec<f64>>(),
        args[3].decode::<rustler::Atom>(),
    ) else {
        return Err("ZUNIONSTORE requires 4 arguments: dest_key must be a binary, source_keys must be a list of binaries, weights must be a list of floats, aggregate must be an atom");
    };

    let aggregate = if aggregate_atom == atoms::sum() {
        Aggregate::Sum
    } else if aggregate_atom == atoms::min() {
        Aggregate::Min
    } else if aggregate_atom == atoms::max() {
        Aggregate::Max
    } else {
        return Err("ZUNIONSTORE aggregate must be :sum, :min, or :max");
    };

    let keys_slices: Vec<&[u8]> = source_keys.iter().map(|k| k.as_slice()).collect();
    inner.zunionstore(db, dest_key.as_slice(), &keys_slices, &weights, aggregate)
}

fn handle_zinterstore<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(dest_key), Ok(source_keys), Ok(weights), Ok(aggregate_atom)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<Vec<rustler::Binary>>(),
        args[2].decode::<Vec<f64>>(),
        args[3].decode::<rustler::Atom>(),
    ) else {
        return Err("ZINTERSTORE requires 4 arguments: dest_key must be a binary, source_keys must be a list of binaries, weights must be a list of floats, aggregate must be an atom");
    };

    let aggregate = if aggregate_atom == atoms::sum() {
        Aggregate::Sum
    } else if aggregate_atom == atoms::min() {
        Aggregate::Min
    } else if aggregate_atom == atoms::max() {
        Aggregate::Max
    } else {
        return Err("ZINTERSTORE aggregate must be :sum, :min, or :max");
    };

    let keys_slices: Vec<&[u8]> = source_keys.iter().map(|k| k.as_slice()).collect();
    inner.zinterstore(db, dest_key.as_slice(), &keys_slices, &weights, aggregate)
}

fn handle_zdiffstore<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(dest_key), Ok(source_keys)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<Vec<rustler::Binary>>(),
    ) else {
        return Err("ZDIFFSTORE requires 2 arguments: dest_key must be a binary, source_keys must be a list of binaries");
    };
    let keys_slices: Vec<&[u8]> = source_keys.iter().map(|k| k.as_slice()).collect();
    inner.zdiffstore(db, dest_key.as_slice(), &keys_slices)
}

fn handle_zrangestore<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(dest_key), Ok(source_key), Ok(min_str), Ok(max_str), Ok(options)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
        args[2].decode::<String>(),
        args[3].decode::<String>(),
        args[4].decode::<Vec<String>>(),
    ) else {
        return Err("ZRANGESTORE requires 5 arguments: dest_key and source_key must be binaries, min_str and max_str must be strings, options must be a list of strings");
    };

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
                    if let (Ok(offset), Ok(count)) =
                        (options[i + 1].parse::<i64>(), options[i + 2].parse::<i64>())
                    {
                        limit = Some((offset, count));
                        i += 2;
                    }
                }
            }
            _ => {}
        }
        i += 1;
    }

    inner.zrangestore(
        db,
        dest_key.as_slice(),
        source_key.as_slice(),
        &min_str,
        &max_str,
        by_score,
        by_lex,
        rev,
        limit,
    )
}

fn handle_zincrby<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(delta), Ok(member)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<f64>(),
        args[2].decode::<rustler::Binary>(),
    ) else {
        return Err(
            "ZINCRBY requires 3 arguments: key and member must be binaries, delta must be a float",
        );
    };
    inner.zincrby(db, key.as_slice(), OrderedFloat(delta), member.as_slice())
}

// Database commands
fn handle_flushall<'a>(inner: &mut StorageInner) -> Result<(), &'static str> {
    inner.flushall()
}

fn handle_flushdb<'a>(inner: &mut StorageInner, db: u64) -> Result<(), &'static str> {
    inner.flushdb(db)
}

fn handle_swapdb<'a>(
    inner: &mut StorageInner,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(db1), Ok(db2)) = (args[0].decode::<u64>(), args[1].decode::<u64>()) else {
        return Err("SWAPDB requires 2 arguments: db1 and db2 must be integers");
    };
    inner.swapdb(db1, db2)
}

/// Helper function to decode Elixir bound tuples into Rust Bound<Score>
/// Elixir format: :unbounded | {:included, score} | {:excluded, score}
fn decode_score_bound(term: rustler::Term) -> Result<Bound<Score>, rustler::Error> {
    // Try to decode as atom first (for :unbounded)
    if let Ok(atom) = term.decode::<rustler::Atom>() {
        if atom == atoms::unbounded() {
            return Ok(Bound::Unbounded);
        }
    }

    // Try to decode as tuple {atom, score}
    let tuple = term.decode::<(rustler::Atom, f64)>()?;
    let (bound_atom, score) = tuple;

    if bound_atom == atoms::included() {
        Ok(Bound::Included(OrderedFloat(score)))
    } else if bound_atom == atoms::excluded() {
        Ok(Bound::Excluded(OrderedFloat(score)))
    } else {
        Err(rustler::Error::BadArg)
    }
}

/// Helper function to decode Elixir bound tuples into Rust Bound<storage::Bytes>
/// Elixir format: :unbounded | {:included, value} | {:excluded, value}
fn decode_lex_bound(term: rustler::Term) -> Result<Bound<storage::Bytes>, rustler::Error> {
    // Try to decode as atom first (for :unbounded)
    if let Ok(atom) = term.decode::<rustler::Atom>() {
        if atom == atoms::unbounded() {
            return Ok(Bound::Unbounded);
        }
    }

    // Try to decode as tuple {atom, value}
    let tuple = term.decode::<(rustler::Atom, rustler::Binary)>()?;
    let (bound_atom, value) = tuple;

    if bound_atom == atoms::included() {
        Ok(Bound::Included(storage::Bytes::new(value.as_slice())))
    } else if bound_atom == atoms::excluded() {
        Ok(Bound::Excluded(storage::Bytes::new(value.as_slice())))
    } else {
        Err(rustler::Error::BadArg)
    }
}

/// Helper function to decode a score value which can be either f64 or special atoms
/// Elixir format: float | :pos_inf | :neg_inf | :nan
fn decode_score(term: rustler::Term) -> Result<f64, rustler::Error> {
    // IMPORTANT: Check for atoms FIRST! If we try f64 first, atoms decode as 0
    if let Ok(atom) = term.decode::<rustler::Atom>() {
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
