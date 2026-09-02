//! Application State Management for ChatZig
//!
//! Handles:
//! - Message history
//! - Input text binding
//! - File attachments via native file dialog
//! - Async API communication via `std.Io.Group` + `Io.Queue` (Zig 0.16)
//! - Result delivery: the render loop drains the queue each frame
//!
//! Zig 0.16 migration notes:
//!   - Replaced `std.Thread.spawn` + `dispatchOnMainThread` with
//!     `Io.async` + `Io.Queue(WorkerResult)`. Workers push typed results
//!     into the queue; the render loop drains them without blocking.
//!     This eliminates the per-request heap allocations (Task, Context)
//!     and the two-hop trampoline (bg → dispatch → main) in favour of
//!     one bounded channel.
//!   - Filesystem reads, HTTP, TLS, and env lookups all thread through the
//!     single `std.Io` instance published by `main` (via `std.process.Init`).
//!   - The in-flight HTTP worker is tracked as a `std.Io.Future(void)` so
//!     the user-facing Stop button can cancel exactly one request without
//!     tearing down anything else. Cancellation propagates through the
//!     next `Io` call inside the worker (the SSE read or a `putOne`),
//!     which returns `error.Canceled` and unwinds cleanly.

const std = @import("std");
const log = std.log.scoped(.chatzig);
const gooey = @import("gooey");
const file_dialog = gooey.file_dialog;

const anthropic = @import("http/anthropic.zig");
const openai = @import("http/openai.zig");
const audio = @import("audio/mod.zig");
const compaction = @import("compaction.zig");
const session_log_mod = @import("session_log.zig");
const SessionLog = session_log_mod.SessionLog;
const VirtualListState = gooey.widgets.VirtualListState;
const UniformListState = gooey.widgets.UniformListState;
const TextAreaState = gooey.widgets.TextAreaState;

// Reach back into `main` for the process-global Io + environ published from
// `std.process.Init`. `AppState.init` needs both but only receives a `*Cx`,
// so rather than thread them through every call we publish them on main.
const main_mod = @import("main.zig");

// =============================================================================
// Constants (CLAUDE rule #4: put a limit on everything)
// =============================================================================

pub const MAX_MESSAGES: usize = 256;
pub const MAX_MESSAGE_LEN: usize = 32768;
pub const MAX_INPUT_LEN: usize = 4096;
pub const DEFAULT_MESSAGE_HEIGHT: f32 = 60.0;
pub const MAX_RESPONSE_LEN: usize = 32768;
pub const MAX_FILE_PATH_LEN: usize = 512;
pub const MAX_ATTACHED_FILENAME_LEN: usize = 128;

/// Max worker results buffered between render frames. With `is_loading`
/// guarding single-flight requests, only one result is ever in flight at a
/// time; 8 is generous headroom for future parallelism (e.g. background
/// thumbnail fetch) and keeps the backing array small
/// (`8 * @sizeOf(WorkerResult)`).
pub const RESULT_QUEUE_CAPACITY: usize = 8;
pub const RECORDING_PATH_MAX_LEN: usize = 128;

/// Row height for the history panel's uniform list (see `HistoryPanel`).
/// Lives here, next to `DEFAULT_MESSAGE_HEIGHT`, because both size a list
/// state that `AppState` owns and must initialize up front.
pub const HISTORY_ROW_HEIGHT: f32 = 56.0;
pub const HISTORY_ROW_GAP: f32 = 8.0;

const CHAT_SYSTEM_INSTRUCTION =
    "Respond in plain text only. Do not use Markdown or other markup. " ++
    "Do not use headings, bullet points, numbered lists, emphasis markers, backticks, code fences, or Markdown links. " ++
    "Keep responses readable with plain sentences, line breaks, and indentation only.";

const DEFAULT_DEVICE_MARKER = "\xe2\x97\x8f ";

// =============================================================================
// Compaction (see docs/CHAT_COMPACTION.md)
// =============================================================================
//
// Compaction never mutates `messages`. The ring stays the UI transcript;
// the summary is a derived cache that only affects *request assembly*, so
// `streaming_message_idx`, every `cached_height`, and `list_state`'s item
// count all stay valid across a compaction. Failure is therefore free:
// leave `summary_len` alone and the next request is simply the
// uncompacted one.
//
// The tuning constants, prompts, and cut arithmetic live in
// `compaction.zig` so they can be unit-tested without pulling gooey into
// the test binary; what stays here is the part that needs the ring.

pub const MAX_SUMMARY_LEN = compaction.MAX_SUMMARY_LEN;

/// Longest banner `AppState.compactionBanner` can format — the template
/// plus a u64 rendered in full.
const COMPACTION_BANNER_MAX_LEN: usize = 96;

pub const MicrophoneState = struct {
    devices: audio.InputDeviceList = .{},
    labels: [audio.MAX_INPUT_DEVICES][]const u8 = undefined,
    label_buffers: [audio.MAX_INPUT_DEVICES][DEFAULT_DEVICE_MARKER.len + audio.DEVICE_NAME_MAX_LEN]u8 = undefined,
    selected: ?usize = null,

    pub fn refresh(self: *MicrophoneState) void {
        self.devices = audio.listInputDevices();
        for (self.devices.slice(), 0..) |*device, device_index| {
            const is_default = self.devices.default_index != null and self.devices.default_index.? == device_index;
            if (is_default) {
                self.labels[device_index] = std.fmt.bufPrint(
                    &self.label_buffers[device_index],
                    "{s}{s}",
                    .{ DEFAULT_DEVICE_MARKER, device.name() },
                ) catch device.name();
            } else {
                self.labels[device_index] = device.name();
            }
        }
        self.selected = self.devices.default_index;

        std.debug.assert(self.devices.count <= audio.MAX_INPUT_DEVICES);
        if (self.selected) |selected| std.debug.assert(selected < self.devices.count);
    }

    pub fn options(self: *const MicrophoneState) []const []const u8 {
        std.debug.assert(self.devices.count <= audio.MAX_INPUT_DEVICES);
        std.debug.assert(self.labels.len == audio.MAX_INPUT_DEVICES);
        return self.labels[0..self.devices.count];
    }
};

pub const RecordingState = struct {
    active: bool = false,
    path_buffer: [RECORDING_PATH_MAX_LEN]u8 = undefined,
    path_len: usize = 0,
    last_error: ?audio.RecorderError = null,

    pub fn path(self: *const RecordingState) []const u8 {
        std.debug.assert(self.path_len <= RECORDING_PATH_MAX_LEN);
        std.debug.assert(self.path_buffer.len == RECORDING_PATH_MAX_LEN);
        return self.path_buffer[0..self.path_len];
    }

    fn preparePath(self: *RecordingState, io: std.Io) bool {
        std.Io.Dir.cwd().createDirPath(io, "recordings") catch return false;
        const seconds = std.Io.Timestamp.now(io, .real).toSeconds();
        const output_path = std.fmt.bufPrint(&self.path_buffer, "recordings/{d}.wav", .{seconds}) catch return false;
        self.path_len = output_path.len;

        std.debug.assert(self.path_len > 0);
        std.debug.assert(self.path_len <= RECORDING_PATH_MAX_LEN);
        return true;
    }
};

// =============================================================================
// Model Selection
// =============================================================================

/// Which HTTP client (`AppState.http_client` vs `.openai_client`) and wire
/// format a `Model` uses. Chat now spans both providers, so
/// `buildAnthropicChatRequest` / `buildOpenAIChatRequest` and `sendMessage`
/// branch on this instead of assuming Anthropic.
pub const ModelProvider = enum(u8) {
    anthropic,
    openai,
};

pub const Model = enum(u8) {
    haiku,
    sonnet,
    opus,
    gpt_sol,
    gpt_terra,
    gpt_luna,

    pub const display_names = [_][]const u8{
        "Claude 4.5 Haiku",
        "Claude Sonnet 5",
        "Claude Opus 5",
        "GPT-5.6 Sol",
        "GPT-5.6 Terra",
        "GPT-5.6 Luna",
    };

    pub const api_names = [_][]const u8{
        "claude-haiku-4-5-20251001",
        "claude-sonnet-5",
        "claude-opus-5",
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
    };

    /// Parallel array to `display_names`/`api_names` (table-driven, CLAUDE
    /// rule #8) rather than a per-variant switch in `provider()` — keeping
    /// all three arrays side by side makes it visually obvious that adding
    /// a model means updating all three.
    pub const providers = [_]ModelProvider{
        .anthropic, .anthropic, .anthropic,
        .openai,    .openai,    .openai,
    };

    /// Input context window, in tokens — the denominator
    /// `compaction.TRIGGER_RATIO` is applied to.
    ///
    /// Distinct from `anthropic.MAX_TOKENS`, which caps *output* length.
    /// The two are easy to confuse at a call site, hence the deliberately
    /// different names.
    ///
    /// Conservative by design: this only decides *when* compaction fires,
    /// and under-stating the window means compacting slightly early, which
    /// is the harmless direction to be wrong in.
    pub const context_window_tokens = [_]u32{
        200_000, 200_000, 200_000,
        272_000, 272_000, 272_000,
    };

    pub fn displayName(self: Model) []const u8 {
        return display_names[@intFromEnum(self)];
    }

    pub fn apiName(self: Model) []const u8 {
        return api_names[@intFromEnum(self)];
    }

    pub fn provider(self: Model) ModelProvider {
        return providers[@intFromEnum(self)];
    }

    pub fn contextWindowTokens(self: Model) u32 {
        return context_window_tokens[@intFromEnum(self)];
    }
};

pub const MODEL_COUNT: usize = 6;

comptime {
    std.debug.assert(Model.display_names.len == MODEL_COUNT);
    std.debug.assert(Model.api_names.len == MODEL_COUNT);
    std.debug.assert(Model.providers.len == MODEL_COUNT);
    std.debug.assert(Model.context_window_tokens.len == MODEL_COUNT);
}

// =============================================================================
// Dictation Model Selection (OpenAI transcription)
// =============================================================================

pub const DictationModel = enum(u8) {
    gpt4o_mini_transcribe,
    gpt4o_transcribe,

    pub const display_names = [_][]const u8{
        "GPT-4o mini Transcribe",
        "GPT-4o Transcribe",
    };

    pub const api_names = [_][]const u8{
        "gpt-4o-mini-transcribe",
        "gpt-4o-transcribe",
    };

    pub fn displayName(self: DictationModel) []const u8 {
        return display_names[@intFromEnum(self)];
    }

    pub fn apiName(self: DictationModel) []const u8 {
        return api_names[@intFromEnum(self)];
    }
};

pub const DICTATION_MODEL_COUNT: usize = 2;

// The default dictation model (index 0) must always match OpenAI's
// hardcoded fallback in `openai.zig` — otherwise the Settings panel and
// the client's own default would silently disagree about what "default"
// means.
comptime {
    std.debug.assert(std.mem.eql(u8, DictationModel.api_names[0], openai.DEFAULT_TRANSCRIBE_MODEL));
}

// =============================================================================
// Message Types
// =============================================================================

