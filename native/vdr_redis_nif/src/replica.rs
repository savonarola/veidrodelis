use bytes::{Buf, BufMut, BytesMut};
use rustler::{Binary, Encoder, Env, LocalPid, NewBinary, Resource, ResourceArc, Term};
use std::cell::RefCell;
use std::panic::{RefUnwindSafe, UnwindSafe};

use crate::atoms;
use crate::rdb::RDBParser;

/// Represents the state of the replica parser
#[derive(Debug, Clone, Copy, PartialEq)]
enum ReplicaState {
    /// Waiting for RDB bulk string header: $<size>\r\n
    WaitingRdb,
    /// Reading and parsing RDB snapshot
    ReadingRdb,
    /// Streaming commands after RDB completion
    Streaming,
    /// Parser has finished (closed connection or error)
    Finished,
}

/// Represents a raw Redis command as parsed from the replica stream
/// Will be converted to Vdr.Command structs in Elixir
#[derive(Debug, Clone)]
struct RawCommand {
    db: u32,            // Database number
    name: Vec<u8>,      // Command name like "SET", "RPUSH", etc.
    args: Vec<Vec<u8>>, // Command arguments
}

/// Internal parser state
struct ParserState {
    buffer: BytesMut,
    state: ReplicaState,
    current_db: u32,

    // RDB transfer state
    rdb_parser: Option<ResourceArc<RDBParser>>,
    rdb_bulk_size: Option<usize>,
    rdb_bytes_read: usize,

    // Flags for special commands encountered during parsing
    ping_received: bool,
    replconf_getack_received: bool,
}

/// Replica parser resource
pub struct ReplicaParser {
    pid: LocalPid,
    state: RefCell<ParserState>,
}

// SAFETY: ReplicaParser is only accessed by a single Erlang process (checked via pid)
// and will never be used concurrently, so it's safe to implement Send and Sync
unsafe impl Send for ReplicaParser {}
unsafe impl Sync for ReplicaParser {}
impl RefUnwindSafe for ReplicaParser {}
impl UnwindSafe for ReplicaParser {}

#[rustler::resource_impl(register = false)]
impl Resource for ReplicaParser {}

impl ReplicaParser {
    fn new(pid: LocalPid, skip_rdb: bool) -> Self {
        ReplicaParser {
            pid,
            state: RefCell::new(ParserState {
                buffer: BytesMut::new(),
                state: if skip_rdb {
                    ReplicaState::Streaming
                } else {
                    ReplicaState::WaitingRdb
                },
                current_db: 0,
                rdb_parser: None,
                rdb_bulk_size: None,
                rdb_bytes_read: 0,
                ping_received: false,
                replconf_getack_received: false,
            }),
        }
    }

    fn feed_data(&self, data: &[u8]) -> Result<(Vec<RawCommand>, bool, bool), String> {
        let mut state = self.state.borrow_mut();

        if state.state == ReplicaState::Finished {
            return Err("already_finished".to_string());
        }

        // Reset flags at the start of each feed_data call
        state.ping_received = false;
        state.replconf_getack_received = false;

        // Append data to buffer
        state.buffer.put_slice(data);

        // Parse and collect commands
        let mut commands = Vec::new();

        loop {
            match state.parse_next(self.pid)? {
                Some(mut cmds) => commands.append(&mut cmds),
                None => break, // Need more data
            }
        }

        Ok((
            commands,
            state.ping_received,
            state.replconf_getack_received,
        ))
    }
}

impl ParserState {
    fn parse_next(&mut self, pid: LocalPid) -> Result<Option<Vec<RawCommand>>, String> {
        match self.state {
            ReplicaState::WaitingRdb => self.parse_rdb_header(pid),
            ReplicaState::ReadingRdb => self.stream_rdb_data(),
            ReplicaState::Streaming => self.parse_command(),
            ReplicaState::Finished => Ok(None),
        }
    }

    /// Parse RDB bulk string header: $<size>\r\n
    fn parse_rdb_header(&mut self, pid: LocalPid) -> Result<Option<Vec<RawCommand>>, String> {
        // Skip any leading newlines (Redis sends \n while waiting for RDB)
        while !self.buffer.is_empty() && self.buffer[0] == b'\n' {
            self.buffer.advance(1);
        }

        if self.buffer.is_empty() {
            return Ok(None);
        }

        // Look for $<size>\r\n
        if self.buffer[0] != b'$' {
            return Err("expected_bulk_string_header".to_string());
        }

        // Find \r\n
        let buf_slice = self.buffer.as_ref();
        if let Some(pos) = find_crlf(buf_slice) {
            // Parse size
            let size_str = std::str::from_utf8(&buf_slice[1..pos]).map_err(|_| "invalid_size")?;
            let size = size_str.parse::<usize>().map_err(|_| "invalid_size")?;

            // Consume header
            self.buffer.advance(pos + 2);

            // Create RDB parser
            let rdb_parser = ResourceArc::new(RDBParser::new(pid));

            self.rdb_parser = Some(rdb_parser);
            self.rdb_bulk_size = Some(size);
            self.rdb_bytes_read = 0;
            self.state = ReplicaState::ReadingRdb;

            // Continue parsing
            self.parse_next(pid)
        } else {
            Ok(None) // Need more data
        }
    }

