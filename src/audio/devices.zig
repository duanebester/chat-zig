//! macOS audio input device enumeration via CoreAudio's `AudioHardware`
//! object-property API, plus CoreFoundation/CoreAudio primitives shared
//! with `recorder.zig`. This module never imports `recorder.zig` or
//! `writer.zig`, keeping the dependency graph a DAG.

const std = @import("std");

// --- CoreFoundation subset (shared with recorder.zig) ---

pub const CFTypeRef = ?*anyopaque;
pub const CFStringRef = ?*anyopaque;
pub const CFAllocatorRef = ?*anyopaque;
pub const CFIndex = i64;
pub const CFStringEncoding = u32;

pub const kCFStringEncodingUTF8: CFStringEncoding = 0x08000100;

pub extern "c" fn CFStringGetCString(
    the_string: CFStringRef,
    buffer: [*]u8,
    buffer_size: CFIndex,
    encoding: CFStringEncoding,
) u8; // Boolean

/// Copies `bytes` into a new CFString; caller must `CFRelease` the result.
pub extern "c" fn CFStringCreateWithBytes(
    alloc: CFAllocatorRef,
    bytes: [*]const u8,
    num_bytes: CFIndex,
    encoding: CFStringEncoding,
    is_external_representation: u8, // Boolean
) CFStringRef;

pub extern "c" fn CFRelease(cf: CFTypeRef) void;

// --- CoreAudio subset (shared with recorder.zig) ---

pub const AudioObjectID = u32;
pub const OSStatus = i32;

pub const kNoErr: OSStatus = 0;

/// Builds an `OSType` four-character-code constant (e.g. `'dev#'`),
/// matching Apple's headers regardless of host endianness.
pub fn fourCC(comptime code: *const [4]u8) u32 {
    comptime std.debug.assert(code.len == 4);

    const result = (@as(u32, code[0]) << 24) | (@as(u32, code[1]) << 16) | (@as(u32, code[2]) << 8) | @as(u32, code[3]);
    comptime std.debug.assert((result >> 24) == code[0]);

    return result;
}

// --- Device types ---

/// Hard cap on the number of input devices we'll enumerate.
pub const MAX_INPUT_DEVICES: usize = 32;

/// Longest device name we'll store, in bytes (UTF-8).
pub const DEVICE_NAME_MAX_LEN: usize = 128;

/// A single audio input device with a display name and stable CoreAudio UID.
pub const InputDevice = struct {
    name_buffer: [DEVICE_NAME_MAX_LEN]u8 = undefined,
    name_len: usize = 0,

    /// Stable CoreAudio UID, usable to restore the user's chosen device.
    uid_buffer: [DEVICE_NAME_MAX_LEN]u8 = undefined,
    uid_len: usize = 0,

    /// Backend-specific device handle (macOS: `AudioObjectID`). `0` means "none".
    backend_id: u32 = 0,

    /// Native input channel count, cached at enumeration time (see `listInputDevices`).
    channel_count: u16 = RECORDING_CHANNELS_FALLBACK,

    pub fn name(self: *const InputDevice) []const u8 {
        return self.name_buffer[0..self.name_len];
    }

    pub fn uid(self: *const InputDevice) []const u8 {
        return self.uid_buffer[0..self.uid_len];
    }

    /// Copies `text` into `name_buffer`, truncating (not erroring) if it doesn't fit.
    pub fn setName(self: *InputDevice, text: []const u8) void {
        const len = @min(text.len, DEVICE_NAME_MAX_LEN);
        std.debug.assert(len <= DEVICE_NAME_MAX_LEN);

        @memcpy(self.name_buffer[0..len], text[0..len]);
        self.name_len = len;

        std.debug.assert(self.name_len == len);
    }
};