pub const MessageRole = enum {
    user,
    assistant,
    system,
};

pub const Message = struct {
    role: MessageRole,
    content: [MAX_MESSAGE_LEN]u8 = undefined,
    content_len: usize = 0,
    /// Optional attached file name (just the filename, not full path).
    attached_file: [MAX_ATTACHED_FILENAME_LEN]u8 = undefined,
    attached_file_len: usize = 0,
    cached_height: f32 = 0.0,

    pub fn getText(self: *const Message) []const u8 {
        return self.content[0..self.content_len];
    }

    pub fn hasAttachment(self: *const Message) bool {
        return self.attached_file_len > 0;
    }

    pub fn getAttachedFileName(self: *const Message) []const u8 {
        return self.attached_file[0..self.attached_file_len];
    }

    pub fn user(text: []const u8) Message {
        var msg = Message{ .role = .user };
        const len = @min(text.len, MAX_MESSAGE_LEN);
        @memcpy(msg.content[0..len], text[0..len]);
        msg.content_len = len;
        msg.cached_height = 0.0;
        return msg;
    }

    pub fn userWithFile(text: []const u8, filename: []const u8) Message {
        var msg = Message{ .role = .user };
        const len = @min(text.len, MAX_MESSAGE_LEN);
        @memcpy(msg.content[0..len], text[0..len]);
        msg.content_len = len;
        const fname_len = @min(filename.len, MAX_ATTACHED_FILENAME_LEN);
        @memcpy(msg.attached_file[0..fname_len], filename[0..fname_len]);
        msg.attached_file_len = fname_len;
        msg.cached_height = 0.0;
        return msg;
    }

    pub fn assistant(text: []const u8) Message {
        var msg = Message{ .role = .assistant };
        const len = @min(text.len, MAX_MESSAGE_LEN);
        @memcpy(msg.content[0..len], text[0..len]);
        msg.content_len = len;
        msg.cached_height = 0.0;
        return msg;
    }
};

// =============================================================================
// Worker Result (delivered via std.Io.Queue from async tasks)
// =============================================================================

pub const SuccessResult = struct {
    response_len: usize,
};

pub const ErrorResult = struct {
    /// Static lifetime — either a compile-time string or a pointer into a
    /// long-lived owned buffer on `anthropic.ChatResult`. The queue never copies
    /// the bytes; it only carries the slice header.
    message: []const u8,
};

/// Incremental delta delivered while a streaming request is in flight.
///
/// The worker fiber appends bytes to `pending_response_buf` and bumps
/// `pending_response_len`, then publishes the new high-water mark via this
/// result. The render thread copies `pending_response_buf[0..cumulative_len]`
/// into the streaming assistant message.
///
/// Why a high-water mark instead of just the new chunk? Two reasons:
///   1. Idempotent — if the queue ever delivered the same delta twice (it
///      shouldn't, but invariants are cheaper than debugging), applying the
///      same `cumulative_len` twice is a no-op rather than a duplicate
///      paste.
///   2. Self-synchronizing — the render thread always knows the exact slice
///      to read, with no need to track a separate "applied so far" counter.
pub const DeltaResult = struct {
    /// New total length of `pending_response_buf` after this delta. Always
    /// strictly greater than the previous delta's `cumulative_len` (the
    /// worker only appends, never rewinds), and always `<= MAX_RESPONSE_LEN`.
    cumulative_len: u32,
};

/// Tagged union over every kind of worker outcome so a single `Io.Queue` can
/// carry chat results. The render loop switches on the tag and applies the
/// matching staging buffer.
///
/// Keep this small: it is copied into the queue's ring buffer by value.
///
/// Streaming flow: `chat_delta` may fire many times before exactly one of
/// `chat_success` / `chat_error` terminates the stream. Non-streaming
/// flow: `chat_delta` never fires.
pub const WorkerResult = union(enum) {
    chat_delta: DeltaResult,
    chat_success: SuccessResult,
    chat_error: ErrorResult,
    compaction_applied: CompactionResult,
    transcription_success: TranscriptionSuccessResult,
    transcription_error: TranscriptionErrorResult,
};

/// Published by the worker after it has summarized the older half of the
/// conversation, so the main thread — which owns the live `summary_*`
/// fields — can adopt the new cut. Same staging discipline as
/// `SuccessResult`: `summary_len` bounds a read of
/// `AppState.pending_summary_buf`.
///
/// Fires at most once per send, always *before* the `chat_delta` /
/// `chat_success` pair for that same send.
pub const CompactionResult = struct {
    summary_len: u32,
    /// New value for `AppState.summary_covers`: every message with a
    /// lower `seq` is now represented by the summary rather than sent
    /// verbatim. Strictly greater than the previous cut — the worker
    /// skips a compaction that would not advance it.
    ///
    /// This is the cut the worker *realized*, not the one
    /// `compaction.proposedCovers` asked for. The two differ because
    /// `retainedStart` snaps a cut forward onto a `.user` turn, so a
    /// summary typically swallows a message or two past the proposal;
    /// `planCompactionCut` converts that snapped boundary back into `seq`
    /// space so the sentence above is literally true.
    covers: u64,
};

/// Which prefix of history a request omits, and the summary standing in
/// for it. Passed explicitly to the request builders rather than read off
/// `AppState` because the worker may be using a summary it just computed
/// and staged, which the main thread has not adopted yet.
pub const CompactionView = struct {
    /// Empty when nothing has been compacted, in which case `covers` is 0
    /// and the builders send the whole ring.
    summary: []const u8,
    covers: u64,
};

/// `text_len` bounds a read of `AppState.pending_transcript_buf` — the
/// worker copies the transcript there (capped at `MAX_INPUT_LEN`) before
/// publishing this result, mirroring `SuccessResult.response_len`.
pub const TranscriptionSuccessResult = struct {
    text_len: u32,
};

pub const TranscriptionErrorResult = struct {
    message: []const u8, // static, never freed
};

// =============================================================================
// AppState
// =============================================================================

