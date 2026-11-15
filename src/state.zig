//! Application State Management for ChatZig
//!
//! Handles:
//! - Message history
//! - Input text binding
//! - File attachments via native file dialog
//! - Chat requests and transcription as Gooey background jobs (`jobs.zig`)
//!
//! Background work under Gooey 0.6:
//!   - Gooey runs every handler on the main thread. Requests run as jobs
//!     (`effects.spawn`) on workers Gooey owns; each streamed piece a job
//!     posts arrives at `onChatResult` in the next drain, and each post wakes
//!     the event loop, so nothing polls and an idle window draws nothing.
//!   - A job never touches `AppState`: it reads a copy of the conversation
//!     in `jobs.exchange`, made by `sendMessage`.
//!   - The Stop button calls `effects.cancelJob`; Gooey drops what the job
//!     posted but did not deliver, and the job stops at its next post.
//!   - At quit Gooey cancels and joins every job before `on_deinit`, so no
//!     worker outlives the state.

const std = @import("std");
const log = std.log.scoped(.chatzig);
const gooey = @import("gooey");
const Effects = gooey.Effects;

const anthropic = @import("http/anthropic.zig");
const openai = @import("http/openai.zig");
const audio = @import("audio/mod.zig");
const compaction = @import("compaction.zig");
const session_log_mod = @import("session_log.zig");
const SessionLog = session_log_mod.SessionLog;

const jobs = @import("jobs.zig");
const theme_mod = @import("theme.zig");
const WidthProbe = @import("components/width_probe.zig").WidthProbe;

// =============================================================================
// Constants (CLAUDE rule #4: put a limit on everything)
// =============================================================================

pub const MAX_MESSAGES: usize = 256;
pub const MAX_MESSAGE_LEN: usize = 32768;
pub const MAX_INPUT_LEN: usize = 4096;
pub const MAX_RESPONSE_LEN: usize = 32768;
pub const MAX_FILE_PATH_LEN: usize = 512;
pub const MAX_ATTACHED_FILENAME_LEN: usize = 128;

pub const RECORDING_PATH_MAX_LEN: usize = 128;

/// Row height and gap for the history panel's session list.
pub const HISTORY_ROW_HEIGHT: f32 = 56.0;
pub const HISTORY_ROW_GAP: f32 = 8.0;

/// Extensions the attachment path understands: images (base64), text files
/// (inline), and PDFs (Files API). Gooey's file dialog has no type filter,
/// so `fileChosen` checks the pick against this list instead.
const ATTACHABLE_EXTENSIONS = [_][]const u8{
    "txt", "md", "json", "csv", "png", "jpg", "jpeg", "gif", "webp", "pdf",
};

pub const CHAT_SYSTEM_INSTRUCTION =
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
// `streaming_message_idx` and the transcript's rendered order stay valid
// across a compaction. Failure is therefore free:
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
        return display_names[@backingInt(self)];
    }

    pub fn apiName(self: Model) []const u8 {
        return api_names[@backingInt(self)];
    }

    pub fn provider(self: Model) ModelProvider {
        return providers[@backingInt(self)];
    }

    pub fn contextWindowTokens(self: Model) u32 {
        return context_window_tokens[@backingInt(self)];
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
        return display_names[@backingInt(self)];
    }

    pub fn apiName(self: DictationModel) []const u8 {
        return api_names[@backingInt(self)];
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
        return msg;
    }

    pub fn assistant(text: []const u8) Message {
        var msg = Message{ .role = .assistant };
        const len = @min(text.len, MAX_MESSAGE_LEN);
        @memcpy(msg.content[0..len], text[0..len]);
        msg.content_len = len;
        return msg;
    }
};

// =============================================================================
// AppState
// =============================================================================