/// Fixed-capacity list of input devices, as returned by `listInputDevices`.
pub const InputDeviceList = struct {
    devices: [MAX_INPUT_DEVICES]InputDevice = undefined,
    count: usize = 0,

    /// Index of the system default input device in `devices`, if present.
    default_index: ?usize = null,

    pub fn slice(self: *const InputDeviceList) []const InputDevice {
        std.debug.assert(self.count <= MAX_INPUT_DEVICES);

        const result = self.devices[0..self.count];
        std.debug.assert(result.len == self.count);
        return result;
    }
};

/// Fallback channel count when a device's native count can't be determined.
pub const RECORDING_CHANNELS_FALLBACK: u16 = 1;

/// Hard cap on requested/written channels, regardless of device capability.
pub const RECORDING_MAX_CHANNELS: u16 = 2;

// --- CoreAudio subset (AudioHardware object-property API) ---

const AudioObjectPropertyAddress = extern struct {
    mSelector: u32,
    mScope: u32,
    mElement: u32,
};

extern "c" fn AudioObjectGetPropertyDataSize(
    in_object_id: AudioObjectID,
    in_address: *const AudioObjectPropertyAddress,
    in_qualifier_data_size: u32,
    in_qualifier_data: ?*const anyopaque,
    out_data_size: *u32,
) OSStatus;

extern "c" fn AudioObjectGetPropertyData(
    in_object_id: AudioObjectID,
    in_address: *const AudioObjectPropertyAddress,
    in_qualifier_data_size: u32,
    in_qualifier_data: ?*const anyopaque,
    io_data_size: *u32,
    out_data: ?*anyopaque,
) OSStatus;

const kAudioObjectSystemObject: AudioObjectID = 1;

const kAudioObjectPropertyScopeGlobal: u32 = fourCC("glob");
const kAudioObjectPropertyScopeInput: u32 = fourCC("inpt");
const kAudioObjectPropertyElementMain: u32 = 0;

const kAudioHardwarePropertyDevices: u32 = fourCC("dev#");
const kAudioHardwarePropertyDefaultInputDevice: u32 = fourCC("dIn ");
const kAudioObjectPropertyName: u32 = fourCC("lnam");
const kAudioDevicePropertyDeviceUID: u32 = fourCC("uid ");
const kAudioDevicePropertyStreams: u32 = fourCC("stm#");
const kAudioDevicePropertyStreamConfiguration: u32 = fourCC("slay");

/// Named-argument bundle for `propertyAddress`, avoiding a same-type positional swap.
const PropertyAddressOptions = struct {
    selector: u32,
    scope: u32,
};

/// Builds a property address targeting the shared main element.
fn propertyAddress(options: PropertyAddressOptions) AudioObjectPropertyAddress {
    const address = AudioObjectPropertyAddress{
        .mSelector = options.selector,
        .mScope = options.scope,
        .mElement = kAudioObjectPropertyElementMain,
    };
    std.debug.assert(address.mSelector == options.selector);
    std.debug.assert(address.mScope == options.scope);
    return address;
}

/// Upper bound on how many raw device IDs we'll fetch before filtering
/// down to input-capable ones.
const MAX_RAW_DEVICES: usize = 128;

/// Upper bound on how many `AudioBuffer` entries we'll read out of a
/// device's `AudioBufferList` when summing channels.
const MAX_AUDIO_BUFFERS: usize = 8;

/// Mirrors CoreAudio's `AudioBuffer` (`CoreAudioTypes.h`): describes one
/// (possibly non-interleaved) buffer within a stream's configuration.
const AudioBuffer = extern struct {
    mNumberChannels: u32,
    mDataByteSize: u32,
    mData: ?*anyopaque,
};

/// Fixed-capacity stand-in for CoreAudio's variable-length `AudioBufferList`.
const AudioBufferListFixed = extern struct {
    mNumberBuffers: u32,
    mBuffers: [MAX_AUDIO_BUFFERS]AudioBuffer,
};

// Guards `inputChannelCount`'s size check against silently drifting if
// either struct's layout changes.
comptime {
    std.debug.assert(@sizeOf(AudioBuffer) == 16);
    std.debug.assert(@sizeOf(AudioBufferListFixed) == 8 + MAX_AUDIO_BUFFERS * @sizeOf(AudioBuffer));
}

