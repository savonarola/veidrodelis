mod atoms;
pub mod lzf;
pub mod rdb;

// Register as Vdr.RedisParser
rustler::init!("Elixir.Vdr.RedisParser", load = load_nif);

fn load_nif(env: rustler::Env, _: rustler::Term) -> bool {
    rdb::load(env);
    true
}