pub const AppState = struct {
    const Self = @This();

    // =========================================================================
    // Message History
    // =========================================================================
    messages: [MAX_MESSAGES]Message = undefined,
    message_head: usize = 0,
    message_count: usize = 0,
    /// Total number of messages ever added via `addMessage`, never reset
    /// and never wraps. Used as the `seq` in the on-disk session log —
    /// unlike a logical index into `messages`, it stays meaningful after
    /// the ring buffer has overwritten the message it refers to.
    messages_total: u64 = 0,

    /// Append-only JSONL transcript of the conversation, one file per app
    /// launch. Best-effort: see `session_log.zig` for the write-failure
    /// contract (`session_log.write_failed`).
    session_log: SessionLog = .{},

    // =========================================================================
    // Compaction state — a derived view, not a mutation of history
    // =========================================================================
    //
    // Owned by the main thread. The worker stages a candidate in
    // `pending_summary_buf` and publishes it as a `compaction_applied`
    // result; `applyCompactionApplied` copies it here. Nothing below ever
    // touches `messages`.

    summary_buf: [MAX_SUMMARY_LEN]u8 = undefined,
    summary_len: usize = 0,
    /// Value of `messages_total` at the compaction cut: the summary covers
    /// every message added before this point. Stored against the monotonic
    /// counter rather than a logical index because logical indices decay —
    /// once the ring overwrites, `getMessage(0)` means a different message
    /// than it did before.
    summary_covers: u64 = 0,

    /// Scratch for `compactionBanner` to format into. Rewritten each time
    /// the banner renders rather than kept in sync with `summary_covers`,
    /// so there is no second source of truth to go stale.
    compaction_banner_buf: [COMPACTION_BANNER_MAX_LEN]u8 = undefined,

    /// Past sessions found under `sessions/*.jsonl`, newest first. Populated
    /// by `refreshSessionHistory` when the history panel is opened rather
    /// than kept live, since the on-disk directory only changes on app
    /// launch (see `session_log.zig`'s "one file per launch" design).
    session_entries: [session_log_mod.MAX_SESSION_ENTRIES]session_log_mod.SessionEntry = undefined,
    session_entry_count: usize = 0,

    // =========================================================================
    // Input State
    // =========================================================================
    input_text: [MAX_INPUT_LEN]u8 = undefined,
    input_slice: []const u8 = "",

    // =========================================================================
    // UI State
    // =========================================================================
    list_state: VirtualListState = VirtualListState.initWithGap(0, DEFAULT_MESSAGE_HEIGHT, 8),
    /// Backs the history panel's session list (see `HistoryPanel`). Rows are
    /// uniform height, unlike `list_state`'s variable-height messages, so
    /// this uses `UniformListState` rather than a second `VirtualListState`.
    history_list_state: UniformListState = UniformListState.initWithGap(0, HISTORY_ROW_HEIGHT, HISTORY_ROW_GAP),
    is_loading: bool = false,
    has_api_key: bool = false,
    has_openai_api_key: bool = false,
    is_transcribing: bool = false,
    error_message: ?[]const u8 = null,
    dark_mode: bool = true, // Start in dark mode like the reference image.
    /// When true, the content area shows `SettingsPanel` (a full-length
    /// settings view) instead of `ContentArea`'s message list. Mutually
    /// exclusive with `history_expanded` — see `toggleSettings`.
    settings_expanded: bool = false,
    /// When true, the content area shows `HistoryPanel` (a full-length list
    /// of past sessions) instead of `ContentArea`'s message list. Mutually
    /// exclusive with `settings_expanded` — see `toggleHistory`.
    history_expanded: bool = false,

    selected_model: Model = .haiku,
    selected_dictation_model: DictationModel = .gpt4o_mini_transcribe,
    microphone: MicrophoneState = .{},
    recording: RecordingState = .{},

    // =========================================================================
    // File Attachment State
    // =========================================================================
    attached_file_path: [MAX_FILE_PATH_LEN]u8 = undefined,
    attached_file_path_len: usize = 0,
    has_attached_file: bool = false,

    // =========================================================================
    // HTTP Clients (borrow `std.Io` from main)
    // =========================================================================
    http_client: ?anthropic.AnthropicClient = null,
    openai_client: ?openai.OpenAIClient = null,

    // Transcript text staged by `transcriptionWorker`, capped at
    // `MAX_INPUT_LEN` since it flows straight into the chat input box.
    // Same threading discipline as the staging buffers below: written by
    // the worker before `putOne`, read by the render thread only after
    // the matching `WorkerResult` is drained.
    pending_transcript_buf: [MAX_INPUT_LEN]u8 = undefined,
    pending_transcript_len: usize = 0,
    pending_transcription: ?std.Io.Future(void) = null,

    // =========================================================================
    // Staging Buffers (written by worker, read by render after queue drain)
    // =========================================================================
    //
    // Threading invariant: these buffers are written ONLY by a worker fiber,
    // and ONLY before it calls `queue.putOne`. They are read ONLY by the
    // render thread, and ONLY after `cx.drainQueue` returns the matching
    // `WorkerResult`. The queue's internal synchronization provides the
    // happens-before edge that makes the writes visible.
    //
    // This is the same discipline as the pre-0.16 "TigersEye" pattern, but
    // without the dispatcher trampoline — the queue IS the synchronization.
    //
    // Streaming refinement: `pending_response_buf` is *append-only* during
    // a streaming request. The worker writes bytes at offsets
    // `[old_len, new_len)` and publishes `new_len` via a `chat_delta`. The
    // render thread only ever reads `[0, last_delivered_len)`. Because
    // those ranges are disjoint and each `putOne` is a happens-before edge
    // for the bytes it announces, no atomics or mutex are required.

    pending_response_buf: [MAX_RESPONSE_LEN]u8 = undefined,
    pending_response_len: usize = 0,

    pending_file_path: [MAX_FILE_PATH_LEN]u8 = undefined,
    pending_file_path_len: usize = 0,

    pending_summary_buf: [MAX_SUMMARY_LEN]u8 = undefined,
    pending_summary_len: usize = 0,

    /// Ring-buffer index of the placeholder assistant `Message` we are
    /// currently streaming into, or `null` if no stream is in flight.
    ///
    /// Set by `applyChatDelta` on the first delta (which appends an empty
    /// `Message.assistant("")`), cleared by `applyChatSuccess` /
    /// `applyChatError` when the stream terminates. The index is into the
    /// public `getMessage(i)` space (0..message_count) — the same one the
    /// virtual list iterates — *not* the underlying `messages[]` slot.
    ///
    /// Invariants:
    ///   * If `streaming_message_idx == null`, `is_loading` may still be
    ///     true (request sent, no deltas yet).
    ///   * If `streaming_message_idx == i`, `getMessage(i).?.role` is
    ///     `.assistant` and `is_loading` is true.
    streaming_message_idx: ?u32 = null,

    /// The `seq` (see `addMessage`) of the message `streaming_message_idx`
    /// refers to, or `null` under the same conditions as that field.
    /// Carried separately because the log write in `applyChatSuccess` /
    /// `applyChatError` happens once the stream is final, long after
    /// `addMessage` returned this value on the first delta.
    streaming_message_seq: ?u64 = null,

    // =========================================================================
    // Async Result Plumbing — Zig 0.16 std.Io
    // =========================================================================
    //
    // `pending_request` is the `Future(void)` for the in-flight HTTP
    // worker, or `null` when no request is outstanding. We track exactly
    // one because `is_loading` enforces single-flight: a second
    // `sendMessage` is a no-op while the first is still running.
    //
    // The Future serves two roles:
    //   * **Cancel** — `pending_request.?.cancel(io)` from the Stop
    //     button signals the worker fiber, which receives
    //     `error.Canceled` from its next IO call (the SSE read or a
    //     queue `putOne`) and unwinds.
    //   * **Await** — when the worker terminates normally,
    //     `pending_request.?.await(io)` releases the task's bookkeeping
    //     before we drop our reference. Skipping the await would leak
    //     task memory inside the `Io` implementation.
    //
    // `result_queue` carries `WorkerResult` values from worker → render.
    // The backing storage lives inline on AppState
    // (`RESULT_QUEUE_CAPACITY` slots); the queue object holds a pointer
    // into it, so AppState must not be moved after `init` runs.

    pending_request: ?std.Io.Future(void) = null,
    result_buffer: [RESULT_QUEUE_CAPACITY]WorkerResult = undefined,
    result_queue: std.Io.Queue(WorkerResult) = undefined,

    // =========================================================================
    // Framework handles
    // =========================================================================
    //
    // `window_ptr` is retained so workers can nudge the event loop via
    // `requestRender()`. That call is threadsafe by contract and does not touch
    // shared state; it only wakes the run loop so the next frame drains the queue.
    window_ptr: ?*gooey.Window = null,

    // =========================================================================
    // Initialization
    // =========================================================================

    pub fn init(cx: *gooey.Cx) void {
        const self = cx.state(Self);
        const window = cx.window();
        self.window_ptr = window;

        // Set initial window appearance from the persisted dark_mode flag.
        window.setAppearance(self.dark_mode);

        // Wire up the async plumbing. The queue is built in place; its
        // backing buffer already lives at its final address on AppState (we
        // are past the stack→heap move because `init` is called on the
        // mounted, committed state pointer).
        //
        // No cancel-group registration: chat-zig is single-flight (one
        // worker at most) and we track that one worker's `Future`
        // directly on AppState. On window close the OS reaps the
        // process; AppState is module-static so there is no teardown
        // for a stray worker to race against.
        self.result_queue = std.Io.Queue(WorkerResult).init(&self.result_buffer);
        self.microphone.refresh();

        // Look up the API key through the environ published by `main`. On
        // macOS this replaces libc's `getenv`, which `std.posix` no longer
        // wraps in 0.16.
        const api_key = main_mod.process_env.getPosix("ANTHROPIC_API_KEY");
        self.has_api_key = api_key != null and api_key.?.len > 0;

        if (self.has_api_key) {
            // AnthropicClient holds `std.Io` so it can spin up `std.http.Client`
            // per request. `page_allocator` is threadsafe and thus safe to
            // hand to a fiber that runs on a worker thread.
            self.http_client = anthropic.AnthropicClient.init(
                api_key.?,
                std.heap.page_allocator,
                main_mod.process_io,
            );
            log.info("Anthropic API key found", .{});
        } else {
            log.warn("ANTHROPIC_API_KEY not set", .{});
        }

        // OpenAI key is optional — Claude models still work without it, so
        // a missing key is a warning, not a blocker. It now gates two
        // things: voice-recording transcription (`DictationModel`) and the
        // GPT chat models (`Model.provider() == .openai`).
        const openai_api_key = main_mod.process_env.getPosix("OPENAI_API_KEY");
        self.has_openai_api_key = openai_api_key != null and openai_api_key.?.len > 0;

        if (self.has_openai_api_key) {
            self.openai_client = openai.OpenAIClient.init(
                openai_api_key.?,
                std.heap.page_allocator,
                main_mod.process_io,
            );
            log.info("OpenAI API key found", .{});
        } else {
            log.warn("OPENAI_API_KEY not set (voice transcription and GPT models disabled)", .{});
        }
    }

    // =========================================================================
    // Message Management
    // =========================================================================

    /// Appends `msg` to the ring buffer and returns the monotonic `seq`
    /// assigned to it (the value of `messages_total` before this call),
    /// for use as the `seq` field when the caller logs the turn via
    /// `session_log`.
    pub fn addMessage(self: *Self, msg: Message) u64 {
        std.debug.assert(self.message_count <= MAX_MESSAGES);
        std.debug.assert(self.message_head < MAX_MESSAGES);

        const seq = self.messages_total;
        self.messages_total += 1;
        std.debug.assert(self.messages_total > seq);

        if (self.message_count < MAX_MESSAGES) {
            self.messages[(self.message_head + self.message_count) % MAX_MESSAGES] = msg;
            self.message_count += 1;
        } else {
            // Ring-buffer overflow: overwrite the oldest message.
            self.messages[self.message_head] = msg;
            self.message_head = (self.message_head + 1) % MAX_MESSAGES;
        }

        // Freshly-added messages start with no cached height. Being explicit
        // here guards against a caller constructing `msg` with a stale value.
        const tail_idx = if (self.message_count == 0)
            self.message_head
        else
            (self.message_head + self.message_count - 1) % MAX_MESSAGES;
        self.messages[tail_idx].cached_height = 0.0;

        // Keep the virtual list in sync with the message ring, and scroll so
        // the freshly-added message is visible. These are UI-side mutations
        // that live on the same thread as the caller (main thread — callers
        // are either `sendMessage` or the render-loop drain).
        self.list_state.setItemCount(@intCast(self.message_count));
        self.list_state.scrollToBottom();

        return seq;
    }

    pub fn getMessage(self: *const Self, i: usize) ?*const Message {
        if (i >= self.message_count) return null;
        std.debug.assert(i < MAX_MESSAGES);
        const idx = (self.message_head + i) % MAX_MESSAGES;
        return &self.messages[idx];
    }

    pub fn getMessageCachedHeight(self: *const Self, i: usize) f32 {
        if (i >= self.message_count) return 0.0;
        std.debug.assert(i < MAX_MESSAGES);
        const idx = (self.message_head + i) % MAX_MESSAGES;
        return self.messages[idx].cached_height;
    }

    pub fn setMessageCachedHeight(self: *Self, i: usize, h: f32) void {
        if (i >= self.message_count) return;
        std.debug.assert(i < MAX_MESSAGES);
        const idx = (self.message_head + i) % MAX_MESSAGES;
        self.messages[idx].cached_height = h;
    }

    pub fn invalidateCachedHeights(self: *Self) void {
        var i: usize = 0;
        while (i < self.message_count) : (i += 1) {
            const idx = (self.message_head + i) % MAX_MESSAGES;
            self.messages[idx].cached_height = 0.0;
        }
    }

    pub fn clearMessages(self: *Self) void {
        self.message_count = 0;
        self.message_head = 0;
        self.error_message = null;
        self.is_loading = false;
        self.list_state.setItemCount(0);
        self.list_state.scrollToTop();
    }

    // =========================================================================
    // Compaction Cut
    // =========================================================================

    /// The compaction state the main thread currently holds. Workers start
    /// from this and may replace it with a freshly computed one — see
    /// `runCompaction`.
    pub fn liveCompactionView(self: *const Self) CompactionView {
        std.debug.assert(self.summary_len <= MAX_SUMMARY_LEN);
        if (self.summary_len == 0) std.debug.assert(self.summary_covers == 0);
        return .{
            .summary = self.summary_buf[0..self.summary_len],
            .covers = self.summary_covers,
        };
    }

    /// Logical index of the first `.user` turn at or after `from`, or null
    /// if the retained tail holds none.
    fn firstUserAtOrAfter(self: *const Self, from: usize) ?usize {
        std.debug.assert(from <= self.message_count);
        var i = from;
        while (i < self.message_count) : (i += 1) {
            const msg = self.getMessage(i) orelse return null;
            if (msg.role == .user) return i;
        }
        return null;
    }

    /// Logical index of the first message a request sends verbatim under
    /// `covers`. Snapped forward to a `.user` turn, because Anthropic
    /// requires the first message to be one — and it is exactly why the
    /// summary rides in the `system` field rather than as a synthetic
    /// leading message, which would collide with this turn.
    ///
    /// Falls back to 0 when the retained tail contains no user turn at all.
    /// That cannot happen on the send path (`sendMessage` appends the
    /// user's turn before launching the worker, so the tail always ends in
    /// one), and sending uncompacted history is the same free failure mode
    /// as a summarization request that errors out.
    fn retainedStart(self: *const Self, covers: u64) usize {
        std.debug.assert(self.message_count <= MAX_MESSAGES);
        std.debug.assert(covers <= self.messages_total);

        const raw = compaction.cutToIndex(.{
            .covers = covers,
            .messages_total = self.messages_total,
            .message_count = @intCast(self.message_count),
        });
        const start = self.firstUserAtOrAfter(raw) orelse 0;
        std.debug.assert(start <= self.message_count);
        return start;
    }

    /// Heuristic token count for the request `view` would produce, plus
    /// `attachment_bytes` for a staged file.
    ///
    /// Deliberately not the real `usage` numbers. On the streaming path —
    /// the only one `httpWorker` uses — `usage` arrives in the
    /// `message_start` and `message_delta` SSE events, both of which
    /// `parseSseTextDelta` discards. Plumbing it through means extending
    /// `SseEvent` and the `StreamSink` contract, which is the largest piece
    /// of work in the whole feature and buys very little: this is a
    /// threshold, not a bill.
    ///
    /// Counting the attachment, on the other hand, cannot be deferred:
    /// files are inlined into the request by the client and never appear in
    /// `messages`, so a single attached file dwarfs the entire text history
    /// and would otherwise be invisible to the estimator.
    fn estimatedTokens(self: *const Self, view: CompactionView, attachment_bytes: u64) u32 {
        std.debug.assert(view.summary.len <= MAX_SUMMARY_LEN);

        var chars: u64 = CHAT_SYSTEM_INSTRUCTION.len + view.summary.len + attachment_bytes;
        var i = self.retainedStart(view.covers);
        while (i < self.message_count) : (i += 1) {
            const msg = self.getMessage(i) orelse break;
            chars += msg.content_len;
        }

        return compaction.estimateTokens(chars);
    }

    // =========================================================================
    // Chat Request Assembly
    // =========================================================================

    const SYSTEM_BUFFER_LEN: usize =
        CHAT_SYSTEM_INSTRUCTION.len + compaction.SUMMARY_PREAMBLE.len + MAX_SUMMARY_LEN;

    /// Composes the system instruction a request carries: the standing
    /// plain-text rules, plus the compaction summary when there is one.
    ///
    /// The summary must not *replace* the formatting rules — that would
    /// silently turn Markdown back on the moment a conversation got long
    /// enough to compact — so the two are concatenated into `out`, whose
    /// length is derived from both operands and therefore cannot overflow.
    fn composeSystemInstruction(out: *[SYSTEM_BUFFER_LEN]u8, summary: []const u8) []const u8 {
        if (summary.len == 0) return CHAT_SYSTEM_INSTRUCTION;
        std.debug.assert(summary.len <= MAX_SUMMARY_LEN);

        const head = CHAT_SYSTEM_INSTRUCTION ++ compaction.SUMMARY_PREAMBLE;
        @memcpy(out[0..head.len], head);
        @memcpy(out[head.len..][0..summary.len], summary);

        const len = head.len + summary.len;
        std.debug.assert(len <= out.len);
        return out[0..len];
    }

    const ChatMessagesBuffer = struct {
        messages: [MAX_MESSAGES]anthropic.ChatMessage = undefined,
        count: usize = 0,
        /// Backs `composeSystemInstruction`'s output. Lives here so the
        /// composed instruction has exactly the same lifetime as the
        /// message slices the request borrows.
        system_buf: [SYSTEM_BUFFER_LEN]u8 = undefined,
    };

    /// Builds an Anthropic request. Only called when `selected_model.provider()
    /// == .anthropic` (see `sendMessage`).
    ///
    /// `view` decides where the loop starts: under compaction the older
    /// turns are omitted and `view.summary` stands in for them. It is a
    /// parameter rather than a read of `summary_*` because the worker may
    /// be using a summary it staged this very request, which the main
    /// thread has not adopted yet.
    fn buildAnthropicChatRequest(
        self: *Self,
        buf: *ChatMessagesBuffer,
        view: CompactionView,
    ) anthropic.ChatRequest {
        // Snapshot the ring buffer into a contiguous slice of ChatMessages.
        // Called from the worker fiber, but `is_loading` guards single-flight
        // so the main thread cannot mutate `messages` concurrently.
        buf.count = 0;
        var i: usize = self.retainedStart(view.covers);
        while (i < self.message_count and buf.count < MAX_MESSAGES) : (i += 1) {
            const msg = self.getMessage(i) orelse break;
            const role: anthropic.ChatRole = switch (msg.role) {
                .user => .user,
                .assistant => .assistant,
                .system => continue, // Anthropic takes system via a separate field.
            };
            buf.messages[buf.count] = anthropic.ChatMessage.text(role, msg.getText());
            buf.count += 1;
        }
        return .{
            .model = self.selected_model.apiName(),
            .messages = buf.messages[0..buf.count],
            .system = composeSystemInstruction(&buf.system_buf, view.summary),
        };
    }

    const OpenAIChatMessagesBuffer = struct {
        messages: [MAX_MESSAGES]openai.ChatMessage = undefined,
        count: usize = 0,
        system_buf: [SYSTEM_BUFFER_LEN]u8 = undefined,
    };

    /// Builds an OpenAI Chat Completions request. Only called when
    /// `selected_model.provider() == .openai` (see `sendMessage`).
    ///
    /// Unlike Anthropic, OpenAI has no separate top-level system field —
    /// the composed instruction rides as the first message in the array
    /// instead. `view` is honored here too: compaction only *runs* on the
    /// Anthropic path (it summarizes with haiku), but a summary earned
    /// there must not be thrown away just because the user switched models
    /// mid-conversation.
    fn buildOpenAIChatRequest(
        self: *Self,
        buf: *OpenAIChatMessagesBuffer,
        view: CompactionView,
    ) openai.ChatRequest {
        buf.count = 0;
        buf.messages[buf.count] = openai.ChatMessage.text(
            .system,
            composeSystemInstruction(&buf.system_buf, view.summary),
        );
        buf.count += 1;

        var i: usize = self.retainedStart(view.covers);
        while (i < self.message_count and buf.count < MAX_MESSAGES) : (i += 1) {
            const msg = self.getMessage(i) orelse break;
            const role: openai.ChatRole = switch (msg.role) {
                .user => .user,
                .assistant => .assistant,
                .system => .system,
            };
            buf.messages[buf.count] = openai.ChatMessage.text(role, msg.getText());
            buf.count += 1;
        }
        return .{
            .model = self.selected_model.apiName(),
            .messages = buf.messages[0..buf.count],
        };
    }

    // =========================================================================
    // Send Message — launches an async worker via Io.Group
    // =========================================================================

    pub fn sendMessage(self: *Self, window: *gooey.Window) void {
        self.window_ptr = window;

        if (self.input_slice.len == 0) return;
        // Single-flight: swallow a second click while the first request is
        // still outstanding. This is also what keeps the worker's snapshot
        // read of `messages` race-free (see `buildAnthropicChatRequest` /
        // `buildOpenAIChatRequest`).
        if (self.is_loading) return;

        // File attachments (images, PDFs) only exist on Anthropic's wire
        // format today (Files API upload, base64 image blocks) — OpenAI
        // chat support is text-only. Refuse up front, before touching
        // history or clearing input, so the user can switch models or drop
        // the attachment and retry without losing anything.
        if (self.has_attached_file and self.selected_model.provider() == .openai) {
            self.error_message = "File attachments aren't supported with GPT models yet — switch to a Claude model or remove the attachment";
            return;
        }

        // Capture the attached file path before clearing, so the worker
        // fiber reads from a stable staging slot rather than the live input
        // slot (which the next user action could mutate).
        var attached_path_len: usize = 0;
        if (self.has_attached_file) {
            attached_path_len = self.attached_file_path_len;
            @memcpy(
                self.pending_file_path[0..attached_path_len],
                self.attached_file_path[0..attached_path_len],
            );
        }

        // Add the user's message to the visible history, then durably log
        // it. Logging reads `getAttachedFileName()` (backed by
        // `attached_file_path`) before that field is cleared below.
        const seq = if (self.has_attached_file)
            self.addMessage(Message.userWithFile(self.input_slice, self.getAttachedFileName()))
        else
            self.addMessage(Message.user(self.input_slice));

        self.session_log.logUser(
            main_mod.process_io,
            seq,
            self.input_slice,
            if (self.has_attached_file) self.getAttachedFileName() else null,
        );

        self.pending_file_path_len = attached_path_len;

        // Clear input + attachment from the UI.
        self.input_slice = "";
        if (window.widgetState(TextAreaState, "chat-input")) |text_area| {
            text_area.clear();
        }
        self.has_attached_file = false;
        self.attached_file_path_len = 0;

        self.is_loading = true;
        self.error_message = null;

        const provider = self.selected_model.provider();
        switch (provider) {
            .anthropic => if (self.http_client == null) {
                self.error_message = "No Anthropic API key configured";
                self.is_loading = false;
                window.requestRender();
                return;
            },
            .openai => if (self.openai_client == null) {
                self.error_message = "No OpenAI API key configured";
                self.is_loading = false;
                window.requestRender();
                return;
            },
        }

        // Launch the worker on the shared Io instance. `io.async` returns
        // a `Future(void)` that we stash on `pending_request` so the Stop
        // button can cancel exactly this one task. Worker functions take
        // only primitives + pointers, never a `self`-style receiver, so
        // the Io runtime can cache arguments in registers (CLAUDE rule
        // #20 — "Hot Loop Extraction" applied to the fiber entry point).
        //
        // Single-flight invariant: `is_loading` was just flipped to true
        // above, so any prior `pending_request` must already have been
        // awaited and cleared by `drainResults`. Assert that pin before
        // overwriting the slot — a stale Future here would leak task
        // memory inside the Io implementation.
        std.debug.assert(self.pending_request == null);

        const io = main_mod.process_io;
        self.pending_request = switch (provider) {
            .anthropic => io.async(httpWorker, .{
                io,
                &self.http_client.?,
                self,
                &self.result_queue,
            }),
            .openai => io.async(openaiChatWorker, .{
                io,
                &self.openai_client.?,
                self,
                &self.result_queue,
            }),
        };

        window.requestRender();
    }

    // =========================================================================
    // Cancel In-Flight — Stop button
    // =========================================================================

    /// Cancel the in-flight HTTP worker, if any. Bound to the Stop button
    /// in the input area; safe to call when no request is outstanding.
    ///
    /// Sequencing matters here:
    ///
    ///   1. **Drain first** — the worker may be blocked inside `putOne`
    ///      because the queue is full (we set `RESULT_QUEUE_CAPACITY = 8`,
    ///      which is generous, but bursty `text_delta` events can hit the
    ///      cap). Draining unblocks the worker so the cancellation
    ///      request can land at its next IO call rather than deadlocking.
    ///
    ///   2. **Cancel + await** — `Future.cancel(io)` posts the
    ///      cancellation request and then awaits the worker; it blocks
    ///      briefly while the worker unwinds. The worker's next IO call
    ///      (the SSE read or another `putOne`) returns `error.Canceled`,
    ///      `client.sendStreaming` converts it to a `ChatResult.err`, and
    ///      the worker pushes a terminal result before returning.
    ///
    ///   3. **Drain again** — discard any straggling deltas + the
    ///      terminal error pushed during step 2. We don't want them
    ///      surfacing as a red banner on a user-initiated cancel.
    ///
    ///   4. **Reset terminal state** — `is_loading = false`,
    ///      `streaming_message_idx = null`, `error_message = null`. The
    ///      partial assistant bubble stays in the message history; the
    ///      user can see what they got before stopping.
    pub fn cancelInFlight(self: *Self, window: *gooey.Window) void {
        if (self.pending_request == null) return;
        std.debug.assert(self.is_loading);

        const io = main_mod.process_io;

        // Step 1: drain any backed-up results so the worker can make
        // forward progress to its next cancelation point. Non-blocking;
        // discards values rather than applying them — by cancelling, the
        // user has signalled they don't want to see what's left.
        var drain_buf: [RESULT_QUEUE_CAPACITY]WorkerResult = undefined;
        _ = self.result_queue.get(io, &drain_buf, 0) catch {};

        // Step 2: post the cancel and await unwind. `Future.cancel`
        // returns the worker's `void` return value; we discard it because
        // any state we care about already flowed through the queue.
        self.pending_request.?.cancel(io);
        self.pending_request = null;

        // Step 3: drain the terminal error / final deltas the worker
        // pushed during cancellation. Same rationale as step 1.
        _ = self.result_queue.get(io, &drain_buf, 0) catch {};

        // Step 4: explicit terminal state. Done last so a render that
        // races with the drain still sees `is_loading == true` (and
        // therefore the Stop button instead of the Send button).
        self.is_loading = false;
        self.streaming_message_idx = null;
        self.streaming_message_seq = null;
        self.error_message = null;

        log.info("Streaming request cancelled by user", .{});
        window.requestRender();
    }

    // =========================================================================
    // Workers — run on an Io fiber, off the main thread
    // =========================================================================

    /// Bundle the worker fiber needs to forward each SSE delta to the
    /// render thread. Lives on the worker's stack — the sink callback only
    /// runs while `httpWorker` is on the stack, so the pointers are valid
    /// for the entire stream's lifetime by construction.
    const StreamCtx = struct {
        io: std.Io,
        app: *AppState,
        queue: *std.Io.Queue(WorkerResult),
    };

    /// SSE sink callback — runs on the worker fiber for each `text_delta`
    /// chunk. Appends to the staging buffer and pushes a `chat_delta`
    /// result. Returning `error.Aborted` short-circuits the SSE read loop;
    /// we do that once the staging buffer is full so the worker doesn't
    /// keep parsing bytes it has nowhere to put.
    fn onStreamDelta(userdata: *anyopaque, text: []const u8) anthropic.StreamSink.Error!void {
        const ctx: *StreamCtx = @ptrCast(@alignCast(userdata));
        const app = ctx.app;

        // Append-only into the staging buffer. CLAUDE rule #4: bounded.
        const old_len = app.pending_response_len;
        std.debug.assert(old_len <= MAX_RESPONSE_LEN);
        const remaining = MAX_RESPONSE_LEN - old_len;

        // No room left — tell the SSE loop to stop reading. The
        // accumulated message stays as-is; the user sees a (truncated)
        // response, the stream tears down cleanly.
        if (remaining == 0) return error.Aborted;

        const to_copy = @min(text.len, remaining);
        @memcpy(
            app.pending_response_buf[old_len .. old_len + to_copy],
            text[0..to_copy],
        );
        const new_len = old_len + to_copy;
        app.pending_response_len = new_len;

        // Publish the new high-water mark. `putOne` is the happens-before
        // edge: the bytes we just wrote at `[old_len, new_len)` are visible
        // to the render thread only after it drains this result.
        //
        // The queue is bounded (RESULT_QUEUE_CAPACITY = 8) so `putOne`
        // blocks the worker if the render thread falls behind — natural
        // backpressure that keeps the staging buffer in sync with what the
        // UI has actually displayed.
        const cumulative_len: u32 = @intCast(new_len);
        ctx.queue.putOne(ctx.io, .{ .chat_delta = .{ .cumulative_len = cumulative_len } }) catch |e| {
            // Queue closed (window closing) — abort the stream so the
            // worker unwinds quickly. Truncation is the right behavior:
            // by the time the queue is closed, AppState is being torn
            // down anyway.
            log.debug("onStreamDelta: queue closed ({t}), aborting", .{e});
            return error.Aborted;
        };

        // Nudge the run loop. `requestRender` is threadsafe by contract.
        app.requestRenderFromWorker();
    }

    // =========================================================================
    // Compaction — runs on the worker fiber, ahead of the chat request
    // =========================================================================

    /// Size of the staged attachment, or 0 when none is staged or it can't
    /// be measured. Best-effort on purpose: a stat failure means the
    /// estimator under-counts and compaction fires a turn later than ideal,
    /// which is strictly better than refusing to send.
    fn stagedAttachmentBytes(io: std.Io, app: *Self) u64 {
        if (app.pending_file_path_len == 0) return 0;
        std.debug.assert(app.pending_file_path_len <= MAX_FILE_PATH_LEN);

        const path = app.pending_file_path[0..app.pending_file_path_len];
        const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |e| {
            log.debug("compaction: cannot stat '{s}' for the token estimate: {t}", .{ path, e });
            return 0;
        };
        defer file.close(io);

        const stat = file.stat(io) catch |e| {
            log.debug("compaction: stat failed for '{s}': {t}", .{ path, e });
            return 0;
        };
        return stat.size;
    }

    /// Fills `buf` with the slice of history `[from, to)` to be summarized,
    /// followed by the instruction turn that asks for the summary.
    ///
    /// `from` is snapped to a `.user` turn by `retainedStart`, so the
    /// request satisfies Anthropic's "first message must be user" rule by
    /// construction. Any prior summary leads the transcript as its own user
    /// turn so the new summary subsumes it instead of losing it —
    /// `compaction.SYSTEM_INSTRUCTION` tells the model to expect that.
    fn buildSummaryRequest(
        self: *Self,
        buf: *ChatMessagesBuffer,
        view: CompactionView,
        from: usize,
        to: usize,
    ) anthropic.ChatRequest {
        std.debug.assert(from < to);
        std.debug.assert(to <= self.message_count);

        buf.count = 0;
        if (view.summary.len > 0) {
            // This can put two `.user` turns back to back (the prior
            // summary, then the retained slice's own leading user turn),
            // and likewise below where the instruction follows a user turn.
            // The Messages API merges consecutive same-role turns, so the
            // only rule that actually binds is "the first message is user"
            // — which holds either way: `retainedStart` snapped `from` to a
            // user turn, and the summary is one.
            buf.messages[buf.count] = anthropic.ChatMessage.text(.user, view.summary);
            buf.count += 1;
        }

        var i = from;
        while (i < to and buf.count + 1 < MAX_MESSAGES) : (i += 1) {
            const msg = self.getMessage(i) orelse break;
            const role: anthropic.ChatRole = switch (msg.role) {
                .user => .user,
                .assistant => .assistant,
                .system => continue,
            };
            buf.messages[buf.count] = anthropic.ChatMessage.text(role, msg.getText());
            buf.count += 1;
        }

        buf.messages[buf.count] = anthropic.ChatMessage.text(.user, compaction.REQUEST);
        buf.count += 1;
        std.debug.assert(buf.count <= MAX_MESSAGES);

        return .{
            // Summarizing with the cheapest model is the industry norm and
            // costs nothing structurally here: the model is per-request and
            // `AnthropicClient` is model-agnostic.
            .model = Model.haiku.apiName(),
            .messages = buf.messages[0..buf.count],
            .system = compaction.SYSTEM_INSTRUCTION,
        };
    }

    /// Compacts if the estimated request has crossed
    /// `compaction.TRIGGER_RATIO` of the model's window, and returns the
    /// view the caller should build its request from.
    ///
    /// Every early return hands back the live view unchanged, which is the
    /// whole point of making compaction derived: a skipped or failed
    /// compaction costs one wasted summarization request at worst and the
    /// send proceeds on whatever history is currently retained. If that
    /// then 400s for length, it surfaces through `applyChatError` with no
    /// new machinery.
    fn runCompaction(
        io: std.Io,
        client: *anthropic.AnthropicClient,
        app: *Self,
        queue: *std.Io.Queue(WorkerResult),
    ) CompactionView {
        const live = app.liveCompactionView();

        const window_tokens = app.selected_model.contextWindowTokens();
        const estimate = app.estimatedTokens(live, stagedAttachmentBytes(io, app));
        if (estimate < compaction.thresholdTokens(window_tokens)) return live;

        const cut = app.planCompactionCut(live) orelse return live;
        log.info(
            "compaction: ~{d} tokens of a {d} window, summarizing messages {d}..{d}",
            .{ estimate, window_tokens, cut.from, cut.to },
        );

        var buf: ChatMessagesBuffer = .{};
        const request = app.buildSummaryRequest(&buf, live, cut.from, cut.to);

        var result = client.sendBlocking(request);
        defer result.deinit(client.allocator);

        const text = result.getText() orelse {
            log.warn("compaction: summarization failed ({s}), sending uncompacted", .{result.getError() orelse "unknown"});
            return live;
        };
        const len = compaction.utf8SafeLen(text, MAX_SUMMARY_LEN);
        if (len == 0) return live;
        std.debug.assert(len <= MAX_SUMMARY_LEN);

        @memcpy(app.pending_summary_buf[0..len], text[0..len]);
        app.pending_summary_len = len;

        // Publish so the main thread — which owns `summary_*` — adopts the
        // cut. We keep using our own staged copy for this request either
        // way; the queue item is what makes the next send inherit it.
        queue.putOne(io, .{ .compaction_applied = .{
            .summary_len = @intCast(len),
            .covers = cut.covers,
        } }) catch |e| {
            log.debug("runCompaction: compaction result dropped ({t})", .{e});
        };
        app.requestRenderFromWorker();

        return .{ .summary = app.pending_summary_buf[0..len], .covers = cut.covers };
    }

    /// Where a new compaction would cut, or null if it would not make
    /// progress.
    ///
    /// Progress is the guard that keeps a long retained tail from
    /// compacting on every single turn: once the newest
    /// `compaction.KEEP_RECENT` messages are all that sit past the existing
    /// cut, there is nothing left to summarize and re-running would just
    /// burn a request per send while staying over threshold.
    ///
    /// The returned `covers` is the realized cut rather than the proposed
    /// one. `retainedStart` snaps forward to a `.user` turn, so the
    /// summarized range `[from, to)` routinely extends past the proposal;
    /// storing the proposal would understate what the summary represents
    /// and leave `covers` meaningful only after a second trip through
    /// `retainedStart`. Converting the snapped index back into `seq` space
    /// here performs the index-to-count conversion once, at the point of
    /// decision, instead of implicitly at every call site that later reads
    /// the cut.
    fn planCompactionCut(self: *const Self, live: CompactionView) ?struct {
        from: usize,
        to: usize,
        covers: u64,
    } {
        const proposed = compaction.proposedCovers(self.messages_total);
        if (proposed <= live.covers) return null;

        const from = self.retainedStart(live.covers);
        const to = self.retainedStart(proposed);
        if (to <= from) return null;

        // `to` indexes the live ring, while the cut is stored against the
        // monotonic counter, so shift it by however far the ring's index 0
        // has drifted from `seq` 0 — the same `evicted` term `cutToIndex`
        // subtracts on the way in.
        const evicted = self.messages_total - @as(u64, @intCast(self.message_count));
        const covers = evicted + @as(u64, @intCast(to));

        std.debug.assert(to <= self.message_count);
        std.debug.assert(covers > live.covers);
        std.debug.assert(covers <= self.messages_total);
        // The snap is already baked into `covers`, so re-resolving it must
        // land on the same boundary rather than sliding forward again.
        // This is the property that makes the stored cut mean what
        // `CompactionResult.covers` claims it means.
        std.debug.assert(self.retainedStart(covers) == to);
        return .{ .from = from, .to = to, .covers = covers };
    }

    /// Chat worker: builds the request, opens an SSE stream against
    /// Anthropic's Messages API, forwards each `text_delta` to the render
    /// thread via `onStreamDelta`, and finally signals stream completion
    /// (success or error). Never touches UI state directly.
    ///
    /// Streaming is unconditional — the API supports it on every model
    /// and the UX is strictly better. The non-streaming `sendBlocking`
    /// path on `AnthropicClient` remains available for tests / future
    /// callers, but this worker does not exercise it.
    fn httpWorker(
        io: std.Io,
        client: *anthropic.AnthropicClient,
        app: *Self,
        queue: *std.Io.Queue(WorkerResult),
    ) void {
        // Reset the staging buffer for this request. Worker is single-flight
        // (guarded by `is_loading`), so no other fiber can be reading or
        // writing here. We reset *before* touching the queue so a stale
        // `pending_response_len` from a previous request can never leak
        // into the first delta.
        app.pending_response_len = 0;

        // Compaction runs here, inline, as the worker's first step rather
        // than as its own fiber. Because it never mutates UI state it needs
        // no round trip to the main thread before the chat request can
        // proceed — which is what keeps this single-flight: no
        // `is_compacting` flag, no second entry point into "launch a
        // worker," no re-entrancy. `is_loading` already means "a send is in
        // flight," which is exactly true during this call, and
        // `cancelInFlight` covers both phases unchanged.
        const view = runCompaction(io, client, app, queue);

        var buf: ChatMessagesBuffer = .{};
        const request = app.buildAnthropicChatRequest(&buf, view);

        var ctx = StreamCtx{ .io = io, .app = app, .queue = queue };
        const sink = anthropic.StreamSink{
            .userdata = @ptrCast(&ctx),
            .callback = onStreamDelta,
        };

        var result: anthropic.ChatResult = undefined;
        if (app.pending_file_path_len > 0) {
            const file_path = app.pending_file_path[0..app.pending_file_path_len];
            log.info("Streaming message with file attachment: {s}", .{file_path});
            result = client.sendStreamingWithFile(request, file_path, sink);
        } else {
            result = client.sendStreaming(request, sink);
        }
        defer result.deinit(client.allocator);

        // Terminal result. Note that on success, `result.text` is the full
        // accumulated response — but the staging buffer already holds it
        // (built up via deltas), so we don't re-copy. We just signal
        // "stream done, the bytes you've already drained are final".
        //
        // On error, the staging buffer may hold a partial response. We
        // leave it in place so the assistant message keeps whatever it
        // managed to render — same UX as a network drop mid-paragraph.
        const outcome: WorkerResult = switch (result.status) {
            .success => .{ .chat_success = .{ .response_len = app.pending_response_len } },
            .err => |msg| .{ .chat_error = .{ .message = msg } },
        };

        queue.putOne(io, outcome) catch |e| {
            // Queue closed (teardown) or task cancelled: main thread is
            // tearing down, drop the result.
            log.debug("httpWorker: terminal result dropped ({t})", .{e});
        };

        app.requestRenderFromWorker();
    }

    /// SSE sink callback for OpenAI streaming chat — mirrors `onStreamDelta`
    /// exactly, but bound to `openai.StreamSink.Error` (a distinct type from
    /// `anthropic.StreamSink.Error`, so it needs its own function pointer
    /// rather than sharing one across providers).
    fn onOpenAIStreamDelta(userdata: *anyopaque, text: []const u8) openai.StreamSink.Error!void {
        const ctx: *StreamCtx = @ptrCast(@alignCast(userdata));
        const app = ctx.app;

        const old_len = app.pending_response_len;
        std.debug.assert(old_len <= MAX_RESPONSE_LEN);
        const remaining = MAX_RESPONSE_LEN - old_len;

        if (remaining == 0) return error.Aborted;

        const to_copy = @min(text.len, remaining);
        @memcpy(
            app.pending_response_buf[old_len .. old_len + to_copy],
            text[0..to_copy],
        );
        const new_len = old_len + to_copy;
        app.pending_response_len = new_len;

        const cumulative_len: u32 = @intCast(new_len);
        ctx.queue.putOne(ctx.io, .{ .chat_delta = .{ .cumulative_len = cumulative_len } }) catch |e| {
            log.debug("onOpenAIStreamDelta: queue closed ({t}), aborting", .{e});
            return error.Aborted;
        };

        app.requestRenderFromWorker();
    }

    /// Chat worker for OpenAI models (see `Model.provider`) — mirrors
    /// `httpWorker`'s shape exactly, but text-only: `sendMessage` refuses
    /// to launch this path when a file is attached (see its doc comment),
    /// so there is no attachment branch here.
    fn openaiChatWorker(
        io: std.Io,
        client: *openai.OpenAIClient,
        app: *Self,
        queue: *std.Io.Queue(WorkerResult),
    ) void {
        app.pending_response_len = 0;

        // No compaction pass: summarizing goes through haiku, which lives
        // on the Anthropic client this worker doesn't have. A summary
        // earned on the Anthropic path is still honored — see
        // `buildOpenAIChatRequest`.
        var buf: OpenAIChatMessagesBuffer = .{};
        const request = app.buildOpenAIChatRequest(&buf, app.liveCompactionView());

        var ctx = StreamCtx{ .io = io, .app = app, .queue = queue };
        const sink = openai.StreamSink{
            .userdata = @ptrCast(&ctx),
            .callback = onOpenAIStreamDelta,
        };

        var result = client.sendStreamingChat(request, sink);
        defer result.deinit(client.allocator);

        const outcome: WorkerResult = switch (result.status) {
            .success => .{ .chat_success = .{ .response_len = app.pending_response_len } },
            .err => |msg| .{ .chat_error = .{ .message = msg } },
        };

        queue.putOne(io, outcome) catch |e| {
            log.debug("openaiChatWorker: terminal result dropped ({t})", .{e});
        };

        app.requestRenderFromWorker();
    }

    /// Transcribes a just-finished recording via the user's selected
    /// OpenAI transcription model (see `DictationModel`) and stages the
    /// result for the render thread. `path_buf`/`path_len` are a value
    /// copy of the recording's path — NOT a live view into
    /// `app.recording.path_buffer` — because a new recording could start
    /// (and overwrite that buffer) while this transcription is still in
    /// flight.
    fn transcriptionWorker(
        io: std.Io,
        client: *openai.OpenAIClient,
        app: *Self,
        queue: *std.Io.Queue(WorkerResult),
        path_buf: [RECORDING_PATH_MAX_LEN]u8,
        path_len: usize,
        dictation_model: DictationModel,
    ) void {
        std.debug.assert(path_len > 0);
        std.debug.assert(path_len <= RECORDING_PATH_MAX_LEN);

        var result = client.transcribeFile(path_buf[0..path_len], dictation_model.apiName());
        defer result.deinit(client.allocator);

        const outcome: WorkerResult = switch (result.status) {
            .success => |text| blk: {
                // Cap to MAX_INPUT_LEN — the transcript flows straight into
                // the chat input box, which enforces the same bound.
                const capped_len = @min(text.len, MAX_INPUT_LEN);
                @memcpy(app.pending_transcript_buf[0..capped_len], text[0..capped_len]);
                app.pending_transcript_len = capped_len;
                break :blk .{ .transcription_success = .{ .text_len = @intCast(capped_len) } };
            },
            .err => |msg| .{ .transcription_error = .{ .message = msg } },
        };

        queue.putOne(io, outcome) catch |e| {
            log.debug("transcriptionWorker: terminal result dropped ({t})", .{e});
        };

        app.requestRenderFromWorker();
    }

    /// Request a render from a worker fiber. Safe to call from any thread —
    /// `Gooey.requestRender` is threadsafe by contract and only nudges the
    /// event loop; the actual result delivery still flows through the
    /// Io.Queue drain on the main thread.
    fn requestRenderFromWorker(self: *Self) void {
        const window = self.window_ptr orelse return;
        window.requestRender();
    }

    // =========================================================================
    // Render-loop Drain — apply pending results on the main thread
    // =========================================================================

    /// Drain the result queue and apply any completed worker outputs. Call
    /// this at the top of the render function, before anything reads
    /// `is_loading` or iterates `messages`.
    ///
    /// Non-blocking: returns immediately if the queue is empty. The internal
    /// buffer is sized to match `RESULT_QUEUE_CAPACITY` so a single drain
    /// cannot leave backlog.
    pub fn drainResults(self: *Self, cx: *gooey.Cx) void {
        var buf: [RESULT_QUEUE_CAPACITY]WorkerResult = undefined;
        const drained = cx.drainQueue(WorkerResult, &self.result_queue, &buf);
        std.debug.assert(drained.len <= RESULT_QUEUE_CAPACITY);
        const window = cx.window();
        for (drained) |r| {
            switch (r) {
                .chat_delta => |d| self.applyChatDelta(d),
                .chat_success => |ok| self.applyChatSuccess(ok),
                .chat_error => |err| self.applyChatError(err),
                .compaction_applied => |c| self.applyCompactionApplied(c),
                .transcription_success => |ok| self.applyTranscriptionSuccess(ok, window),
                .transcription_error => |err| self.applyTranscriptionError(err),
            }
        }
    }

    /// Apply one streaming delta. Lazily creates an empty assistant
    /// `Message` on the first delta of a stream, then grows it in-place
    /// for every subsequent delta. The cached layout height is
    /// invalidated each time so the virtual list re-measures the
    /// growing bubble on the next frame.
    fn applyChatDelta(self: *Self, d: DeltaResult) void {
        std.debug.assert(d.cumulative_len <= MAX_RESPONSE_LEN);
        std.debug.assert(self.is_loading);

        // First delta: append the placeholder assistant message and
        // remember its index. `addMessage` does the virtual-list /
        // scroll bookkeeping; we just have to capture the index *after*
        // the message is appended (so it survives any future overwrites
        // — which can't happen during a single stream, but the
        // assertion below pins the invariant either way).
        if (self.streaming_message_idx == null) {
            const seq = self.addMessage(Message.assistant(""));
            std.debug.assert(self.message_count > 0);
            self.streaming_message_idx = @intCast(self.message_count - 1);
            self.streaming_message_seq = seq;
        }

        const idx = self.streaming_message_idx.?;
        std.debug.assert(idx < self.message_count);
        const follow_stream = self.list_state.isScrolledToBottom(2.0);

        // Compute the slot in the underlying ring and grow the message in
        // place. Worker only appends, so `cumulative_len` only goes up;
        // an out-of-order delta would trip the assertion below.
        const ring_idx = (self.message_head + idx) % MAX_MESSAGES;
        std.debug.assert(self.messages[ring_idx].role == .assistant);

        const new_len: usize = @intCast(d.cumulative_len);
        const cap = @min(new_len, MAX_MESSAGE_LEN);
        std.debug.assert(cap >= self.messages[ring_idx].content_len);

        @memcpy(
            self.messages[ring_idx].content[0..cap],
            self.pending_response_buf[0..cap],
        );
        self.messages[ring_idx].content_len = cap;
        // Invalidate cached height — the bubble just grew. The virtual
        // list will re-measure on the next render pass.
        self.messages[ring_idx].cached_height = 0.0;

        // Follow new content only while the viewport was already at the end.
        // Once the user scrolls upward, streamed deltas preserve that position.
        if (follow_stream) {
            self.list_state.scrollToBottom();
        }
    }

    /// Await and clear the in-flight worker `Future`. Idempotent — safe
    /// to call when no request is outstanding (e.g., after `cancelInFlight`
    /// already cleared the slot).
    ///
    /// `Future.await(io)` is required for normal completion so the `Io`
    /// implementation can release the task's bookkeeping. By the time a
    /// terminal `chat_success` / `chat_error` reaches the render thread,
    /// the worker has already pushed its last queue item and is on its
    /// way out — `await` blocks for at most one fiber-scheduling tick.
    fn awaitPendingRequest(self: *Self) void {
        if (self.pending_request == null) return;
        const io = main_mod.process_io;
        self.pending_request.?.await(io);
        self.pending_request = null;
    }

    fn applyChatSuccess(self: *Self, r: SuccessResult) void {
        std.debug.assert(r.response_len <= MAX_RESPONSE_LEN);

        // Reap the worker's task slot before we touch any UI state. If
        // we skipped this we'd leak task memory inside the Io
        // implementation on every successful request.
        self.awaitPendingRequest();

        // Streaming path: deltas already populated the assistant message.
        // Log the finalized text now (never per-delta — see
        // `session_log.zig`), then clear the "stream in flight" tracking.
        if (self.streaming_message_idx) |idx| {
            const seq = self.streaming_message_seq.?;
            const text = self.getMessage(idx).?.getText();
            self.session_log.logAssistant(main_mod.process_io, seq, text);

            self.streaming_message_idx = null;
            self.streaming_message_seq = null;
            self.error_message = null;
            self.is_loading = false;
            return;
        }

        // Fallback: stream completed without producing any deltas (zero-
        // length response). Surface as a single empty assistant message
        // for visual consistency rather than silently dropping the turn.
        const response = self.pending_response_buf[0..r.response_len];
        const seq = self.addMessage(Message.assistant(response));
        self.session_log.logAssistant(main_mod.process_io, seq, response);
        self.error_message = null;
        self.is_loading = false;
    }

    fn applyChatError(self: *Self, e: ErrorResult) void {
        // Reap the worker's task slot first — same rationale as
        // `applyChatSuccess`. The worker has already pushed its terminal
        // error and is about to return, so the await is brief.
        self.awaitPendingRequest();

        // If the stream already produced visible output, leave the
        // partial assistant message in place — it's better UX than
        // wiping a half-typed paragraph. The error banner still tells
        // the user something went wrong. Log that partial text too: the
        // turn is final (it will never receive another delta), even
        // though it's truncated.
        if (self.streaming_message_idx) |idx| {
            const seq = self.streaming_message_seq.?;
            const text = self.getMessage(idx).?.getText();
            self.session_log.logAssistant(main_mod.process_io, seq, text);
        }

        self.streaming_message_idx = null;
        self.streaming_message_seq = null;
        self.error_message = e.message;
        self.is_loading = false;
    }

    /// Adopt the summary the worker staged, advancing the cut every future
    /// request assembles from. Nothing here touches `messages`: the ring
    /// keeps every turn, so scrolling up still shows real history and the
    /// virtual list's indices and cached heights are untouched.
    ///
    /// Also durably records the summary, so a restored session inherits the
    /// cut instead of re-paying for summarization.
    fn applyCompactionApplied(self: *Self, r: CompactionResult) void {
        std.debug.assert(r.summary_len > 0);
        std.debug.assert(r.summary_len <= MAX_SUMMARY_LEN);
        std.debug.assert(r.covers > self.summary_covers); // Must make progress.
        std.debug.assert(r.covers <= self.messages_total);

        const len: usize = @intCast(r.summary_len);
        std.debug.assert(len <= self.pending_summary_len);
        @memcpy(self.summary_buf[0..len], self.pending_summary_buf[0..len]);
        self.summary_len = len;
        self.summary_covers = r.covers;

        self.session_log.logSummary(
            main_mod.process_io,
            self.messages_total,
            r.covers,
            self.summary_buf[0..len],
        );

        log.info("compaction applied: {d} messages now summarized in {d} bytes", .{ r.covers, len });
    }

    /// Clears the derived compaction state. Called wherever the transcript
    /// those `seq` numbers refer to is replaced — a stale `summary_covers`
    /// against a different conversation would silently truncate the new
    /// one's history.
    fn clearCompaction(self: *Self) void {
        self.summary_len = 0;
        self.summary_covers = 0;
        self.pending_summary_len = 0;
        std.debug.assert(self.summary_len == 0);
        std.debug.assert(self.summary_covers == 0);
    }

    /// Banner text for the composer — "History compacted · N earlier
    /// messages summarized" — or null when nothing has been compacted.
    ///
    /// Formatted on demand into a state-owned buffer rather than kept in
    /// sync with `summary_covers` at each write point, so there is no
    /// second source of truth that can drift. Main thread only.
    pub fn compactionBanner(self: *Self) ?[]const u8 {
        if (self.summary_len == 0) return null;
        std.debug.assert(self.summary_covers > 0);

        return std.fmt.bufPrint(
            &self.compaction_banner_buf,
            "History compacted \xc2\xb7 {d} earlier messages summarized",
            .{self.summary_covers},
        ) catch null;
    }

    /// Await and clear the in-flight transcription `Future`. Same
    /// rationale as `awaitPendingRequest` — required so the `Io`
    /// implementation can release the worker task's bookkeeping.
    fn awaitPendingTranscription(self: *Self) void {
        if (self.pending_transcription == null) return;
        const io = main_mod.process_io;
        self.pending_transcription.?.await(io);
        self.pending_transcription = null;
    }

    /// Drops the transcribed text into the chat input box, replacing
    /// whatever was there. Updates both the bound model (`input_slice`,
    /// backed by the fixed `input_text` buffer — no heap allocation) and
    /// the live widget directly, so the change is visible this frame
    /// rather than lagging one frame behind the next `syncBoundText`
    /// reconciliation. Mirrors the clear-on-send pattern in `sendMessage`.
    fn applyTranscriptionSuccess(self: *Self, r: TranscriptionSuccessResult, window: *gooey.Window) void {
        std.debug.assert(r.text_len > 0);
        std.debug.assert(r.text_len <= MAX_INPUT_LEN);

        self.awaitPendingTranscription();
        self.is_transcribing = false;
        self.error_message = null;

        const text_len: usize = @intCast(r.text_len);
        std.debug.assert(text_len <= self.pending_transcript_buf.len);
        @memcpy(self.input_text[0..text_len], self.pending_transcript_buf[0..text_len]);
        self.input_slice = self.input_text[0..text_len];

        if (window.widgetState(TextAreaState, "chat-input")) |text_area| {
            text_area.setText(self.input_slice) catch {};
        }
    }

    fn applyTranscriptionError(self: *Self, e: TranscriptionErrorResult) void {
        self.awaitPendingTranscription();
        self.is_transcribing = false;
        self.error_message = e.message;
    }

    // =========================================================================
    // Theme / Model Toggles
    // =========================================================================

    pub fn toggleDarkMode(self: *Self, window: *gooey.Window) void {
        self.dark_mode = !self.dark_mode;
        window.setAppearance(self.dark_mode);
        window.requestRender();
    }

    /// Toggles the settings view. Mutually exclusive with the history view
    /// (`history_expanded`) — opening settings closes history, since both
    /// take over the content area in place of `ContentArea`.
    pub fn toggleSettings(self: *Self, window: *gooey.Window) void {
        std.debug.assert(self.microphone.devices.count <= audio.MAX_INPUT_DEVICES);
        std.debug.assert(self.message_count <= MAX_MESSAGES);
        self.settings_expanded = !self.settings_expanded;
        if (self.settings_expanded) self.history_expanded = false;
        window.requestRender();
    }

    /// Toggles the history panel. Opening it re-scans `sessions/*.jsonl`
    /// (see `refreshSessionHistory`) so the list reflects any sessions
    /// written since it was last opened; closing it leaves the last scan in
    /// place rather than clearing it, since re-opening will just rescan.
    /// Mutually exclusive with the settings view — see `toggleSettings`.
    pub fn toggleHistory(self: *Self, window: *gooey.Window) void {
        std.debug.assert(self.session_entry_count <= session_log_mod.MAX_SESSION_ENTRIES);
        self.history_expanded = !self.history_expanded;
        if (self.history_expanded) self.settings_expanded = false;
        if (self.history_expanded) self.refreshSessionHistory();
        if (self.history_expanded) {
            std.debug.assert(self.history_list_state.item_count == @as(u32, @intCast(self.session_entry_count)));
        }
        window.requestRender();
    }

    /// Scans `sessions/*.jsonl` (via `session_log.listSessions`) into
    /// `session_entries`, newest first, and syncs `history_list_state` so
    /// the panel's uniform list has the right item count.
    fn refreshSessionHistory(self: *Self) void {
        std.debug.assert(self.session_entry_count <= session_log_mod.MAX_SESSION_ENTRIES);

        const io = main_mod.process_io;
        self.session_entry_count = session_log_mod.listSessions(std.Io.Dir.cwd(), io, &self.session_entries);
        std.debug.assert(self.session_entry_count <= session_log_mod.MAX_SESSION_ENTRIES);

        self.history_list_state.setItemCount(@intCast(self.session_entry_count));
        self.history_list_state.scrollToTop();
    }

    /// Bounded-checked accessor for `session_entries`, mirroring `getMessage`.
    pub fn getSessionEntry(self: *const Self, i: usize) ?session_log_mod.SessionEntry {
        if (i >= self.session_entry_count) return null;
        std.debug.assert(i < session_log_mod.MAX_SESSION_ENTRIES);
        return self.session_entries[i];
    }

    /// Restores `session_entries[index]`'s conversation into the live
    /// ring, replacing whatever is currently loaded — the "Restore"
    /// mechanism sketched in `docs/CHAT_COMPACTION.md`. Cancels any
    /// in-flight request first (a stale `streaming_message_idx` into a
    /// just-cleared ring would be unsound), then reads the session's own
    /// JSONL file — not the current `SessionLog`, which keeps writing to
    /// this process's own file unaffected: any turns sent after a restore
    /// extend it, continuing from the restored `messages_total`.
    pub fn loadSession(self: *Self, window: *gooey.Window, index: u32) void {
        std.debug.assert(self.session_entry_count <= session_log_mod.MAX_SESSION_ENTRIES);
        const entry = self.getSessionEntry(index) orelse return;
        std.debug.assert(entry.unix_seconds > 0);

        self.cancelInFlight(window);
        self.clearMessages();
        self.clearCompaction();

        const RestoreCtx = struct {
            app: *Self,
            max_seq_seen: u64 = 0,

            fn onLine(ctx: *@This(), line: session_log_mod.LoadedLine) void {
                switch (line) {
                    .message => |m| ctx.onMessage(m),
                    .summary => |s| ctx.onSummary(s),
                }
            }

            fn onMessage(ctx: *@This(), m: session_log_mod.LoadedMessage) void {
                const msg = switch (m.role) {
                    .user => if (m.attached_file) |file_name|
                        Message.userWithFile(m.text, file_name)
                    else
                        Message.user(m.text),
                    .assistant => Message.assistant(m.text),
                };
                _ = ctx.app.addMessage(msg);
                if (m.seq >= ctx.max_seq_seen) ctx.max_seq_seen = m.seq + 1;
            }

            /// Adopt the last summary the session recorded. Later summaries
            /// subsume earlier ones (each is computed from the previous
            /// one — see `buildSummaryRequest`), so plain assignment in
            /// file order lands on the right cut.
            fn onSummary(ctx: *@This(), s: session_log_mod.LoadedSummary) void {
                const len = @min(s.text.len, MAX_SUMMARY_LEN);
                if (len == 0) return;
                // A summary that covers nothing is not a summary. Only a
                // truncated or hand-edited file can produce one, but
                // adopting it would leave `summary_len > 0` alongside
                // `summary_covers == 0` — a state the guard below cannot
                // see and `compactionBanner` asserts against on the very
                // next frame.
                if (s.covers == 0) return;
                @memcpy(ctx.app.summary_buf[0..len], s.text[0..len]);
                ctx.app.summary_len = len;
                ctx.app.summary_covers = s.covers;
                if (s.seq >= ctx.max_seq_seen) ctx.max_seq_seen = s.seq;
            }
        };

        var ctx = RestoreCtx{ .app = self };
        session_log_mod.loadSessionLines(
            std.Io.Dir.cwd(),
            main_mod.process_io,
            std.heap.page_allocator,
            entry.unix_seconds,
            &ctx,
            RestoreCtx.onLine,
        );

        // `messages_total` must land at least at the restored high-water
        // mark so a turn sent after this point gets a `seq` the on-disk
        // log has never used — even though the ring only kept the newest
        // `MAX_MESSAGES` of a longer session.
        if (ctx.max_seq_seen > self.messages_total) self.messages_total = ctx.max_seq_seen;

        // The restored `summary_covers` is a `seq` from *that file's*
        // numbering, while `messages_total` keeps counting in this
        // process's. The two coincide when restoring into a session that
        // hasn't sent anything yet — the common case, and the one where the
        // cut lands exactly right. Otherwise this process is already `base`
        // messages ahead, so `cutToIndex` resolves the cut `base` messages
        // too early and a few turns get sent verbatim that the summary
        // already covers. Redundant, never lossy, and it costs a handful of
        // messages rather than the machinery to translate seq spaces.
        //
        // A cut past the end of the transcript, though, would clamp real
        // history away, so drop the summary outright. Only reachable via a
        // truncated or hand-edited file.
        if (self.summary_covers > self.messages_total) self.clearCompaction();
        if (self.summary_len == 0) std.debug.assert(self.summary_covers == 0);

        self.invalidateCachedHeights();
        self.history_expanded = false;
        window.requestRender();
    }

    /// Starts a brand new conversation: cancels any in-flight request,
    /// clears the live message ring, and rotates `session_log` onto a new
    /// on-disk file (`SessionLog.startNew`) so this conversation's turns
    /// don't mix into whatever file this process had been writing to.
    /// `messages_total` resets to 0 too — unlike `loadSession`'s restore,
    /// there is no prior transcript whose `seq` numbers need protecting
    /// from reuse, since the old file is left untouched on disk under its
    /// own name. Also closes the history panel, so the freshly emptied
    /// `ContentArea` is what greets the user next.
    ///
    /// Not currently wired to any UI control — `HistoryPanel` dropped its
    /// "New chat" button once `HistoryToggle` started doubling as a "back
    /// to chat" affordance. Kept for a future call site (e.g. a keyboard
    /// shortcut) rather than deleted outright.
    pub fn newConversation(self: *Self, window: *gooey.Window) void {
        std.debug.assert(self.session_entry_count <= session_log_mod.MAX_SESSION_ENTRIES);

        self.cancelInFlight(window);
        self.clearMessages();

        self.session_log.startNew(main_mod.process_io);
        self.messages_total = 0;
        self.clearCompaction();

        self.invalidateCachedHeights();
        self.history_expanded = false;
        std.debug.assert(self.message_count == 0);
        window.requestRender();
    }

    pub fn selectModel(self: *Self, index: usize) void {
        self.selected_model = @enumFromInt(index);
    }

    pub fn selectDictationModel(self: *Self, index: usize) void {
        std.debug.assert(index < DICTATION_MODEL_COUNT);
        std.debug.assert(index < DictationModel.api_names.len);
        self.selected_dictation_model = @enumFromInt(index);
    }

    pub fn selectMicrophone(self: *Self, index: usize) void {
        std.debug.assert(index < self.microphone.devices.count);
        std.debug.assert(index < audio.MAX_INPUT_DEVICES);
        self.microphone.selected = index;
    }

    pub fn refreshMicrophones(self: *Self, window: *gooey.Window) void {
        std.debug.assert(self.microphone.devices.count <= audio.MAX_INPUT_DEVICES);
        std.debug.assert(!self.recording.active);
        self.microphone.refresh();
        window.requestRender();
    }

    pub fn toggleRecording(self: *Self, window: *gooey.Window) void {
        std.debug.assert(self.microphone.devices.count <= audio.MAX_INPUT_DEVICES);
        std.debug.assert(self.recording.path_len <= RECORDING_PATH_MAX_LEN);

        if (self.recording.active) {
            self.recording.active = false;
            if (audio.stopRecording()) |_| {
                self.recording.last_error = null;
                self.startTranscription(window);
            } else |capture_error| {
                self.recording.last_error = capture_error;
            }
            window.requestRender();
            return;
        }

        const selected = self.microphone.selected orelse return;
        std.debug.assert(selected < self.microphone.devices.count);
        const device = self.microphone.devices.slice()[selected];

        if (!self.recording.preparePath(main_mod.process_io)) {
            self.recording.last_error = error.FileError;
            return;
        }

        audio.startRecording(main_mod.process_io, device, self.recording.path()) catch |capture_error| {
            self.recording.last_error = capture_error;
            return;
        };

        self.recording.last_error = null;
        self.recording.active = true;
        window.requestRender();
    }

    /// Kicks off background transcription of the just-finished recording
    /// via the user's selected OpenAI transcription model (`DictationModel`,
    /// configurable in Settings). No-op if no OpenAI key is configured, or
    /// the recording never got a path (both defensive — `toggleRecording`
    /// only calls this after a successful `stopRecording`) — voice
    /// recording works fine without transcription, it's a bonus.
    ///
    /// Copies the recording path into a value buffer rather than passing a
    /// view into `self.recording.path_buffer`: that buffer gets overwritten
    /// by `preparePath` the moment a new recording starts, which the UI
    /// otherwise allows (the record button is only disabled while a
    /// transcription is in flight — see `can_record` in `layout.zig`, and
    /// `is_transcribing` closes that window, but the copy is cheap
    /// insurance against future UI changes reopening it).
    fn startTranscription(self: *Self, window: *gooey.Window) void {
        std.debug.assert(!self.is_transcribing);
        std.debug.assert(self.pending_transcription == null);

        if (self.openai_client == null) return;
        if (self.recording.path_len == 0) return;

        var path_buf: [RECORDING_PATH_MAX_LEN]u8 = undefined;
        const path_len = self.recording.path_len;
        @memcpy(path_buf[0..path_len], self.recording.path());

        self.is_transcribing = true;
        self.error_message = null;
        self.window_ptr = window;

        const io = main_mod.process_io;
        self.pending_transcription = io.async(transcriptionWorker, .{
            io,
            &self.openai_client.?,
            self,
            &self.result_queue,
            path_buf,
            path_len,
            self.selected_dictation_model,
        });

        window.requestRender();
    }

    pub fn microphoneLevels(_: *const Self) [audio.WAVEFORM_BAR_COUNT]f32 {
        const levels = audio.waveformLevels();
        std.debug.assert(levels.len == audio.WAVEFORM_BAR_COUNT);
        std.debug.assert(audio.WAVEFORM_BAR_COUNT > 0);
        return levels;
    }

    // =========================================================================
    // File Attachments
    // File Attachment Handlers
    // =========================================================================

    pub fn openFileDialog(self: *Self, window: *gooey.Window) void {
        _ = self;
        // Defer to avoid deadlock — the native file dialog blocks and
        // processes events, which can re-enter input handlers while the
        // render mutex is held.
        window.deferCommand(Self.openFileDialogDeferred);
    }

    fn openFileDialogDeferred(self: *Self, _: *gooey.Window) void {
        if (file_dialog.promptForPaths(std.heap.page_allocator, .{
            .files = true,
            .directories = false,
            .multiple = false,
            .prompt = "Attach",
            .message = "Select a file to attach",
            // Supported file types: images (base64), text files (inline), PDFs (Files API).
            .allowed_extensions = &.{ "txt", "md", "json", "csv", "png", "jpg", "jpeg", "gif", "webp", "pdf" },
        })) |result| {
            defer result.deinit();
            if (result.paths.len > 0) {
                const path = result.paths[0];
                const len = @min(path.len, MAX_FILE_PATH_LEN);
                @memcpy(self.attached_file_path[0..len], path[0..len]);
                self.attached_file_path_len = len;
                self.has_attached_file = true;
                log.info("File attached: {s}", .{self.getAttachedFilePath()});
            }
        } else {
            log.debug("File dialog cancelled", .{});
        }
    }

    pub fn clearAttachedFile(self: *Self, _: *gooey.Window) void {
        self.has_attached_file = false;
        self.attached_file_path_len = 0;
    }

    pub fn getAttachedFilePath(self: *const Self) []const u8 {
        return self.attached_file_path[0..self.attached_file_path_len];
    }

    pub fn getAttachedFileName(self: *const Self) []const u8 {
        const path = self.getAttachedFilePath();
        // Find the last '/' to extract just the filename.
        var last_slash: usize = 0;
        for (path, 0..) |c, i| {
            if (c == '/') last_slash = i + 1;
        }
        return path[last_slash..];
    }
};
