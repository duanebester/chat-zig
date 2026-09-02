//! Append-only JSONL session transcript.
//!
//! One file per app launch: `sessions/{unix_seconds}.jsonl`, mirroring
//! `RecordingState.preparePath`'s idiom (`Io.Dir.createDirPath` plus a
//! timestamp-named file) and reusing `anthropic.writeJsonEscapedString` so
//! there is no second JSON-escaping implementation to keep in sync.
//!
//! The file is opened lazily on the first write rather than at app launch,
//! so a session with zero messages never creates an empty file on disk.
//!
//! Best-effort by design: a session-log write must never block a chat
//! send. Any failure — creating the directory, opening the file, or a
//! write failing partway through a line — flips `write_failed` (a
//! one-shot latch) and every subsequent call becomes a no-op rather than
//! retrying on every message.
//!
//! Format: one JSON object per line —
//!   {"seq":0,"role":"user","text":"...","file":"notes.txt"}
//!   {"seq":1,"role":"assistant","text":"..."}
//!   {"seq":8,"type":"summary","covers":8,"text":"..."}
//! `seq` is `AppState.messages_total` at the time the message was added —
//! a monotonic counter, safe to use as a cut point even after the ring
//! buffer (`AppState.messages`) has overwritten the message it refers to.
//!
//! Summary lines carry no `role`: they are not turns in the conversation,
//! they are compaction bookkeeping (see `docs/CHAT_COMPACTION.md`). Their
//! `covers` is a `seq` too, which is exactly why a restored session can
//! adopt the summary without re-paying for summarization — the cut it
//! names is directly comparable to the `seq` of every message line.

const std = @import("std");
const log = std.log.scoped(.chatzig);
const anthropic = @import("http/anthropic.zig");

pub const SESSION_DIR = "sessions";
pub const SESSION_PATH_MAX_LEN: usize = 128;

/// Deliberately small: `writeJsonLine` drains through this buffer in
/// chunks via the generic `Io.Writer` interface, so its size bounds
/// nothing about how long a logged message may be (see `MAX_MESSAGE_LEN`).
const LINE_BUFFER_LEN: usize = 256;