// --- Property helpers ---

/// Reads a CFString-typed property (e.g. device name or UID) into
/// `out_buffer` as UTF-8, returning bytes written (0 on any failure,
/// logged for diagnosis). Releases the CFString CoreAudio hands back.
fn readCFStringProperty(device_id: AudioObjectID, selector: u32, out_buffer: []u8) usize {
    std.debug.assert(out_buffer.len > 0);

    const address = propertyAddress(.{ .selector = selector, .scope = kAudioObjectPropertyScopeGlobal });
    std.debug.assert(address.mScope == kAudioObjectPropertyScopeGlobal);

    var cf_string: CFStringRef = null;
    var data_size: u32 = @sizeOf(CFStringRef);
    const status = AudioObjectGetPropertyData(device_id, &address, 0, null, &data_size, @ptrCast(&cf_string));
    if (status != kNoErr or cf_string == null) {
        std.log.debug("readCFStringProperty: device {d} selector 0x{x} unavailable (status {d})", .{ device_id, selector, status });
        return 0;
    }

    defer CFRelease(cf_string);

    const ok = CFStringGetCString(cf_string, out_buffer.ptr, @intCast(out_buffer.len), kCFStringEncodingUTF8);
    if (ok == 0) {
        std.log.debug("readCFStringProperty: device {d} selector 0x{x} did not fit in {d} bytes", .{ device_id, selector, out_buffer.len });
        return 0;
    }

    return std.mem.indexOfScalar(u8, out_buffer, 0) orelse out_buffer.len;
}

/// A device counts as an input device if it exposes at least one stream
/// in the input scope.
fn hasInputStreams(device_id: AudioObjectID) bool {
    const address = propertyAddress(.{ .selector = kAudioDevicePropertyStreams, .scope = kAudioObjectPropertyScopeInput });
    std.debug.assert(address.mSelector == kAudioDevicePropertyStreams);
    std.debug.assert(address.mScope == kAudioObjectPropertyScopeInput);

    var data_size: u32 = 0;
    const status = AudioObjectGetPropertyDataSize(device_id, &address, 0, null, &data_size);
    if (status != kNoErr) {
        // Folded into "no input streams" so one query failure doesn't
        // abort enumeration of every other device.
        std.log.debug("hasInputStreams: device {d} stream-size query failed (status {d})", .{ device_id, status });
        return false;
    }
    return data_size > 0;
}

/// Sums `mNumberChannels` across `buffers`, caps at `RECORDING_MAX_CHANNELS`,
/// and falls back to `RECORDING_CHANNELS_FALLBACK` if the sum is zero.
fn cappedChannelCount(buffers: []const AudioBuffer) u16 {
    var total_channels: u32 = 0;
    for (buffers) |buffer| {
        total_channels += buffer.mNumberChannels;
    }

    if (total_channels == 0) return RECORDING_CHANNELS_FALLBACK;

    const capped = @min(total_channels, @as(u32, RECORDING_MAX_CHANNELS));
    std.debug.assert(capped > 0);
    std.debug.assert(capped <= RECORDING_MAX_CHANNELS);
    return @intCast(capped);
}

const ReturnedElementCountOptions = struct {
    requested_bytes: u32,
    returned_bytes: u32,
    element_size: u32,
    capacity: u32,
};

/// Validates a fixed-width property response before its storage is read.
/// CoreAudio may return fewer bytes than requested when devices change.
fn returnedElementCount(options: ReturnedElementCountOptions) ?u32 {
    std.debug.assert(options.element_size > 0);
    std.debug.assert(options.capacity > 0);

    if (options.returned_bytes > options.requested_bytes) return null;
    if (options.returned_bytes % options.element_size != 0) return null;

    const count = @divExact(options.returned_bytes, options.element_size);
    if (count > options.capacity) return null;
    return count;
}

