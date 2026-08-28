//! macOS microphone capture via CoreAudio's AudioQueue Services
//! (`AudioToolbox`), streaming PCM straight to a WAV file on disk.
//!
//! AudioQueue is used instead of the lower-latency `AudioUnit` render
//! callback because, with a `NULL` run loop, it delivers buffers on a
//! CoreAudio-managed background thread with no hard real-time
//! constraints — so blocking file I/O directly in the callback is safe.
//!
//! Only one recording is supported at a time; state lives in a single
//! module-level `RecordingContext`.

const std = @import("std");
const devices = @import("devices.zig");
const writer = @import("writer.zig");
const waveform = @import("waveform.zig");

/// Number of bars in the live "while recording" meter. Re-exported from
/// `waveform.zig` so callers only need to depend on `recorder.zig` (and,
/// transitively, `mod.zig`).
pub const WAVEFORM_BAR_COUNT = waveform.WAVEFORM_BAR_COUNT;

const CFStringRef = devices.CFStringRef;
const CFStringCreateWithBytes = devices.CFStringCreateWithBytes;
const CFRelease = devices.CFRelease;
const kCFStringEncodingUTF8 = devices.kCFStringEncodingUTF8;
const OSStatus = devices.OSStatus;
const kNoErr = devices.kNoErr;
const fourCC = devices.fourCC;

const InputDevice = devices.InputDevice;

/// Shared across every capture backend so `mod.zig` can forward calls
/// to whichever one is compiled in without a type mismatch.
pub const RecorderError = error{
    AlreadyRecording,
    NotRecording,
    BackendError,
    FileError,
};

/// Fixed at 16-bit/44.1kHz, sufficient for dictation-quality speech.
/// Channel count is queried per-device at record-start time instead
/// (see `InputDevice.channel_count`), so stereo devices stay stereo.
pub const RECORDING_SAMPLE_RATE: u32 = 44100;
pub const RECORDING_BITS_PER_SAMPLE: u16 = 16;

const AudioQueueRef = ?*anyopaque;

const AudioQueueBuffer = extern struct {
    mAudioDataBytesCapacity: u32,
    mAudioData: ?*anyopaque,
    mAudioDataByteSize: u32,
    mUserData: ?*anyopaque,
    mPacketDescriptionCapacity: u32,
    mPacketDescriptions: ?*anyopaque,
    mPacketDescriptionCount: u32,
};
const AudioQueueBufferRef = ?*AudioQueueBuffer;

const AudioStreamBasicDescription = extern struct {
    mSampleRate: f64,
    mFormatID: u32,
    mFormatFlags: u32,
    mBytesPerPacket: u32,
    mFramesPerPacket: u32,
    mBytesPerFrame: u32,
    mChannelsPerFrame: u32,
    mBitsPerChannel: u32,
    mReserved: u32 = 0,
};

const AudioQueueInputCallback = *const fn (
    in_user_data: ?*anyopaque,
    in_aq: AudioQueueRef,
    in_buffer: AudioQueueBufferRef,
    in_start_time: ?*const anyopaque, // AudioTimeStamp*, unused
    in_num_packet_descs: u32,
    in_packet_descs: ?*const anyopaque, // AudioStreamPacketDescription*, unused
) callconv(.c) void;

extern "c" fn AudioQueueNewInput(
    in_format: *const AudioStreamBasicDescription,
    in_callback: AudioQueueInputCallback,
    in_user_data: ?*anyopaque,
    in_callback_run_loop: ?*anyopaque, // CFRunLoopRef — NULL runs on a queue-owned thread
    in_callback_run_loop_mode: ?*anyopaque, // CFStringRef — ignored when the run loop is NULL
    in_flags: u32,
    out_aq: *AudioQueueRef,
) OSStatus;