pub const SessionLog = struct {
    file: ?std.Io.File = null,
    write_failed: bool = false,

    /// Path passed to `createFile` when the session file was opened
    /// (`sessions/{unix_seconds}.jsonl`), valid only once `file != null`.
    /// Kept so `currentSeconds` can report which on-disk session this
    /// process is writing to — see `listSessions` below, which a history
    /// panel uses to mark that entry as the current one.
    path_buf: [SESSION_PATH_MAX_LEN]u8 = undefined,
    path_len: usize = 0,

    /// Log a user turn. `attached_file` is the filename only (never the
    /// file's bytes) — the log records that a file was attached, not its
    /// contents.
    pub fn logUser(self: *SessionLog, io: std.Io, seq: u64, text: []const u8, attached_file: ?[]const u8) void {
        self.writeLineIn(std.Io.Dir.cwd(), io, seq, "user", text, attached_file);
    }

    /// Log a finalized assistant turn. Call once the response is complete
    /// (success or error), never per streaming delta.
    pub fn logAssistant(self: *SessionLog, io: std.Io, seq: u64, text: []const u8) void {
        self.writeLineIn(std.Io.Dir.cwd(), io, seq, "assistant", text, null);
    }

    /// Log a compaction summary. `covers` is the `AppState.summary_covers`
    /// cut the summary stands in for: every message with `seq < covers` is
    /// represented by `text` rather than sent verbatim. `seq` is
    /// `messages_total` at the moment the summary was applied, so the line
    /// sorts into the transcript at the point compaction happened.
    pub fn logSummary(self: *SessionLog, io: std.Io, seq: u64, covers: u64, text: []const u8) void {
        self.writeSummaryLineIn(std.Io.Dir.cwd(), io, seq, covers, text);
    }

    /// Path of the open session file (`sessions/{unix_seconds}.jsonl`), or
    /// null before the first write has opened one.
    pub fn path(self: *const SessionLog) ?[]const u8 {
        if (self.file == null) return null;
        std.debug.assert(self.path_len > 0);
        std.debug.assert(self.path_len <= self.path_buf.len);
        return self.path_buf[0..self.path_len];
    }

    /// The `unix_seconds` this log's own open file encodes, or null before
    /// the first write. Lets a caller building a session list (see
    /// `listSessions` below) mark which entry is the one currently being
    /// written to.
    pub fn currentSeconds(self: *const SessionLog) ?i64 {
        const p = self.path() orelse return null;
        const slash = std.mem.lastIndexOfScalar(u8, p, '/') orelse return null;
        return parseSessionSeconds(p[slash + 1 ..]);
    }

    /// Closes the current session file (if one was ever opened) and resets
    /// state so the next `logUser`/`logAssistant` call lazily opens a brand
    /// new `sessions/{unix_seconds}.jsonl` file, per this module's "opened
    /// lazily on the first write" contract. Used by `AppState.newConversation`
    /// when the user starts a fresh conversation — the old file is left
    /// untouched on disk (and stays visible in the history panel), while
    /// this process's log moves on to writing a new one.
    pub fn startNew(self: *SessionLog, io: std.Io) void {
        std.debug.assert(!(self.file != null and self.write_failed));
        std.debug.assert(self.path_len <= self.path_buf.len);

        if (self.file != null) self.file.?.close(io);
        self.file = null;
        self.write_failed = false;
        self.path_len = 0;

        std.debug.assert(self.file == null);
        std.debug.assert(self.path_len == 0);
    }

    /// Opens (or reuses) the session file. `dir` is threaded through
    /// purely so tests can point this at a `tmpDir` instead of the real
    /// cwd; production call sites always go through `logUser`/`logAssistant`,
    /// which pin `dir` to `Io.Dir.cwd()`.
    fn ensureOpen(self: *SessionLog, dir: std.Io.Dir, io: std.Io) bool {
        std.debug.assert(!(self.file != null and self.write_failed));
        if (self.file != null) return true;
        if (self.write_failed) return false;

        dir.createDirPath(io, SESSION_DIR) catch |e| {
            log.warn("session log: failed to create '{s}' directory: {t}", .{ SESSION_DIR, e });
            self.write_failed = true;
            return false;
        };

        const seconds = std.Io.Timestamp.now(io, .real).toSeconds();
        const session_path = std.fmt.bufPrint(&self.path_buf, SESSION_DIR ++ "/{d}.jsonl", .{seconds}) catch |e| {
            log.warn("session log: path formatting failed: {t}", .{e});
            self.write_failed = true;
            return false;
        };

        // `.read = true` isn't needed for production writes, but keeps
        // the handle usable for the read-back assertions in this file's
        // tests without needing a second, separately-opened handle.
        self.file = dir.createFile(io, session_path, .{ .truncate = true, .read = true }) catch |e| {
            log.warn("session log: failed to create '{s}': {t}", .{ session_path, e });
            self.write_failed = true;
            return false;
        };
        self.path_len = session_path.len;

        std.debug.assert(self.file != null);
        std.debug.assert(!self.write_failed);
        return true;
    }

    fn writeLineIn(
        self: *SessionLog,
        dir: std.Io.Dir,
        io: std.Io,
        seq: u64,
        role: []const u8,
        text: []const u8,
        attached_file: ?[]const u8,
    ) void {
        if (!self.ensureOpen(dir, io)) return;
        std.debug.assert(self.file != null);
        std.debug.assert(role.len > 0);

        var write_buffer: [LINE_BUFFER_LEN]u8 = undefined;
        var file_writer = self.file.?.writerStreaming(io, &write_buffer);
        writeJsonLine(&file_writer.interface, seq, role, text, attached_file) catch |e| {
            log.warn("session log: write failed: {t}", .{e});
            self.write_failed = true;
        };
    }

    /// Summary counterpart to `writeLineIn`. Kept as its own function
    /// rather than folded into `writeLineIn` behind a role/type flag: the
    /// two line shapes share no fields beyond `seq` and `text`, and a
    /// single formatter branching on which of `role` or `covers` is
    /// meaningful would be harder to read than two flat ones.
    fn writeSummaryLineIn(
        self: *SessionLog,
        dir: std.Io.Dir,
        io: std.Io,
        seq: u64,
        covers: u64,
        text: []const u8,
    ) void {
        if (!self.ensureOpen(dir, io)) return;
        std.debug.assert(self.file != null);
        std.debug.assert(text.len > 0);

        var write_buffer: [LINE_BUFFER_LEN]u8 = undefined;
        var file_writer = self.file.?.writerStreaming(io, &write_buffer);
        writeSummaryJsonLine(&file_writer.interface, seq, covers, text) catch |e| {
            log.warn("session log: summary write failed: {t}", .{e});
            self.write_failed = true;
        };
    }
};