/// Proves every claimed `AudioBuffer` is present in the returned bytes.
/// Rejecting partial entries prevents reads from untouched stack storage.
fn returnedAudioBufferCount(returned_bytes: u32, claimed_count: u32) ?u32 {
    const buffers_offset: u32 = @offsetOf(AudioBufferListFixed, "mBuffers");
    const buffer_size: u32 = @sizeOf(AudioBuffer);
    std.debug.assert(buffers_offset >= @sizeOf(u32));
    std.debug.assert(buffer_size > 0);

    if (returned_bytes < buffers_offset) return null;
    const buffer_bytes = returned_bytes - buffers_offset;
    if (buffer_bytes % buffer_size != 0) return null;

    const available_count = @divExact(buffer_bytes, buffer_size);
    if (claimed_count > available_count) return null;
    if (claimed_count > MAX_AUDIO_BUFFERS) return null;
    return claimed_count;
}

/// Total input channels for `device_id`, capped at `RECORDING_MAX_CHANNELS`
/// and falling back to `RECORDING_CHANNELS_FALLBACK` on any failure.
pub fn inputChannelCount(device_id: AudioObjectID) u16 {
    const address = propertyAddress(.{ .selector = kAudioDevicePropertyStreamConfiguration, .scope = kAudioObjectPropertyScopeInput });
    std.debug.assert(address.mScope == kAudioObjectPropertyScopeInput);

    var data_size: u32 = 0;
    var status = AudioObjectGetPropertyDataSize(device_id, &address, 0, null, &data_size);
    if (status != kNoErr or data_size == 0) return RECORDING_CHANNELS_FALLBACK;
    if (data_size > @sizeOf(AudioBufferListFixed)) return RECORDING_CHANNELS_FALLBACK;

    const requested_bytes = data_size;
    var buffer_list: AudioBufferListFixed = undefined;
    status = AudioObjectGetPropertyData(device_id, &address, 0, null, &data_size, @ptrCast(&buffer_list));
    if (status != kNoErr) return RECORDING_CHANNELS_FALLBACK;
    if (data_size > requested_bytes) return RECORDING_CHANNELS_FALLBACK;
    if (data_size < @offsetOf(AudioBufferListFixed, "mBuffers")) return RECORDING_CHANNELS_FALLBACK;

    const buffer_count = returnedAudioBufferCount(data_size, buffer_list.mNumberBuffers) orelse return RECORDING_CHANNELS_FALLBACK;
    std.debug.assert(buffer_count <= MAX_AUDIO_BUFFERS);
    std.debug.assert(data_size <= requested_bytes);

    return cappedChannelCount(buffer_list.mBuffers[0..buffer_count]);
}

/// The system's current default input device, or `null` if none is set.
fn defaultInputDeviceId() ?AudioObjectID {
    const address = propertyAddress(.{ .selector = kAudioHardwarePropertyDefaultInputDevice, .scope = kAudioObjectPropertyScopeGlobal });

    var device_id: AudioObjectID = 0;
    var data_size: u32 = @sizeOf(AudioObjectID);
    std.debug.assert(data_size == @sizeOf(AudioObjectID));

    const status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, null, &data_size, @ptrCast(&device_id));
    if (status != kNoErr or device_id == 0) return null;

    std.debug.assert(device_id != 0);
    return device_id;
}

// --- Public API ---