    /// Stream data to RDB parser
    fn stream_rdb_data(&mut self) -> Result<Option<Vec<RawCommand>>, String> {
        let rdb_size = self.rdb_bulk_size.ok_or("no_rdb_size")?;
        let bytes_remaining = rdb_size - self.rdb_bytes_read;

        if bytes_remaining == 0 {
            return Err("rdb_already_complete".to_string());
        }

        let bytes_available = self.buffer.len();
        if bytes_available == 0 {
            return Ok(None); // Need more data
        }

        let bytes_to_feed = bytes_available.min(bytes_remaining);
        let chunk = self.buffer.split_to(bytes_to_feed);
        self.rdb_bytes_read += bytes_to_feed;

        // Feed to RDB parser
        let rdb_parser = self.rdb_parser.as_ref().ok_or("no_rdb_parser")?;

        match rdb_parser.feed_data(&chunk) {
            Ok(rdb_commands) => {
                // Convert RDB commands to replica commands
                // RDB commands are the raw tuples we need to re-wrap
                let commands: Vec<RawCommand> = rdb_commands
                    .into_iter()
                    .map(|rdb_cmd| {
                        // The RDB RawCommand has the same structure, just need to copy fields
                        RawCommand {
                            db: rdb_cmd.db,
                            name: rdb_cmd.name,
                            args: rdb_cmd.args,
                        }
                    })
                    .collect();

                // Check if RDB parsing is complete
                if self.rdb_bytes_read >= rdb_size {
                    // RDB transfer complete, switch to streaming
                    self.rdb_parser = None;
                    self.rdb_bulk_size = None;
                    self.rdb_bytes_read = 0;
                    self.state = ReplicaState::Streaming;
                }

                Ok(Some(commands))
            }
            Err(e) => Err(e),
        }
    }

    /// Parse RESP array command: *<count>\r\n$<len>\r\n<data>\r\n...
    fn parse_command(&mut self) -> Result<Option<Vec<RawCommand>>, String> {
        // Skip any leading newlines
        while !self.buffer.is_empty() && self.buffer[0] == b'\n' {
            self.buffer.advance(1);
        }

        if self.buffer.is_empty() {
            return Ok(None);
        }

        // Parse array header
        if self.buffer[0] != b'*' {
            return Err("expected_array".to_string());
        }

        // Find first \r\n
        let buf_slice = self.buffer.as_ref();
        let count_end = match find_crlf(buf_slice) {
            Some(pos) => pos,
            None => return Ok(None), // Need more data
        };

        let count_str =
            std::str::from_utf8(&buf_slice[1..count_end]).map_err(|_| "invalid_count")?;
        let count = count_str.parse::<usize>().map_err(|_| "invalid_count")?;

        // Try to parse all elements
        let mut cursor = count_end + 2; // Skip *<count>\r\n
        let mut elements = Vec::new();

        for _ in 0..count {
            if cursor >= buf_slice.len() {
                return Ok(None); // Need more data
            }

            if buf_slice[cursor] != b'$' {
                return Err("expected_bulk_string".to_string());
            }

            // Find next \r\n for bulk string length
            let len_start = cursor + 1;
            let len_end = match find_crlf_from(&buf_slice[len_start..]) {
                Some(pos) => len_start + pos,
                None => return Ok(None), // Need more data
            };

            let len_str = std::str::from_utf8(&buf_slice[len_start..len_end])
                .map_err(|_| "invalid_length")?;
            let len = len_str.parse::<usize>().map_err(|_| "invalid_length")?;

            // Read bulk string data
            let data_start = len_end + 2;
            let data_end = data_start + len;

            if data_end + 2 > buf_slice.len() {
                return Ok(None); // Need more data
            }

            elements.push(buf_slice[data_start..data_end].to_vec());
            cursor = data_end + 2; // Skip data + \r\n
        }

        // Consume the parsed data
        self.buffer.advance(cursor);

        // Process the command
        if elements.is_empty() {
            return Ok(Some(Vec::new()));
        }

        // Handle special commands
        let cmd_name = String::from_utf8_lossy(&elements[0]).to_uppercase();

        match cmd_name.as_str() {
            "SELECT" => {
                if elements.len() >= 2 {
                    if let Ok(db_str) = std::str::from_utf8(&elements[1]) {
                        if let Ok(db_num) = db_str.parse::<u32>() {
                            self.current_db = db_num;
                        }
                    }
                }
                // Don't emit SELECT commands
                Ok(Some(Vec::new()))
            }
            "PING" => {
                // Set ping flag but don't emit command
                self.ping_received = true;
                Ok(Some(Vec::new()))
            }
            "REPLCONF" => {
                // Check if this is REPLCONF GETACK
                if elements.len() >= 2 {
                    let subcommand = String::from_utf8_lossy(&elements[1]).to_uppercase();
                    if subcommand == "GETACK" {
                        self.replconf_getack_received = true;
                    }
                }
                // Don't emit REPLCONF commands
                Ok(Some(Vec::new()))
            }
            _ => {
                // Convert to RawCommand
                let cmd = RawCommand {
                    db: self.current_db,
                    name: elements[0].clone(),
                    args: elements[1..].to_vec(),
                };
                Ok(Some(vec![cmd]))
            }
        }
    }
}