// =============================================================================
// Session history listing
// =============================================================================
//
// Reading side of the format documented at the top of this file: turns the
// `sessions/*.jsonl` directory back into a list a history UI can render.
// Deliberately shallow — it only decodes what the filename already encodes
// (`unix_seconds`), not the JSONL contents, so this stays a directory
// listing plus a sort rather than a second JSON reader to keep in sync with
// `writeJsonLine`.

pub const MAX_SESSION_ENTRIES: usize = 200;

pub const SessionEntry = struct {
    unix_seconds: i64 = 0,
};

/// Scans `sessions/` under `parent_dir` (normally `Io.Dir.cwd()`) and fills
/// `out` with one entry per `*.jsonl` file found, newest first. Returns the
/// number of entries written.
///
/// Best-effort, matching this module's write-side discipline: a missing or
/// unreadable directory yields zero entries rather than an error, since a
/// history panel has nothing actionable to do with a filesystem failure.
pub fn listSessions(parent_dir: std.Io.Dir, io: std.Io, out: *[MAX_SESSION_ENTRIES]SessionEntry) usize {
    std.debug.assert(out.len == MAX_SESSION_ENTRIES);

    var dir = parent_dir.openDir(io, SESSION_DIR, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var count: usize = 0;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (count >= MAX_SESSION_ENTRIES) break;

        const seconds = parseSessionSeconds(entry.name) orelse continue;
        out[count] = .{ .unix_seconds = seconds };
        count += 1;
    }
    std.debug.assert(count <= MAX_SESSION_ENTRIES);

    sortNewestFirst(out[0..count]);
    return count;
}

fn sortNewestFirst(entries: []SessionEntry) void {
    std.sort.insertion(SessionEntry, entries, {}, struct {
        fn lessThan(_: void, a: SessionEntry, b: SessionEntry) bool {
            return a.unix_seconds > b.unix_seconds;
        }
    }.lessThan);
}

/// Parses a `sessions/` directory entry's filename (e.g. `"1735300000.jsonl"`)
/// back into the seconds it encodes. Returns null for anything that doesn't
/// match — non-session files that might share the directory, or a name this
/// version doesn't recognize.
fn parseSessionSeconds(name: []const u8) ?i64 {
    const suffix = ".jsonl";
    if (!std.mem.endsWith(u8, name, suffix)) return null;
    const digits = name[0 .. name.len - suffix.len];
    if (digits.len == 0) return null;
    return std.fmt.parseInt(i64, digits, 10) catch null;
}

// =============================================================================
// Restoring a session's messages
// =============================================================================
//
// The counterpart to `logUser`/`logAssistant`: turns a `sessions/*.jsonl`
// file back into the message lines it recorded, oldest first. Unlike
// `listSessions`, this does read the JSONL contents — but only to hand each
// line's fields to a caller-supplied callback, never to build UI state
// itself (that's `AppState.loadSession`'s job, mirroring how this module
// never touches `AppState.messages` on the write side either).