/// Enumerates every input-capable audio device known to CoreAudio.
/// Synchronous and allocation-free.
pub fn listInputDevices() InputDeviceList {
    var result = InputDeviceList{};

    const address = propertyAddress(.{ .selector = kAudioHardwarePropertyDevices, .scope = kAudioObjectPropertyScopeGlobal });

    var data_size: u32 = 0;
    var status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, null, &data_size);
    if (status != kNoErr or data_size == 0) return result;

    // @divExact enforces that CoreAudio reports a whole number of
    // AudioObjectIDs, instead of silently truncating if it's ever wrong.
    const device_count: usize = @divExact(data_size, @sizeOf(AudioObjectID));
    std.debug.assert(device_count > 0);

    var raw_ids: [MAX_RAW_DEVICES]AudioObjectID = undefined;
    const fetch_count = @min(device_count, MAX_RAW_DEVICES);
    const requested_bytes: u32 = @intCast(fetch_count * @sizeOf(AudioObjectID));
    data_size = requested_bytes;

    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, null, &data_size, @ptrCast(&raw_ids));
    if (status != kNoErr) return result;
    const returned_count = returnedElementCount(.{
        .requested_bytes = requested_bytes,
        .returned_bytes = data_size,
        .element_size = @sizeOf(AudioObjectID),
        .capacity = MAX_RAW_DEVICES,
    }) orelse return result;
    std.debug.assert(returned_count <= fetch_count);

    const default_id = defaultInputDeviceId();

    for (raw_ids[0..returned_count]) |device_id| {
        if (result.count >= MAX_INPUT_DEVICES) break;
        if (!hasInputStreams(device_id)) continue;

        var device = InputDevice{};
        device.backend_id = device_id;
        device.channel_count = inputChannelCount(device_id);

        const name_len = readCFStringProperty(device_id, kAudioObjectPropertyName, device.name_buffer[0..]);
        if (name_len > 0) {
            device.name_len = name_len;
        } else {
            device.setName("Unknown Microphone");
        }

        device.uid_len = readCFStringProperty(device_id, kAudioDevicePropertyDeviceUID, device.uid_buffer[0..]);

        if (default_id) |id| {
            if (id == device_id) result.default_index = result.count;
        }

        result.devices[result.count] = device;
        result.count += 1;
    }

    std.debug.assert(result.count <= MAX_INPUT_DEVICES);
    return result;
}

// --- Tests ---

test "fourCC matches known CoreAudio selectors" {
    try std.testing.expectEqual(@as(u32, 0x6465_7623), fourCC("dev#")); // kAudioHardwarePropertyDevices
    try std.testing.expectEqual(@as(u32, 0x676C_6F62), fourCC("glob")); // kAudioObjectPropertyScopeGlobal
}

test "fourCC matches every other CoreAudio selector this module builds from ASCII" {
    try std.testing.expectEqual(@as(u32, 0x64496E20), fourCC("dIn ")); // kAudioHardwarePropertyDefaultInputDevice
    try std.testing.expectEqual(@as(u32, 0x6C6E616D), fourCC("lnam")); // kAudioObjectPropertyName
    try std.testing.expectEqual(@as(u32, 0x75696420), fourCC("uid ")); // kAudioDevicePropertyDeviceUID
    try std.testing.expectEqual(@as(u32, 0x73746D23), fourCC("stm#")); // kAudioDevicePropertyStreams
    try std.testing.expectEqual(@as(u32, 0x736C6179), fourCC("slay")); // kAudioDevicePropertyStreamConfiguration
    try std.testing.expectEqual(@as(u32, 0x696E7074), fourCC("inpt")); // kAudioObjectPropertyScopeInput
}

test "listInputDevices returns a well-formed (possibly empty) list" {
    const list = listInputDevices();
    try std.testing.expect(list.count <= MAX_INPUT_DEVICES);
    if (list.default_index) |idx| {
        try std.testing.expect(idx < list.count);
    }
    for (list.slice()) |*device| {
        try std.testing.expect(device.name().len > 0);
    }
}

test "inputChannelCount falls back to mono for an invalid device id" {
    try std.testing.expectEqual(RECORDING_CHANNELS_FALLBACK, inputChannelCount(0));
}

test "inputChannelCount is always positive and within the supported cap, for every enumerated device" {
    const list = listInputDevices();
    for (list.slice()) |*device| {
        const channels = inputChannelCount(device.backend_id);
        try std.testing.expect(channels > 0);
        try std.testing.expect(channels <= RECORDING_MAX_CHANNELS);
    }
}

test "listInputDevices caches each device's channel count" {
    const list = listInputDevices();
    for (list.slice()) |*device| {
        try std.testing.expect(device.channel_count > 0);
        try std.testing.expect(device.channel_count <= RECORDING_MAX_CHANNELS);
        try std.testing.expectEqual(inputChannelCount(device.backend_id), device.channel_count);
    }
}

