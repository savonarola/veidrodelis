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
        return encode_error(env, "Invalid command tuple");
    };

    if terms.len() != 2 {
        return encode_error(env, "Invalid command tuple");
    }

    // First element is db (u64)
    let Ok(db) = terms[0].decode::<u64>() else {
        return encode_error(env, "Invalid database index");
    };

    // Second element is inner tuple {command_atom, arg1, arg2, ...}
    let inner_tuple: Result<Vec<rustler::Term>, _> = tuple::get_tuple(terms[1]);

    let Ok(cmd_terms) = inner_tuple else {
        return encode_error(env, "Invalid command tuple");
    };

    if cmd_terms.len() < 1 {
        return encode_error(env, "Invalid command tuple");
    }

    // First element of inner tuple is command atom
    let Ok(cmd_atom) = cmd_terms[0].decode::<rustler::Atom>() else {
        return encode_error(env, "Invalid command atom");
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
        Err("Invalid command")
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
        return Err("Invalid arguments for set");
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
        return Err("Invalid arguments for del");
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
        return Err("Invalid arguments for mset");
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
        return Err("Invalid arguments for copy");
    };
    let _ = inner.copy_key(db, source.as_slice(), destination.as_slice(), replace);
    Ok(())
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
        return Err("Invalid arguments for rename");
    };
    let _ = inner.rename(db, old_key.as_slice(), new_key.as_slice());
    Ok(())
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
        return Err("Invalid arguments for renamenx");
    };
    let _ = inner.renamenx(db, old_key.as_slice(), new_key.as_slice());
    Ok(())
}

fn handle_move_key<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(target_db)) = (args[0].decode::<rustler::Binary>(), args[1].decode::<u64>())
    else {
        return Err("Invalid arguments for move_key");
    };
    let _ = inner.move_key(db, target_db, key.as_slice());
    Ok(())
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
        return Err("Invalid arguments for append");
    };
    let _ = inner.append(db, key.as_slice(), value.as_slice());
    Ok(())
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
        return Err("Invalid arguments for setrange");
    };
    let _ = inner.setrange(db, key.as_slice(), offset, value.as_slice());
    Ok(())
}

fn handle_incr<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("Invalid arguments for incr");
    };
    let _ = inner.incr(db, key.as_slice());
    Ok(())
}

fn handle_incrby<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(increment)) = (args[0].decode::<rustler::Binary>(), args[1].decode::<i64>())
    else {
        return Err("Invalid arguments for incrby");
    };
    let _ = inner.incrby(db, key.as_slice(), increment);
    Ok(())
}

fn handle_decr<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("Invalid arguments for decr");
    };
    let _ = inner.decr(db, key.as_slice());
    Ok(())
}

fn handle_decrby<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(decrement)) = (args[0].decode::<rustler::Binary>(), args[1].decode::<i64>())
    else {
        return Err("Invalid arguments for decrby");
    };
    let _ = inner.decrby(db, key.as_slice(), decrement);
    Ok(())
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
        return Err("Invalid arguments for setnx");
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
        return Err("Invalid arguments for msetnx");
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
        return Err("Invalid arguments for getset");
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
        return Err("Invalid arguments for getdel");
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
        return Err("Invalid arguments for sadd");
    };
    let members_slices: Vec<&[u8]> = members.iter().map(|b| b.as_slice()).collect();
    let _ = inner.sadd(db, key.as_slice(), &members_slices);
    Ok(())
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
        return Err("Invalid arguments for srem");
    };
    let members_slices: Vec<&[u8]> = members.iter().map(|b| b.as_slice()).collect();
    let _ = inner.srem(db, key.as_slice(), &members_slices);
    Ok(())
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
        return Err("Invalid arguments for smove");
    };
    let _ = inner.smove(
        db,
        source_key.as_slice(),
        dest_key.as_slice(),
        member.as_slice(),
    );
    Ok(())
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
        return Err("Invalid arguments for sunionstore");
    };
    let keys_slices: Vec<&[u8]> = source_keys.iter().map(|b| b.as_slice()).collect();
    let _ = inner.sunionstore(db, dest_key.as_slice(), &keys_slices);
    Ok(())
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
        return Err("Invalid arguments for sinterstore");
    };
    let keys_slices: Vec<&[u8]> = source_keys.iter().map(|b| b.as_slice()).collect();
    let _ = inner.sinterstore(db, dest_key.as_slice(), &keys_slices);
    Ok(())
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
        return Err("Invalid arguments for sdiffstore");
    };
    let keys_slices: Vec<&[u8]> = source_keys.iter().map(|b| b.as_slice()).collect();
    let _ = inner.sdiffstore(db, dest_key.as_slice(), &keys_slices);
    Ok(())
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
        return Err("Invalid arguments for lpush");
    };
    let values_slices: Vec<&[u8]> = values.iter().map(|b| b.as_slice()).collect();
    let _ = inner.lpush(db, key.as_slice(), &values_slices);
    Ok(())
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
        return Err("Invalid arguments for rpush");
    };
    let values_slices: Vec<&[u8]> = values.iter().map(|b| b.as_slice()).collect();
    let _ = inner.rpush(db, key.as_slice(), &values_slices);
    Ok(())
}

fn handle_lpop<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("Invalid arguments for lpop");
    };
    let _ = inner.lpop(db, key.as_slice());
    Ok(())
}

fn handle_rpop<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("Invalid arguments for rpop");
    };
    let _ = inner.rpop(db, key.as_slice());
    Ok(())
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
        return Err("Invalid arguments for lset");
    };
    let _ = inner.lset(db, key.as_slice(), index, value.as_slice());
    Ok(())
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
        return Err("Invalid arguments for rpoplpush");
    };
    let _ = inner.rpoplpush(db, source_key.as_slice(), dest_key.as_slice());
    Ok(())
}

