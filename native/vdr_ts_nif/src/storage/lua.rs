use crate::storage::StorageInner;
use mlua::{Lua, Value as LuaValue};
use ordered_float::OrderedFloat;

/// Helper function to extract storage and db from Lua context
fn get_tx_ctx(lua_ctx: &mlua::Lua) -> mlua::Result<(&StorageInner, u64)> {
    let db: u64 = lua_ctx.globals().get("__db")?;
    let storage_ptr: mlua::LightUserData = lua_ctx.globals().get("__storage_ptr")?;
    // SAFETY: The pointer is valid for the duration of tx() call
    let storage = unsafe { &*(storage_ptr.0 as *const StorageInner) };
    Ok((storage, db))
}

/// Create and initialize a new Lua VM with all ts.* functions
pub fn new_lua() -> Lua {
    let lua = Lua::new();

    // Initialize globals once
    lua.globals()
        .set("__db", 0u64)
        .expect("Failed to set __db global");
    lua.globals()
        .set("__storage_ptr", mlua::LightUserData(std::ptr::null_mut()))
        .expect("Failed to set __storage_ptr");

    // Create ts.get function once
    let get_fn = lua
        .create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            let key_bytes = key.as_bytes();

            match storage.get(db, &key_bytes) {
                Ok(Some(value)) => {
                    let bytes = value.as_slice();
                    Ok(Some(lua_ctx.create_string(bytes)?))
                }
                Ok(None) => Ok(None),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create get function");

    // Create ts.hget function once
    let hget_fn = lua
        .create_function(|lua_ctx, (key, field): (mlua::String, mlua::String)| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            let key_bytes = key.as_bytes();
            let field_bytes = field.as_bytes();

            match storage.hget(db, &key_bytes, &field_bytes) {
                Ok(Some(value)) => {
                    let bytes = value.as_slice();
                    Ok(Some(lua_ctx.create_string(bytes)?))
                }
                Ok(None) => Ok(None),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create hget function");

    // List functions
    let llen_fn = lua
        .create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.llen(db, &key.as_bytes()) {
                Ok(len) => Ok(len as i64),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create llen");

    let lrange_fn = lua
        .create_function(|lua_ctx, (key, start, stop): (mlua::String, i64, i64)| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.lrange(db, &key.as_bytes(), start, stop) {
                Ok(elements) => {
                    let table = lua_ctx.create_table()?;
                    for (i, elem) in elements.iter().enumerate() {
                        table.set(i + 1, lua_ctx.create_string(elem.as_slice())?)?;
                    }
                    Ok(table)
                }
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create lrange");

    // Set functions
    let smembers_fn = lua
        .create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.smembers(db, &key.as_bytes()) {
                Ok(members) => {
                    let table = lua_ctx.create_table()?;
                    for (i, member) in members.iter().enumerate() {
                        table.set(i + 1, lua_ctx.create_string(member.as_slice())?)?;
                    }
                    Ok(table)
                }
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create smembers");

    let sismember_fn = lua
        .create_function(|lua_ctx, (key, member): (mlua::String, mlua::String)| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.sismember(db, &key.as_bytes(), &member.as_bytes()) {
                Ok(is_member) => Ok(is_member),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create sismember");

    let scard_fn = lua
        .create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.scard(db, &key.as_bytes()) {
                Ok(count) => Ok(count as i64),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create scard");

    let sfirst_fn = lua
        .create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.sfirst(db, &key.as_bytes()) {
                Ok(Some(member)) => Ok(Some(lua_ctx.create_string(member.as_slice())?)),
                Ok(None) => Ok(None),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create sfirst");

    let slast_fn = lua
        .create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.slast(db, &key.as_bytes()) {
                Ok(Some(member)) => Ok(Some(lua_ctx.create_string(member.as_slice())?)),
                Ok(None) => Ok(None),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create slast");

    let snext_fn = lua
        .create_function(|lua_ctx, (key, member): (mlua::String, mlua::String)| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.snext(db, &key.as_bytes(), &member.as_bytes()) {
                Ok(Some(next_member)) => Ok(Some(lua_ctx.create_string(next_member.as_slice())?)),
                Ok(None) => Ok(None),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create snext");

    let sprev_fn = lua
        .create_function(|lua_ctx, (key, member): (mlua::String, mlua::String)| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.sprev(db, &key.as_bytes(), &member.as_bytes()) {
                Ok(Some(prev_member)) => Ok(Some(lua_ctx.create_string(prev_member.as_slice())?)),
                Ok(None) => Ok(None),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create sprev");

    let smismember_fn = lua
        .create_function(|lua_ctx, (key, members): (mlua::String, mlua::Table)| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            let mut member_vec = Vec::new();
            for pair in members.pairs::<i64, mlua::String>() {
                let (_, member) = pair?;
                member_vec.push(member.as_bytes().to_vec());
            }
            let member_refs: Vec<&[u8]> = member_vec.iter().map(|v| v.as_slice()).collect();
            match storage.smismember(db, &key.as_bytes(), &member_refs) {
                Ok(results) => {
                    let table = lua_ctx.create_table()?;
                    for (i, result) in results.iter().enumerate() {
                        table.set(i + 1, *result)?;
                    }
                    Ok(table)
                }
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create smismember");

    let srandmember_fn = lua
        .create_function(|lua_ctx, (key, count): (mlua::String, i64)| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.srandmember(db, &key.as_bytes(), count) {
                Ok(members) => {
                    let table = lua_ctx.create_table()?;
                    for (i, member) in members.iter().enumerate() {
                        table.set(i + 1, lua_ctx.create_string(member.as_slice())?)?;
                    }
                    Ok(table)
                }
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create srandmember");

    let sunion_fn = lua
        .create_function(|lua_ctx, keys: mlua::Table| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            let mut key_vec = Vec::new();
            for pair in keys.pairs::<i64, mlua::String>() {
                let (_, key) = pair?;
                key_vec.push(key.as_bytes().to_vec());
            }
            let key_refs: Vec<&[u8]> = key_vec.iter().map(|v| v.as_slice()).collect();
            match storage.sunion(db, &key_refs) {
                Ok(members) => {
                    let table = lua_ctx.create_table()?;
                    for (i, member) in members.iter().enumerate() {
                        table.set(i + 1, lua_ctx.create_string(member.as_slice())?)?;
                    }
                    Ok(table)
                }
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create sunion");

    let sinter_fn = lua
        .create_function(|lua_ctx, keys: mlua::Table| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            let mut key_vec = Vec::new();
            for pair in keys.pairs::<i64, mlua::String>() {
                let (_, key) = pair?;
                key_vec.push(key.as_bytes().to_vec());
            }
            let key_refs: Vec<&[u8]> = key_vec.iter().map(|v| v.as_slice()).collect();
            match storage.sinter(db, &key_refs) {
                Ok(members) => {
                    let table = lua_ctx.create_table()?;
                    for (i, member) in members.iter().enumerate() {
                        table.set(i + 1, lua_ctx.create_string(member.as_slice())?)?;
                    }
                    Ok(table)
                }
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create sinter");

    let sdiff_fn = lua
        .create_function(|lua_ctx, keys: mlua::Table| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            let mut key_vec = Vec::new();
            for pair in keys.pairs::<i64, mlua::String>() {
                let (_, key) = pair?;
                key_vec.push(key.as_bytes().to_vec());
            }
            let key_refs: Vec<&[u8]> = key_vec.iter().map(|v| v.as_slice()).collect();
            match storage.sdiff(db, &key_refs) {
                Ok(members) => {
                    let table = lua_ctx.create_table()?;
                    for (i, member) in members.iter().enumerate() {
                        table.set(i + 1, lua_ctx.create_string(member.as_slice())?)?;
                    }
                    Ok(table)
                }
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create sdiff");

    let sintercard_fn = lua
        .create_function(|lua_ctx, keys: mlua::Table| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            let mut key_vec = Vec::new();
            for pair in keys.pairs::<i64, mlua::String>() {
                let (_, key) = pair?;
                key_vec.push(key.as_bytes().to_vec());
            }
            let key_refs: Vec<&[u8]> = key_vec.iter().map(|v| v.as_slice()).collect();
            match storage.sintercard(db, &key_refs) {
                Ok(count) => Ok(count as i64),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create sintercard");

    // Hash functions
    let hmget_fn = lua
        .create_function(|lua_ctx, (key, fields): (mlua::String, mlua::Table)| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            let mut field_vec = Vec::new();
            for pair in fields.pairs::<i64, mlua::String>() {
                let (_, field) = pair?;
                field_vec.push(field.as_bytes().to_vec());
            }
            let field_refs: Vec<&[u8]> = field_vec.iter().map(|v| v.as_slice()).collect();

            match storage.hmget(db, &key.as_bytes(), &field_refs) {
                Ok(values) => {
                    let table = lua_ctx.create_table()?;
                    for (i, value) in values.iter().enumerate() {
                        if let Some(v) = value {
                            table.set(i + 1, lua_ctx.create_string(v.as_slice())?)?;
                        } else {
                            table.set(i + 1, mlua::Value::Nil)?;
                        }
                    }
                    Ok(table)
                }
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create hmget");

    let hgetall_fn = lua
        .create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.hgetall(db, &key.as_bytes()) {
                Ok(pairs) => {
                    let table = lua_ctx.create_table()?;
                    for (field, value) in pairs {
                        table.set(
                            lua_ctx.create_string(field.as_slice())?,
                            lua_ctx.create_string(value.as_slice())?,
                        )?;
                    }
                    Ok(table)
                }
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create hgetall");

    let hkeys_fn = lua
        .create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.hkeys(db, &key.as_bytes()) {
                Ok(keys) => {
                    let table = lua_ctx.create_table()?;
                    for (i, k) in keys.iter().enumerate() {
                        table.set(i + 1, lua_ctx.create_string(k.as_slice())?)?;
                    }
                    Ok(table)
                }
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create hkeys");

    let hvals_fn = lua
        .create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.hvals(db, &key.as_bytes()) {
                Ok(values) => {
                    let table = lua_ctx.create_table()?;
                    for (i, v) in values.iter().enumerate() {
                        table.set(i + 1, lua_ctx.create_string(v.as_slice())?)?;
                    }
                    Ok(table)
                }
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create hvals");

    let hlen_fn = lua
        .create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.hlen(db, &key.as_bytes()) {
                Ok(len) => Ok(len as i64),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create hlen");

    let hexists_fn = lua
        .create_function(|lua_ctx, (key, field): (mlua::String, mlua::String)| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.hexists(db, &key.as_bytes(), &field.as_bytes()) {
                Ok(exists) => Ok(exists),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create hexists");

    let hfirst_fn = lua
        .create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.hfirst(db, &key.as_bytes()) {
                Ok(Some((field, value))) => Ok((
                    Some(lua_ctx.create_string(field.as_slice())?),
                    Some(lua_ctx.create_string(value.as_slice())?),
                )),
                Ok(None) => Ok((None::<mlua::String>, None::<mlua::String>)),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create hfirst");

    let hlast_fn = lua
        .create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.hlast(db, &key.as_bytes()) {
                Ok(Some((field, value))) => Ok((
                    Some(lua_ctx.create_string(field.as_slice())?),
                    Some(lua_ctx.create_string(value.as_slice())?),
                )),
                Ok(None) => Ok((None::<mlua::String>, None::<mlua::String>)),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create hlast");

    let hnext_fn = lua
        .create_function(|lua_ctx, (key, field): (mlua::String, mlua::String)| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.hnext(db, &key.as_bytes(), &field.as_bytes()) {
                Ok(Some((next_field, value))) => Ok((
                    Some(lua_ctx.create_string(next_field.as_slice())?),
                    Some(lua_ctx.create_string(value.as_slice())?),
                )),
                Ok(None) => Ok((None::<mlua::String>, None::<mlua::String>)),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create hnext");

    let hprev_fn = lua
        .create_function(|lua_ctx, (key, field): (mlua::String, mlua::String)| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.hprev(db, &key.as_bytes(), &field.as_bytes()) {
                Ok(Some((prev_field, value))) => Ok((
                    Some(lua_ctx.create_string(prev_field.as_slice())?),
                    Some(lua_ctx.create_string(value.as_slice())?),
                )),
                Ok(None) => Ok((None::<mlua::String>, None::<mlua::String>)),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create hprev");

    let hstrlen_fn = lua
        .create_function(|lua_ctx, (key, field): (mlua::String, mlua::String)| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.hstrlen(db, &key.as_bytes(), &field.as_bytes()) {
                Ok(len) => Ok(len as i64),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create hstrlen");

    let hrandfield_fn = lua
        .create_function(
            |lua_ctx, (key, count, with_values): (mlua::String, i64, bool)| {
                let (storage, db) = get_tx_ctx(lua_ctx)?;
                match storage.hrandfield(db, &key.as_bytes(), count, with_values) {
                    Ok(results) => {
                        let table = lua_ctx.create_table()?;
                        for (i, (field, opt_value)) in results.iter().enumerate() {
                            if with_values {
                                if let Some(value) = opt_value {
                                    let item = lua_ctx.create_table()?;
                                    item.set(1, lua_ctx.create_string(field.as_slice())?)?;
                                    item.set(2, lua_ctx.create_string(value.as_slice())?)?;
                                    table.set(i + 1, item)?;
                                } else {
                                    table.set(i + 1, lua_ctx.create_string(field.as_slice())?)?;
                                }
                            } else {
                                table.set(i + 1, lua_ctx.create_string(field.as_slice())?)?;
                            }
                        }
                        Ok(table)
                    }
                    Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
                }
            },
        )
        .expect("Failed to create hrandfield");

    // Sorted set functions
    let zscore_fn = lua
        .create_function(|lua_ctx, (key, member): (mlua::String, mlua::String)| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.zscore(db, &key.as_bytes(), &member.as_bytes()) {
                Ok(Some(score)) => Ok(Some(score.into_inner())),
                Ok(None) => Ok(None),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create zscore");

    let zcard_fn = lua
        .create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.zcard(db, &key.as_bytes()) {
                Ok(count) => Ok(count as i64),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create zcard");

    let zrange_fn = lua
        .create_function(|lua_ctx, (key, start, stop): (mlua::String, i64, i64)| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.zrange(db, &key.as_bytes(), start, stop, true) {
                Ok(results) => {
                    let table = lua_ctx.create_table()?;
                    for (i, (member, score_opt)) in results.iter().enumerate() {
                        let item = lua_ctx.create_table()?;
                        item.set(1, lua_ctx.create_string(member.as_slice())?)?;
                        if let Some(score) = score_opt {
                            item.set(2, score.into_inner())?;
                        }
                        table.set(i + 1, item)?;
                    }
                    Ok(table)
                }
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create zrange");

    let zrangebyscore_fn = lua
        .create_function(|lua_ctx, (key, min, max): (mlua::String, f64, f64)| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.zrangebyscore(
                db,
                &key.as_bytes(),
                OrderedFloat(min),
                OrderedFloat(max),
                true,
            ) {
                Ok(results) => {
                    let table = lua_ctx.create_table()?;
                    for (i, (member, score_opt)) in results.iter().enumerate() {
                        let item = lua_ctx.create_table()?;
                        item.set(1, lua_ctx.create_string(member.as_slice())?)?;
                        if let Some(score) = score_opt {
                            item.set(2, score.into_inner())?;
                        }
                        table.set(i + 1, item)?;
                    }
                    Ok(table)
                }
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create zrangebyscore");

    let zrank_fn = lua
        .create_function(|lua_ctx, (key, member): (mlua::String, mlua::String)| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.zrank(db, &key.as_bytes(), &member.as_bytes()) {
                Ok(Some(rank)) => Ok(Some(rank as i64)),
                Ok(None) => Ok(None),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create zrank");

    let zrevrank_fn = lua
        .create_function(|lua_ctx, (key, member): (mlua::String, mlua::String)| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.zrevrank(db, &key.as_bytes(), &member.as_bytes()) {
                Ok(Some(rank)) => Ok(Some(rank as i64)),
                Ok(None) => Ok(None),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create zrevrank");

    let zcount_fn = lua
        .create_function(|lua_ctx, (key, min, max): (mlua::String, f64, f64)| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.zcount(db, &key.as_bytes(), OrderedFloat(min), OrderedFloat(max)) {
                Ok(count) => Ok(count as i64),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create zcount");

    let zfirst_fn = lua
        .create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.zfirst(db, &key.as_bytes()) {
                Ok(Some((score, member))) => Ok((
                    Some(score.into_inner()),
                    Some(lua_ctx.create_string(member.as_slice())?),
                )),
                Ok(None) => Ok((None::<f64>, None::<mlua::String>)),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create zfirst");

    let zlast_fn = lua
        .create_function(|lua_ctx, key: mlua::String| {
            let (storage, db) = get_tx_ctx(lua_ctx)?;
            match storage.zlast(db, &key.as_bytes()) {
                Ok(Some((score, member))) => Ok((
                    Some(score.into_inner()),
                    Some(lua_ctx.create_string(member.as_slice())?),
                )),
                Ok(None) => Ok((None::<f64>, None::<mlua::String>)),
                Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
            }
        })
        .expect("Failed to create zlast");

    let znext_fn = lua
        .create_function(
            |lua_ctx, (key, score, member): (mlua::String, f64, mlua::String)| {
                let (storage, db) = get_tx_ctx(lua_ctx)?;
                match storage.znext(db, &key.as_bytes(), OrderedFloat(score), &member.as_bytes()) {
                    Ok(Some((next_score, next_member))) => Ok((
                        Some(next_score.into_inner()),
                        Some(lua_ctx.create_string(next_member.as_slice())?),
                    )),
                    Ok(None) => Ok((None::<f64>, None::<mlua::String>)),
                    Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
                }
            },
        )
        .expect("Failed to create znext");

    let zprev_fn = lua
        .create_function(
            |lua_ctx, (key, score, member): (mlua::String, f64, mlua::String)| {
                let (storage, db) = get_tx_ctx(lua_ctx)?;
                match storage.zprev(db, &key.as_bytes(), OrderedFloat(score), &member.as_bytes()) {
                    Ok(Some((prev_score, prev_member))) => Ok((
                        Some(prev_score.into_inner()),
                        Some(lua_ctx.create_string(prev_member.as_slice())?),
                    )),
                    Ok(None) => Ok((None::<f64>, None::<mlua::String>)),
                    Err(e) => Err(mlua::Error::RuntimeError(e.to_string())),
                }
            },
        )
        .expect("Failed to create zprev");

    // Create the ts table once with all functions
    let ts_table = lua.create_table().expect("Failed to create ts table");

    // String functions
    ts_table.set("get", get_fn).expect("Failed to set get");

    // List functions
    ts_table.set("llen", llen_fn).expect("Failed to set llen");
    ts_table
        .set("lrange", lrange_fn)
        .expect("Failed to set lrange");

    // Set functions
    ts_table
        .set("smembers", smembers_fn)
        .expect("Failed to set smembers");
    ts_table
        .set("sismember", sismember_fn)
        .expect("Failed to set sismember");
    ts_table
        .set("scard", scard_fn)
        .expect("Failed to set scard");
    ts_table
        .set("sfirst", sfirst_fn)
        .expect("Failed to set sfirst");
    ts_table
        .set("slast", slast_fn)
        .expect("Failed to set slast");
    ts_table
        .set("snext", snext_fn)
        .expect("Failed to set snext");
    ts_table
        .set("sprev", sprev_fn)
        .expect("Failed to set sprev");
    ts_table
        .set("smismember", smismember_fn)
        .expect("Failed to set smismember");
    ts_table
        .set("srandmember", srandmember_fn)
        .expect("Failed to set srandmember");
    ts_table
        .set("sunion", sunion_fn)
        .expect("Failed to set sunion");
    ts_table
        .set("sinter", sinter_fn)
        .expect("Failed to set sinter");
    ts_table
        .set("sdiff", sdiff_fn)
        .expect("Failed to set sdiff");
    ts_table
        .set("sintercard", sintercard_fn)
        .expect("Failed to set sintercard");

    // Hash functions
    ts_table.set("hget", hget_fn).expect("Failed to set hget");
    ts_table
        .set("hmget", hmget_fn)
        .expect("Failed to set hmget");
    ts_table
        .set("hgetall", hgetall_fn)
        .expect("Failed to set hgetall");
    ts_table
        .set("hkeys", hkeys_fn)
        .expect("Failed to set hkeys");
    ts_table
        .set("hvals", hvals_fn)
        .expect("Failed to set hvals");
    ts_table.set("hlen", hlen_fn).expect("Failed to set hlen");
    ts_table
        .set("hexists", hexists_fn)
        .expect("Failed to set hexists");
    ts_table
        .set("hfirst", hfirst_fn)
        .expect("Failed to set hfirst");
    ts_table
        .set("hlast", hlast_fn)
        .expect("Failed to set hlast");
    ts_table
        .set("hnext", hnext_fn)
        .expect("Failed to set hnext");
    ts_table
        .set("hprev", hprev_fn)
        .expect("Failed to set hprev");
    ts_table
        .set("hstrlen", hstrlen_fn)
        .expect("Failed to set hstrlen");
    ts_table
        .set("hrandfield", hrandfield_fn)
        .expect("Failed to set hrandfield");

    // Sorted set functions
    ts_table
        .set("zscore", zscore_fn)
        .expect("Failed to set zscore");
    ts_table
        .set("zcard", zcard_fn)
        .expect("Failed to set zcard");
    ts_table
        .set("zrange", zrange_fn)
        .expect("Failed to set zrange");
    ts_table
        .set("zrangebyscore", zrangebyscore_fn)
        .expect("Failed to set zrangebyscore");
    ts_table
        .set("zrank", zrank_fn)
        .expect("Failed to set zrank");
    ts_table
        .set("zrevrank", zrevrank_fn)
        .expect("Failed to set zrevrank");
    ts_table
        .set("zcount", zcount_fn)
        .expect("Failed to set zcount");
    ts_table
        .set("zfirst", zfirst_fn)
        .expect("Failed to set zfirst");
    ts_table
        .set("zlast", zlast_fn)
        .expect("Failed to set zlast");
    ts_table
        .set("znext", znext_fn)
        .expect("Failed to set znext");
    ts_table
        .set("zprev", zprev_fn)
        .expect("Failed to set zprev");

    lua.globals()
        .set("ts", ts_table)
        .expect("Failed to set ts global");

    lua
}

impl StorageInner {
    /// Compile a Lua script to bytecode for later execution
    ///
    /// The script has access to all ts.* functions for read-only operations.
    /// Returns bytecode that can be passed to tx() for execution.
    pub fn lua_load(&self, script: &[u8]) -> Result<Vec<u8>, String> {
        // Compile the script to bytecode
        let func = self
            .lua
            .load(script)
            .into_function()
            .map_err(|e| e.to_string())?;
        Ok(func.dump(false))
    }

    /// Execute a Lua script or bytecode with access to storage
    ///
    /// Sets up the Lua context with:
    /// - __db: The database number
    /// - __storage_ptr: Pointer to this StorageInner instance
    /// - ts.*: All read-only storage functions
    ///
    /// The script/bytecode is executed atomically and can access storage via ts.* functions.
    pub fn tx(&self, db: u64, script_or_bytecode: &[u8]) -> Result<LuaValue, String> {
        // Set the current database and storage pointer in global variables
        self.lua
            .globals()
            .set("__db", db)
            .map_err(|e| e.to_string())?;
        self.lua
            .globals()
            .set(
                "__storage_ptr",
                mlua::LightUserData(self as *const _ as *mut _),
            )
            .map_err(|e| e.to_string())?;

        // Execute the script or bytecode (mlua's load() handles both)
        let result: LuaValue = self
            .lua
            .load(script_or_bytecode)
            .eval()
            .map_err(|e| e.to_string())?;

        // Clear the storage pointer for safety
        self.lua
            .globals()
            .set("__storage_ptr", mlua::LightUserData(std::ptr::null_mut()))
            .map_err(|e| e.to_string())?;

        Ok(result)
    }
}