test "returnedElementCount uses the smaller returned device byte count" {
    try std.testing.expectEqual(@as(?u32, 2), returnedElementCount(.{
        .requested_bytes = 4 * @sizeOf(AudioObjectID),
        .returned_bytes = 2 * @sizeOf(AudioObjectID),
        .element_size = @sizeOf(AudioObjectID),
        .capacity = MAX_RAW_DEVICES,
    }));
}

test "returnedElementCount rejects non-divisible returned device sizes" {
    try std.testing.expectEqual(@as(?u32, null), returnedElementCount(.{
        .requested_bytes = 4 * @sizeOf(AudioObjectID),
        .returned_bytes = 2 * @sizeOf(AudioObjectID) + 1,
        .element_size = @sizeOf(AudioObjectID),
        .capacity = MAX_RAW_DEVICES,
    }));
}

test "returnedAudioBufferCount rejects a short AudioBufferList" {
    const short_size = @offsetOf(AudioBufferListFixed, "mBuffers") - 1;
    try std.testing.expectEqual(@as(?u32, null), returnedAudioBufferCount(short_size, 0));
}

test "returnedAudioBufferCount rejects a claim larger than returned storage" {
    const one_buffer_size = @offsetOf(AudioBufferListFixed, "mBuffers") + @sizeOf(AudioBuffer);
    try std.testing.expectEqual(@as(?u32, null), returnedAudioBufferCount(one_buffer_size, 2));
}

test "returnedAudioBufferCount accepts complete valid lists" {
    const two_buffer_size = @offsetOf(AudioBufferListFixed, "mBuffers") + 2 * @sizeOf(AudioBuffer);
    try std.testing.expectEqual(@as(?u32, 0), returnedAudioBufferCount(@offsetOf(AudioBufferListFixed, "mBuffers"), 0));
    try std.testing.expectEqual(@as(?u32, 2), returnedAudioBufferCount(two_buffer_size, 2));
}

// --- cappedChannelCount unit tests (exercises the channel cap directly) ---

test "cappedChannelCount falls back to mono for an empty buffer list" {
    try std.testing.expectEqual(RECORDING_CHANNELS_FALLBACK, cappedChannelCount(&.{}));
}

test "cappedChannelCount falls back to mono when every buffer reports zero channels" {
    const buffers = [_]AudioBuffer{
        .{ .mNumberChannels = 0, .mDataByteSize = 0, .mData = null },
        .{ .mNumberChannels = 0, .mDataByteSize = 0, .mData = null },
    };
    try std.testing.expectEqual(RECORDING_CHANNELS_FALLBACK, cappedChannelCount(&buffers));
}

test "cappedChannelCount sums channels across multiple non-interleaved buffers" {
    const buffers = [_]AudioBuffer{
        .{ .mNumberChannels = 1, .mDataByteSize = 0, .mData = null },
        .{ .mNumberChannels = 1, .mDataByteSize = 0, .mData = null },
    };
    try std.testing.expectEqual(@as(u16, 2), cappedChannelCount(&buffers));
}

test "cappedChannelCount does not cap a device reporting exactly RECORDING_MAX_CHANNELS" {
    const buffers = [_]AudioBuffer{
        .{ .mNumberChannels = RECORDING_MAX_CHANNELS, .mDataByteSize = 0, .mData = null },
    };
    try std.testing.expectEqual(RECORDING_MAX_CHANNELS, cappedChannelCount(&buffers));
}

test "cappedChannelCount caps a multichannel device at RECORDING_MAX_CHANNELS" {
    const buffers = [_]AudioBuffer{
        .{ .mNumberChannels = 8, .mDataByteSize = 0, .mData = null },
    };
    try std.testing.expectEqual(RECORDING_MAX_CHANNELS, cappedChannelCount(&buffers));
}

// --- InputDevice / InputDeviceList unit tests ---

