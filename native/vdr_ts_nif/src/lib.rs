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
        Some(value) => {
            // Return the binary value
            let mut binary = rustler::types::OwnedBinary::new(value.len()).unwrap();
            binary.as_mut_slice().copy_from_slice(value);
            binary.release(env).encode(env)
        }
        None => {
            // Return nil for missing keys
            atoms::nil().encode(env)
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

rustler::init!("Elixir.Vdr.TS", load = load_nif);

fn load_nif(env: Env, _: Term) -> bool {
    env.register::<TStorage>().is_ok()
}