/// Read cap for a single session file. A session grows at human turn rate
/// (one line per send/reply), so this bounds a pathological or corrupted
/// file rather than any realistic conversation.
const MAX_SESSION_FILE_BYTES: usize = 8 * 1024 * 1024;

/// Role of a restored message line — a narrower enum than
/// `AppState.MessageRole` since `.system` is never logged (see this file's
/// top-level doc comment).
pub const LoadedRole = enum { user, assistant };

/// One parsed conversation turn.
///
/// `text` and `attached_file` are borrowed from a buffer freed when
/// `loadSessionLines` returns — the callback must copy anything it needs
/// to keep past that point. Same for `LoadedSummary.text`.
pub const LoadedMessage = struct {
    seq: u64,
    role: LoadedRole,
    text: []const u8,
    attached_file: ?[]const u8,
};

/// One parsed compaction summary (see `SessionLog.logSummary`).
pub const LoadedSummary = struct {
    seq: u64,
    covers: u64,
    text: []const u8,
};

/// A recognized line, handed to `loadSessionLines`'s callback. A union
/// rather than a struct with optional halves so a callback that only
/// cares about turns can `switch` and ignore the rest, without having to
/// reason about which field combinations are possible.
pub const LoadedLine = union(enum) {
    message: LoadedMessage,
    summary: LoadedSummary,
};

/// Reads `sessions/{unix_seconds}.jsonl` and invokes `callback` once per
/// recognized line, oldest first — message turns and compaction summaries
/// alike, interleaved in the order they were written. Lines this version
/// doesn't recognize are silently skipped rather than aborting the
/// restore, so a file written by a newer build still replays its turns.
///
/// Best-effort, matching `listSessions`: a missing file, an oversized file
/// (see `MAX_SESSION_FILE_BYTES`), or a malformed line yields fewer
/// callbacks rather than an error — a history panel has nothing actionable
/// to do with a restore failure.
pub fn loadSessionLines(
    parent_dir: std.Io.Dir,
    io: std.Io,
    gpa: std.mem.Allocator,
    unix_seconds: i64,
    context: anytype,
    comptime callback: fn (@TypeOf(context), LoadedLine) void,
) void {
    std.debug.assert(unix_seconds > 0);

    var path_buf: [SESSION_PATH_MAX_LEN]u8 = undefined;
    const session_path = std.fmt.bufPrint(&path_buf, SESSION_DIR ++ "/{d}.jsonl", .{unix_seconds}) catch |e| {
        log.warn("session log: path formatting failed during restore: {t}", .{e});
        return;
    };

    const file = parent_dir.openFile(io, session_path, .{}) catch |e| {
        log.warn("session log: failed to open '{s}' for restore: {t}", .{ session_path, e });
        return;
    };
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const content = file_reader.interface.allocRemaining(gpa, std.Io.Limit.limited(MAX_SESSION_FILE_BYTES)) catch |e| {
        log.warn("session log: failed to read '{s}' for restore: {t}", .{ session_path, e });
        return;
    };
    defer gpa.free(content);
    std.debug.assert(content.len <= MAX_SESSION_FILE_BYTES);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        dispatchLine(gpa, line, context, callback);
    }
}