extern "c" fn AudioQueueAllocateBuffer(in_aq: AudioQueueRef, in_buffer_byte_size: u32, out_buffer: *AudioQueueBufferRef) OSStatus;
extern "c" fn AudioQueueEnqueueBuffer(in_aq: AudioQueueRef, in_buffer: AudioQueueBufferRef, in_num_packet_descs: u32, in_packet_descs: ?*const anyopaque) OSStatus;
extern "c" fn AudioQueueStart(in_aq: AudioQueueRef, in_start_time: ?*const anyopaque) OSStatus;
extern "c" fn AudioQueueStop(in_aq: AudioQueueRef, in_immediate: u8) OSStatus; // Boolean
extern "c" fn AudioQueueDispose(in_aq: AudioQueueRef, in_immediate: u8) OSStatus; // Boolean
extern "c" fn AudioQueueSetProperty(in_aq: AudioQueueRef, in_property_id: u32, in_data: ?*const anyopaque, in_data_size: u32) OSStatus;

const kAudioFormatLinearPCM: u32 = fourCC("lpcm");
const kAudioFormatFlagIsSignedInteger: u32 = 1 << 2;
const kAudioFormatFlagIsPacked: u32 = 1 << 3;
const kAudioQueueProperty_CurrentDevice: u32 = fourCC("aqcd");

/// Three is the standard AudioQueue recording recipe: one being filled
/// by hardware, one queued behind it, one being drained by the callback.
const NUM_BUFFERS: usize = 3;

/// ~46-93ms of 16-bit audio at 44.1kHz: low enough for latency, high
/// enough to keep the callback rate well under 100Hz.
const BUFFER_BYTE_SIZE: u32 = 8192;

const BackendFailure = enum(u8) {
    stop = 1 << 0,
    dispose = 1 << 1,
    enqueue = 1 << 2,
};

const Lifecycle = struct {
    claimed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    backend_failures: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    fn claim(self: *Lifecycle) bool {
        std.debug.assert(@intFromEnum(BackendFailure.stop) != 0);
        std.debug.assert(@intFromEnum(BackendFailure.dispose) != 0);
        return self.claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) == null;
    }

    fn release(self: *Lifecycle) void {
        std.debug.assert(self.claimed.load(.acquire));
        std.debug.assert(@intFromEnum(BackendFailure.enqueue) != 0);
        self.claimed.store(false, .release);
    }

    fn resetFailures(self: *Lifecycle) void {
        std.debug.assert(self.claimed.load(.acquire));
        std.debug.assert(@intFromEnum(BackendFailure.stop) != @intFromEnum(BackendFailure.dispose));
        self.backend_failures.store(0, .release);
    }

    fn recordFailure(self: *Lifecycle, failure: BackendFailure) void {
        const failure_bit = @intFromEnum(failure);
        std.debug.assert(failure_bit != 0);
        std.debug.assert(failure_bit & (failure_bit - 1) == 0);
        _ = self.backend_failures.fetchOr(failure_bit, .acq_rel);
    }

    fn backendResult(self: *const Lifecycle) RecorderError!void {
        const failures = self.backend_failures.load(.acquire);
        std.debug.assert(failures & ~@as(u8, 0b111) == 0);
        std.debug.assert(@intFromEnum(BackendFailure.enqueue) == 0b100);
        if (failures != 0) return error.BackendError;
    }
};

const RecordingContext = struct {
    queue: AudioQueueRef = null,
    writer: writer.WavWriter = undefined,
    /// Overwritten by `start()` with the selected device's real channel
    /// count; never read before that assignment happens.
    format: writer.Format = .{
        .sample_rate = RECORDING_SAMPLE_RATE,
        .num_channels = devices.RECORDING_CHANNELS_FALLBACK,
        .bits_per_sample = RECORDING_BITS_PER_SAMPLE,
    },
    lifecycle: Lifecycle = .{},
    recording: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    write_failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    waveform: waveform.WaveformHistory = .{},
};

/// Global by necessity: `start` hands `&g_ctx` to CoreAudio as
/// `inputCallback`'s `in_user_data`, and only one recording is ever
/// supported at a time.
var g_ctx: RecordingContext = .{};

/// Tears down a partially- or fully-set-up queue on any failure path in
/// `start`.
fn disposeQueue(queue: AudioQueueRef) void {
    std.debug.assert(queue != null);

    const status = AudioQueueDispose(queue, 1);
    if (status != kNoErr) std.log.debug("disposeQueue: AudioQueueDispose failed (status {d})", .{status});
}

