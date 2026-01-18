use rustler::{Binary, Encoder, Env, LocalPid, NewBinary, Resource, ResourceArc, Term};
use bytes::{Buf, BufMut, BytesMut};
use std::cell::RefCell;
use std::panic::{RefUnwindSafe, UnwindSafe};

use crate::atoms;

// RDB Opcodes
const RDB_OPCODE_AUX: u8 = 250;
const RDB_OPCODE_RESIZEDB: u8 = 251;
const RDB_OPCODE_EXPIRETIME_MS: u8 = 252;
const RDB_OPCODE_EXPIRETIME: u8 = 253;
const RDB_OPCODE_SELECTDB: u8 = 254;
const RDB_OPCODE_EOF: u8 = 255;

// RDB Value Types
const RDB_TYPE_STRING: u8 = 0;
const RDB_TYPE_LIST: u8 = 1;
const RDB_TYPE_SET: u8 = 2;
const RDB_TYPE_ZSET: u8 = 3;
const RDB_TYPE_HASH: u8 = 4;
const RDB_TYPE_ZSET_2: u8 = 5;
const RDB_TYPE_SET_INTSET: u8 = 11;
const RDB_TYPE_ZSET_ZIPLIST: u8 = 12;
const RDB_TYPE_HASH_ZIPLIST: u8 = 13;
const RDB_TYPE_LIST_QUICKLIST: u8 = 14;
const RDB_TYPE_HASH_LISTPACK: u8 = 16;
const RDB_TYPE_ZSET_LISTPACK: u8 = 17;
const RDB_TYPE_LIST_QUICKLIST_2: u8 = 18;
const RDB_TYPE_SET_LISTPACK: u8 = 20;
const RDB_TYPE_HASH_METADATA: u8 = 21;     // Redis/Valkey 9.0+ hash with per-field TTLs (with min_expire prefix)
const RDB_TYPE_HASH_LISTPACK_EX: u8 = 22;  // Valkey 9.0+ hash listpack with per-field TTLs
const RDB_TYPE_HASH_METADATA_PRE_GA: u8 = 200; // Pre-GA hash with per-field TTLs (no min_expire prefix)

// Encoding types
const RDB_ENC_INT8: u8 = 0;
const RDB_ENC_INT16: u8 = 1;
const RDB_ENC_INT32: u8 = 2;
const RDB_ENC_LZF: u8 = 3;

/// Represents a raw Redis command as parsed from RDB
/// Will be converted to Vdr.Command structs in Elixir
#[derive(Debug, Clone)]
pub(crate) struct RawCommand {
    pub(crate) db: u32,           // Database number
    pub(crate) name: Vec<u8>,     // Command name like "SET", "RPUSH", etc.
    pub(crate) args: Vec<Vec<u8>>, // Command arguments
}