/// Parses one JSONL line and, if it is a shape this version recognizes,
/// forwards it to `callback`. Split out of `loadSessionLines` so the
/// per-line parse (and its `defer parsed.deinit()`) doesn't accumulate
/// across iterations.
fn dispatchLine(
    gpa: std.mem.Allocator,
    line: []const u8,
    context: anytype,
    comptime callback: fn (@TypeOf(context), LoadedLine) void,
) void {
    std.debug.assert(line.len > 0);

    const LogLine = struct {
        seq: u64,
        role: ?[]const u8 = null,
        type: ?[]const u8 = null,
        covers: ?u64 = null,
        text: ?[]const u8 = null,
        file: ?[]const u8 = null,
    };

    const parsed = std.json.parseFromSlice(LogLine, gpa, line, .{ .ignore_unknown_fields = true }) catch |e| {
        log.warn("session log: skipping unparseable line during restore: {t}", .{e});
        return;
    };
    defer parsed.deinit();

    // Every recognized shape carries text; nothing downstream can use a
    // line without it.
    const text = parsed.value.text orelse return;

    if (parsed.value.type) |type_str| {
        if (!std.mem.eql(u8, type_str, "summary")) return;
        const covers = parsed.value.covers orelse return;
        callback(context, .{ .summary = .{
            .seq = parsed.value.seq,
            .covers = covers,
            .text = text,
        } });
        return;
    }

    const role_str = parsed.value.role orelse return;
    std.debug.assert(role_str.len > 0);

    const role: LoadedRole = if (std.mem.eql(u8, role_str, "user"))
        .user
    else if (std.mem.eql(u8, role_str, "assistant"))
        .assistant
    else
        return;

    callback(context, .{ .message = .{
        .seq = parsed.value.seq,
        .role = role,
        .text = text,
        .attached_file = parsed.value.file,
    } });
}

/// Pure line formatter: one JSON object plus a trailing newline. Kept
/// free of `SessionLog` state so it can be exercised directly against an
/// in-memory `Io.Writer.fixed` in tests, with no filesystem involved.
fn writeJsonLine(
    writer: *std.Io.Writer,
    seq: u64,
    role: []const u8,
    text: []const u8,
    attached_file: ?[]const u8,
) !void {
    std.debug.assert(role.len > 0);
    if (attached_file) |name| std.debug.assert(name.len > 0);

    try writer.print("{{\"seq\":{d},\"role\":\"{s}\",\"text\":\"", .{ seq, role });
    try anthropic.writeJsonEscapedString(writer, text);
    try writer.writeByte('"');

    if (attached_file) |name| {
        try writer.writeAll(",\"file\":\"");
        try anthropic.writeJsonEscapedString(writer, name);
        try writer.writeByte('"');
    }

    try writer.writeAll("}\n");
    try writer.flush();
}

/// Summary counterpart to `writeJsonLine`. Emits no `role`, which is what
/// makes the two shapes distinguishable on the read side without a
/// version field — see `dispatchLine`.
fn writeSummaryJsonLine(
    writer: *std.Io.Writer,
    seq: u64,
    covers: u64,
    text: []const u8,
) !void {
    std.debug.assert(text.len > 0);
    std.debug.assert(covers <= seq);

    try writer.print("{{\"seq\":{d},\"type\":\"summary\",\"covers\":{d},\"text\":\"", .{ seq, covers });
    try anthropic.writeJsonEscapedString(writer, text);
    try writer.writeAll("\"}\n");
    try writer.flush();
}

// =============================================================================
// Tests
// =============================================================================

test "writeJsonLine formats a user turn without an attachment" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeJsonLine(&w, 0, "user", "hello", null);
    try std.testing.expectEqualStrings(
        "{\"seq\":0,\"role\":\"user\",\"text\":\"hello\"}\n",
        w.buffered(),
    );
}

test "writeJsonLine formats a user turn with an attachment" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeJsonLine(&w, 3, "user", "see attached", "notes.txt");
    try std.testing.expectEqualStrings(
        "{\"seq\":3,\"role\":\"user\",\"text\":\"see attached\",\"file\":\"notes.txt\"}\n",
        w.buffered(),
    );
}

test "writeJsonLine escapes quotes, backslashes, and newlines in text" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeJsonLine(&w, 7, "assistant", "line one\nline \"two\"\\three", null);
    try std.testing.expectEqualStrings(
        "{\"seq\":7,\"role\":\"assistant\",\"text\":\"line one\\nline \\\"two\\\"\\\\three\"}\n",
        w.buffered(),
    );
}