/// Directs `queue`'s input to the exact device UID requested by the
/// caller; never silently falls back to the default microphone.
fn selectDevice(queue: AudioQueueRef, device: *const InputDevice) RecorderError!void {
    std.debug.assert(queue != null);
    std.debug.assert(device.uid_len <= devices.DEVICE_NAME_MAX_LEN);

    const uid = device.uid();
    if (!shouldSelectDevice(uid)) return error.BackendError;

    const cf_uid = CFStringCreateWithBytes(null, uid.ptr, @intCast(uid.len), kCFStringEncodingUTF8, 0);
    if (cf_uid == null) return error.BackendError;
    defer CFRelease(cf_uid);

    const status = AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, @ptrCast(&cf_uid), @sizeOf(CFStringRef));
    if (status != kNoErr) {
        std.log.debug("selectDevice: AudioQueueSetProperty failed (status {d})", .{status});
        return error.BackendError;
    }
}

/// Pure guard for `selectDevice`, unit-testable without CoreAudio.
fn shouldSelectDevice(uid: []const u8) bool {
    return uid.len > 0;
}

/// Bytes per frame for uncompressed linear PCM, where a "packet" is
/// exactly one frame — so this also serves as `mBytesPerPacket` in the
/// `AudioStreamBasicDescription`.
fn bytesPerFrame(format: writer.Format) u32 {
    std.debug.assert(format.num_channels > 0);
    std.debug.assert(format.bits_per_sample % 8 == 0);

    const result: u32 = @as(u32, format.num_channels) * (format.bits_per_sample / 8);

    std.debug.assert(result > 0);
    return result;
}

/// Builds the `AudioStreamBasicDescription` CoreAudio needs to open an
/// input queue for `format`.
fn buildAsbd(format: writer.Format) AudioStreamBasicDescription {
    const bytes_per_frame = bytesPerFrame(format);

    return .{
        .mSampleRate = @floatFromInt(format.sample_rate),
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = bytes_per_frame,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = bytes_per_frame,
        .mChannelsPerFrame = format.num_channels,
        .mBitsPerChannel = format.bits_per_sample,
    };
}

pub fn start(io: std.Io, device: InputDevice, output_path: []const u8) RecorderError!void {
    if (!g_ctx.lifecycle.claim()) return error.AlreadyRecording;
    var retain_claim = false;
    defer if (!retain_claim) g_ctx.lifecycle.release();
    g_ctx.lifecycle.resetFailures();

    const channel_count = device.channel_count;
    std.debug.assert(channel_count > 0);
    std.debug.assert(channel_count <= devices.RECORDING_MAX_CHANNELS);
    g_ctx.format = .{
        .sample_rate = RECORDING_SAMPLE_RATE,
        .num_channels = channel_count,
        .bits_per_sample = RECORDING_BITS_PER_SAMPLE,
    };

    g_ctx.writer = writer.WavWriter.create(io, .cwd(), output_path, g_ctx.format) catch return error.FileError;
    // Any failure below leaves a useless zero-sample WAV; clean it up.
    errdefer {
        g_ctx.writer.file.close(io);
        std.Io.Dir.cwd().deleteFile(io, output_path) catch {};
    }

    const asbd = buildAsbd(g_ctx.format);

    var queue: AudioQueueRef = null;
    var status = AudioQueueNewInput(&asbd, inputCallback, &g_ctx, null, null, 0, &queue);
    if (status != kNoErr or queue == null) return error.BackendError;
    g_ctx.queue = queue;
    errdefer {
        disposeQueue(queue);
        g_ctx.queue = null;
    }

    try selectDevice(queue, &device);

    if (!allocateAndEnqueueBuffers(queue)) return error.BackendError;

    g_ctx.write_failed.store(false, .release);
    g_ctx.waveform.reset();

    status = AudioQueueStart(queue, null);
    if (status != kNoErr) return error.BackendError;

    g_ctx.recording.store(true, .release);
    retain_claim = true;
}

