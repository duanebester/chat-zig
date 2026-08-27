//! Minimal streaming WAV (RIFF/PCM) writer.
//!
//! Writes a placeholder 44-byte header up front, appends raw PCM bytes as
//! they arrive, and patches the header's size fields in place on `finalize()`.
//!
//! Platform-agnostic: depends only on `std.Io.File`/`std.Io.Dir`, never on
//! `devices.zig` or `recorder.zig`, so any future capture backend can reuse it.

const std = @import("std");

const WAV_HEADER_LEN: usize = 44;
const WAV_DATA_SIZE_MAX: u64 = std.math.maxInt(u32) - 36;

comptime {
    std.debug.assert(WAV_HEADER_LEN == 12 + 24 + 8);
}

pub const Format = struct {
    sample_rate: u32,
    num_channels: u16,
    bits_per_sample: u16,
};

pub const WavWriter = struct {
    file: std.Io.File,
    io: std.Io,
    format: Format,
    block_align: u16,

    /// Tracked directly so `finalize` doesn't need an extra `stat` call.
    data_bytes_written: u64 = 0,

    pub fn create(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, format: Format) !WavWriter {
        const format_arithmetic = try validateFormat(format);
        std.debug.assert(format_arithmetic.block_align > 0);
        std.debug.assert(format_arithmetic.byte_rate > 0);

        var file = try dir.createFile(io, sub_path, .{ .truncate = true });
        errdefer file.close(io);

        var header: [WAV_HEADER_LEN]u8 = undefined;
        writeHeader(&header, format, format_arithmetic, 0);
        try file.writeStreamingAll(io, &header);

        return .{
            .file = file,
            .io = io,
            .format = format,
            .block_align = format_arithmetic.block_align,
        };
    }

    pub fn writeSamples(self: *WavWriter, bytes: []const u8) !void {
        std.debug.assert(self.block_align > 0);
        std.debug.assert(self.format.num_channels > 0);

        if (bytes.len % self.block_align != 0) return error.UnalignedPcmWrite;
        if (bytes.len == 0) return;

        const byte_count: u64 = @intCast(bytes.len);
        const data_size = std.math.add(u64, self.data_bytes_written, byte_count) catch {
            return error.WavFileTooLarge;
        };
        if (data_size > WAV_DATA_SIZE_MAX) return error.WavFileTooLarge;

        try self.file.writeStreamingAll(self.io, bytes);
        self.data_bytes_written = data_size;
        std.debug.assert(self.data_bytes_written >= byte_count);
    }

    /// Must be called exactly once, after the last `writeSamples`.
    pub fn finalize(self: *WavWriter) !void {
        std.debug.assert(self.block_align > 0);
        std.debug.assert(self.data_bytes_written <= WAV_DATA_SIZE_MAX);

        // Close unconditionally: a failed positional write must not leak the fd.
        defer self.file.close(self.io);

        const format_arithmetic = try validateFormat(self.format);
        var header: [WAV_HEADER_LEN]u8 = undefined;
        writeHeader(&header, self.format, format_arithmetic, self.data_bytes_written);
        try self.file.writePositionalAll(self.io, &header, 0);
    }
};

const FormatArithmetic = struct {
    block_align: u16,
    byte_rate: u32,
};

fn validateFormat(format: Format) !FormatArithmetic {
    if (format.sample_rate == 0) return error.InvalidPcmFormat;
    if (format.num_channels == 0) return error.InvalidPcmFormat;
    if (format.bits_per_sample == 0) return error.InvalidPcmFormat;
    if (format.bits_per_sample % 8 != 0) return error.InvalidPcmFormat;

    const bytes_per_sample = @divExact(format.bits_per_sample, 8);
    const block_align = std.math.mul(u16, format.num_channels, bytes_per_sample) catch {
        return error.InvalidPcmFormat;
    };
    const byte_rate = std.math.mul(u32, format.sample_rate, block_align) catch {
        return error.InvalidPcmFormat;
    };
    std.debug.assert(block_align > 0);
    std.debug.assert(byte_rate > 0);
    return .{ .block_align = block_align, .byte_rate = byte_rate };
}