test "SessionLog appends one line per write to a lazily-created file" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var session_log = SessionLog{};
    session_log.writeLineIn(tmp_dir.dir, io, 0, "user", "hello", null);
    session_log.writeLineIn(tmp_dir.dir, io, 1, "assistant", "hi there", null);

    try std.testing.expect(!session_log.write_failed);
    try std.testing.expect(session_log.file != null);

    var read_buf: [256]u8 = undefined;
    const n = try session_log.file.?.readPositionalAll(io, &read_buf, 0);
    const contents = read_buf[0..n];

    var lines = std.mem.splitScalar(u8, contents, '\n');
    try std.testing.expectEqualStrings(
        "{\"seq\":0,\"role\":\"user\",\"text\":\"hello\"}",
        lines.next().?,
    );
    try std.testing.expectEqualStrings(
        "{\"seq\":1,\"role\":\"assistant\",\"text\":\"hi there\"}",
        lines.next().?,
    );
    try std.testing.expectEqualStrings("", lines.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), lines.next());
}

test "SessionLog reuses the same file across writes instead of truncating" {
    // If ensureOpen re-created the file on every write, the first line
    // would be lost. Guards that regression directly.
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var session_log = SessionLog{};
    var i: u64 = 0;
    while (i < 20) : (i += 1) {
        session_log.writeLineIn(tmp_dir.dir, io, i, "user", "turn", null);
    }
    try std.testing.expect(!session_log.write_failed);

    var read_buf: [1024]u8 = undefined;
    const n = try session_log.file.?.readPositionalAll(io, &read_buf, 0);
    const contents = read_buf[0..n];

    var line_count: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 20), line_count);
}

test "SessionLog.startNew closes the open file and lets the next write open a fresh one" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var session_log = SessionLog{};
    session_log.writeLineIn(tmp_dir.dir, io, 0, "user", "first conversation", null);
    try std.testing.expect(!session_log.write_failed);
    try std.testing.expect(session_log.file != null);
    const first_path_len = session_log.path_len;
    try std.testing.expect(first_path_len > 0);

    session_log.startNew(io);
    try std.testing.expectEqual(@as(?std.Io.File, null), session_log.file);
    try std.testing.expectEqual(@as(usize, 0), session_log.path_len);
    try std.testing.expectEqual(@as(?[]const u8, null), session_log.path());

    // The next write must lazily reopen rather than staying wedged closed.
    session_log.writeLineIn(tmp_dir.dir, io, 0, "user", "second conversation", null);
    try std.testing.expect(!session_log.write_failed);
    try std.testing.expect(session_log.file != null);
}

test "SessionLog sets write_failed when the sessions directory cannot be created" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Occupy the "sessions" path with a plain file so createDirPath fails
    // with a deterministic, cross-platform error instead of relying on
    // permission bits.
    var blocker = try tmp_dir.dir.createFile(io, SESSION_DIR, .{});
    blocker.close(io);

    var session_log = SessionLog{};
    session_log.writeLineIn(tmp_dir.dir, io, 0, "user", "hello", null);

    try std.testing.expect(session_log.write_failed);
    try std.testing.expect(session_log.file == null);

    // The latch is one-shot: a second call must not retry (and thus not
    // clear write_failed even though nothing here would make the retry
    // succeed).
    session_log.writeLineIn(tmp_dir.dir, io, 1, "user", "again", null);
    try std.testing.expect(session_log.write_failed);
}

test "listSessions returns zero entries when the sessions directory is missing" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var entries: [MAX_SESSION_ENTRIES]SessionEntry = undefined;
    const count = listSessions(tmp_dir.dir, io, &entries);

    try std.testing.expectEqual(@as(usize, 0), count);
}

test "listSessions returns session files newest first" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(io, SESSION_DIR);
    var sessions_dir = try tmp_dir.dir.openDir(io, SESSION_DIR, .{});
    defer sessions_dir.close(io);

    for ([_]i64{ 100, 300, 200 }) |seconds| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{d}.jsonl", .{seconds});
        var f = try sessions_dir.createFile(io, name, .{});
        f.close(io);
    }

    var entries: [MAX_SESSION_ENTRIES]SessionEntry = undefined;
    const count = listSessions(tmp_dir.dir, io, &entries);

    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(@as(i64, 300), entries[0].unix_seconds);
    try std.testing.expectEqual(@as(i64, 200), entries[1].unix_seconds);
    try std.testing.expectEqual(@as(i64, 100), entries[2].unix_seconds);
}