/// Allocates and enqueues `NUM_BUFFERS` input buffers on `queue`.
/// Returns `false` (queue left for the caller to dispose) on failure.
fn allocateAndEnqueueBuffers(queue: AudioQueueRef) bool {
    std.debug.assert(queue != null);
    std.debug.assert(NUM_BUFFERS > 0);

    var i: usize = 0;
    while (i < NUM_BUFFERS) : (i += 1) {
        var buffer: AudioQueueBufferRef = null;
        const allocate_status = AudioQueueAllocateBuffer(queue, BUFFER_BYTE_SIZE, &buffer);
        if (allocate_status != kNoErr or buffer == null) return false;

        const enqueue_status = AudioQueueEnqueueBuffer(queue, buffer, 0, null);
        if (enqueue_status != kNoErr) return false;
    }

    std.debug.assert(i == NUM_BUFFERS);
    return true;
}

pub fn stop() RecorderError!void {
    if (!g_ctx.recording.swap(false, .acq_rel)) return error.NotRecording;
    std.debug.assert(g_ctx.lifecycle.claimed.load(.acquire));
    std.debug.assert(!g_ctx.recording.load(.acquire));
    defer g_ctx.lifecycle.release();

    if (g_ctx.queue) |queue| {
        // `inImmediate = true` halts callback delivery synchronously, so no
        // callback can touch `g_ctx.writer` concurrently with `finalize` below.
        const stop_status = AudioQueueStop(queue, 1);
        const dispose_status = AudioQueueDispose(queue, 1);
        if (stop_status != kNoErr) {
            g_ctx.lifecycle.recordFailure(.stop);
            std.log.debug("stop: AudioQueueStop failed (status {d})", .{stop_status});
        }
        if (dispose_status != kNoErr) {
            g_ctx.lifecycle.recordFailure(.dispose);
            std.log.debug("stop: AudioQueueDispose failed (status {d})", .{dispose_status});
        }
        g_ctx.queue = null;
    } else {
        // Missing backend state must not bypass file finalization.
        g_ctx.lifecycle.recordFailure(.stop);
        std.debug.assert(g_ctx.queue == null);
    }

    std.debug.assert(g_ctx.format.num_channels > 0);
    g_ctx.writer.finalize() catch return error.FileError;

    if (g_ctx.write_failed.load(.acquire)) return error.FileError;
    try g_ctx.lifecycle.backendResult();
}

/// Snapshot of the last `WAVEFORM_BAR_COUNT` amplitude levels, oldest
/// first, for the UI thread to spring a live meter toward. Always safe
/// to call, recording or not — reads silence (all zeros) otherwise.
pub fn waveformLevels() [WAVEFORM_BAR_COUNT]f32 {
    return g_ctx.waveform.snapshot();
}

/// Runs on a CoreAudio-managed background thread, never the UI thread.
fn inputCallback(
    in_user_data: ?*anyopaque,
    in_aq: AudioQueueRef,
    in_buffer: AudioQueueBufferRef,
    _: ?*const anyopaque,
    _: u32,
    _: ?*const anyopaque,
) callconv(.c) void {
    const ctx: *RecordingContext = @ptrCast(@alignCast(in_user_data.?));
    std.debug.assert(ctx == &g_ctx);

    const buffer = in_buffer.?;
    std.debug.assert(buffer.mAudioDataByteSize <= buffer.mAudioDataBytesCapacity);

    if (shouldWriteBuffer(ctx.recording.load(.acquire), buffer.mAudioDataByteSize)) {
        const bytes: []const u8 = @as([*]const u8, @ptrCast(buffer.mAudioData.?))[0..buffer.mAudioDataByteSize];
        ctx.waveform.push(bytes);
        ctx.writer.writeSamples(bytes) catch {
            ctx.write_failed.store(true, .release);
        };
    }

    // Re-enqueue so CoreAudio always has buffers to fill; a failure is
    // retained for `stop()` because callbacks cannot return it.
    const enqueue_status = AudioQueueEnqueueBuffer(in_aq, in_buffer, 0, null);
    if (enqueue_status != kNoErr and ctx.recording.load(.acquire)) {
        ctx.lifecycle.recordFailure(.enqueue);
    }
}