fn handle_lpop_count<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(count)) = (args[0].decode::<rustler::Binary>(), args[1].decode::<u64>())
    else {
        return Err("Invalid arguments for lpop_count");
    };
    let _ = inner.lpop_count(db, key.as_slice(), count as usize);
    Ok(())
}

fn handle_rpop_count<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let (Ok(key), Ok(count)) = (args[0].decode::<rustler::Binary>(), args[1].decode::<u64>())
    else {
        return Err("Invalid arguments for rpop_count");
    };
    let _ = inner.rpop_count(db, key.as_slice(), count as usize);
    Ok(())
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
        return Err("Invalid arguments for lmove");
    };
    let from_left = wherefrom == atoms::left();
    let to_left = whereto == atoms::left();
    let _ = inner.lmove(
        db,
        source_key.as_slice(),
        dest_key.as_slice(),
        from_left,
        to_left,
    );
    Ok(())
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
        return Err("Invalid arguments for lpushx");
    };
    let values_slices: Vec<&[u8]> = values.iter().map(|b| b.as_slice()).collect();
    let _ = inner.lpushx(db, key.as_slice(), &values_slices);
    Ok(())
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
        return Err("Invalid arguments for rpushx");
    };
    let values_slices: Vec<&[u8]> = values.iter().map(|b| b.as_slice()).collect();
    let _ = inner.rpushx(db, key.as_slice(), &values_slices);
    Ok(())
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
        return Err("Invalid arguments for lrem");
    };
    let _ = inner.lrem(db, key.as_slice(), count, value.as_slice());
    Ok(())
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
        return Err("Invalid arguments for ltrim");
    };
    let _ = inner.ltrim(db, key.as_slice(), start, stop);
    Ok(())
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
        return Err("Invalid arguments for linsert");
    };
    let before = if direction == atoms::before() {
        true
    } else if direction == atoms::after() {
        false
    } else {
        return Err("Invalid direction for linsert");
    };
    let _ = inner.linsert(
        db,
        key.as_slice(),
        before,
        pivot.as_slice(),
        value.as_slice(),
    );
    Ok(())
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
        return Err("Invalid arguments for hset");
    };
    let _ = inner.hset(db, key.as_slice(), field.as_slice(), value.as_slice());
    Ok(())
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
        return Err("Invalid arguments for hmset");
    };
    let fields_slices: Vec<(&[u8], &[u8])> = fields
        .iter()
        .map(|(f, v)| (f.as_slice(), v.as_slice()))
        .collect();
    let _ = inner.hmset(db, key.as_slice(), &fields_slices);
    Ok(())
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
        return Err("Invalid arguments for hdel");
    };
    let fields_slices: Vec<&[u8]> = fields.iter().map(|f| f.as_slice()).collect();
    let _ = inner.hdel(db, key.as_slice(), &fields_slices);
    Ok(())
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
        return Err("Invalid arguments for hsetnx");
    };
    let _ = inner.hsetnx(db, key.as_slice(), field.as_slice(), value.as_slice());
    Ok(())
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
        return Err("Invalid arguments for hincrby");
    };
    let _ = inner.hincrby(db, key.as_slice(), field.as_slice(), delta);
    Ok(())
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
        return Err("Invalid arguments for hincrbyfloat");
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
        return Err("Invalid arguments for hsetex");
    };

    let mode_term = args[1];

    let Ok(mode_atom) = mode_term.decode::<rustler::Atom>() else {
        return Err("Invalid mode for hsetex");
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
        return Err("Invalid arguments for zadd");
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
        return Err("Invalid arguments for zadd");
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
        return Err("Invalid arguments for zrem");
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
        return Err("Invalid arguments for zpopmax");
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
        return Err("Invalid arguments for zpopmin");
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
        return Err("Invalid arguments for zremrangebyrank");
    };
    inner.zremrangebyrank(db, key.as_slice(), start, stop)
}

fn handle_zremrangebyscore<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("Invalid arguments for zremrangebyscore");
    };
    let (Ok(min_bound), Ok(max_bound)) = (decode_score_bound(args[1]), decode_score_bound(args[2]))
    else {
        return Err("Invalid arguments for zremrangebyscore");
    };
    inner.zremrangebyscore(db, key.as_slice(), min_bound, max_bound)
}

fn handle_zremrangebylex<'a>(
    inner: &mut StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> Result<(), &'static str> {
    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("Invalid arguments for zremrangebylex");
    };
    let (Ok(min_bound), Ok(max_bound)) = (decode_lex_bound(args[1]), decode_lex_bound(args[2]))
    else {
        return Err("Invalid arguments for zremrangebylex");
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
        return Err("Invalid arguments for zunionstore");
    };

    let aggregate = if aggregate_atom == atoms::sum() {
        Aggregate::Sum
    } else if aggregate_atom == atoms::min() {
        Aggregate::Min
    } else if aggregate_atom == atoms::max() {
        Aggregate::Max
    } else {
        return Err("Invalid aggregate for zunionstore");
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
        return Err("Invalid arguments for zinterstore");
    };

    let aggregate = if aggregate_atom == atoms::sum() {
        Aggregate::Sum
    } else if aggregate_atom == atoms::min() {
        Aggregate::Min
    } else if aggregate_atom == atoms::max() {
        Aggregate::Max
    } else {
        return Err("Invalid aggregate for zinterstore");
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
        return Err("Invalid arguments for zdiffstore");
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
        return Err("Invalid arguments for zrangestore");
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
        return Err("Invalid arguments for zincrby");
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
        return Err("Invalid arguments for swapdb");
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