test "listSessions ignores files that don't match the session naming scheme" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(io, SESSION_DIR);
    var sessions_dir = try tmp_dir.dir.openDir(io, SESSION_DIR, .{});
    defer sessions_dir.close(io);

    for ([_][]const u8{ "notes.txt", "abc.jsonl", "42.jsonl" }) |name| {
        var f = try sessions_dir.createFile(io, name, .{});
        f.close(io);
    }

    var entries: [MAX_SESSION_ENTRIES]SessionEntry = undefined;
    const count = listSessions(tmp_dir.dir, io, &entries);

    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(i64, 42), entries[0].unix_seconds);
}

test "loadSessionLines invokes callback once per message line, oldest first" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var session_log = SessionLog{};
    session_log.writeLineIn(tmp_dir.dir, io, 0, "user", "hello", null);
    session_log.writeLineIn(tmp_dir.dir, io, 1, "assistant", "hi there", null);
    session_log.writeLineIn(tmp_dir.dir, io, 2, "user", "see attached", "notes.txt");
    const seconds = session_log.currentSeconds() orelse return error.TestUnexpectedResult;

    const Ctx = struct {
        step: usize = 0,
        ok: bool = true,

        fn onLine(self: *@This(), line: LoadedLine) void {
            const msg = switch (line) {
                .message => |m| m,
                .summary => {
                    self.ok = false;
                    return;
                },
            };
            switch (self.step) {
                0 => {
                    if (msg.seq != 0) self.ok = false;
                    if (msg.role != .user) self.ok = false;
                    if (!std.mem.eql(u8, msg.text, "hello")) self.ok = false;
                    if (msg.attached_file != null) self.ok = false;
                },
                1 => {
                    if (msg.seq != 1) self.ok = false;
                    if (msg.role != .assistant) self.ok = false;
                    if (!std.mem.eql(u8, msg.text, "hi there")) self.ok = false;
                    if (msg.attached_file != null) self.ok = false;
                },
                2 => {
                    if (msg.seq != 2) self.ok = false;
                    if (msg.role != .user) self.ok = false;
                    if (!std.mem.eql(u8, msg.text, "see attached")) self.ok = false;
                    if (msg.attached_file == null or !std.mem.eql(u8, msg.attached_file.?, "notes.txt")) self.ok = false;
                },
                else => self.ok = false,
            }
            self.step += 1;
        }
    };
    var ctx = Ctx{};
    loadSessionLines(tmp_dir.dir, io, std.testing.allocator, seconds, &ctx, Ctx.onLine);

    try std.testing.expect(ctx.ok);
    try std.testing.expectEqual(@as(usize, 3), ctx.step);
}

test "loadSessionLines skips lines whose role and type are both unrecognized" {
    // A line from a hypothetical newer build must not abort the restore or
    // get misparsed as a turn — the surrounding real turns still replay.
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(io, SESSION_DIR);
    var sessions_dir = try tmp_dir.dir.openDir(io, SESSION_DIR, .{});
    defer sessions_dir.close(io);

    var f = try sessions_dir.createFile(io, "999.jsonl", .{});
    defer f.close(io);
    var write_buf: [256]u8 = undefined;
    var fw = f.writerStreaming(io, &write_buf);
    try fw.interface.writeAll("{\"seq\":0,\"type\":\"telemetry\",\"text\":\"unknown shape\"}\n");
    try fw.interface.writeAll("{\"seq\":1,\"role\":\"moderator\",\"text\":\"unknown role\"}\n");
    try fw.interface.writeAll("{\"seq\":2,\"role\":\"user\",\"text\":\"real turn\"}\n");
    try fw.interface.flush();

    const Ctx = struct {
        count: usize = 0,
        last_seq: u64 = 0,

        fn onLine(self: *@This(), line: LoadedLine) void {
            self.count += 1;
            self.last_seq = switch (line) {
                .message => |m| m.seq,
                .summary => |s| s.seq,
            };
        }
    };
    var ctx = Ctx{};
    loadSessionLines(tmp_dir.dir, io, std.testing.allocator, 999, &ctx, Ctx.onLine);

    try std.testing.expectEqual(@as(usize, 1), ctx.count);
    try std.testing.expectEqual(@as(u64, 2), ctx.last_seq);
}