// Helper functions

fn find_crlf(data: &[u8]) -> Option<usize> {
    data.windows(2).position(|w| w == b"\r\n")
}

fn find_crlf_from(data: &[u8]) -> Option<usize> {
    data.windows(2).position(|w| w == b"\r\n")
}

// NIFs

/// Create a new replica parser
///
/// Arguments:
/// - skip_rdb: if true, starts in streaming mode without expecting RDB
///
/// Returns a resource arc to the parser
#[rustler::nif(name = "do_replica_create")]
fn create_parser(env: Env, skip_rdb: bool) -> ResourceArc<ReplicaParser> {
    ResourceArc::new(ReplicaParser::new(env.pid(), skip_rdb))
}

/// Feed data to the replica parser
///
/// Returns:
/// - {:finished, commands} if finished parsing
/// - {:ok, commands, parser, %{ping: boolean}} if more data needed
/// - {:error, reason} on error
///
/// Commands are tuples: {db, name, [args...]}
#[rustler::nif(name = "replica_data")]
fn feed_data<'a>(env: Env<'a>, parser: ResourceArc<ReplicaParser>, data: Binary) -> Term<'a> {
    // Verify parser ownership
    if parser.pid != env.pid() {
        return (atoms::error(), "parser_not_owned".to_string()).encode(env);
    }

    match parser.feed_data(data.as_slice()) {
        Ok((commands, ping_received, replconf_getack_received)) => {
            // Convert RawCommand to Elixir terms: {db, name, [args...]}
            let result: Vec<Term<'a>> = commands
                .iter()
                .map(|cmd| {
                    // Create binary for command name
                    let mut name_bin = NewBinary::new(env, cmd.name.len());
                    name_bin.as_mut_slice().copy_from_slice(&cmd.name);
                    let name_binary: Binary = name_bin.into();

                    // Create binaries for all args
                    let args: Vec<Binary> = cmd
                        .args
                        .iter()
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
            let finished = parser.state.borrow().state == ReplicaState::Finished;

            if finished {
                // Return {:finished, commands} - finished parsing
                (atoms::finished(), result).encode(env)
            } else {
                // Build flags map with ping and replconf_getack flags
                let flags = rustler::Term::map_from_pairs(
                    env,
                    &[
                        (atoms::ping(), ping_received),
                        (atoms::replconf_getack(), replconf_getack_received),
                    ],
                )
                .expect("failed to create flags map");

                // Return {:ok, commands, parser, %{ping: boolean, replconf_getack: boolean}} - more data needed
                (atoms::ok(), result, parser, flags).encode(env)
            }
        }
        Err(e) => (atoms::error(), e).encode(env),
    }
}

/// Get the current parser state
/// Returns :waiting_rdb, :reading_rdb, :streaming, or :finished
#[rustler::nif(name = "replica_state")]
fn replica_state<'a>(env: Env<'a>, parser: ResourceArc<ReplicaParser>) -> Term<'a> {
    let state = parser.state.borrow().state;
    match state {
        ReplicaState::WaitingRdb => atoms::waiting_rdb().encode(env),
        ReplicaState::ReadingRdb => atoms::reading_rdb().encode(env),
        ReplicaState::Streaming => atoms::streaming().encode(env),
        ReplicaState::Finished => atoms::finished().encode(env),
    }
}

/// Load the replica module and register resources
pub fn load(env: Env) -> bool {
    env.register::<ReplicaParser>().is_ok()
}