fn writeHeader(header_bytes: *[WAV_HEADER_LEN]u8, format: Format, arithmetic: FormatArithmetic, data_size: u64) void {
    std.debug.assert(arithmetic.block_align > 0);
    std.debug.assert(data_size <= WAV_DATA_SIZE_MAX);

    const riff_size: u32 = @intCast(36 + data_size);
    const data_size_32: u32 = @intCast(data_size);

    @memcpy(header_bytes[0..4], "RIFF");
    std.mem.writeInt(u32, header_bytes[4..8], riff_size, .little);
    @memcpy(header_bytes[8..12], "WAVE");

    @memcpy(header_bytes[12..16], "fmt ");
    std.mem.writeInt(u32, header_bytes[16..20], 16, .little); // fmt chunk size
    std.mem.writeInt(u16, header_bytes[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, header_bytes[22..24], format.num_channels, .little);
    std.mem.writeInt(u32, header_bytes[24..28], format.sample_rate, .little);
    std.mem.writeInt(u32, header_bytes[28..32], arithmetic.byte_rate, .little);
    std.mem.writeInt(u16, header_bytes[32..34], arithmetic.block_align, .little);
    std.mem.writeInt(u16, header_bytes[34..36], format.bits_per_sample, .little);

    @memcpy(header_bytes[36..40], "data");
    std.mem.writeInt(u32, header_bytes[40..44], data_size_32, .little);
}

test "writeHeader: zero-length header round-trips expected byte layout" {
    var buf: [WAV_HEADER_LEN]u8 = undefined;
    const format = Format{ .sample_rate = 44100, .num_channels = 1, .bits_per_sample = 16 };
    writeHeader(&buf, format, try validateFormat(format), 0);

    try std.testing.expectEqualStrings("RIFF", buf[0..4]);
    try std.testing.expectEqualStrings("WAVE", buf[8..12]);
    try std.testing.expectEqualStrings("fmt ", buf[12..16]);
    try std.testing.expectEqualStrings("data", buf[36..40]);

    try std.testing.expectEqual(@as(u32, 36), std.mem.readInt(u32, buf[4..8], .little));
    try std.testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, buf[16..20], .little));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[20..22], .little));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[22..24], .little));
    try std.testing.expectEqual(@as(u32, 44100), std.mem.readInt(u32, buf[24..28], .little));
    try std.testing.expectEqual(@as(u32, 88200), std.mem.readInt(u32, buf[28..32], .little));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, buf[32..34], .little));
    try std.testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, buf[34..36], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[40..44], .little));
}

test "writeHeader: nonzero data size updates RIFF and data chunk sizes" {
    var buf: [WAV_HEADER_LEN]u8 = undefined;
    const format = Format{ .sample_rate = 16000, .num_channels = 2, .bits_per_sample = 16 };
    writeHeader(&buf, format, try validateFormat(format), 1000);

    try std.testing.expectEqual(@as(u32, 1036), std.mem.readInt(u32, buf[4..8], .little));
    try std.testing.expectEqual(@as(u32, 1000), std.mem.readInt(u32, buf[40..44], .little));
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, buf[32..34], .little));

    // Stereo, so block_align (4) != bytes_per_sample (2) — the only
    // configuration that can catch `byte_rate` computed from the wrong operand.
    try std.testing.expectEqual(@as(u32, 64000), std.mem.readInt(u32, buf[28..32], .little));
}

test "create/writeSamples/finalize produces a well-formed WAV file" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const format = Format{ .sample_rate = 8000, .num_channels = 1, .bits_per_sample = 16 };
    var writer = try WavWriter.create(io, tmp_dir.dir, "out.wav", format);

    const samples = [_]u8{ 1, 2, 3, 4, 5, 6 };
    try writer.writeSamples(&samples);
    try writer.writeSamples(&samples);
    try writer.finalize();

    var read_buf: [WAV_HEADER_LEN + 12]u8 = undefined;
    const contents = try tmp_dir.dir.readFile(io, "out.wav", &read_buf);
    try std.testing.expectEqual(@as(usize, WAV_HEADER_LEN + samples.len * 2), contents.len);
    try std.testing.expectEqual(@as(u32, 12), std.mem.readInt(u32, contents[40..44], .little));
    try std.testing.expectEqualSlices(u8, &samples, contents[WAV_HEADER_LEN .. WAV_HEADER_LEN + samples.len]);
}

test "create writes a zero-sized placeholder header, independent of finalize" {
    // Read before any writeSamples/finalize call: finalize rewrites the whole
    // header, so checking only after it would never pin down create's own contract.
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const format = Format{ .sample_rate = 48000, .num_channels = 2, .bits_per_sample = 16 };
    var writer = try WavWriter.create(io, tmp_dir.dir, "placeholder.wav", format);

    var read_buf: [WAV_HEADER_LEN]u8 = undefined;
    const contents = try tmp_dir.dir.readFile(io, "placeholder.wav", &read_buf);
    try std.testing.expectEqual(@as(usize, WAV_HEADER_LEN), contents.len);
    try std.testing.expectEqualStrings("RIFF", contents[0..4]);
    try std.testing.expectEqual(@as(u32, 36), std.mem.readInt(u32, contents[4..8], .little));
    try std.testing.expectEqualStrings("data", contents[36..40]);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, contents[40..44], .little));

    try writer.finalize();
}