/// Pure guard for `inputCallback`, unit-testable without a live callback.
fn shouldWriteBuffer(is_recording: bool, byte_size: u32) bool {
    return is_recording and byte_size > 0;
}

test "concurrent start reservation permits exactly one claim" {
    const Worker = struct {
        fn run(lifecycle: *Lifecycle, successes: *std.atomic.Value(u8)) void {
            std.debug.assert(@intFromPtr(lifecycle) != 0);
            std.debug.assert(successes.load(.acquire) <= 1);
            if (lifecycle.claim()) _ = successes.fetchAdd(1, .acq_rel);
        }
    };

    var lifecycle = Lifecycle{};
    var successes = std.atomic.Value(u8).init(0);
    const first = try std.Thread.spawn(.{}, Worker.run, .{ &lifecycle, &successes });
    const second = try std.Thread.spawn(.{}, Worker.run, .{ &lifecycle, &successes });
    first.join();
    second.join();

    try std.testing.expectEqual(@as(u8, 1), successes.load(.acquire));
    try std.testing.expect(lifecycle.claimed.load(.acquire));
    lifecycle.release();
}

test "failed start releases its reservation for the next start" {
    var lifecycle = Lifecycle{};
    try std.testing.expect(lifecycle.claim());
    lifecycle.resetFailures();
    lifecycle.release();

    try std.testing.expect(lifecycle.claim());
    try std.testing.expect(lifecycle.claimed.load(.acquire));
    lifecycle.release();
}

test "stop dispose and enqueue failures map to BackendError" {
    inline for (.{ BackendFailure.stop, BackendFailure.dispose, BackendFailure.enqueue }) |failure| {
        var lifecycle = Lifecycle{};
        try std.testing.expect(lifecycle.claim());
        lifecycle.resetFailures();
        lifecycle.recordFailure(failure);

        try std.testing.expectError(error.BackendError, lifecycle.backendResult());
        lifecycle.release();
    }
}

test "backend failure bookkeeping resets between recordings" {
    var lifecycle = Lifecycle{};
    try std.testing.expect(lifecycle.claim());
    lifecycle.recordFailure(.enqueue);
    try std.testing.expectError(error.BackendError, lifecycle.backendResult());

    lifecycle.resetFailures();
    try lifecycle.backendResult();
    lifecycle.release();
}

test "stop finalizes the WAV file when its queue is missing" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const format = writer.Format{ .sample_rate = 8000, .num_channels = 1, .bits_per_sample = 16 };
    g_ctx.writer = try writer.WavWriter.create(io, tmp_dir.dir, "missing_queue.wav", format);
    try g_ctx.writer.writeSamples(&[_]u8{ 1, 2 });
    g_ctx.format = format;
    g_ctx.queue = null;
    g_ctx.write_failed.store(false, .release);
    try std.testing.expect(g_ctx.lifecycle.claim());
    g_ctx.lifecycle.resetFailures();
    g_ctx.recording.store(true, .release);

    try std.testing.expectError(error.BackendError, stop());
    try std.testing.expect(!g_ctx.lifecycle.claimed.load(.acquire));

    var read_buffer: [46]u8 = undefined;
    const contents = try tmp_dir.dir.readFile(io, "missing_queue.wav", &read_buffer);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, contents[40..44], .little));
    try std.testing.expectEqual(@as(usize, 46), contents.len);
}

test "current-device selector matches AudioQueue.h" {
    try std.testing.expectEqual(@as(u32, 0x6171_6364), kAudioQueueProperty_CurrentDevice);
    try std.testing.expectEqual(fourCC("aqcd"), kAudioQueueProperty_CurrentDevice);
}

test "selectDevice rejects an empty UID before calling CoreAudio" {
    // Sentinel queue is safe: the missing UID must return before the FFI call.
    const queue: AudioQueueRef = @ptrFromInt(1);
    const device = InputDevice{};
    try std.testing.expectError(error.BackendError, selectDevice(queue, &device));
    try std.testing.expect(!shouldSelectDevice(device.uid()));
}

