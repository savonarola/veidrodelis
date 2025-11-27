#include <erl_nif.h>
#include <string.h>
#include "lzf.h"

static ERL_NIF_TERM
compress_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary uncompressed;
    ErlNifBinary compressed;
    size_t result;
    size_t max_compressed_size;

    if (argc != 1) {
        return enif_make_badarg(env);
    }

    if (!enif_inspect_binary(env, argv[0], &uncompressed)) {
        return enif_make_badarg(env);
    }

    /* LZF worst case: input size + input size / 32 + 1 
     * But we'll be more generous and use input size * 1.05 + 16 */
    max_compressed_size = uncompressed.size + (uncompressed.size / 20) + 16;
    
    if (!enif_alloc_binary(max_compressed_size, &compressed)) {
        return enif_make_atom(env, "allocation_failed");
    }

    result = lzf_compress(uncompressed.data, uncompressed.size,
                         compressed.data, compressed.size);

    if (result == 0) {
        enif_release_binary(&compressed);
        return enif_make_tuple2(env,
                               enif_make_atom(env, "error"),
                               enif_make_atom(env, "compression_failed"));
    }

    /* Resize binary to actual compressed size */
    if (!enif_realloc_binary(&compressed, result)) {
        enif_release_binary(&compressed);
        return enif_make_tuple2(env,
                               enif_make_atom(env, "error"),
                               enif_make_atom(env, "realloc_failed"));
    }

    return enif_make_tuple2(env,
                           enif_make_atom(env, "ok"),
                           enif_make_binary(env, &compressed));
}

static ERL_NIF_TERM
decompress_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary compressed;
    ErlNifBinary decompressed;
    unsigned long uncompressed_len;
    size_t result;

    if (argc != 2) {
        return enif_make_badarg(env);
    }

    if (!enif_inspect_binary(env, argv[0], &compressed)) {
        return enif_make_badarg(env);
    }

    if (!enif_get_ulong(env, argv[1], &uncompressed_len)) {
        return enif_make_badarg(env);
    }

    if (!enif_alloc_binary(uncompressed_len, &decompressed)) {
        return enif_make_atom(env, "allocation_failed");
    }

    result = lzf_decompress(compressed.data, compressed.size,
                           decompressed.data, decompressed.size);

    if (result == 0) {
        enif_release_binary(&decompressed);
        return enif_make_tuple2(env,
                               enif_make_atom(env, "error"),
                               enif_make_atom(env, "decompression_failed"));
    }

    if (result != uncompressed_len) {
        enif_release_binary(&decompressed);
        return enif_make_tuple2(env,
                               enif_make_atom(env, "error"),
                               enif_make_atom(env, "size_mismatch"));
    }

    return enif_make_tuple2(env,
                           enif_make_atom(env, "ok"),
                           enif_make_binary(env, &decompressed));
}

static ErlNifFunc nif_funcs[] = {
    {"compress", 1, compress_nif},
    {"decompress", 2, decompress_nif}
};

ERL_NIF_INIT(Elixir.Veidrodelis.LZF, nif_funcs, NULL, NULL, NULL, NULL)

