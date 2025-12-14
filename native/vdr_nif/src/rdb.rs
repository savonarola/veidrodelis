use rustler::{Binary, Encoder, Env, NewBinary, ResourceArc, Term};
use bytes::{Buf, BufMut, BytesMut};

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

// Encoding types
const RDB_ENC_INT8: u8 = 0;
const RDB_ENC_INT16: u8 = 1;
const RDB_ENC_INT32: u8 = 2;
const RDB_ENC_LZF: u8 = 3;

/// Represents a raw Redis command as parsed from RDB
/// Will be converted to Vdr.Command structs in Elixir
#[derive(Debug, Clone)]
struct RawCommand {
    db: u32,           // Database number
    name: Vec<u8>,     // Command name like "SET", "RPUSH", etc.
    args: Vec<Vec<u8>>, // Command arguments
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
    ProcessingValue(u8, usize), // type, key_offset in saved_key
    WaitingChecksum, // Encountered EOF, waiting for 8-byte checksum
    Finished,
}

#[derive(Clone)]
pub struct RDBParser {
    buffer: BytesMut,
    parse_state: ParseState,
    current_db: u32,
    expire_ms: Option<u64>,
    finished: bool,
    saved_key: Vec<u8>, // Temporary storage for key when parsing value
}

impl RDBParser {
    fn new() -> Self {
        RDBParser {
            buffer: BytesMut::new(),
            parse_state: ParseState::Magic(0),
            current_db: 0,
            expire_ms: None,
            finished: false,
            saved_key: Vec::new(),
        }
    }

    fn feed_data(&mut self, data: &[u8]) -> Result<Vec<RawCommand>, String> {
        if self.finished {
            return Err("already_finished".to_string());
        }

        // Append data to buffer
        self.buffer.put_slice(data);

        // Parse and collect commands
        let mut commands = Vec::new();

        loop {
            match self.parse_next()? {
                Some(mut cmds) => commands.append(&mut cmds),
                None => break,  // Need more data
            }
        }

        Ok(commands)
    }