test "shouldSelectDevice accepts a non-empty UID" {
    var device = InputDevice{};
    device.uid_len = 4;
    @memcpy(device.uid_buffer[0..4], "abcd");
    try std.testing.expect(shouldSelectDevice(device.uid()));
}

test "bytesPerFrame: mono and stereo 16-bit" {
    try std.testing.expectEqual(@as(u32, 2), bytesPerFrame(.{ .sample_rate = 44100, .num_channels = 1, .bits_per_sample = 16 }));
    try std.testing.expectEqual(@as(u32, 4), bytesPerFrame(.{ .sample_rate = 44100, .num_channels = 2, .bits_per_sample = 16 }));
}

test "buildAsbd: every field matches the requested format exactly" {
    const format = writer.Format{ .sample_rate = 44100, .num_channels = 2, .bits_per_sample = 16 };
    const asbd = buildAsbd(format);

    try std.testing.expectEqual(@as(f64, 44100.0), asbd.mSampleRate);
    try std.testing.expectEqual(kAudioFormatLinearPCM, asbd.mFormatID);
    try std.testing.expectEqual(kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, asbd.mFormatFlags);
    try std.testing.expectEqual(bytesPerFrame(format), asbd.mBytesPerPacket);
    try std.testing.expectEqual(bytesPerFrame(format), asbd.mBytesPerFrame);
    try std.testing.expectEqual(@as(u32, 1), asbd.mFramesPerPacket);
    try std.testing.expectEqual(@as(u32, 2), asbd.mChannelsPerFrame);
    try std.testing.expectEqual(@as(u32, 16), asbd.mBitsPerChannel);
}

test "shouldWriteBuffer: only writes while recording and given a nonempty buffer" {
    try std.testing.expect(shouldWriteBuffer(true, 512));
    try std.testing.expect(!shouldWriteBuffer(false, 512));
    try std.testing.expect(!shouldWriteBuffer(true, 0));
    try std.testing.expect(!shouldWriteBuffer(false, 0));
}

test "start/stop captures real microphone audio into a well-formed, nonempty WAV file" {
    // Hardware-dependent (needs a mic + permission); skip rather than fail
    // when unavailable so this never wedges a mic-less or sandboxed CI runner.
    const list = devices.listInputDevices();
    if (list.count == 0) return error.SkipZigTest;

    const device = if (list.default_index) |idx| list.slice()[idx] else list.slice()[0];

    const io = std.testing.io;
    const output_path = "recorder_integration_test_output.wav";
    defer std.Io.Dir.cwd().deleteFile(io, output_path) catch {};

    start(io, device, output_path) catch |err| switch (err) {
        error.BackendError => return error.SkipZigTest,
        else => return err,
    };

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(300), .awake);

    try stop();

    var read_buf: [128]u8 = undefined;
    const contents = try std.Io.Dir.cwd().readFile(io, output_path, &read_buf);
    try std.testing.expect(contents.len >= 44);
    try std.testing.expectEqualStrings("RIFF", contents[0..4]);
    try std.testing.expectEqualStrings("WAVE", contents[8..12]);
    try std.testing.expectEqualStrings("data", contents[36..40]);

    const data_size = std.mem.readInt(u32, contents[40..44], .little);
    try std.testing.expect(data_size > 0);
}

test "start() clears a write_failed flag left over from a previous session" {
    // write_failed is module-level and shared by every recording, so a
    // leftover failure must not poison the next session.
    const list = devices.listInputDevices();
    if (list.count == 0) return error.SkipZigTest;

    const device = if (list.default_index) |idx| list.slice()[idx] else list.slice()[0];

    const io = std.testing.io;
    const output_path = "recorder_integration_test_write_failed_reset.wav";
    defer std.Io.Dir.cwd().deleteFile(io, output_path) catch {};

    g_ctx.write_failed.store(true, .release);

    start(io, device, output_path) catch |err| switch (err) {
        error.BackendError => return error.SkipZigTest,
        else => return err,
    };

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);
    try stop();
}
