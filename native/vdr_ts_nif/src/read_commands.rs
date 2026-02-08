use crate::atoms;
use crate::storage::StorageInner;
use ordered_float::OrderedFloat;
use rustler::types::tuple;
use rustler::Encoder;

type ReadResult<'a> = Result<rustler::Term<'a>, &'static str>;

pub fn execute<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    cmd_term: rustler::Term<'a>,
) -> rustler::Term<'a> {
    // Decode the command tuple: {command_atom, arg1, arg2, ...}
    let cmd_terms: Result<Vec<rustler::Term>, _> = tuple::get_tuple(cmd_term);

    let Ok(cmd_terms) = cmd_terms else {
        return encode_error(env, "Invalid command tuple");
    };

    if cmd_terms.is_empty() {
        return encode_error(env, "Empty command tuple");
    }

    // First element is command atom
    let Ok(cmd_atom) = cmd_terms[0].decode::<rustler::Atom>() else {
        return encode_error(env, "Invalid command atom");
    };

    // Rest are arguments
    let args = &cmd_terms[1..];

    // Dispatch to handler
    let result = dispatch_read_command(env, inner, db, cmd_atom, args);

    match result {
        Ok(term) => term,
        Err(error_msg) => encode_error(env, error_msg),
    }
}

fn encode_error<'a>(env: rustler::Env<'a>, error: &str) -> rustler::Term<'a> {
    (atoms::error(), error).encode(env)
}

fn dispatch_read_command<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    cmd_atom: rustler::Atom,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    // String commands
    if cmd_atom == atoms::get() {
        handle_get(env, inner, db, args)
    // Set commands
    } else if cmd_atom == atoms::smembers() {
        handle_smembers(env, inner, db, args)
    } else if cmd_atom == atoms::sismember() {
        handle_sismember(env, inner, db, args)
    } else if cmd_atom == atoms::scard() {
        handle_scard(env, inner, db, args)
    } else if cmd_atom == atoms::sfirst() {
        handle_sfirst(env, inner, db, args)
    } else if cmd_atom == atoms::slast() {
        handle_slast(env, inner, db, args)
    } else if cmd_atom == atoms::snext() {
        handle_snext(env, inner, db, args)
    } else if cmd_atom == atoms::sprev() {
        handle_sprev(env, inner, db, args)
    } else if cmd_atom == atoms::smismember() {
        handle_smismember(env, inner, db, args)
    } else if cmd_atom == atoms::srandmember() {
        handle_srandmember(env, inner, db, args)
    } else if cmd_atom == atoms::sunion() {
        handle_sunion(env, inner, db, args)
    } else if cmd_atom == atoms::sinter() {
        handle_sinter(env, inner, db, args)
    } else if cmd_atom == atoms::sdiff() {
        handle_sdiff(env, inner, db, args)
    } else if cmd_atom == atoms::sintercard() {
        handle_sintercard(env, inner, db, args)
    // List commands
    } else if cmd_atom == atoms::llen() {
        handle_llen(env, inner, db, args)
    } else if cmd_atom == atoms::lrange() {
        handle_lrange(env, inner, db, args)
    // Hash commands
    } else if cmd_atom == atoms::hget() {
        handle_hget(env, inner, db, args)
    } else if cmd_atom == atoms::hmget() {
        handle_hmget(env, inner, db, args)
    } else if cmd_atom == atoms::hgetall() {
        handle_hgetall(env, inner, db, args)
    } else if cmd_atom == atoms::hkeys() {
        handle_hkeys(env, inner, db, args)
    } else if cmd_atom == atoms::hvals() {
        handle_hvals(env, inner, db, args)
    } else if cmd_atom == atoms::hlen() {
        handle_hlen(env, inner, db, args)
    } else if cmd_atom == atoms::hexists() {
        handle_hexists(env, inner, db, args)
    } else if cmd_atom == atoms::hfirst() {
        handle_hfirst(env, inner, db, args)
    } else if cmd_atom == atoms::hlast() {
        handle_hlast(env, inner, db, args)
    } else if cmd_atom == atoms::hnext() {
        handle_hnext(env, inner, db, args)
    } else if cmd_atom == atoms::hprev() {
        handle_hprev(env, inner, db, args)
    } else if cmd_atom == atoms::hstrlen() {
        handle_hstrlen(env, inner, db, args)
    } else if cmd_atom == atoms::hrandfield() {
        handle_hrandfield(env, inner, db, args)
    // Sorted set commands
    } else if cmd_atom == atoms::zscore() {
        handle_zscore(env, inner, db, args)
    } else if cmd_atom == atoms::zcard() {
        handle_zcard(env, inner, db, args)
    } else if cmd_atom == atoms::zrange() {
        handle_zrange(env, inner, db, args)
    } else if cmd_atom == atoms::zrangebyscore() {
        handle_zrangebyscore(env, inner, db, args)
    } else if cmd_atom == atoms::zrank() {
        handle_zrank(env, inner, db, args)
    } else if cmd_atom == atoms::zrevrank() {
        handle_zrevrank(env, inner, db, args)
    } else if cmd_atom == atoms::zcount() {
        handle_zcount(env, inner, db, args)
    } else if cmd_atom == atoms::zfirst() {
        handle_zfirst(env, inner, db, args)
    } else if cmd_atom == atoms::zlast() {
        handle_zlast(env, inner, db, args)
    } else if cmd_atom == atoms::znext() {
        handle_znext(env, inner, db, args)
    } else if cmd_atom == atoms::zprev() {
        handle_zprev(env, inner, db, args)
    } else {
        Err("Unknown read command")
    }
}

