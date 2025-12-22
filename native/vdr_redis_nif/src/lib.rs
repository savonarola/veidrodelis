mod atoms;
pub mod rdb;
pub mod replica;

// Register as Vdr.RedisStream.Nif
rustler::init!("Elixir.Vdr.RedisStream.Nif", load = load_nif);

fn load_nif(env: rustler::Env, _: rustler::Term) -> bool {
    // Initialize logger (reads RUST_LOG environment variable)
    // This will only initialize once, subsequent calls are no-ops
    let _ = env_logger::try_init();

    rdb::load(env) && replica::load(env)
}