/// The settings panel's dropdowns, for `AppState.open_select`.
pub const SelectId = enum(u8) { model, dictation_model, microphone };

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
    // Owned by the main thread. The chat job stages a candidate in
    // `jobs.exchange.summary` and posts a `.compaction` result;
    // `adoptCompaction` copies it here. Nothing below ever touches
    // `messages`.

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
    is_loading: bool = false,
    /// The transcript `List`'s id, which `ContentArea` records as it builds
    /// the list, for `sendMessage` to scroll; null while no list is shown.
    message_list_id: ?gooey.ElementId = null,
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
    /// Which settings dropdown has its menu open. Gooey 0.4's `Select` is
    /// controlled: the app owns the open flag and closes it on a pick or a
    /// click outside.
    open_select: ?SelectId = null,
    /// Width of the composer card's text row, measured by a probe painted
    /// in the last frame (see `InputArea`). Gooey's `TextArea` takes a fixed
    /// width, and render has no window size, so this is how the input
    /// follows the window. 500 px window minus the column and card padding.
    composer_width: f32 = 426,
    /// The `composer_width` the last build used.
    composer_width_used: f32 = 426,
    /// The probe's paint data; it must outlive the build that emits it.
    composer_probe: WidthProbe = .{},

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
    // Background jobs (see `jobs.zig`)
    // =========================================================================

    /// The process's io, from `gooey.Init`: the session log, the history
    /// scan, and the recorder use it on the main thread.
    io: std.Io = undefined,

    /// The chat job in flight, from `sendMessage` until its `on_done`. It
    /// stays set after a Stop until the cancelled job returns, because the
    /// job reads `jobs.exchange.conversation` until then.
    chat_job: ?gooey.JobId = null,

    /// Backs `error_message` when it holds text a job posted or a formatted
    /// error, both of which do not outlive their handler.
    error_buf: [256]u8 = undefined,

    /// Ring-buffer index of the placeholder assistant `Message` we are
    /// currently streaming into, or `null` if no stream is in flight.
    ///
    /// Set by `appendDelta` on the first delta (which appends an empty
    /// `Message.assistant("")`), cleared by `finishChat` / `failChat` /
    /// `cancelInFlight` when the stream ends. The index is into the
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
    /// Carried separately because the log write in `finishChat` /
    /// `failChat` happens once the stream is final, long after
    /// `addMessage` returned this value on the first delta.
    streaming_message_seq: ?u64 = null,

    // =========================================================================
    // Initialization
    // =========================================================================

    /// Gooey's `on_init`: runs once, on the state at its final address,
    /// before the first frame. Creates the HTTP clients the jobs share; they
    /// live in `jobs.exchange`, outside the state, and are never written
    /// again.
    pub fn init(self: *Self, init_options: gooey.Init, _: *Effects) void {
        self.io = init_options.io;
        self.microphone.refresh();

        const api_key = init_options.environ.get("ANTHROPIC_API_KEY");
        self.has_api_key = api_key != null and api_key.?.len > 0;
        if (self.has_api_key) {
            // `page_allocator` is thread-safe, so a job's worker may use it.
            // The key is owned by the process environment, which outlives
            // the app.
            jobs.exchange.anthropic_client = anthropic.AnthropicClient.init(
                api_key.?,
                std.heap.page_allocator,
                self.io,
            );
            log.info("Anthropic API key found", .{});
        } else {
            log.warn("ANTHROPIC_API_KEY not set", .{});
        }

        // OpenAI key is optional: it gates voice transcription
        // (`DictationModel`) and the GPT chat models.
        const openai_api_key = init_options.environ.get("OPENAI_API_KEY");
        self.has_openai_api_key = openai_api_key != null and openai_api_key.?.len > 0;
        if (self.has_openai_api_key) {
            jobs.exchange.openai_client = openai.OpenAIClient.init(
                openai_api_key.?,
                std.heap.page_allocator,
                self.io,
            );
            log.info("OpenAI API key found", .{});
        } else {
            log.warn("OPENAI_API_KEY not set (voice transcription and GPT models disabled)", .{});
        }
    }

    /// Gooey's `on_deinit`: runs after Gooey cancelled and joined every job,
    /// so nothing else touches the state or `jobs.exchange`. Stops a
    /// recording still running so its file is finished.
    pub fn deinit(self: *Self) void {
        std.debug.assert(self.message_count <= MAX_MESSAGES);
        if (self.chat_job != null) log.info("quit with a reply in flight", .{});
        if (self.recording.active) {
            self.recording.active = false;
            audio.stopRecording() catch |err| log.warn("stopping the recording failed: {t}", .{err});
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

        return seq;
    }

    pub fn getMessage(self: *const Self, i: usize) ?*const Message {
        if (i >= self.message_count) return null;
        std.debug.assert(i < MAX_MESSAGES);
        const idx = (self.message_head + i) % MAX_MESSAGES;
        return &self.messages[idx];
    }

    pub fn clearMessages(self: *Self) void {
        self.message_count = 0;
        self.message_head = 0;
        self.error_message = null;
        self.is_loading = false;
    }

    // =========================================================================
    // Send Message — spawns a ChatJob
    // =========================================================================

    pub fn sendMessage(self: *Self, effects: *Effects) void {
        if (self.input_slice.len == 0) return;
        // Single-flight: swallow a second click while a request is
        // outstanding. `chat_job` outlives `is_loading` after a Stop, until
        // the cancelled job returns, because the job still reads
        // `jobs.exchange.conversation` until then.
        if (self.is_loading) return;
        if (self.chat_job != null) {
            self.error_message = "Still stopping the previous reply — send again in a moment";
            return;
        }

        // File attachments (images, PDFs) only exist on Anthropic's wire
        // format today — OpenAI chat support is text-only. Refuse up front,
        // before touching history or clearing input.
        if (self.has_attached_file and self.selected_model.provider() == .openai) {
            self.error_message = "File attachments aren't supported with GPT models yet — switch to a Claude model or remove the attachment";
            return;
        }

        const provider = self.selected_model.provider();
        const configured = switch (provider) {
            .anthropic => jobs.exchange.anthropic_client != null,
            .openai => jobs.exchange.openai_client != null,
        };
        if (!configured) {
            self.error_message = switch (provider) {
                .anthropic => "No Anthropic API key configured",
                .openai => "No OpenAI API key configured",
            };
            return;
        }

        // Add the user's message to the visible history, then durably log
        // it. Logging reads `getAttachedFileName()` before it is cleared.
        const seq = if (self.has_attached_file)
            self.addMessage(Message.userWithFile(self.input_slice, self.getAttachedFileName()))
        else
            self.addMessage(Message.user(self.input_slice));
        // Sending jumps to the new message from wherever the reader was; the
        // list's end anchor then keeps the streamed reply in view.
        if (self.message_list_id) |list| effects.scrollTo(list, .end);

        self.session_log.logUser(
            self.io,
            seq,
            self.input_slice,
            if (self.has_attached_file) self.getAttachedFileName() else null,
        );

        // Hand the job its own copy of everything it reads, including the
        // turn just added and the attachment's path.
        const attachment = if (self.has_attached_file) self.getAttachedFilePath() else "";
        jobs.exchange.conversation.capture(self, attachment);

        // Clear input + attachment from the UI. The `TextArea` bound to
        // `input_slice` adopts the empty value on the next build.
        self.input_slice = "";
        self.has_attached_file = false;
        self.attached_file_path_len = 0;
        self.is_loading = true;
        self.error_message = null;

        // A full job table panics, naming `events.job_count_max`; chat-zig
        // runs at most one chat job and one transcription.
        self.chat_job = effects.spawn(jobs.ChatJob, &.{ .provider = provider }, .{
            .on_result = effects.handler(Self.onChatResult),
            .on_done = effects.handler(Self.onChatDone),
        });
    }

    // =========================================================================
    // Cancel In-Flight — Stop button
    // =========================================================================

    /// Stops the reply in flight, if any. Safe to call with none.
    ///
    /// The UI resets now: Gooey drops results the cancelled job had posted
    /// but not delivered, so no delta lands after this. The partial bubble
    /// stays. The job itself stops at its next post or cancellation check
    /// (the next SSE delta), and `chat_job` stays set until its `on_done`.
    pub fn cancelInFlight(self: *Self, effects: *Effects) void {
        const id = self.chat_job orelse return;
        if (!self.is_loading) return; // Already stopped; waiting for `on_done`.

        effects.cancelJob(id);
        self.is_loading = false;
        self.streaming_message_idx = null;
        self.streaming_message_seq = null;
        self.error_message = null;
        log.info("Streaming request cancelled by user", .{});
    }

    // =========================================================================
    // Job results — Gooey calls these on the main thread, in the next drain
    // =========================================================================

    /// `ChatJob`'s `on_result`: a streamed piece of the reply, the stream's
    /// error, or a compaction to adopt.
    pub fn onChatResult(self: *Self, effects: *Effects) void {
        const result = effects.jobResult(jobs.ChatJob).?;
        std.debug.assert(self.chat_job != null);
        std.debug.assert(self.is_loading); // Results of a cancelled job are dropped.
        switch (result.*) {
            .delta => |*text| self.appendDelta(text.slice()),
            .failure => |*text| self.failChat(text.slice()),
            .compaction => |cut| self.adoptCompaction(cut.len, cut.covers),
        }
    }

    /// `ChatJob`'s `on_done`, once, last. The job no longer reads
    /// `jobs.exchange`, so the next send may overwrite it.
    pub fn onChatDone(self: *Self, effects: *Effects) void {
        const done = effects.jobDone().?;
        std.debug.assert(std.meta.eql(done.id, self.chat_job.?));
        self.chat_job = null;
        // A Stop or a posted failure already ended the turn.
        if (!self.is_loading) return;

        switch (done.outcome) {
            .finished => self.finishChat(),
            // Only `cancelInFlight` cancels, and it clears `is_loading` first.
            .cancelled => self.failChat("The request was cancelled"),
            .failed => |err| {
                const message = std.fmt.bufPrint(&self.error_buf, "The request failed: {t}", .{err}) catch
                    "The request failed";
                self.failChat(message);
            },
        }
    }

    /// Append one streamed piece to the reply, creating the assistant
    /// message on the first one.
    fn appendDelta(self: *Self, text: []const u8) void {
        std.debug.assert(self.is_loading);
        std.debug.assert(text.len > 0);

        if (self.streaming_message_idx == null) {
            const seq = self.addMessage(Message.assistant(""));
            std.debug.assert(self.message_count > 0);
            self.streaming_message_idx = @intCast(self.message_count - 1);
            self.streaming_message_seq = seq;
        }

        const idx = self.streaming_message_idx.?;
        std.debug.assert(idx < self.message_count);
        const ring_idx = (self.message_head + idx) % MAX_MESSAGES;
        const msg = &self.messages[ring_idx];
        std.debug.assert(msg.role == .assistant);
        std.debug.assert(msg.content_len <= MAX_MESSAGE_LEN);

        const kept = @min(text.len, MAX_MESSAGE_LEN - msg.content_len);
        @memcpy(msg.content[msg.content_len..][0..kept], text[0..kept]);
        msg.content_len += kept;
    }

    /// The stream ended without an error: log the final reply.
    fn finishChat(self: *Self) void {
        std.debug.assert(self.is_loading);
        if (self.streaming_message_idx) |idx| {
            const text = self.getMessage(idx).?.getText();
            self.session_log.logAssistant(self.io, self.streaming_message_seq.?, text);
        } else {
            // No deltas: show an empty reply rather than silently dropping
            // the turn.
            const seq = self.addMessage(Message.assistant(""));
            self.session_log.logAssistant(self.io, seq, "");
        }
        self.streaming_message_idx = null;
        self.streaming_message_seq = null;
        self.error_message = null;
        self.is_loading = false;
    }

    /// The stream failed: keep and log any partial reply, show `message`.
    fn failChat(self: *Self, message: []const u8) void {
        std.debug.assert(self.is_loading);
        if (self.streaming_message_idx) |idx| {
            const text = self.getMessage(idx).?.getText();
            self.session_log.logAssistant(self.io, self.streaming_message_seq.?, text);
        }
        self.streaming_message_idx = null;
        self.streaming_message_seq = null;
        self.setError(message);
        self.is_loading = false;
    }

    /// Show `message`, copied: a job's text lives only while it is
    /// delivered.
    fn setError(self: *Self, message: []const u8) void {
        if (@intFromPtr(message.ptr) == @intFromPtr(&self.error_buf)) {
            self.error_message = message;
            return;
        }
        const len = @min(message.len, self.error_buf.len);
        @memcpy(self.error_buf[0..len], message[0..len]);
        self.error_message = self.error_buf[0..len];
    }

    /// Adopt the summary the job staged in `jobs.exchange.summary`,
    /// advancing the cut every future request assembles from. Nothing here
    /// touches `messages`, so the transcript and its scroll are unchanged.
    /// Also durably records the summary, so a restored session inherits it.
    fn adoptCompaction(self: *Self, len: u32, covers: u64) void {
        std.debug.assert(len > 0);
        std.debug.assert(len <= MAX_SUMMARY_LEN);
        std.debug.assert(covers > self.summary_covers); // Must make progress.
        std.debug.assert(covers <= self.messages_total);

        @memcpy(self.summary_buf[0..len], jobs.exchange.summary[0..len]);
        self.summary_len = len;
        self.summary_covers = covers;
        self.session_log.logSummary(self.io, self.messages_total, covers, self.summary_buf[0..len]);
        log.info("compaction applied: {d} messages now summarized in {d} bytes", .{ covers, len });
    }

    /// Clears the derived compaction state. Called wherever the transcript
    /// those `seq` numbers refer to is replaced — a stale `summary_covers`
    /// against a different conversation would silently truncate the new
    /// one's history.
    fn clearCompaction(self: *Self) void {
        self.summary_len = 0;
        self.summary_covers = 0;
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

    /// `TranscribeJob`'s `on_result`: the transcript replaces the input
    /// box's text, or the error shows.
    pub fn onTranscribed(self: *Self, effects: *Effects) void {
        const result = effects.jobResult(jobs.TranscribeJob).?;
        std.debug.assert(self.is_transcribing);
        switch (result.*) {
            .transcript => |*text| {
                const transcript = text.slice();
                std.debug.assert(transcript.len <= self.input_text.len);
                @memcpy(self.input_text[0..transcript.len], transcript);
                self.input_slice = self.input_text[0..transcript.len];
                self.error_message = null;
            },
            .failure => |*text| self.setError(text.slice()),
        }
    }

    /// `TranscribeJob`'s `on_done`, once, last.
    pub fn onTranscribeDone(self: *Self, effects: *Effects) void {
        const done = effects.jobDone().?;
        std.debug.assert(self.is_transcribing);
        self.is_transcribing = false;
        switch (done.outcome) {
            .finished, .cancelled => {},
            .failed => |err| {
                const message = std.fmt.bufPrint(&self.error_buf, "Transcription failed: {t}", .{err}) catch
                    "Transcription failed";
                self.setError(message);
            },
        }
    }

    // =========================================================================
    // Theme / Model Toggles
    // =========================================================================

    /// Flips the palette. Gooey's stock components (`TextArea`, `Select`)
    /// read theme tokens, so the matching `gooey.Theme` goes with it.
    pub fn toggleDarkMode(self: *Self, effects: *Effects) void {
        self.dark_mode = !self.dark_mode;
        effects.setTheme(theme_mod.gooeyFor(self.dark_mode));
    }

    /// Toggles the settings view. Mutually exclusive with the history view
    /// (`history_expanded`) — opening settings closes history, since both
    /// take over the content area in place of `ContentArea`.
    pub fn toggleSettings(self: *Self) void {
        std.debug.assert(self.microphone.devices.count <= audio.MAX_INPUT_DEVICES);
        std.debug.assert(self.message_count <= MAX_MESSAGES);
        self.settings_expanded = !self.settings_expanded;
        if (self.settings_expanded) self.history_expanded = false;
        self.open_select = null;
    }

    /// Toggles the history panel. Opening it re-scans `sessions/*.jsonl`
    /// (see `refreshSessionHistory`) so the list reflects any sessions
    /// written since it was last opened; closing it leaves the last scan in
    /// place rather than clearing it, since re-opening will just rescan.
    /// Mutually exclusive with the settings view — see `toggleSettings`.
    pub fn toggleHistory(self: *Self) void {
        std.debug.assert(self.session_entry_count <= session_log_mod.MAX_SESSION_ENTRIES);
        self.history_expanded = !self.history_expanded;
        if (self.history_expanded) self.settings_expanded = false;
        if (self.history_expanded) self.refreshSessionHistory();
        self.open_select = null;
    }

    /// Scans `sessions/*.jsonl` (via `session_log.listSessions`) into
    /// `session_entries`, newest first.
    fn refreshSessionHistory(self: *Self) void {
        std.debug.assert(self.session_entry_count <= session_log_mod.MAX_SESSION_ENTRIES);

        const io = self.io;
        self.session_entry_count = session_log_mod.listSessions(std.Io.Dir.cwd(), io, &self.session_entries);
        std.debug.assert(self.session_entry_count <= session_log_mod.MAX_SESSION_ENTRIES);
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
    pub fn loadSession(self: *Self, index: u32, effects: *Effects) void {
        std.debug.assert(self.session_entry_count <= session_log_mod.MAX_SESSION_ENTRIES);
        const entry = self.getSessionEntry(index) orelse return;
        std.debug.assert(entry.unix_seconds > 0);

        self.cancelInFlight(effects);
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
            self.io,
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

        self.history_expanded = false;
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
    pub fn newConversation(self: *Self, effects: *Effects) void {
        std.debug.assert(self.session_entry_count <= session_log_mod.MAX_SESSION_ENTRIES);

        self.cancelInFlight(effects);
        self.clearMessages();

        self.session_log.startNew(self.io);
        self.messages_total = 0;
        self.clearCompaction();

        self.history_expanded = false;
        std.debug.assert(self.message_count == 0);
    }

    pub fn selectModel(self: *Self, index: u32) void {
        std.debug.assert(index < MODEL_COUNT);
        self.selected_model = @fromBackingInt(@intCast(index));
        self.open_select = null;
    }

    pub fn selectDictationModel(self: *Self, index: u32) void {
        std.debug.assert(index < DICTATION_MODEL_COUNT);
        std.debug.assert(index < DictationModel.api_names.len);
        self.selected_dictation_model = @fromBackingInt(@intCast(index));
        self.open_select = null;
    }

    pub fn selectMicrophone(self: *Self, index: u32) void {
        std.debug.assert(index < self.microphone.devices.count);
        std.debug.assert(index < audio.MAX_INPUT_DEVICES);
        self.microphone.selected = index;
        self.open_select = null;
    }

    /// `Select.on_toggle`: opens `select`'s menu, closing any other.
    pub fn toggleSelect(self: *Self, select: SelectId) void {
        self.open_select = if (self.open_select == select) null else select;
    }

    /// `Select.on_close`: a click outside the open menu, or Escape.
    pub fn closeSelect(self: *Self, select: SelectId) void {
        if (self.open_select == select) self.open_select = null;
    }

    pub fn refreshMicrophones(self: *Self) void {
        std.debug.assert(self.microphone.devices.count <= audio.MAX_INPUT_DEVICES);
        std.debug.assert(!self.recording.active);
        self.microphone.refresh();
    }

    pub fn toggleRecording(self: *Self, effects: *Effects) void {
        std.debug.assert(self.microphone.devices.count <= audio.MAX_INPUT_DEVICES);
        std.debug.assert(self.recording.path_len <= RECORDING_PATH_MAX_LEN);

        if (self.recording.active) {
            self.recording.active = false;
            if (audio.stopRecording()) |_| {
                self.recording.last_error = null;
                self.startTranscription(effects);
            } else |capture_error| {
                self.recording.last_error = capture_error;
            }
            return;
        }

        const selected = self.microphone.selected orelse return;
        std.debug.assert(selected < self.microphone.devices.count);
        const device = self.microphone.devices.slice()[selected];

        if (!self.recording.preparePath(self.io)) {
            self.recording.last_error = error.FileError;
            return;
        }

        audio.startRecording(self.io, device, self.recording.path()) catch |capture_error| {
            self.recording.last_error = capture_error;
            return;
        };

        self.recording.last_error = null;
        self.recording.active = true;
    }

    /// Kicks off background transcription of the just-finished recording
    /// via the user's selected OpenAI transcription model (`DictationModel`,
    /// configurable in Settings). No-op if no OpenAI key is configured, or
    /// the recording never got a path (both defensive — `toggleRecording`
    /// only calls this after a successful `stopRecording`) — voice
    /// recording works fine without transcription, it's a bonus.
    ///
    /// The job gets a copy of the recording's path in its input: Gooey
    /// rejects job inputs that point anywhere, and `preparePath` overwrites
    /// `self.recording.path_buffer` when a new recording starts.
    fn startTranscription(self: *Self, effects: *Effects) void {
        std.debug.assert(!self.is_transcribing);
        std.debug.assert(self.recording.path_len <= RECORDING_PATH_MAX_LEN);

        if (jobs.exchange.openai_client == null) return;
        if (self.recording.path_len == 0) return;

        var input: jobs.TranscribeJob.Input = .{
            .path = undefined,
            .path_len = @intCast(self.recording.path_len),
            .model = self.selected_dictation_model,
        };
        @memcpy(input.path[0..self.recording.path_len], self.recording.path());
        _ = effects.spawn(jobs.TranscribeJob, &input, .{
            .on_result = effects.handler(Self.onTranscribed),
            .on_done = effects.handler(Self.onTranscribeDone),
        });
        self.is_transcribing = true;
        self.error_message = null;
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

    /// Asks Gooey for the native open dialog; the pick arrives in
    /// `fileChosen` on a later drain, on the main thread.
    pub fn openFileDialog(_: *Self, effects: *Effects) void {
        effects.openFileDialog(.{
            .kind = .{ .open = .{ .files = true, .directories = false, .multiple = false } },
            .on_complete = effects.handler(Self.fileChosen),
        });
    }

    pub fn fileChosen(self: *Self, effects: *Effects) void {
        const completion = effects.completionEvent().?;
        switch (completion.outcome) {
            .file_selected => |paths| self.attachFile(paths.first()),
            .cancelled => log.debug("File dialog cancelled", .{}),
            .failed => |err| {
                log.warn("File dialog failed: {t}", .{err});
                self.error_message = "The file dialog failed to open";
            },
        }
    }

    /// Stages `path` as the next message's attachment, if the request
    /// builders understand its type and the path fits.
    fn attachFile(self: *Self, path: []const u8) void {
        std.debug.assert(path.len > 0);
        if (path.len > MAX_FILE_PATH_LEN) {
            self.error_message = "That file's path is too long to attach";
            return;
        }
        if (!isAttachable(path)) {
            self.error_message = "Attach a text, Markdown, JSON, CSV, image, or PDF file";
            return;
        }
        @memcpy(self.attached_file_path[0..path.len], path);
        self.attached_file_path_len = path.len;
        self.has_attached_file = true;
        self.error_message = null;
        log.info("File attached: {s}", .{self.getAttachedFilePath()});
    }

    fn isAttachable(path: []const u8) bool {
        const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
        const extension = path[dot + 1 ..];
        for (ATTACHABLE_EXTENSIONS) |allowed| {
            if (std.ascii.eqlIgnoreCase(extension, allowed)) return true;
        }
        return false;
    }

    pub fn clearAttachedFile(self: *Self) void {
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