test "InputDevice defaults to the mono fallback before enumeration populates it" {
    const device = InputDevice{};
    try std.testing.expectEqual(RECORDING_CHANNELS_FALLBACK, device.channel_count);
    try std.testing.expectEqual(@as(usize, 0), device.name().len);
    try std.testing.expectEqual(@as(usize, 0), device.uid().len);
}

test "InputDevice.setName copies short names verbatim" {
    var device = InputDevice{};
    device.setName("AirPods Pro");
    try std.testing.expectEqualStrings("AirPods Pro", device.name());
}

test "InputDevice.setName truncates names longer than DEVICE_NAME_MAX_LEN" {
    var too_long: [DEVICE_NAME_MAX_LEN + 50]u8 = undefined;
    @memset(&too_long, 'x');

    var device = InputDevice{};
    device.setName(&too_long);

    try std.testing.expectEqual(DEVICE_NAME_MAX_LEN, device.name_len);
    try std.testing.expectEqualStrings(too_long[0..DEVICE_NAME_MAX_LEN], device.name());
}

test "InputDevice.setName overwrites a previous, longer name" {
    var device = InputDevice{};
    device.setName("A Fairly Long Placeholder Device Name");
    device.setName("Mic");
    try std.testing.expectEqualStrings("Mic", device.name());
}

test "InputDeviceList defaults to an empty, default-less list" {
    const list = InputDeviceList{};
    try std.testing.expectEqual(@as(usize, 0), list.count);
    try std.testing.expectEqual(@as(usize, 0), list.slice().len);
    try std.testing.expectEqual(@as(?usize, null), list.default_index);
}

// --- Internal helper unit tests ---

test "hasInputStreams rejects an invalid device id" {
    try std.testing.expect(!hasInputStreams(0));
}

test "readCFStringProperty returns zero length for an invalid device id" {
    var buffer: [DEVICE_NAME_MAX_LEN]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), readCFStringProperty(0, kAudioObjectPropertyName, &buffer));
}

test "defaultInputDeviceId, when present, is reflected by listInputDevices' default_index" {
    const default_id = defaultInputDeviceId();
    const list = listInputDevices();

    if (default_id) |id| {
        var found_at: ?usize = null;
        for (list.slice(), 0..) |*device, i| {
            if (device.backend_id == id) found_at = i;
        }
        if (found_at) |idx| {
            try std.testing.expectEqual(idx, list.default_index.?);
        }
    } else {
        try std.testing.expectEqual(@as(?usize, null), list.default_index);
    }
}

test "listInputDevices never reports two devices with the same backend id" {
    const list = listInputDevices();
    for (list.slice(), 0..) |*device, i| {
        for (list.slice()[i + 1 ..]) |*other| {
            try std.testing.expect(device.backend_id != other.backend_id);
        }
    }
}

test "listInputDevices never reports two devices with the same non-empty uid" {
    const list = listInputDevices();
    for (list.slice(), 0..) |*device, i| {
        if (device.uid().len == 0) continue;
        for (list.slice()[i + 1 ..]) |*other| {
            if (other.uid().len == 0) continue;
            try std.testing.expect(!std.mem.eql(u8, device.uid(), other.uid()));
        }
    }
}

// --- Independent-oracle tests: re-derive expected values from a separate
// CoreAudio query rather than the function under test, so these catch
// bugs a self-consistency check would agree with. ---

test "defaultInputDeviceId matches an independent query of the system default" {
    const address = propertyAddress(.{ .selector = kAudioHardwarePropertyDefaultInputDevice, .scope = kAudioObjectPropertyScopeGlobal });
    var expected_id: AudioObjectID = 0;
    var data_size: u32 = @sizeOf(AudioObjectID);
    const status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, null, &data_size, @ptrCast(&expected_id));
    try std.testing.expectEqual(kNoErr, status);

    if (expected_id == 0) {
        try std.testing.expectEqual(@as(?AudioObjectID, null), defaultInputDeviceId());
    } else {
        try std.testing.expectEqual(@as(?AudioObjectID, expected_id), defaultInputDeviceId());
    }
}