test "writeSummaryJsonLine formats a summary line with no role field" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeSummaryJsonLine(&w, 8, 8, "user asked about ring buffers");
    try std.testing.expectEqualStrings(
        "{\"seq\":8,\"type\":\"summary\",\"covers\":8,\"text\":\"user asked about ring buffers\"}\n",
        w.buffered(),
    );
}

test "a logged summary round-trips through loadSessionLines" {
    // The whole point of persisting the summary: a restored session adopts
    // the cut instead of re-paying for summarization. Writes an interleaved
    // transcript and asserts both shapes come back in write order.
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var session_log = SessionLog{};
    session_log.writeLineIn(tmp_dir.dir, io, 0, "user", "hello", null);
    session_log.writeSummaryLineIn(tmp_dir.dir, io, 1, 1, "greeting exchanged");
    session_log.writeLineIn(tmp_dir.dir, io, 1, "assistant", "hi there", null);
    try std.testing.expect(!session_log.write_failed);
    const seconds = session_log.currentSeconds() orelse return error.TestUnexpectedResult;

    const Ctx = struct {
        step: usize = 0,
        ok: bool = true,

        fn onLine(self: *@This(), line: LoadedLine) void {
            switch (self.step) {
                0 => switch (line) {
                    .message => |m| {
                        if (m.role != .user) self.ok = false;
                    },
                    .summary => self.ok = false,
                },
                1 => switch (line) {
                    .summary => |s| {
                        if (s.seq != 1) self.ok = false;
                        if (s.covers != 1) self.ok = false;
                        if (!std.mem.eql(u8, s.text, "greeting exchanged")) self.ok = false;
                    },
                    .message => self.ok = false,
                },
                2 => switch (line) {
                    .message => |m| {
                        if (m.role != .assistant) self.ok = false;
                    },
                    .summary => self.ok = false,
                },
                else => self.ok = false,
            }
            self.step += 1;
        }
    };
    var ctx = Ctx{};
    loadSessionLines(tmp_dir.dir, io, std.testing.allocator, seconds, &ctx, Ctx.onLine);

    try std.testing.expect(ctx.ok);
    try std.testing.expectEqual(@as(usize, 3), ctx.step);
}

test "loadSessionLines is a no-op when the session file doesn't exist" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const Ctx = struct {
        count: usize = 0,
        fn onLine(self: *@This(), _: LoadedLine) void {
            self.count += 1;
        }
    };
    var ctx = Ctx{};
    loadSessionLines(tmp_dir.dir, io, std.testing.allocator, 123456, &ctx, Ctx.onLine);

    try std.testing.expectEqual(@as(usize, 0), ctx.count);
}

test "currentSeconds is null before the first write and parses the file's own name after" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var session_log = SessionLog{};
    try std.testing.expectEqual(@as(?i64, null), session_log.currentSeconds());
    try std.testing.expectEqual(@as(?[]const u8, null), session_log.path());

    session_log.writeLineIn(tmp_dir.dir, io, 0, "user", "hello", null);
    try std.testing.expect(!session_log.write_failed);

    const seconds = session_log.currentSeconds() orelse return error.TestUnexpectedResult;
    try std.testing.expect(seconds > 0);
    try std.testing.expect(std.mem.endsWith(u8, session_log.path().?, ".jsonl"));
}
