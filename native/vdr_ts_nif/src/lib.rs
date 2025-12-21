mod atoms;

use rustler::types::Binary;
use rustler::{Encoder, Env, Resource, ResourceArc, Term};
use std::collections::BTreeMap;
use std::panic::{RefUnwindSafe, UnwindSafe};
use std::sync::{Arc, Mutex};

/// Inner storage structure guarded by mutex
struct StorageInner {
    map: BTreeMap<Vec<u8>, Vec<u8>>,
}

/// The term storage resource exposed to Elixir
pub struct TStorage {
    data: Arc<Mutex<StorageInner>>,
}

// Safety: TStorage is explicitly designed for concurrent access via Mutex
unsafe impl Send for TStorage {}
unsafe impl Sync for TStorage {}
impl RefUnwindSafe for TStorage {}
impl UnwindSafe for TStorage {}

#[rustler::resource_impl(register = false)]
impl Resource for TStorage {}

#[rustler::nif(name = "create")]
fn create_storage() -> ResourceArc<TStorage> {
    ResourceArc::new(TStorage {
        data: Arc::new(Mutex::new(StorageInner {
            map: BTreeMap::new(),
        })),
    })
}

#[rustler::nif(name = "set")]
fn set_value<'a>(
    env: Env<'a>,
    storage: ResourceArc<TStorage>,
    key: Binary,
    value: Binary,
) -> Term<'a> {
    // Lock the storage to get mutable access
    let mut inner = match storage.data.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    // Insert the binary value into the map
    inner
        .map
        .insert(key.as_slice().to_vec(), value.as_slice().to_vec());

    // Return :ok
    atoms::ok().encode(env)
}

#[rustler::nif(name = "get")]
fn get_value<'a>(env: Env<'a>, storage: ResourceArc<TStorage>, key: Binary) -> Term<'a> {
    // Lock the storage
    let inner = match storage.data.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    // Look up the key
    match inner.map.get(key.as_slice()) {
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
fn delete_value<'a>(env: Env<'a>, storage: ResourceArc<TStorage>, key: Binary) -> Term<'a> {
    // Lock the storage
    let mut inner = match storage.data.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    // Remove the key (returns Option<Vec<u8>>, which we ignore)
    let _removed = inner.map.remove(key.as_slice());

    // Always return :ok
    atoms::ok().encode(env)
}

#[rustler::nif(name = "destroy")]
fn destroy_storage<'a>(env: Env<'a>, storage: ResourceArc<TStorage>) -> Term<'a> {
    // Lock the storage
    let mut inner = match storage.data.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };

    // Clear all entries from the map
    inner.map.clear();

    // Return :ok
    atoms::ok().encode(env)
}

rustler::init!("Elixir.Vdr.TS", load = load_nif);

fn load_nif(env: Env, _: Term) -> bool {
    env.register::<TStorage>().is_ok()
}
