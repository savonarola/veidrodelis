use rustler::{Atom, Binary, Env, NewBinary, OwnedBinary};

use crate::atoms;

// External C functions from LZF library
extern "C" {
    fn lzf_compress(
        in_data: *const u8,
        in_len: libc::c_uint,
        out_data: *mut u8,
        out_len: libc::c_uint,
    ) -> libc::c_uint;

    fn lzf_decompress(
        in_data: *const u8,
        in_len: libc::c_uint,
        out_data: *mut u8,
        out_len: libc::c_uint,
    ) -> libc::c_uint;
}

#[rustler::nif]
pub fn compress<'a>(env: Env<'a>, data: Binary) -> Result<Binary<'a>, (Atom, Atom)> {
    let input_len = data.len();

    // LZF worst case: input size + input size / 32 + 1
    // We'll be more generous and use input size * 1.05 + 16
    let max_compressed_size = input_len + (input_len / 20) + 16;

    let mut output = match OwnedBinary::new(max_compressed_size) {
        Some(bin) => bin,
        None => return Err((atoms::error(), atoms::allocation_failed())),
    };

    let result = unsafe {
        lzf_compress(
            data.as_ptr(),
            input_len as libc::c_uint,
            output.as_mut_ptr(),
            max_compressed_size as libc::c_uint,
        )
    };

    if result == 0 {
        return Err((atoms::error(), atoms::compression_failed()));
    }

    // Resize to actual compressed size
    if !output.realloc(result as usize) {
        return Err((atoms::error(), atoms::allocation_failed()));
    }

    Ok(Binary::from_owned(output, env))
}

#[rustler::nif]
pub fn decompress<'a>(env: Env<'a>, compressed_data: Binary, uncompressed_size: usize) -> Result<Binary<'a>, (Atom, Atom)> {
    let mut output = NewBinary::new(env, uncompressed_size);

    let result = unsafe {
        lzf_decompress(
            compressed_data.as_ptr(),
            compressed_data.len() as libc::c_uint,
            output.as_mut_slice().as_mut_ptr(),
            uncompressed_size as libc::c_uint,
        )
    };

    if result == 0 {
        return Err((atoms::error(), atoms::decompression_failed()));
    }

    if result as usize != uncompressed_size {
        return Err((atoms::error(), atoms::size_mismatch()));
    }

    Ok(output.into())
}