    fn parse_next(&mut self) -> Result<Option<Vec<RawCommand>>, String> {
        match self.parse_state {
            ParseState::Magic(pos) => self.parse_magic(pos),
            ParseState::Opcode => self.parse_opcode(),
            ParseState::ProcessingOpcode(opcode) => self.process_opcode(opcode),
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

        // Check magic "REDIS"
        if &magic_version[0..5] != b"REDIS" {
            return Err("invalid_magic".to_string());
        }

        // Check version (0001-0012)
        let version_str = std::str::from_utf8(&magic_version[5..9])
            .map_err(|_| "invalid_version")?;
        let version: u32 = version_str.parse()
            .map_err(|_| "invalid_version")?;

        if !(1..=12).contains(&version) {
            return Err("unsupported_version".to_string());
        }

        self.buffer.advance(9);
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
        self.buffer.advance(8);

        self.finished = true;
        self.parse_state = ParseState::Finished;
        Ok(None)
    }

    fn parse_opcode(&mut self) -> Result<Option<Vec<RawCommand>>, String> {
        if self.buffer.is_empty() {
            return Ok(None); // Need more data
        }

        let opcode = self.buffer[0];
        self.buffer.advance(1);

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
                self.parse_state = ParseState::Opcode; // Reset for next iteration
                match self.load_string()? {
                    Some(key) => {
                        self.saved_key = key;
                        let key_len = self.saved_key.len();
                        self.parse_state = ParseState::ProcessingValue(value_type, key_len);
                        self.parse_next()
                    }
                    None => {
                        // Need more data, put opcode back
                        let mut temp = BytesMut::with_capacity(1 + self.buffer.len());
                        temp.put_u8(value_type);
                        temp.put(self.buffer.split());
                        self.buffer = temp;
                        self.parse_state = ParseState::Opcode;
                        Ok(None)
                    }
                }
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
                let _val_size = match self.calculate_string_size(key_size)? {
                    Some(s) => s,
                    None => return Ok(None),
                };

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
            RDB_TYPE_ZSET_ZIPLIST | RDB_TYPE_ZSET_LISTPACK => {
                // These are all stored as a single string
                self.calculate_string_size(offset)
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
                self.buffer.advance(bytes_used);
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
                        return Ok(None);
                    }
                    self.buffer.advance(1);
                    let val = self.buffer.get_i8();
                    Ok(Some(val.to_string().into_bytes()))
                }
                RDB_ENC_INT16 => {
                    if self.buffer.len() < 3 {
                        return Ok(None);
                    }
                    self.buffer.advance(1);
                    let val = self.buffer.get_i16_le();
                    Ok(Some(val.to_string().into_bytes()))
                }
                RDB_ENC_INT32 => {
                    if self.buffer.len() < 5 {
                        return Ok(None);
                    }
                    self.buffer.advance(1);
                    let val = self.buffer.get_i32_le();
                    Ok(Some(val.to_string().into_bytes()))
                }
                RDB_ENC_LZF => {
                    // LZF: Peek at lengths without consuming to know total size needed
                    let mut peek_cursor = 1; // Will skip encoding byte

                    if self.buffer.len() < peek_cursor + 1 {
                        return Ok(None);
                    }

                    // Peek at compressed length
                    let (clen, clen_bytes) = match self.peek_length_at(peek_cursor)? {
                        Some((len, bytes_used)) => (len, bytes_used),
                        None => return Ok(None),
                    };
                    peek_cursor += clen_bytes;

                    // Peek at uncompressed length
                    let (_ulen, ulen_bytes) = match self.peek_length_at(peek_cursor)? {
                        Some((len, bytes_used)) => (len, bytes_used),
                        None => return Ok(None),
                    };
                    peek_cursor += ulen_bytes;

                    // Check if we have all the compressed data
                    if self.buffer.len() < peek_cursor + clen as usize {
                        return Ok(None);
                    }

                    // Now we know we have everything - consume bytes
                    self.buffer.advance(1); // encoding byte
                    let clen_actual = self.load_length()?.unwrap(); // comp len
                    let ulen_actual = self.load_length()?.unwrap(); // uncomp len
                    let compressed = self.buffer.split_to(clen_actual as usize);
                    let decompressed = lzf_decompress(&compressed, ulen_actual as usize)?;
                    Ok(Some(decompressed))
                }
                _ => Err(format!("unknown_encoding: 0x{:02X} (enc_type={}, subtype={})",
                          first, enc_type, enc_subtype)),
            }
        } else {
            // Regular string - peek at length first
            let (len, len_bytes) = match self.peek_length_at(0)? {
                Some((len, bytes_used)) => (len, bytes_used),
                None => return Ok(None),
            };

            // Check if we have enough data for the entire string
            if self.buffer.len() < len_bytes + len as usize {
                return Ok(None);
            }

            // Now consume the length and data
            let _ = self.load_length()?; // Already validated
            let data = self.buffer.split_to(len as usize).to_vec();
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
            RDB_TYPE_SET_INTSET => self.load_set_intset_value(key),
            RDB_TYPE_SET_LISTPACK => self.load_set_listpack_value(key),
            RDB_TYPE_ZSET_ZIPLIST => self.load_zset_ziplist_value(key),
            RDB_TYPE_ZSET_LISTPACK => self.load_zset_listpack_value(key),
            _ => {
                // Skip unknown type
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
        self.buffer.advance(1);

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

#[rustler::nif(name = "create")]
fn create_parser() -> ResourceArc<RDBParser> {
    ResourceArc::new(RDBParser::new())
}

#[rustler::nif(name = "data")]
fn feed_data<'a>(
    env: Env<'a>,
    parser: ResourceArc<RDBParser>,
    data: Binary,
) -> Term<'a> {
    let mut parser_clone = (*parser).clone();

    match parser_clone.feed_data(data.as_slice()) {
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

            // Check if finished before moving
            let finished = parser_clone.finished;

            if finished {
                // Return {:ok, commands} - finished parsing
                (atoms::ok(), result).encode(env)
            } else {
                // Return {:ok, commands, parser} - more data needed
                let new_parser = ResourceArc::new(parser_clone);
                (atoms::ok(), result, new_parser).encode(env)
            }
        }
        Err(e) => (atoms::error(), e).encode(env),
    }
}

#[allow(unused_must_use)]
#[allow(non_local_definitions)]
pub fn load(env: Env) -> bool {
    rustler::resource!(RDBParser, env);
    true
}