impl RawCommand {
    fn with_args(db: u32, name: &[u8], args: Vec<Vec<u8>>) -> Self {
        RawCommand {
            db,
            name: name.to_vec(),
            args,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum ParseState {
    Magic(usize),    // Reading magic + version (9 bytes total)
    Opcode,
    ProcessingOpcode(u8),
    ProcessingKey(u8),
    ProcessingValue(u8, usize), // type, key_offset in saved_key
    WaitingChecksum, // Encountered EOF, waiting for 8-byte checksum
    Finished,
}

struct ParserState {
    buffer: BytesMut,
    parse_state: ParseState,
    current_db: u32,
    expire_ms: Option<u64>,
    finished: bool,
    saved_key: Vec<u8>, // Temporary storage for key when parsing value
}

pub struct RDBParser {
    pid: LocalPid,
    state: RefCell<ParserState>,
}

// SAFETY: RDBParser is only accessed by a single Erlang process (checked via pid)
// and will never be used concurrently, so it's safe to implement Send and Sync
unsafe impl Send for RDBParser {}
unsafe impl Sync for RDBParser {}
impl RefUnwindSafe for RDBParser {}
impl UnwindSafe for RDBParser {}

#[rustler::resource_impl(register = false)]
impl Resource for RDBParser {}

impl RDBParser {
    pub(crate) fn new(pid: LocalPid) -> Self {
        RDBParser {
            pid,
            state: RefCell::new(ParserState {
                buffer: BytesMut::new(),
                parse_state: ParseState::Magic(0),
                current_db: 0,
                expire_ms: None,
                finished: false,
                saved_key: Vec::new(),
            }),
        }
    }

    pub(crate) fn feed_data(&self, data: &[u8]) -> Result<Vec<RawCommand>, String> {
        let mut state = self.state.borrow_mut();

        if state.finished {
            return Err("already_finished".to_string());
        }

        // Append data to buffer
        state.buffer.put_slice(data);

        // Parse and collect commands
        let mut commands = Vec::new();

        log::debug!("feed_data, state: {:?}, passed bytes: {:?}", state.parse_state, data.len());

        loop {
            match state.parse_next()? {
                Some(mut cmds) => {
                    log::debug!("parse_next is some, state: {:?}, cmds: {:?}", state.parse_state, cmds);
                    commands.append(&mut cmds);
                }
                None => {
                    log::trace!("parse_next is none, state: {:?}", state.parse_state);
                    break;
                }
            }
        }

        log::debug!("feed_data, buf size: {:?}", state.buffer.len());

        Ok(commands)
    }
}

impl ParserState {
    fn buffer_advance(&mut self, bytes: usize) {
        self.buffer.advance(bytes);
    }

    fn parse_next(&mut self) -> Result<Option<Vec<RawCommand>>, String> {
        match self.parse_state {
            ParseState::Magic(pos) => self.parse_magic(pos),
            ParseState::Opcode => self.parse_opcode(),
            ParseState::ProcessingOpcode(opcode) => self.process_opcode(opcode),
            ParseState::ProcessingKey(value_type) => self.process_key(value_type),
            ParseState::ProcessingValue(value_type, key_len) => {
                self.parse_value(value_type, key_len)
            }
            ParseState::WaitingChecksum => self.parse_checksum(),
            ParseState::Finished => Ok(None),
        }
    }

    fn parse_magic(&mut self, pos: usize) -> Result<Option<Vec<RawCommand>>, String> {
        let needed = 9 - pos;
        if self.buffer.len() < needed {
            return Ok(None); // Need more data
        }

        let magic_version = &self.buffer[0..9];

        // Check magic: "REDIS" (5 chars + 4-digit version) or "VALKEY" (6 chars + 3-digit version)
        // Both formats are 9 bytes total
        if &magic_version[0..5] == b"REDIS" {
            // Redis format: REDIS0001-0012
            let version_str = std::str::from_utf8(&magic_version[5..9])
                .map_err(|_| "invalid_version")?;
            let version: u32 = version_str.parse()
                .map_err(|_| "invalid_version")?;

            if !(1..=12).contains(&version) {
                return Err("unsupported_version".to_string());
            }
        } else if &magic_version[0..6] == b"VALKEY" {
            // Valkey format: VALKEY080, etc (3-digit version)
            let version_str = std::str::from_utf8(&magic_version[6..9])
                .map_err(|_| "invalid_version")?;
            let version: u32 = version_str.parse()
                .map_err(|_| "invalid_version")?;

            // Valkey versions start at 080 (forked from Redis 7.2)
            if !(80..=999).contains(&version) {
                return Err("unsupported_version".to_string());
            }
        } else {
            return Err("invalid_magic".to_string());
        }

        self.buffer.advance(9);
        log::debug!("parsed_magic, got to opcode");
        self.parse_state = ParseState::Opcode;

        // Continue parsing
        self.parse_next()
    }

    fn parse_checksum(&mut self) -> Result<Option<Vec<RawCommand>>, String> {
        // After EOF, there must be an 8-byte CRC64 checksum
        if self.buffer.len() < 8 {
            // Need more data for checksum
            return Ok(None);
        }

        // Consume the checksum (we don't verify it currently)
        self.buffer_advance(8);
        self.finished = true;
        self.parse_state = ParseState::Finished;
        Ok(None)
    }

    fn parse_opcode(&mut self) -> Result<Option<Vec<RawCommand>>, String> {
        if self.buffer.is_empty() {
            log::trace!("parse_opcode, buffer is empty");
            return Ok(None); // Need more data
        }

        let opcode = self.buffer[0];
        log::debug!("parse_opcode, opcode: {:?}", opcode);
        self.buffer_advance(1);

        match opcode {
            RDB_OPCODE_EOF => {
                // After EOF, there's an 8-byte CRC64 checksum
                self.parse_state = ParseState::WaitingChecksum;
                self.parse_next()
            }
            RDB_OPCODE_SELECTDB | RDB_OPCODE_RESIZEDB |
            RDB_OPCODE_AUX | RDB_OPCODE_EXPIRETIME | RDB_OPCODE_EXPIRETIME_MS => {
                self.parse_state = ParseState::ProcessingOpcode(opcode);
                self.parse_next()
            }
            value_type => {
                // This is a value type, read the key
                self.parse_state = ParseState::ProcessingKey(value_type);
                self.parse_next()
            }
        }
    }

    fn process_key(&mut self, value_type: u8) -> Result<Option<Vec<RawCommand>>, String> {
        match self.load_string()? {
            Some(key) => {
                self.saved_key = key;
                let key_len = self.saved_key.len();
                self.parse_state = ParseState::ProcessingValue(value_type, key_len);
                self.parse_next()
            }
            None => {
                Ok(None)
            }
        }
    }

    fn process_opcode(&mut self, opcode: u8) -> Result<Option<Vec<RawCommand>>, String> {
        match opcode {
            RDB_OPCODE_SELECTDB => {
                match self.load_length()? {
                    Some(db_num) => {
                        self.current_db = db_num as u32;
                        self.parse_state = ParseState::Opcode;
                        self.parse_next()
                    }
                    None => Ok(None),
                }
            }
            RDB_OPCODE_RESIZEDB => {
                // Peek at both lengths to ensure we have all data
                let (_db_size, db_bytes) = match self.peek_length_at(0)? {
                    Some(v) => v,
                    None => return Ok(None),
                };
                let (_exp_size, _exp_bytes) = match self.peek_length_at(db_bytes)? {
                    Some(v) => v,
                    None => return Ok(None),
                };

                // Now consume both lengths
                let _ = self.load_length()?;
                let _ = self.load_length()?;
                self.parse_state = ParseState::Opcode;
                self.parse_next()
            }
            RDB_OPCODE_AUX => {
                // Peek at both strings to ensure we have all data
                let key_size = match self.calculate_string_size(0)? {
                    Some(s) => s,
                    None => return Ok(None),
                };
                let val_size = match self.calculate_string_size(key_size)? {
                    Some(s) => s,
                    None => return Ok(None),
                };
                // println!("process_opcode, RDB_OPCODE_AUX, enough data, key_size: {:?}, val_size: {:?}", key_size, val_size);
                if self.buffer.len() < key_size + val_size {
                    return Ok(None);
                }

                // Now consume both strings
                let _ = self.load_string()?;
                let _ = self.load_string()?;
                self.parse_state = ParseState::Opcode;
                self.parse_next()
            }
            RDB_OPCODE_EXPIRETIME => {
                if self.buffer.len() < 4 {
                    return Ok(None);
                }
                let expire_sec = self.buffer.get_u32_le();
                self.expire_ms = Some(expire_sec as u64 * 1000);
                self.parse_state = ParseState::Opcode;
                self.parse_next()
            }
            RDB_OPCODE_EXPIRETIME_MS => {
                if self.buffer.len() < 8 {
                    return Ok(None);
                }
                let expire_ms = self.buffer.get_u64_le();
                self.expire_ms = Some(expire_ms);
                self.parse_state = ParseState::Opcode;
                self.parse_next()
            }
            _ => Err("unknown_opcode".to_string()),
        }
    }

    fn parse_value(&mut self, value_type: u8, _key_len: usize) -> Result<Option<Vec<RawCommand>>, String> {
        // Calculate how much data we need for this entire value
        // If we don't have it all, wait for more data to avoid partial consumption
        match self.calculate_value_size(value_type, 0)? {
            Some(total_size) => {
                if self.buffer.len() < total_size {
                    return Ok(None);  // Wait for complete value data
                }
                // We have all the data, proceed with parsing
            }
            None => return Ok(None),  // Not enough data to even determine size
        }

        let key = self.saved_key.clone();
        match self.load_object(value_type, &key)? {
            Some(mut commands) => {
                // Add expire command if needed
                if let Some(expire_ms) = self.expire_ms {
                    let expire_cmd = RawCommand::with_args(
                        self.current_db,
                        b"PEXPIREAT",
                        vec![key.clone(), expire_ms.to_string().into_bytes()],
                    );
                    commands.push(expire_cmd);
                }

                self.expire_ms = None;
                self.saved_key.clear();
                self.parse_state = ParseState::Opcode;
                Ok(Some(commands))
            }
            None => Ok(None),
        }
    }

    // Calculate the total size needed for a value (including all nested data)
    // Returns None if we don't have enough data to determine the size
    fn calculate_value_size(&self, value_type: u8, offset: usize) -> Result<Option<usize>, String> {
        match value_type {
            RDB_TYPE_STRING => {
                // Just need the string data
                self.calculate_string_size(offset)
            }
            RDB_TYPE_LIST | RDB_TYPE_SET => {
                // Length + N strings
                let (count, len_bytes) = match self.peek_length_at(offset)? {
                    Some(v) => v,
                    None => return Ok(None),
                };
                let mut total = len_bytes;
                let mut current_offset = offset + len_bytes;

                for _ in 0..count {
                    match self.calculate_string_size(current_offset)? {
                        Some(size) => {
                            total += size;
                            current_offset += size;
                        }
                        None => return Ok(None),
                    }
                }
                Ok(Some(total))
            }
            RDB_TYPE_ZSET => {
                // Length + N * (string + double)
                let (count, len_bytes) = match self.peek_length_at(offset)? {
                    Some(v) => v,
                    None => return Ok(None),
                };
                let mut total = len_bytes;
                let mut current_offset = offset + len_bytes;

                for _ in 0..count {
                    // Member string
                    match self.calculate_string_size(current_offset)? {
                        Some(size) => {
                            total += size;
                            current_offset += size;
                        }
                        None => return Ok(None),
                    }
                    // Score (old format: 1 byte len + data)
                    if current_offset >= self.buffer.len() {
                        return Ok(None);
                    }
                    let score_len = self.buffer[current_offset] as usize;
                    total += 1 + score_len;
                    current_offset += 1 + score_len;
                }
                Ok(Some(total))
            }
            RDB_TYPE_ZSET_2 => {
                // Length + N * (string + 8 bytes for double)
                let (count, len_bytes) = match self.peek_length_at(offset)? {
                    Some(v) => v,
                    None => return Ok(None),
                };
                let mut total = len_bytes;
                let mut current_offset = offset + len_bytes;

                for _ in 0..count {
                    match self.calculate_string_size(current_offset)? {
                        Some(size) => {
                            total += size;
                            current_offset += size;
                        }
                        None => return Ok(None),
                    }
                    total += 8;  // 8 bytes for f64
                    current_offset += 8;
                }
                Ok(Some(total))
            }
            RDB_TYPE_HASH => {
                // Length + N * (field string + value string)
                let (count, len_bytes) = match self.peek_length_at(offset)? {
                    Some(v) => v,
                    None => return Ok(None),
                };
                let mut total = len_bytes;
                let mut current_offset = offset + len_bytes;

                for _ in 0..count {
                    // Field
                    match self.calculate_string_size(current_offset)? {
                        Some(size) => {
                            total += size;
                            current_offset += size;
                        }
                        None => return Ok(None),
                    }
                    // Value
                    match self.calculate_string_size(current_offset)? {
                        Some(size) => {
                            total += size;
                            current_offset += size;
                        }
                        None => return Ok(None),
                    }
                }
                Ok(Some(total))
            }
            // For encoded types (ziplist, listpack, etc.), the data is in a single string
            RDB_TYPE_LIST_QUICKLIST | RDB_TYPE_LIST_QUICKLIST_2 => {
                // Length + N strings (each string is a listpack/ziplist)
                let (count, len_bytes) = match self.peek_length_at(offset)? {
                    Some(v) => v,
                    None => return Ok(None),
                };
                let mut total = len_bytes;
                let mut current_offset = offset + len_bytes;

                for i in 0..count {
                    // For quicklist_2, there's a 1-byte container type before each string
                    if value_type == RDB_TYPE_LIST_QUICKLIST_2 {
                        if i == 0 || current_offset < self.buffer.len() {
                            total += 1;
                            current_offset += 1;
                        } else {
                            return Ok(None);
                        }
                    }

                    match self.calculate_string_size(current_offset)? {
                        Some(size) => {
                            total += size;
                            current_offset += size;
                        }
                        None => return Ok(None),
                    }
                }
                Ok(Some(total))
            }
            RDB_TYPE_HASH_ZIPLIST | RDB_TYPE_HASH_LISTPACK |
            RDB_TYPE_SET_INTSET | RDB_TYPE_SET_LISTPACK |
            RDB_TYPE_ZSET_ZIPLIST | RDB_TYPE_ZSET_LISTPACK |
            RDB_TYPE_HASH_METADATA_PRE_GA => {
                // These are all stored as a single string
                self.calculate_string_size(offset)
            }
            RDB_TYPE_HASH_METADATA => {
                // Length-encoded min_expire + length-encoded count + (field + value + length-encoded TTL) * count
                let (_min_expire, min_expire_bytes) = match self.peek_length_at(offset)? {
                    Some(v) => v,
                    None => return Ok(None),
                };
                let (count, count_bytes) = match self.peek_length_at(offset + min_expire_bytes)? {
                    Some(v) => v,
                    None => return Ok(None),
                };
                let mut total = min_expire_bytes + count_bytes;
                let mut current_offset = offset + total;
                for _ in 0..count {
                    // Field
                    match self.calculate_string_size(current_offset)? {
                        Some(size) => { total += size; current_offset += size; }
                        None => return Ok(None),
                    }
                    // Value
                    match self.calculate_string_size(current_offset)? {
                        Some(size) => { total += size; current_offset += size; }
                        None => return Ok(None),
                    }
                    // Length-encoded TTL
                    let (_, ttl_bytes) = match self.peek_length_at(current_offset)? {
                        Some(v) => v,
                        None => return Ok(None),
                    };
                    total += ttl_bytes;
                    current_offset += ttl_bytes;
                }
                Ok(Some(total))
            }
            RDB_TYPE_HASH_LISTPACK_EX => {
                // Length-encoded count + (field + value + 8-byte expiry) * count
                let (count, len_bytes) = match self.peek_length_at(offset)? {
                    Some(v) => v,
                    None => return Ok(None),
                };
                let mut total = len_bytes;
                let mut current_offset = offset + len_bytes;
                for _ in 0..count {
                    // Field
                    match self.calculate_string_size(current_offset)? {
                        Some(size) => { total += size; current_offset += size; }
                        None => return Ok(None),
                    }
                    // Value
                    match self.calculate_string_size(current_offset)? {
                        Some(size) => { total += size; current_offset += size; }
                        None => return Ok(None),
                    }
                    // 8-byte expiry
                    total += 8;
                    current_offset += 8;
                }
                Ok(Some(total))
            }
            _ => {
                // Unknown type - try to skip as a string
                self.calculate_string_size(offset)
            }
        }
    }

    // Calculate size needed for a string at given offset
    fn calculate_string_size(&self, offset: usize) -> Result<Option<usize>, String> {
        if offset >= self.buffer.len() {
            return Ok(None);
        }

        let first = self.buffer[offset];
        let enc_type = (first & 0xC0) >> 6;

        if enc_type == 3 {
            // Special encoding
            let enc_subtype = first & 0x3F;
            let size = match enc_subtype {
                0 => 2,  // INT8
                1 => 3,  // INT16
                2 => 5,  // INT32
                3 => {   // LZF
                    let (clen, clen_bytes) = match self.peek_length_at(offset + 1)? {
                        Some(v) => v,
                        None => return Ok(None),
                    };
                    let (_ulen, ulen_bytes) = match self.peek_length_at(offset + 1 + clen_bytes)? {
                        Some(v) => v,
                        None => return Ok(None),
                    };
                    1 + clen_bytes + ulen_bytes + clen as usize
                }
                _ => return Err(format!("unknown_encoding: 0x{:02X}", first)),
            };
            Ok(Some(size))
        } else {
            // Regular string
            let (str_len, len_bytes) = match self.peek_length_at(offset)? {
                Some(v) => v,
                None => return Ok(None),
            };
            Ok(Some(len_bytes + str_len as usize))
        }
    }

    fn load_length(&mut self) -> Result<Option<u64>, String> {
        // Use peek to check if we have enough data before consuming
        match self.peek_length_at(0)? {
            Some((length, bytes_used)) => {
                // We have enough data, now consume it
                self.buffer_advance(bytes_used);
                Ok(Some(length))
            }
            None => Ok(None),
        }
    }

    fn load_string(&mut self) -> Result<Option<Vec<u8>>, String> {
        if self.buffer.is_empty() {
            return Ok(None);
        }

        let first = self.buffer[0];
        let enc_type = (first & 0xC0) >> 6;

        if enc_type == 3 {
            // Special encoding
            let enc_subtype = first & 0x3F;

            match enc_subtype {
                RDB_ENC_INT8 => {
                    if self.buffer.len() < 2 {
                        log::trace!("load_string, RDB_ENC_INT8, not enough data, state: {:?}", self.parse_state);
                        return Ok(None);
                    }
                    self.buffer_advance(1);
                    let val = self.buffer.get_i8();
                    log::debug!("load_string, RDB_ENC_INT8, value: {}", val.to_string());
                    Ok(Some(val.to_string().into_bytes()))
                }
                RDB_ENC_INT16 => {
                    log::debug!("load_string, RDB_ENC_INT16");
                    if self.buffer.len() < 3 {
                        log::trace!("load_string, RDB_ENC_INT16, not enough data");
                        return Ok(None);
                    }
                    self.buffer_advance(1);
                    let val = self.buffer.get_i16_le();
                    log::debug!("load_string, RDB_ENC_INT16, value: {}", val.to_string());
                    Ok(Some(val.to_string().into_bytes()))
                }
                RDB_ENC_INT32 => {
                    log::debug!("load_string, RDB_ENC_INT32");
                    if self.buffer.len() < 5 {
                        log::trace!("load_string, RDB_ENC_INT32, not enough data");
                        return Ok(None);
                    }
                    self.buffer_advance(1);
                    let val = self.buffer.get_i32_le();
                    log::debug!("load_string, RDB_ENC_INT32, value: {}", val.to_string());
                    Ok(Some(val.to_string().into_bytes()))
                }
                RDB_ENC_LZF => {
                    log::debug!("load_string, RDB_ENC_LZF");
                    // LZF: Peek at lengths without consuming to know total size needed
                    let mut peek_cursor = 1; // Will skip encoding byte

                    if self.buffer.len() < peek_cursor + 1 {
                        log::trace!("load_string, RDB_ENC_LZF, not enough data");
                        return Ok(None);
                    }

                    // Peek at compressed length
                    let (clen, clen_bytes) = match self.peek_length_at(peek_cursor)? {
                        Some((len, bytes_used)) => (len, bytes_used),
                        None =>
                        {
                            log::trace!("load_string, RDB_ENC_LZF, not enough data");
                            return Ok(None);
                        }
                    };
                    peek_cursor += clen_bytes;

                    // Peek at uncompressed length
                    let (_ulen, ulen_bytes) = match self.peek_length_at(peek_cursor)? {
                        Some((len, bytes_used)) => (len, bytes_used),
                        None => {
                            log::trace!("load_string, RDB_ENC_LZF, not enough data");
                            return Ok(None);
                        }
                    };
                    peek_cursor += ulen_bytes;

                    // Check if we have all the compressed data
                    if self.buffer.len() < peek_cursor + clen as usize {
                        log::trace!("load_string, RDB_ENC_LZF, not enough data");
                        return Ok(None);
                    }

                    // Now we know we have everything - consume bytes
                    self.buffer_advance(1); // encoding byte
                    let clen_actual = self.load_length()?.unwrap(); // comp len
                    let ulen_actual = self.load_length()?.unwrap(); // uncomp len
                    let compressed = self.buffer.split_to(clen_actual as usize);
                    let decompressed = lzf_decompress(&compressed, ulen_actual as usize)?;
                    log::debug!("load_string, RDB_ENC_LZF, decompressed: {}", String::from_utf8_lossy(&decompressed));
                    Ok(Some(decompressed))
                }
                _ => Err(format!("unknown_encoding: 0x{:02X} (enc_type={}, subtype={})",
                          first, enc_type, enc_subtype)),
            }
        } else {
            // Regular string - peek at length first
            let (len, len_bytes) = match self.peek_length_at(0)? {
                Some((len, bytes_used)) => (len, bytes_used),
                None => {
                    log::trace!("load_string, regular string, no length");
                    return Ok(None)
                }
            };

            // Check if we have enough data for the entire string
            if self.buffer.len() < len_bytes + len as usize {
                log::trace!("load_string, regular string, not enough data");
                return Ok(None);
            }

            // Now consume the length and data
            let _ = self.load_length()?; // Already validated
            let data = self.buffer.split_to(len as usize).to_vec();
            log::debug!("load_string, regular string, data: {:?}, ascii: {}", data, String::from_utf8_lossy(&data));
            Ok(Some(data))
        }
    }

    // Peek at a length value without consuming bytes
    // Returns (length, bytes_used_for_length_encoding)
    fn peek_length_at(&self, offset: usize) -> Result<Option<(u64, usize)>, String> {
        if offset >= self.buffer.len() {
            return Ok(None);
        }

        let first = self.buffer[offset];
        let enc_type = (first & 0xC0) >> 6;

        match enc_type {
            0 => {
                // 6-bit length
                Ok(Some(((first & 0x3F) as u64, 1)))
            }
            1 => {
                // 14-bit length
                if offset + 1 >= self.buffer.len() {
                    return Ok(None);
                }
                let val = (((first & 0x3F) as u64) << 8) | (self.buffer[offset + 1] as u64);
                Ok(Some((val, 2)))
            }
            2 => {
                // 32-bit or 64-bit length
                match first {
                    0x80 => {
                        // 32-bit length
                        if offset + 4 >= self.buffer.len() {
                            return Ok(None);
                        }
                        let val = u32::from_be_bytes([
                            self.buffer[offset + 1],
                            self.buffer[offset + 2],
                            self.buffer[offset + 3],
                            self.buffer[offset + 4],
                        ]) as u64;
                        Ok(Some((val, 5)))
                    }
                    0x81 => {
                        // 64-bit length
                        if offset + 8 >= self.buffer.len() {
                            return Ok(None);
                        }
                        let val = u64::from_be_bytes([
                            self.buffer[offset + 1],
                            self.buffer[offset + 2],
                            self.buffer[offset + 3],
                            self.buffer[offset + 4],
                            self.buffer[offset + 5],
                            self.buffer[offset + 6],
                            self.buffer[offset + 7],
                            self.buffer[offset + 8],
                        ]);
                        Ok(Some((val, 9)))
                    }
                    _ => Err("invalid_length_encoding".to_string()),
                }
            }
            3 => {
                // Special encoding - not a length
                Err("special_encoding_in_length".to_string())
            }
            _ => unreachable!(),
        }
    }

    fn load_object(&mut self, value_type: u8, key: &[u8]) -> Result<Option<Vec<RawCommand>>, String> {
        match value_type {
            RDB_TYPE_STRING => self.load_string_value(key),
            RDB_TYPE_LIST => self.load_list_value(key),
            RDB_TYPE_SET => self.load_set_value(key),
            RDB_TYPE_ZSET => self.load_zset_value(key),
            RDB_TYPE_ZSET_2 => self.load_zset2_value(key),
            RDB_TYPE_HASH => self.load_hash_value(key),
            RDB_TYPE_LIST_QUICKLIST => self.load_quicklist_value(key),
            RDB_TYPE_LIST_QUICKLIST_2 => self.load_quicklist2_value(key),
            RDB_TYPE_HASH_ZIPLIST => self.load_hash_ziplist_value(key),
            RDB_TYPE_HASH_LISTPACK => self.load_hash_listpack_value(key),
            RDB_TYPE_HASH_METADATA => self.load_hash_metadata_value(key),
            RDB_TYPE_HASH_LISTPACK_EX => self.load_hash_listpack_ex_value(key),
            RDB_TYPE_HASH_METADATA_PRE_GA => self.load_hash_metadata_pre_ga_value(key),
            RDB_TYPE_SET_INTSET => self.load_set_intset_value(key),
            RDB_TYPE_SET_LISTPACK => self.load_set_listpack_value(key),
            RDB_TYPE_ZSET_ZIPLIST => self.load_zset_ziplist_value(key),
            RDB_TYPE_ZSET_LISTPACK => self.load_zset_listpack_value(key),
            _ => {
                // Skip unknown type - attempt to load as string
                log::warn!("Unknown RDB type {} for key {:?}", value_type, String::from_utf8_lossy(key));
                match self.load_string()? {
                    Some(_) => Ok(Some(Vec::new())),
                    None => Ok(None),
                }
            }
        }
    }

    fn load_string_value(&mut self, key: &[u8]) -> Result<Option<Vec<RawCommand>>, String> {
        match self.load_string()? {
            Some(value) => {
                let cmd = RawCommand::with_args(
                    self.current_db,
                    b"SET",
                    vec![key.to_vec(), value],
                );
                Ok(Some(vec![cmd]))
            }
            None => Ok(None),
        }
    }

    fn load_list_value(&mut self, key: &[u8]) -> Result<Option<Vec<RawCommand>>, String> {
        match self.load_length()? {
            Some(count) => {
                let mut values = Vec::new();
                for _ in 0..count {
                    match self.load_string()? {
                        Some(v) => values.push(v),
                        None => return Ok(None),
                    }
                }

                let mut args = vec![key.to_vec()];
                args.extend(values);
                let cmd = RawCommand::with_args(self.current_db, b"RPUSH", args);
                Ok(Some(vec![cmd]))
            }
            None => Ok(None),
        }
    }

    fn load_set_value(&mut self, key: &[u8]) -> Result<Option<Vec<RawCommand>>, String> {
        match self.load_length()? {
            Some(count) => {
                let mut members = Vec::new();
                for _ in 0..count {
                    match self.load_string()? {
                        Some(m) => members.push(m),
                        None => return Ok(None),
                    }
                }

                let mut args = vec![key.to_vec()];
                args.extend(members);
                let cmd = RawCommand::with_args(self.current_db, b"SADD", args);
                Ok(Some(vec![cmd]))
            }
            None => Ok(None),
        }
    }

    fn load_zset_value(&mut self, key: &[u8]) -> Result<Option<Vec<RawCommand>>, String> {
        match self.load_length()? {
            Some(count) => {
                let mut members = Vec::new();
                for _ in 0..count {
                    match self.load_string()? {
                        Some(member) => {
                            match self.load_double_value()? {
                                Some(score) => {
                                    members.push(score);
                                    members.push(member);
                                }
                                None => return Ok(None),
                            }
                        }
                        None => return Ok(None),
                    }
                }

                let mut args = vec![key.to_vec()];
                args.extend(members);
                let cmd = RawCommand::with_args(self.current_db, b"ZADD", args);
                Ok(Some(vec![cmd]))
            }
            None => Ok(None),
        }
    }

    fn load_zset2_value(&mut self, key: &[u8]) -> Result<Option<Vec<RawCommand>>, String> {
        match self.load_length()? {
            Some(count) => {
                let mut members = Vec::new();
                for _ in 0..count {
                    match self.load_string()? {
                        Some(member) => {
                            if self.buffer.len() < 8 {
                                return Ok(None);
                            }
                            let score = self.buffer.get_f64_le();
                            members.push(score.to_string().into_bytes());
                            members.push(member);
                        }
                        None => return Ok(None),
                    }
                }

                let mut args = vec![key.to_vec()];
                args.extend(members);
                let cmd = RawCommand::with_args(self.current_db, b"ZADD", args);
                Ok(Some(vec![cmd]))
            }
            None => Ok(None),
        }
    }

    fn load_hash_value(&mut self, key: &[u8]) -> Result<Option<Vec<RawCommand>>, String> {
        match self.load_length()? {
            Some(count) => {
                let mut fields = Vec::new();
                for _ in 0..count {
                    match self.load_string()? {
                        Some(field) => {
                            match self.load_string()? {
                                Some(value) => {
                                    fields.push(field);
                                    fields.push(value);
                                }
                                None => return Ok(None),
                            }
                        }
                        None => return Ok(None),
                    }
                }

                let mut args = vec![key.to_vec()];
                args.extend(fields);
                let cmd = RawCommand::with_args(self.current_db, b"HSET", args);
                Ok(Some(vec![cmd]))
            }
            None => Ok(None),
        }
    }

    fn load_double_value(&mut self) -> Result<Option<Vec<u8>>, String> {
        if self.buffer.is_empty() {
            return Ok(None);
        }

        let len = self.buffer[0];
        self.buffer_advance(1);

        match len {
            253 => Ok(Some(b"nan".to_vec())),
            254 => Ok(Some(b"inf".to_vec())),
            255 => Ok(Some(b"-inf".to_vec())),
            _ => {
                if self.buffer.len() < len as usize {
                    return Ok(None);
                }
                let score_bytes = self.buffer.split_to(len as usize).to_vec();
                Ok(Some(score_bytes))
            }
        }
    }

    // Encoded type implementations

    fn load_quicklist_value(&mut self, key: &[u8]) -> Result<Option<Vec<RawCommand>>, String> {
        match self.load_length()? {
            Some(count) => {
                let mut all_values = Vec::new();

                for _ in 0..count {
                    match self.load_string()? {
                        Some(listpack_bin) => {
                            match parse_listpack(&listpack_bin) {
                                Ok(entries) => all_values.extend(entries),
                                Err(e) => return Err(e),
                            }
                        }
                        None => return Ok(None),
                    }
                }

                if all_values.is_empty() {
                    return Ok(Some(Vec::new()));
                }

                let mut args = vec![key.to_vec()];
                args.extend(all_values);
                let cmd = RawCommand::with_args(self.current_db, b"RPUSH", args);
                Ok(Some(vec![cmd]))
            }
            None => Ok(None),
        }
    }

    fn load_quicklist2_value(&mut self, key: &[u8]) -> Result<Option<Vec<RawCommand>>, String> {
        match self.load_length()? {
            Some(count) => {
                let mut all_values = Vec::new();

                for _ in 0..count {
                    // Read container type: 1 = plain, 2 = packed (LZF compressed)
                    if self.buffer.is_empty() {
                        return Ok(None);
                    }
                    let _container_type = self.buffer[0];
                    self.buffer.advance(1);

                    match self.load_string()? {
                        Some(listpack_bin) => {
                            match parse_listpack(&listpack_bin) {
                                Ok(entries) => all_values.extend(entries),
                                Err(e) => return Err(e),
                            }
                        }
                        None => return Ok(None),
                    }
                }

                if all_values.is_empty() {
                    return Ok(Some(Vec::new()));
                }

                let mut args = vec![key.to_vec()];
                args.extend(all_values);
                let cmd = RawCommand::with_args(self.current_db, b"RPUSH", args);
                Ok(Some(vec![cmd]))
            }
            None => Ok(None),
        }
    }

    fn load_hash_ziplist_value(&mut self, key: &[u8]) -> Result<Option<Vec<RawCommand>>, String> {
        match self.load_string()? {
            Some(ziplist_bin) => {
                match parse_ziplist(&ziplist_bin) {
                    Ok(entries) => {
                        if entries.len() % 2 != 0 {
                            return Err("odd_hash_entries".to_string());
                        }

                        let mut args = vec![key.to_vec()];
                        args.extend(entries);
                        let cmd = RawCommand::with_args(self.current_db, b"HSET", args);
                        Ok(Some(vec![cmd]))
                    }
                    Err(e) => Err(e),
                }
            }
            None => Ok(None),
        }
    }

    fn load_hash_listpack_value(&mut self, key: &[u8]) -> Result<Option<Vec<RawCommand>>, String> {
        match self.load_string()? {
            Some(listpack_bin) => {
                match parse_listpack(&listpack_bin) {
                    Ok(entries) => {
                        if entries.len() % 2 != 0 {
                            return Err("odd_hash_entries".to_string());
                        }

                        let mut args = vec![key.to_vec()];
                        args.extend(entries);
                        let cmd = RawCommand::with_args(self.current_db, b"HSET", args);
                        Ok(Some(vec![cmd]))
                    }
                    Err(e) => Err(e),
                }
            }
            None => Ok(None),
        }
    }

    // Hash with per-field TTLs (type 21, Redis/Valkey 9.0+)
    // Format: length-encoded min_expire, length-encoded count, then for each: string field, string value, length-encoded TTL
    fn load_hash_metadata_value(&mut self, key: &[u8]) -> Result<Option<Vec<RawCommand>>, String> {
        // Skip length-encoded min_expire_time
        match self.load_length()? {
            Some(_) => {}
            None => return Ok(None),
        }

        // Load count
        let count = match self.load_length()? {
            Some(c) => c,
            None => return Ok(None),
        };

        let mut args = vec![key.to_vec()];
        for _ in 0..count {
            // Load field
            let field = match self.load_string()? {
                Some(f) => f,
                None => return Ok(None),
            };
            // Load value
            let value = match self.load_string()? {
                Some(v) => v,
                None => return Ok(None),
            };
            // Skip length-encoded TTL
            match self.load_length()? {
                Some(_) => {}
                None => return Ok(None),
            }

            args.push(field);
            args.push(value);
        }

        if args.len() == 1 {
            return Ok(Some(Vec::new()));
        }

        let cmd = RawCommand::with_args(self.current_db, b"HSET", args);
        Ok(Some(vec![cmd]))
    }

    // Hash with per-field TTLs (type 22, Valkey 9.0+)
    // Format: length-encoded count, then for each field: string field, string value, 8-byte expiry
    // This is the same as RDB_TYPE_HASH (type 4) but with 8-byte expiry after each field-value pair
    fn load_hash_listpack_ex_value(&mut self, key: &[u8]) -> Result<Option<Vec<RawCommand>>, String> {
        let count = match self.load_length()? {
            Some(c) => c,
            None => return Ok(None),
        };

        let mut args = vec![key.to_vec()];
        for _ in 0..count {
            // Load field
            let field = match self.load_string()? {
                Some(f) => f,
                None => return Ok(None),
            };
            // Load value
            let value = match self.load_string()? {
                Some(v) => v,
                None => return Ok(None),
            };
            // Skip 8-byte expiry time (milliseconds)
            if self.buffer.len() < 8 {
                return Ok(None);
            }
            self.buffer_advance(8);

            args.push(field);
            args.push(value);
        }

        if args.len() == 1 {
            return Ok(Some(Vec::new()));
        }

        let cmd = RawCommand::with_args(self.current_db, b"HSET", args);
        Ok(Some(vec![cmd]))
    }

    // Pre-GA hash with per-field TTLs (type 200)
    // Format: listpack containing triplets: [ttl, field, value, ttl, field, value, ...]
    fn load_hash_metadata_pre_ga_value(&mut self, key: &[u8]) -> Result<Option<Vec<RawCommand>>, String> {
        match self.load_string()? {
            Some(listpack_bin) => {
                match parse_listpack(&listpack_bin) {
                    Ok(entries) => {
                        if entries.len() % 3 != 0 {
                            return Err("hash_metadata_entries_not_multiple_of_3".to_string());
                        }

                        // Extract field-value pairs, ignoring TTL
                        let mut args = vec![key.to_vec()];
                        let mut i = 0;
                        while i < entries.len() {
                            // Skip TTL (entries[i])
                            let field = entries[i + 1].clone();
                            let value = entries[i + 2].clone();
                            args.push(field);
                            args.push(value);
                            i += 3;
                        }

                        if args.len() == 1 {
                            return Ok(Some(Vec::new()));
                        }

                        let cmd = RawCommand::with_args(self.current_db, b"HSET", args);
                        Ok(Some(vec![cmd]))
                    }
                    Err(e) => Err(e),
                }
            }
            None => Ok(None),
        }
    }

    fn load_set_intset_value(&mut self, key: &[u8]) -> Result<Option<Vec<RawCommand>>, String> {
        match self.load_string()? {
            Some(intset_bin) => {
                match parse_intset(&intset_bin) {
                    Ok(integers) => {
                        let members: Vec<Vec<u8>> = integers.iter()
                            .map(|i| i.to_string().into_bytes())
                            .collect();

                        let mut args = vec![key.to_vec()];
                        args.extend(members);
                        let cmd = RawCommand::with_args(self.current_db, b"SADD", args);
                        Ok(Some(vec![cmd]))
                    }
                    Err(e) => Err(e),
                }
            }
            None => Ok(None),
        }
    }

    fn load_set_listpack_value(&mut self, key: &[u8]) -> Result<Option<Vec<RawCommand>>, String> {
        match self.load_string()? {
            Some(listpack_bin) => {
                match parse_listpack(&listpack_bin) {
                    Ok(entries) => {
                        let mut args = vec![key.to_vec()];
                        args.extend(entries);
                        let cmd = RawCommand::with_args(self.current_db, b"SADD", args);
                        Ok(Some(vec![cmd]))
                    }
                    Err(e) => Err(e),
                }
            }
            None => Ok(None),
        }
    }

    fn load_zset_ziplist_value(&mut self, key: &[u8]) -> Result<Option<Vec<RawCommand>>, String> {
        match self.load_string()? {
            Some(ziplist_bin) => {
                match parse_ziplist(&ziplist_bin) {
                    Ok(entries) => {
                        if entries.len() % 2 != 0 {
                            return Err("odd_zset_entries".to_string());
                        }

                        // Convert member, score pairs to score, member for ZADD
                        let mut args = vec![key.to_vec()];
                        let mut i = 0;
                        while i < entries.len() {
                            let member = &entries[i];
                            let score_bin = &entries[i + 1];

                            // Parse score
                            let score = binary_to_float_safe(score_bin);
                            args.push(score.to_string().into_bytes());
                            args.push(member.clone());
                            i += 2;
                        }

                        let cmd = RawCommand::with_args(self.current_db, b"ZADD", args);
                        Ok(Some(vec![cmd]))
                    }
                    Err(e) => Err(e),
                }
            }
            None => Ok(None),
        }
    }

    fn load_zset_listpack_value(&mut self, key: &[u8]) -> Result<Option<Vec<RawCommand>>, String> {
        match self.load_string()? {
            Some(listpack_bin) => {
                match parse_listpack(&listpack_bin) {
                    Ok(entries) => {
                        if entries.len() % 2 != 0 {
                            return Err("odd_zset_entries".to_string());
                        }

                        // Convert member, score pairs to score, member for ZADD
                        let mut args = vec![key.to_vec()];
                        let mut i = 0;
                        while i < entries.len() {
                            let member = &entries[i];
                            let score_bin = &entries[i + 1];

                            // Parse score
                            let score = binary_to_float_safe(score_bin);
                            args.push(score.to_string().into_bytes());
                            args.push(member.clone());
                            i += 2;
                        }

                        let cmd = RawCommand::with_args(self.current_db, b"ZADD", args);
                        Ok(Some(vec![cmd]))
                    }
                    Err(e) => Err(e),
                }
            }
            None => Ok(None),
        }
    }
}

// LZF decompression using existing C function
fn lzf_decompress(compressed: &[u8], expected_len: usize) -> Result<Vec<u8>, String> {
    extern "C" {
        fn lzf_decompress(
            in_data: *const u8,
            in_len: libc::c_uint,
            out_data: *mut u8,
            out_len: libc::c_uint,
        ) -> libc::c_uint;
    }

    let mut output = vec![0u8; expected_len];

    unsafe {
        let result = lzf_decompress(
            compressed.as_ptr(),
            compressed.len() as libc::c_uint,
            output.as_mut_ptr(),
            expected_len as libc::c_uint,
        );

        if result == 0 {
            return Err("lzf_decompression_failed".to_string());
        }

        if result as usize != expected_len {
            return Err("lzf_size_mismatch".to_string());
        }
    }

    Ok(output)
}

// Helper function to convert binary to float safely
fn binary_to_float_safe(bin: &[u8]) -> f64 {
    // Try to parse as float
    if let Ok(s) = std::str::from_utf8(bin) {
        if let Ok(f) = s.parse::<f64>() {
            return f;
        }
        // Try as integer
        if let Ok(i) = s.parse::<i64>() {
            return i as f64;
        }
    }
    0.0
}

// Parse ziplist format
fn parse_ziplist(data: &[u8]) -> Result<Vec<Vec<u8>>, String> {
    if data.len() < 10 {
        return Err("ziplist_too_small".to_string());
    }

    let mut buf = BytesMut::from(data);

    let _total_bytes = buf.get_u32_le();
    let _tail_offset = buf.get_u32_le();
    let num_entries = buf.get_u16_le();

    let mut entries = Vec::new();

    for _ in 0..num_entries {
        if buf.is_empty() {
            break;
        }

        // Check for end marker
        if buf[0] == 0xFF {
            break;
        }

        match parse_ziplist_entry(&mut buf) {
            Ok(entry) => entries.push(entry),
            Err(e) => return Err(e),
        }
    }

    Ok(entries)
}

fn parse_ziplist_entry(buf: &mut BytesMut) -> Result<Vec<u8>, String> {
    if buf.is_empty() {
        return Err("ziplist_entry_empty".to_string());
    }

    // Read previous entry length
    let prev_len = buf[0];
    if prev_len < 254 {
        buf.advance(1);
    } else {
        if buf.len() < 5 {
            return Err("ziplist_entry_too_short".to_string());
        }
        buf.advance(5); // 1 byte marker + 4 bytes length
    }

    if buf.is_empty() {
        return Err("ziplist_entry_no_encoding".to_string());
    }

    // Parse encoding
    let enc = buf[0];
    buf.advance(1);

    match enc & 0xC0 {
        0x00 => {
            // String with length <= 63
            let len = (enc & 0x3F) as usize;
            if buf.len() < len {
                return Err("ziplist_entry_string_too_short".to_string());
            }
            let data = buf.split_to(len).to_vec();
            Ok(data)
        }
        0x40 => {
            // String with length <= 16383
            if buf.is_empty() {
                return Err("ziplist_entry_string_too_short".to_string());
            }
            let next_byte = buf[0];
            buf.advance(1);
            let len = (((enc & 0x3F) as usize) << 8) | (next_byte as usize);
            if buf.len() < len {
                return Err("ziplist_entry_string_too_short".to_string());
            }
            let data = buf.split_to(len).to_vec();
            Ok(data)
        }
        0x80 => {
            // String with length > 16383
            if buf.len() < 4 {
                return Err("ziplist_entry_string_too_short".to_string());
            }
            let len = buf.get_u32() as usize;
            if buf.len() < len {
                return Err("ziplist_entry_string_too_short".to_string());
            }
            let data = buf.split_to(len).to_vec();
            Ok(data)
        }
        0xC0 => {
            // Integer encoding
            match enc {
                0xF0 => {
                    // 16-bit integer
                    if buf.len() < 2 {
                        return Err("ziplist_entry_int_too_short".to_string());
                    }
                    let val = buf.get_i16_le();
                    Ok(val.to_string().into_bytes())
                }
                0xFE => {
                    // 8-bit integer
                    if buf.is_empty() {
                        return Err("ziplist_entry_int_too_short".to_string());
                    }
                    let val = buf.get_i8();
                    Ok(val.to_string().into_bytes())
                }
                0xF1 => {
                    // 32-bit integer
                    if buf.len() < 4 {
                        return Err("ziplist_entry_int_too_short".to_string());
                    }
                    let val = buf.get_i32_le();
                    Ok(val.to_string().into_bytes())
                }
                0xF2 => {
                    // 64-bit integer
                    if buf.len() < 8 {
                        return Err("ziplist_entry_int_too_short".to_string());
                    }
                    let val = buf.get_i64_le();
                    Ok(val.to_string().into_bytes())
                }
                0xF3 => {
                    // 24-bit integer
                    if buf.len() < 3 {
                        return Err("ziplist_entry_int_too_short".to_string());
                    }
                    let low = buf.get_u8() as i32;
                    let mid = buf.get_u8() as i32;
                    let high = buf.get_i8() as i32;
                    let val = low | (mid << 8) | (high << 16);
                    Ok(val.to_string().into_bytes())
                }
                _ if (0xF4..=0xFD).contains(&enc) => {
                    // 4-bit integer (0-12)
                    let val = ((enc & 0x0F) - 1) as i8;
                    Ok(val.to_string().into_bytes())
                }
                _ => Err("unknown_ziplist_encoding".to_string()),
            }
        }
        _ => Err("invalid_ziplist_encoding".to_string()),
    }
}

// Parse intset format
fn parse_intset(data: &[u8]) -> Result<Vec<i64>, String> {
    if data.len() < 8 {
        return Err("intset_too_small".to_string());
    }

    let mut buf = BytesMut::from(data);
    let encoding = buf.get_u32_le();
    let length = buf.get_u32_le();

    let mut integers = Vec::new();

    for _ in 0..length {
        let val = match encoding {
            2 => {
                // 16-bit integers
                if buf.len() < 2 {
                    return Err("intset_entry_too_short".to_string());
                }
                buf.get_i16_le() as i64
            }
            4 => {
                // 32-bit integers
                if buf.len() < 4 {
                    return Err("intset_entry_too_short".to_string());
                }
                buf.get_i32_le() as i64
            }
            8 => {
                // 64-bit integers
                if buf.len() < 8 {
                    return Err("intset_entry_too_short".to_string());
                }
                buf.get_i64_le()
            }
            _ => return Err("unknown_intset_encoding".to_string()),
        };
        integers.push(val);
    }

    Ok(integers)
}

// Calculate listpack back length size based on entry size
fn calculate_backlen_size(entry_size: usize) -> usize {
    if entry_size <= 127 {
        1
    } else if entry_size <= 16383 {
        2
    } else if entry_size <= 2_097_151 {
        3
    } else if entry_size <= 268_435_455 {
        4
    } else {
        5
    }
}

// Parse listpack format
fn parse_listpack(data: &[u8]) -> Result<Vec<Vec<u8>>, String> {
    if data.len() < 6 {
        return Err("listpack_too_small".to_string());
    }

    let mut buf = BytesMut::from(data);

    let _total_bytes = buf.get_u32_le();
    let num_entries = buf.get_u16_le();

    let mut entries = Vec::new();

    for _ in 0..num_entries {
        if buf.is_empty() {
            break;
        }

        // Check for end marker
        if buf[0] == 0xFF {
            break;
        }

        match parse_listpack_entry(&mut buf) {
            Ok(entry) => entries.push(entry),
            Err(e) => return Err(e),
        }
    }

    Ok(entries)
}

fn parse_listpack_entry(buf: &mut BytesMut) -> Result<Vec<u8>, String> {
    if buf.is_empty() {
        return Err("listpack_entry_empty".to_string());
    }

    let enc = buf[0];
    buf.advance(1);

    match enc & 0x80 {
        0 => {
            // 7-bit unsigned integer
            let val = enc & 0x7F;
            if buf.is_empty() {
                return Err("listpack_entry_no_backlen".to_string());
            }
            buf.advance(1); // Skip backlen
            Ok(val.to_string().into_bytes())
        }
        0x80 => {
            match enc & 0xC0 {
                0x80 => {
                    // 6-bit string
                    let len = (enc & 0x3F) as usize;
                    if buf.len() < len + 1 {
                        return Err("listpack_entry_string_too_short".to_string());
                    }
                    let data = buf.split_to(len).to_vec();
                    buf.advance(1); // Skip backlen
                    Ok(data)
                }
                0xC0 => {
                    match enc & 0xF0 {
                        0xC0 => {
                            // 13-bit signed integer
                            if buf.len() < 2 {
                                return Err("listpack_entry_int_too_short".to_string());
                            }
                            let next_byte = buf[0];
                            buf.advance(1);
                            let val = (((enc & 0x1F) as u16) << 8) | (next_byte as u16);
                            let signed_val = if val >= 4096 {
                                (val as i16) - 8192
                            } else {
                                val as i16
                            };
                            buf.advance(1); // Skip backlen
                            Ok(signed_val.to_string().into_bytes())
                        }
                        0xD0 => {
                            // 16-bit string
                            if buf.len() < 2 {
                                return Err("listpack_entry_string_too_short".to_string());
                            }
                            let len = buf.get_u16() as usize;
                            let backlen_size = calculate_backlen_size(3 + len);
                            if buf.len() < len + backlen_size {
                                return Err("listpack_entry_string_too_short".to_string());
                            }
                            let data = buf.split_to(len).to_vec();
                            buf.advance(backlen_size);
                            Ok(data)
                        }
                        0xE0 => {
                            // 12-bit string
                            if buf.is_empty() {
                                return Err("listpack_entry_string_too_short".to_string());
                            }
                            let next_byte = buf[0];
                            buf.advance(1);
                            let len = (((enc & 0x0F) as usize) << 8) | (next_byte as usize);
                            let backlen_size = calculate_backlen_size(2 + len);
                            if buf.len() < len + backlen_size {
                                return Err("listpack_entry_string_too_short".to_string());
                            }
                            let data = buf.split_to(len).to_vec();
                            buf.advance(backlen_size);
                            Ok(data)
                        }
                        0xF0 => {
                            match enc {
                                0xF0 => {
                                    // 32-bit string
                                    if buf.len() < 4 {
                                        return Err("listpack_entry_string_too_short".to_string());
                                    }
                                    let len = buf.get_u32_le() as usize;
                                    let backlen_size = calculate_backlen_size(5 + len);
                                    if buf.len() < len + backlen_size {
                                        return Err("listpack_entry_string_too_short".to_string());
                                    }
                                    let data = buf.split_to(len).to_vec();
                                    buf.advance(backlen_size);
                                    Ok(data)
                                }
                                0xF1 => {
                                    // 16-bit signed integer
                                    if buf.len() < 3 {
                                        return Err("listpack_entry_int_too_short".to_string());
                                    }
                                    let val = buf.get_i16_le();
                                    buf.advance(1); // Skip backlen
                                    Ok(val.to_string().into_bytes())
                                }
                                0xF2 => {
                                    // 24-bit signed integer
                                    if buf.len() < 4 {
                                        return Err("listpack_entry_int_too_short".to_string());
                                    }
                                    let low = buf.get_u8() as i32;
                                    let mid = buf.get_u8() as i32;
                                    let high = buf.get_i8() as i32;
                                    let val = low | (mid << 8) | (high << 16);
                                    buf.advance(1); // Skip backlen
                                    Ok(val.to_string().into_bytes())
                                }
                                0xF3 => {
                                    // 32-bit signed integer
                                    if buf.len() < 5 {
                                        return Err("listpack_entry_int_too_short".to_string());
                                    }
                                    let val = buf.get_i32_le();
                                    buf.advance(1); // Skip backlen
                                    Ok(val.to_string().into_bytes())
                                }
                                0xF4 => {
                                    // 64-bit signed integer
                                    if buf.len() < 9 {
                                        return Err("listpack_entry_int_too_short".to_string());
                                    }
                                    let val = buf.get_i64_le();
                                    buf.advance(1); // Skip backlen
                                    Ok(val.to_string().into_bytes())
                                }
                                _ => Err("unknown_listpack_encoding".to_string()),
                            }
                        }
                        _ => Err("invalid_listpack_encoding".to_string()),
                    }
                }
                _ => Err("invalid_listpack_encoding".to_string()),
            }
        }
        _ => Err("invalid_listpack_encoding".to_string()),
    }

}

// NIFs

#[rustler::nif(name = "rdb_create")]
fn create_parser(env: Env) -> ResourceArc<RDBParser> {
    ResourceArc::new(RDBParser::new(env.pid()))
}

#[rustler::nif(name = "rdb_data")]
fn feed_data<'a>(
    env: Env<'a>,
    parser: ResourceArc<RDBParser>,
    data: Binary,
) -> Term<'a> {
    if parser.pid != env.pid() {
        return (atoms::error(), "parser_not_owned".to_string()).encode(env);
    }

    match parser.feed_data(data.as_slice()) {
        Ok(commands) => {
            // Convert RawCommand to Elixir terms: {db, name, [args...]}
            let result: Vec<Term<'a>> = commands.iter()
                .map(|cmd| {
                    // Create binary for command name
                    let mut name_bin = NewBinary::new(env, cmd.name.len());
                    name_bin.as_mut_slice().copy_from_slice(&cmd.name);
                    let name_binary: Binary = name_bin.into();

                    // Create binaries for all args
                    let args: Vec<Binary> = cmd.args.iter()
                        .map(|arg| {
                            let mut arg_bin = NewBinary::new(env, arg.len());
                            arg_bin.as_mut_slice().copy_from_slice(arg);
                            arg_bin.into()
                        })
                        .collect();

                    (cmd.db, name_binary, args).encode(env)
                })
                .collect();

            // Check if finished
            let finished = parser.state.borrow().finished;

            if finished {
                // Return {:ok, commands} - finished parsing
                (atoms::ok(), result).encode(env)
            } else {
                // Return {:ok, commands, parser} - more data needed
                // Parser has been mutated in place, just return the same resource
                (atoms::ok(), result, parser).encode(env)
            }
        }
        Err(e) => (atoms::error(), e).encode(env),
    }
}

pub fn load(env: Env) -> bool {
    env.register::<RDBParser>().is_ok()
}