test "listInputDevices excludes devices with no input streams, per an independent stream-size query" {
    const list = listInputDevices();
    for (list.slice()) |*device| {
        const address = propertyAddress(.{ .selector = kAudioDevicePropertyStreams, .scope = kAudioObjectPropertyScopeInput });
        var data_size: u32 = 0;
        const status = AudioObjectGetPropertyDataSize(device.backend_id, &address, 0, null, &data_size);
        try std.testing.expectEqual(kNoErr, status);
        try std.testing.expect(data_size > 0);
    }
}

test "listInputDevices' name and uid come from the selectors they're documented to use" {
    const list = listInputDevices();
    for (list.slice()) |*device| {
        var name_buffer: [DEVICE_NAME_MAX_LEN]u8 = undefined;
        const expected_name_len = readCFStringProperty(device.backend_id, kAudioObjectPropertyName, &name_buffer);
        if (expected_name_len > 0) {
            try std.testing.expectEqualStrings(name_buffer[0..expected_name_len], device.name());
        } else {
            try std.testing.expectEqualStrings("Unknown Microphone", device.name());
        }

        var uid_buffer: [DEVICE_NAME_MAX_LEN]u8 = undefined;
        const expected_uid_len = readCFStringProperty(device.backend_id, kAudioDevicePropertyDeviceUID, &uid_buffer);
        try std.testing.expectEqualStrings(uid_buffer[0..expected_uid_len], device.uid());
    }
}

// --- Stress/probe tests: hammer the public API under repetition/concurrency ---

test "stress: listInputDevices is stable across many repeated calls" {
    const REPEAT_COUNT = 64;

    const first = listInputDevices();

    var i: usize = 0;
    while (i < REPEAT_COUNT) : (i += 1) {
        const list = listInputDevices();
        try std.testing.expectEqual(first.count, list.count);
        try std.testing.expectEqual(first.default_index, list.default_index);

        for (first.slice(), list.slice()) |*expected, *actual| {
            try std.testing.expectEqual(expected.backend_id, actual.backend_id);
            try std.testing.expectEqualStrings(expected.name(), actual.name());
            try std.testing.expectEqualStrings(expected.uid(), actual.uid());
            try std.testing.expectEqual(expected.channel_count, actual.channel_count);
        }
    }
}

test "stress: inputChannelCount stays within bounds across a wide range of device ids" {
    const MAX_PROBE_ID: u32 = 2000;

    var id: u32 = 0;
    while (id < MAX_PROBE_ID) : (id += 1) {
        const channels = inputChannelCount(id);
        try std.testing.expect(channels > 0);
        try std.testing.expect(channels <= RECORDING_MAX_CHANNELS);
    }
}

test "stress: concurrent listInputDevices/inputChannelCount calls don't violate invariants" {
    const THREAD_COUNT = 8;
    const ITERATIONS_PER_THREAD = 50;

    const Worker = struct {
        fn run(violation: *std.atomic.Value(bool)) void {
            var i: usize = 0;
            while (i < ITERATIONS_PER_THREAD) : (i += 1) {
                const list = listInputDevices();
                if (list.count > MAX_INPUT_DEVICES) violation.store(true, .release);
                if (list.default_index) |idx| {
                    if (idx >= list.count) violation.store(true, .release);
                }
                for (list.slice()) |*device| {
                    const channels = inputChannelCount(device.backend_id);
                    if (channels == 0 or channels > RECORDING_MAX_CHANNELS) {
                        violation.store(true, .release);
                    }
                }
            }
        }
    };

    var violation = std.atomic.Value(bool).init(false);
    var threads: [THREAD_COUNT]std.Thread = undefined;

    var i: usize = 0;
    while (i < THREAD_COUNT) : (i += 1) {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{&violation});
    }
    i = 0;
    while (i < THREAD_COUNT) : (i += 1) {
        threads[i].join();
    }

    try std.testing.expect(!violation.load(.acquire));
}