test "finalize releases the file descriptor (a leak would exhaust the process fd limit)" {
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const format = Format{ .sample_rate = 8000, .num_channels = 1, .bits_per_sample = 16 };

    // Cap the fd limit well below what 300 correctly-closed cycles need, so a
    // leaked fd fails deterministically instead of passing silently.
    const original_limit = try std.posix.getrlimit(.NOFILE);
    defer std.posix.setrlimit(.NOFILE, original_limit) catch {};
    try std.posix.setrlimit(.NOFILE, .{ .cur = 100, .max = original_limit.max });

    var i: usize = 0;
    while (i < 300) : (i += 1) {
        var writer = try WavWriter.create(io, tmp_dir.dir, "leak_check.wav", format);
        try writer.finalize();
    }
}

test "format arithmetic rejects invalid and overflowing PCM formats" {
    try std.testing.expectError(error.InvalidPcmFormat, validateFormat(.{ .sample_rate = 0, .num_channels = 1, .bits_per_sample = 16 }));
    try std.testing.expectError(error.InvalidPcmFormat, validateFormat(.{ .sample_rate = 8000, .num_channels = 0, .bits_per_sample = 16 }));
    try std.testing.expectError(error.InvalidPcmFormat, validateFormat(.{ .sample_rate = 8000, .num_channels = 1, .bits_per_sample = 12 }));
    try std.testing.expectError(error.InvalidPcmFormat, validateFormat(.{ .sample_rate = 1, .num_channels = std.math.maxInt(u16), .bits_per_sample = 16 }));
    try std.testing.expectError(error.InvalidPcmFormat, validateFormat(.{ .sample_rate = std.math.maxInt(u32), .num_channels = 1, .bits_per_sample = 16 }));
}

test "writer retains its creation format for finalize" {
    // Mutate the caller's copy after create to prove finalize uses the retained value.
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var format = Format{ .sample_rate = 8000, .num_channels = 1, .bits_per_sample = 16 };
    var writer = try WavWriter.create(io, tmp_dir.dir, "retained.wav", format);
    format = .{ .sample_rate = 48000, .num_channels = 2, .bits_per_sample = 32 };
    try writer.finalize();

    var read_buf: [WAV_HEADER_LEN]u8 = undefined;
    const contents = try tmp_dir.dir.readFile(io, "retained.wav", &read_buf);
    try std.testing.expectEqual(@as(u32, 8000), std.mem.readInt(u32, contents[24..28], .little));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, contents[22..24], .little));
}

test "writeSamples rejects unaligned PCM without extending the file" {
    // Checking file length proves rejection happens before I/O, not just before
    // the byte counter update.
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const format = Format{ .sample_rate = 8000, .num_channels = 2, .bits_per_sample = 16 };
    var writer = try WavWriter.create(io, tmp_dir.dir, "unaligned.wav", format);
    try std.testing.expectError(error.UnalignedPcmWrite, writer.writeSamples(&[_]u8{ 1, 2 }));
    try writer.finalize();

    var read_buf: [WAV_HEADER_LEN + 2]u8 = undefined;
    const contents = try tmp_dir.dir.readFile(io, "unaligned.wav", &read_buf);
    try std.testing.expectEqual(@as(usize, WAV_HEADER_LEN), contents.len);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, contents[40..44], .little));
}

test "writeSamples checks the RIFF size boundary before writing" {
    // Seed the counter near the max instead of allocating a multi-gigabyte fixture.
    const io = std.testing.io;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const format = Format{ .sample_rate = 8000, .num_channels = 1, .bits_per_sample = 16 };
    var writer = try WavWriter.create(io, tmp_dir.dir, "boundary.wav", format);
    writer.data_bytes_written = WAV_DATA_SIZE_MAX - 1;
    try std.testing.expectError(error.WavFileTooLarge, writer.writeSamples(&[_]u8{ 1, 2 }));
    writer.data_bytes_written = 0;
    try writer.finalize();

    var read_buf: [WAV_HEADER_LEN + 2]u8 = undefined;
    const contents = try tmp_dir.dir.readFile(io, "boundary.wav", &read_buf);
    try std.testing.expectEqual(@as(usize, WAV_HEADER_LEN), contents.len);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, contents[40..44], .little));
}