// String commands
fn handle_get<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 1 {
        return Err("GET requires exactly 1 argument: key");
    }

    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("GET key must be a binary");
    };

    match inner.get(db, key.as_slice()) {
        Ok(Some(value)) => {
            let mut binary = rustler::types::OwnedBinary::new(value.len()).unwrap();
            binary.as_mut_slice().copy_from_slice(value.as_slice());
            Ok((atoms::ok(), binary.release(env)).encode(env))
        }
        Ok(None) => Ok((atoms::ok(), atoms::nil()).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

// Set commands
fn handle_smembers<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 1 {
        return Err("SMEMBERS requires exactly 1 argument: key");
    }

    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("SMEMBERS key must be a binary");
    };

    match inner.smembers(db, key.as_slice()) {
        Ok(members) => {
            let binaries: Vec<rustler::Binary> = members
                .iter()
                .map(|m| {
                    let mut binary = rustler::types::OwnedBinary::new(m.len()).unwrap();
                    binary.as_mut_slice().copy_from_slice(m.as_slice());
                    binary.release(env)
                })
                .collect();
            Ok((atoms::ok(), binaries).encode(env))
        }
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_sismember<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 2 {
        return Err("SISMEMBER requires exactly 2 arguments: key, member");
    }

    let (Ok(key), Ok(member)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
    ) else {
        return Err("SISMEMBER key and member must be binaries");
    };

    match inner.sismember(db, key.as_slice(), member.as_slice()) {
        Ok(is_member) => Ok((atoms::ok(), is_member).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_scard<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 1 {
        return Err("SCARD requires exactly 1 argument: key");
    }

    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("SCARD key must be a binary");
    };

    match inner.scard(db, key.as_slice()) {
        Ok(count) => Ok((atoms::ok(), count).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_sfirst<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 1 {
        return Err("SFIRST requires exactly 1 argument: key");
    }

    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("SFIRST key must be a binary");
    };

    match inner.sfirst(db, key.as_slice()) {
        Ok(Some(member)) => {
            let mut member_bin = rustler::types::OwnedBinary::new(member.len()).unwrap();
            member_bin.as_mut_slice().copy_from_slice(member.as_slice());
            Ok((atoms::ok(), member_bin.release(env)).encode(env))
        }
        Ok(None) => Ok((atoms::ok(), atoms::nil()).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_slast<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 1 {
        return Err("SLAST requires exactly 1 argument: key");
    }

    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("SLAST key must be a binary");
    };

    match inner.slast(db, key.as_slice()) {
        Ok(Some(member)) => {
            let mut member_bin = rustler::types::OwnedBinary::new(member.len()).unwrap();
            member_bin.as_mut_slice().copy_from_slice(member.as_slice());
            Ok((atoms::ok(), member_bin.release(env)).encode(env))
        }
        Ok(None) => Ok((atoms::ok(), atoms::nil()).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_snext<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 2 {
        return Err("SNEXT requires exactly 2 arguments: key, member");
    }

    let (Ok(key), Ok(member)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
    ) else {
        return Err("SNEXT key and member must be binaries");
    };

    match inner.snext(db, key.as_slice(), member.as_slice()) {
        Ok(Some(next_member)) => {
            let mut member_bin = rustler::types::OwnedBinary::new(next_member.len()).unwrap();
            member_bin
                .as_mut_slice()
                .copy_from_slice(next_member.as_slice());
            Ok((atoms::ok(), member_bin.release(env)).encode(env))
        }
        Ok(None) => Ok((atoms::ok(), atoms::nil()).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_sprev<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 2 {
        return Err("SPREV requires exactly 2 arguments: key, member");
    }

    let (Ok(key), Ok(member)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
    ) else {
        return Err("SPREV key and member must be binaries");
    };

    match inner.sprev(db, key.as_slice(), member.as_slice()) {
        Ok(Some(prev_member)) => {
            let mut member_bin = rustler::types::OwnedBinary::new(prev_member.len()).unwrap();
            member_bin
                .as_mut_slice()
                .copy_from_slice(prev_member.as_slice());
            Ok((atoms::ok(), member_bin.release(env)).encode(env))
        }
        Ok(None) => Ok((atoms::ok(), atoms::nil()).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_smismember<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 2 {
        return Err("SMISMEMBER requires exactly 2 arguments: key, members");
    }

    let (Ok(key), Ok(members_list)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<Vec<rustler::Binary>>(),
    ) else {
        return Err("SMISMEMBER key must be a binary and members must be a list of binaries");
    };

    let members: Vec<&[u8]> = members_list.iter().map(|b| b.as_slice()).collect();
    match inner.smismember(db, key.as_slice(), &members) {
        Ok(results) => Ok((atoms::ok(), results).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_srandmember<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 2 {
        return Err("SRANDMEMBER requires exactly 2 arguments: key, count");
    }

    let (Ok(key), Ok(count)) = (args[0].decode::<rustler::Binary>(), args[1].decode::<i64>())
    else {
        return Err("SRANDMEMBER key must be a binary and count must be an integer");
    };

    match inner.srandmember(db, key.as_slice(), count) {
        Ok(members) => {
            let binaries: Vec<rustler::Binary> = members
                .iter()
                .map(|m| {
                    let mut binary = rustler::types::OwnedBinary::new(m.len()).unwrap();
                    binary.as_mut_slice().copy_from_slice(m.as_slice());
                    binary.release(env)
                })
                .collect();
            Ok((atoms::ok(), binaries).encode(env))
        }
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_sunion<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 1 {
        return Err("SUNION requires exactly 1 argument: keys");
    }

    let Ok(keys_list) = args[0].decode::<Vec<rustler::Binary>>() else {
        return Err("SUNION keys must be a list of binaries");
    };

    let keys: Vec<&[u8]> = keys_list.iter().map(|b| b.as_slice()).collect();
    match inner.sunion(db, &keys) {
        Ok(members) => {
            let binaries: Vec<rustler::Binary> = members
                .iter()
                .map(|m| {
                    let mut binary = rustler::types::OwnedBinary::new(m.len()).unwrap();
                    binary.as_mut_slice().copy_from_slice(m.as_slice());
                    binary.release(env)
                })
                .collect();
            Ok((atoms::ok(), binaries).encode(env))
        }
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_sinter<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 1 {
        return Err("SINTER requires exactly 1 argument: keys");
    }

    let Ok(keys_list) = args[0].decode::<Vec<rustler::Binary>>() else {
        return Err("SINTER keys must be a list of binaries");
    };

    let keys: Vec<&[u8]> = keys_list.iter().map(|b| b.as_slice()).collect();
    match inner.sinter(db, &keys) {
        Ok(members) => {
            let binaries: Vec<rustler::Binary> = members
                .iter()
                .map(|m| {
                    let mut binary = rustler::types::OwnedBinary::new(m.len()).unwrap();
                    binary.as_mut_slice().copy_from_slice(m.as_slice());
                    binary.release(env)
                })
                .collect();
            Ok((atoms::ok(), binaries).encode(env))
        }
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_sdiff<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 1 {
        return Err("SDIFF requires exactly 1 argument: keys");
    }

    let Ok(keys_list) = args[0].decode::<Vec<rustler::Binary>>() else {
        return Err("SDIFF keys must be a list of binaries");
    };

    let keys: Vec<&[u8]> = keys_list.iter().map(|b| b.as_slice()).collect();
    match inner.sdiff(db, &keys) {
        Ok(members) => {
            let binaries: Vec<rustler::Binary> = members
                .iter()
                .map(|m| {
                    let mut binary = rustler::types::OwnedBinary::new(m.len()).unwrap();
                    binary.as_mut_slice().copy_from_slice(m.as_slice());
                    binary.release(env)
                })
                .collect();
            Ok((atoms::ok(), binaries).encode(env))
        }
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_sintercard<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 1 {
        return Err("SINTERCARD requires exactly 1 argument: keys");
    }

    let Ok(keys_list) = args[0].decode::<Vec<rustler::Binary>>() else {
        return Err("SINTERCARD keys must be a list of binaries");
    };

    let keys: Vec<&[u8]> = keys_list.iter().map(|b| b.as_slice()).collect();
    match inner.sintercard(db, &keys) {
        Ok(count) => Ok((atoms::ok(), count).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

// List commands
fn handle_llen<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 1 {
        return Err("LLEN requires exactly 1 argument: key");
    }

    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("LLEN key must be a binary");
    };

    match inner.llen(db, key.as_slice()) {
        Ok(len) => Ok((atoms::ok(), len).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_lrange<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 3 {
        return Err("LRANGE requires exactly 3 arguments: key, start, stop");
    }

    let (Ok(key), Ok(start), Ok(stop)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<i64>(),
        args[2].decode::<i64>(),
    ) else {
        return Err("LRANGE key must be a binary, start and stop must be integers");
    };

    match inner.lrange(db, key.as_slice(), start, stop) {
        Ok(elements) => {
            let binaries: Vec<rustler::Binary> = elements
                .iter()
                .map(|e| {
                    let mut binary = rustler::types::OwnedBinary::new(e.len()).unwrap();
                    binary.as_mut_slice().copy_from_slice(e.as_slice());
                    binary.release(env)
                })
                .collect();
            Ok((atoms::ok(), binaries).encode(env))
        }
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

// Hash commands
fn handle_hget<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 2 {
        return Err("HGET requires exactly 2 arguments: key, field");
    }

    let (Ok(key), Ok(field)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
    ) else {
        return Err("HGET key and field must be binaries");
    };

    match inner.hget(db, key.as_slice(), field.as_slice()) {
        Ok(Some(value)) => {
            let mut binary = rustler::types::OwnedBinary::new(value.len()).unwrap();
            binary.as_mut_slice().copy_from_slice(value.as_slice());
            Ok((atoms::ok(), binary.release(env)).encode(env))
        }
        Ok(None) => Ok((atoms::ok(), atoms::nil()).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_hmget<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 2 {
        return Err("HMGET requires exactly 2 arguments: key, fields");
    }

    let (Ok(key), Ok(fields)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<Vec<rustler::Binary>>(),
    ) else {
        return Err("HMGET key must be a binary and fields must be a list of binaries");
    };

    let fields_slices: Vec<&[u8]> = fields.iter().map(|f| f.as_slice()).collect();
    match inner.hmget(db, key.as_slice(), &fields_slices) {
        Ok(values) => {
            let results: Vec<rustler::Term> = values
                .iter()
                .map(|opt_v| match opt_v {
                    Some(v) => {
                        let mut binary = rustler::types::OwnedBinary::new(v.len()).unwrap();
                        binary.as_mut_slice().copy_from_slice(v.as_slice());
                        binary.release(env).encode(env)
                    }
                    None => atoms::nil().encode(env),
                })
                .collect();
            Ok((atoms::ok(), results).encode(env))
        }
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_hgetall<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 1 {
        return Err("HGETALL requires exactly 1 argument: key");
    }

    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("HGETALL key must be a binary");
    };

    match inner.hgetall(db, key.as_slice()) {
        Ok(pairs) => {
            let tuples: Vec<(rustler::Binary, rustler::Binary)> = pairs
                .iter()
                .map(|(f, v)| {
                    let mut field_bin = rustler::types::OwnedBinary::new(f.len()).unwrap();
                    field_bin.as_mut_slice().copy_from_slice(f.as_slice());
                    let mut value_bin = rustler::types::OwnedBinary::new(v.len()).unwrap();
                    value_bin.as_mut_slice().copy_from_slice(v.as_slice());
                    (field_bin.release(env), value_bin.release(env))
                })
                .collect();
            Ok((atoms::ok(), tuples).encode(env))
        }
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_hkeys<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 1 {
        return Err("HKEYS requires exactly 1 argument: key");
    }

    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("HKEYS key must be a binary");
    };

    match inner.hkeys(db, key.as_slice()) {
        Ok(keys) => {
            let binaries: Vec<rustler::Binary> = keys
                .iter()
                .map(|k| {
                    let mut binary = rustler::types::OwnedBinary::new(k.len()).unwrap();
                    binary.as_mut_slice().copy_from_slice(k.as_slice());
                    binary.release(env)
                })
                .collect();
            Ok((atoms::ok(), binaries).encode(env))
        }
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_hvals<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 1 {
        return Err("HVALS requires exactly 1 argument: key");
    }

    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("HVALS key must be a binary");
    };

    match inner.hvals(db, key.as_slice()) {
        Ok(vals) => {
            let binaries: Vec<rustler::Binary> = vals
                .iter()
                .map(|v| {
                    let mut binary = rustler::types::OwnedBinary::new(v.len()).unwrap();
                    binary.as_mut_slice().copy_from_slice(v.as_slice());
                    binary.release(env)
                })
                .collect();
            Ok((atoms::ok(), binaries).encode(env))
        }
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_hlen<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 1 {
        return Err("HLEN requires exactly 1 argument: key");
    }

    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("HLEN key must be a binary");
    };

    match inner.hlen(db, key.as_slice()) {
        Ok(len) => Ok((atoms::ok(), len).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_hexists<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 2 {
        return Err("HEXISTS requires exactly 2 arguments: key, field");
    }

    let (Ok(key), Ok(field)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
    ) else {
        return Err("HEXISTS key and field must be binaries");
    };

    match inner.hexists(db, key.as_slice(), field.as_slice()) {
        Ok(exists) => Ok((atoms::ok(), exists).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_hfirst<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 1 {
        return Err("HFIRST requires exactly 1 argument: key");
    }

    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("HFIRST key must be a binary");
    };

    match inner.hfirst(db, key.as_slice()) {
        Ok(Some((field, value))) => {
            let mut field_bin = rustler::types::OwnedBinary::new(field.len()).unwrap();
            field_bin.as_mut_slice().copy_from_slice(field.as_slice());
            let mut value_bin = rustler::types::OwnedBinary::new(value.len()).unwrap();
            value_bin.as_mut_slice().copy_from_slice(value.as_slice());
            Ok((
                atoms::ok(),
                (field_bin.release(env), value_bin.release(env)),
            )
                .encode(env))
        }
        Ok(None) => Ok((atoms::ok(), atoms::nil()).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_hlast<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 1 {
        return Err("HLAST requires exactly 1 argument: key");
    }

    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("HLAST key must be a binary");
    };

    match inner.hlast(db, key.as_slice()) {
        Ok(Some((field, value))) => {
            let mut field_bin = rustler::types::OwnedBinary::new(field.len()).unwrap();
            field_bin.as_mut_slice().copy_from_slice(field.as_slice());
            let mut value_bin = rustler::types::OwnedBinary::new(value.len()).unwrap();
            value_bin.as_mut_slice().copy_from_slice(value.as_slice());
            Ok((
                atoms::ok(),
                (field_bin.release(env), value_bin.release(env)),
            )
                .encode(env))
        }
        Ok(None) => Ok((atoms::ok(), atoms::nil()).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_hnext<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 2 {
        return Err("HNEXT requires exactly 2 arguments: key, field");
    }

    let (Ok(key), Ok(field)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
    ) else {
        return Err("HNEXT key and field must be binaries");
    };

    match inner.hnext(db, key.as_slice(), field.as_slice()) {
        Ok(Some((next_field, value))) => {
            let mut field_bin = rustler::types::OwnedBinary::new(next_field.len()).unwrap();
            field_bin
                .as_mut_slice()
                .copy_from_slice(next_field.as_slice());
            let mut value_bin = rustler::types::OwnedBinary::new(value.len()).unwrap();
            value_bin.as_mut_slice().copy_from_slice(value.as_slice());
            Ok((
                atoms::ok(),
                (field_bin.release(env), value_bin.release(env)),
            )
                .encode(env))
        }
        Ok(None) => Ok((atoms::ok(), atoms::nil()).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_hprev<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 2 {
        return Err("HPREV requires exactly 2 arguments: key, field");
    }

    let (Ok(key), Ok(field)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
    ) else {
        return Err("HPREV key and field must be binaries");
    };

    match inner.hprev(db, key.as_slice(), field.as_slice()) {
        Ok(Some((prev_field, value))) => {
            let mut field_bin = rustler::types::OwnedBinary::new(prev_field.len()).unwrap();
            field_bin
                .as_mut_slice()
                .copy_from_slice(prev_field.as_slice());
            let mut value_bin = rustler::types::OwnedBinary::new(value.len()).unwrap();
            value_bin.as_mut_slice().copy_from_slice(value.as_slice());
            Ok((
                atoms::ok(),
                (field_bin.release(env), value_bin.release(env)),
            )
                .encode(env))
        }
        Ok(None) => Ok((atoms::ok(), atoms::nil()).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_hstrlen<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 2 {
        return Err("HSTRLEN requires exactly 2 arguments: key, field");
    }

    let (Ok(key), Ok(field)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
    ) else {
        return Err("HSTRLEN key and field must be binaries");
    };

    match inner.hstrlen(db, key.as_slice(), field.as_slice()) {
        Ok(len) => Ok((atoms::ok(), len).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_hrandfield<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 3 {
        return Err("HRANDFIELD requires exactly 3 arguments: key, count, with_values");
    }

    let (Ok(key), Ok(count), Ok(with_values)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<i64>(),
        args[2].decode::<bool>(),
    ) else {
        return Err("HRANDFIELD key must be a binary, count must be an integer, with_values must be a boolean");
    };

    match inner.hrandfield(db, key.as_slice(), count, with_values) {
        Ok(results) => {
            let elems: Vec<rustler::Term> = results
                .iter()
                .map(|(field, opt_value)| {
                    let mut field_bin = rustler::types::OwnedBinary::new(field.len()).unwrap();
                    field_bin.as_mut_slice().copy_from_slice(field.as_slice());

                    if with_values {
                        if let Some(value) = opt_value {
                            let mut value_bin =
                                rustler::types::OwnedBinary::new(value.len()).unwrap();
                            value_bin.as_mut_slice().copy_from_slice(value.as_slice());
                            (field_bin.release(env), value_bin.release(env)).encode(env)
                        } else {
                            field_bin.release(env).encode(env)
                        }
                    } else {
                        field_bin.release(env).encode(env)
                    }
                })
                .collect();
            Ok((atoms::ok(), elems).encode(env))
        }
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

// Sorted set commands
fn handle_zscore<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 2 {
        return Err("ZSCORE requires exactly 2 arguments: key, member");
    }

    let (Ok(key), Ok(member)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
    ) else {
        return Err("ZSCORE key and member must be binaries");
    };

    match inner.zscore(db, key.as_slice(), member.as_slice()) {
        Ok(Some(score)) => Ok((atoms::ok(), score.into_inner()).encode(env)),
        Ok(None) => Ok((atoms::ok(), atoms::nil()).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_zcard<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 1 {
        return Err("ZCARD requires exactly 1 argument: key");
    }

    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("ZCARD key must be a binary");
    };

    match inner.zcard(db, key.as_slice()) {
        Ok(count) => Ok((atoms::ok(), count).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_zrange<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 4 {
        return Err("ZRANGE requires exactly 4 arguments: key, start, stop, with_scores");
    }

    let (Ok(key), Ok(start), Ok(stop), Ok(with_scores)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<i64>(),
        args[2].decode::<i64>(),
        args[3].decode::<bool>(),
    ) else {
        return Err("ZRANGE key must be a binary, start and stop must be integers, with_scores must be a boolean");
    };

    match inner.zrange(db, key.as_slice(), start, stop, with_scores) {
        Ok(members) => {
            let results: Vec<rustler::Term> = members
                .iter()
                .map(|(member, opt_score)| {
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
                })
                .collect();
            Ok((atoms::ok(), results).encode(env))
        }
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_zrangebyscore<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 4 {
        return Err("ZRANGEBYSCORE requires exactly 4 arguments: key, min, max, with_scores");
    }

    let (Ok(key), Ok(min), Ok(max), Ok(with_scores)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<f64>(),
        args[2].decode::<f64>(),
        args[3].decode::<bool>(),
    ) else {
        return Err("ZRANGEBYSCORE key must be a binary, min and max must be floats, with_scores must be a boolean");
    };

    match inner.zrangebyscore(
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
                })
                .collect();
            Ok((atoms::ok(), results).encode(env))
        }
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_zrank<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 2 {
        return Err("ZRANK requires exactly 2 arguments: key, member");
    }

    let (Ok(key), Ok(member)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
    ) else {
        return Err("ZRANK key and member must be binaries");
    };

    match inner.zrank(db, key.as_slice(), member.as_slice()) {
        Ok(Some(rank)) => Ok((atoms::ok(), rank).encode(env)),
        Ok(None) => Ok((atoms::ok(), atoms::nil()).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_zrevrank<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 2 {
        return Err("ZREVRANK requires exactly 2 arguments: key, member");
    }

    let (Ok(key), Ok(member)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<rustler::Binary>(),
    ) else {
        return Err("ZREVRANK key and member must be binaries");
    };

    match inner.zrevrank(db, key.as_slice(), member.as_slice()) {
        Ok(Some(rank)) => Ok((atoms::ok(), rank).encode(env)),
        Ok(None) => Ok((atoms::ok(), atoms::nil()).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_zcount<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 3 {
        return Err("ZCOUNT requires exactly 3 arguments: key, min, max");
    }

    let (Ok(key), Ok(min), Ok(max)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<f64>(),
        args[2].decode::<f64>(),
    ) else {
        return Err("ZCOUNT key must be a binary, min and max must be floats");
    };

    match inner.zcount(db, key.as_slice(), OrderedFloat(min), OrderedFloat(max)) {
        Ok(count) => Ok((atoms::ok(), count).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_zfirst<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 1 {
        return Err("ZFIRST requires exactly 1 argument: key");
    }

    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("ZFIRST key must be a binary");
    };

    match inner.zfirst(db, key.as_slice()) {
        Ok(Some((score, member))) => {
            let mut member_bin = rustler::types::OwnedBinary::new(member.len()).unwrap();
            member_bin.as_mut_slice().copy_from_slice(member.as_slice());
            Ok((atoms::ok(), (score.into_inner(), member_bin.release(env))).encode(env))
        }
        Ok(None) => Ok((atoms::ok(), atoms::nil()).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_zlast<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 1 {
        return Err("ZLAST requires exactly 1 argument: key");
    }

    let Ok(key) = args[0].decode::<rustler::Binary>() else {
        return Err("ZLAST key must be a binary");
    };

    match inner.zlast(db, key.as_slice()) {
        Ok(Some((score, member))) => {
            let mut member_bin = rustler::types::OwnedBinary::new(member.len()).unwrap();
            member_bin.as_mut_slice().copy_from_slice(member.as_slice());
            Ok((atoms::ok(), (score.into_inner(), member_bin.release(env))).encode(env))
        }
        Ok(None) => Ok((atoms::ok(), atoms::nil()).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_znext<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 3 {
        return Err("ZNEXT requires exactly 3 arguments: key, score, member");
    }

    let (Ok(key), Ok(score), Ok(member)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<f64>(),
        args[2].decode::<rustler::Binary>(),
    ) else {
        return Err("ZNEXT key and member must be binaries, score must be a float");
    };

    match inner.znext(db, key.as_slice(), OrderedFloat(score), member.as_slice()) {
        Ok(Some((new_score, new_member))) => {
            let mut member_bin = rustler::types::OwnedBinary::new(new_member.len()).unwrap();
            member_bin
                .as_mut_slice()
                .copy_from_slice(new_member.as_slice());
            Ok((
                atoms::ok(),
                (new_score.into_inner(), member_bin.release(env)),
            )
                .encode(env))
        }
        Ok(None) => Ok((atoms::ok(), atoms::nil()).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}

fn handle_zprev<'a>(
    env: rustler::Env<'a>,
    inner: &StorageInner,
    db: u64,
    args: &[rustler::Term<'a>],
) -> ReadResult<'a> {
    if args.len() != 3 {
        return Err("ZPREV requires exactly 3 arguments: key, score, member");
    }

    let (Ok(key), Ok(score), Ok(member)) = (
        args[0].decode::<rustler::Binary>(),
        args[1].decode::<f64>(),
        args[2].decode::<rustler::Binary>(),
    ) else {
        return Err("ZPREV key and member must be binaries, score must be a float");
    };

    match inner.zprev(db, key.as_slice(), OrderedFloat(score), member.as_slice()) {
        Ok(Some((new_score, new_member))) => {
            let mut member_bin = rustler::types::OwnedBinary::new(new_member.len()).unwrap();
            member_bin
                .as_mut_slice()
                .copy_from_slice(new_member.as_slice());
            Ok((
                atoms::ok(),
                (new_score.into_inner(), member_bin.release(env)),
            )
                .encode(env))
        }
        Ok(None) => Ok((atoms::ok(), atoms::nil()).encode(env)),
        Err(_) => Err("WRONGTYPE: Operation against a key holding the wrong kind of value"),
    }
}
