//! macOS audio input device enumeration and recording.

const std = @import("std");
const devices = @import("devices.zig");
const recorder = @import("recorder.zig");

pub const InputDevice = devices.InputDevice;
pub const InputDeviceList = devices.InputDeviceList;
pub const MAX_INPUT_DEVICES = devices.MAX_INPUT_DEVICES;
pub const DEVICE_NAME_MAX_LEN = devices.DEVICE_NAME_MAX_LEN;
pub const RecorderError = recorder.RecorderError;
pub const RECORDING_MAX_CHANNELS = devices.RECORDING_MAX_CHANNELS;
pub const RECORDING_CHANNELS_FALLBACK = devices.RECORDING_CHANNELS_FALLBACK;
pub const WAVEFORM_BAR_COUNT = recorder.WAVEFORM_BAR_COUNT;

/// Enumerate the system's audio input (microphone) devices.
/// Synchronous and allocation-free.
pub fn listInputDevices() InputDeviceList {
    const result = devices.listInputDevices();

    std.debug.assert(result.count <= MAX_INPUT_DEVICES);
    if (result.default_index) |default_index| std.debug.assert(default_index < result.count);

    return result;
}

/// Streams raw PCM from `device` into a new 16-bit/44.1kHz WAV file at
/// `output_path` (created, or truncated if it already exists). Channel
/// count matches `device`'s native input channel count, capped at
/// `RECORDING_MAX_CHANNELS`. Only one recording at a time — returns
/// `error.AlreadyRecording` otherwise.
///
/// `io` should be the caller's Gooey IO handle (e.g. `cx.io()` / `w.io`)
/// so WAV file creation stays on the same IO plumbing as the rest of the app.
pub fn startRecording(io: std.Io, device: InputDevice, output_path: []const u8) RecorderError!void {
    std.debug.assert(output_path.len > 0);
    std.debug.assert(device.channel_count > 0);

    return recorder.start(io, device, output_path);
}

/// Stops the in-progress recording, patches the WAV header with the true
/// sample count, and closes the file. `error.NotRecording` if nothing
/// was recording.
pub fn stopRecording() RecorderError!void {
    return recorder.stop();
}

/// Snapshot of the live "while recording" meter: the last
/// `WAVEFORM_BAR_COUNT` amplitude levels, oldest first, each in `[0, 1]`.
/// Safe to call every frame, recording or not.
pub fn waveformLevels() [WAVEFORM_BAR_COUNT]f32 {
    const result = recorder.waveformLevels();

    std.debug.assert(result.len == WAVEFORM_BAR_COUNT);
    return result;
}
