//! Shared HTTP retry and error-classification policy for API providers.

const std = @import("std");
const log = std.log.scoped(.chatzig);
const http = std.http;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Uri = std.Uri;

pub const MAX_FETCH_ATTEMPTS: u32 = 3;
pub const BASE_BACKOFF_MS: u64 = 500;
pub const JITTER_PERCENT: u64 = 25;
pub const MAX_RETRY_AFTER_SECS: u64 = 60;

pub const FetchError = error{
    Transient,
    Permanent,
};

pub const AttemptOptions = struct {
    io: Io,
    allocator: Allocator,
    method: http.Method,
    uri: Uri,
    headers: http.Client.Request.Headers,
    extra_headers: []const http.Header,
    request_body: []u8,
    request_body_size_max: u32,
    expected_status: http.Status,
    label: []const u8,
};

pub fn AttemptOutcome(comptime T: type) type {
    return union(enum) {
        terminal: T,
        transient: ?u64,
    };
}

pub fn classifyHttpStatus(status: http.Status) FetchError {
    std.debug.assert(@intFromEnum(status) >= 100);
    std.debug.assert(@intFromEnum(status) <= 999);

    return switch (@intFromEnum(status)) {
        408, 429 => error.Transient,
        500...599 => error.Transient,
        else => error.Permanent,
    };
}

pub fn classifyRequestError(err: anyerror) FetchError {
    std.debug.assert(@errorName(err).len > 0);
    std.debug.assert(@errorName(err).len < 256);

    return switch (err) {
        error.OutOfMemory,
        error.UnsupportedUriScheme,
        error.UriMissingHost,
        error.CertificateBundleLoadFailure,
        => error.Permanent,
        else => error.Transient,
    };
}

pub fn classifyReceiveHeadError(err: anyerror) FetchError {
    std.debug.assert(@errorName(err).len > 0);
    std.debug.assert(@errorName(err).len < 256);

    return switch (err) {
        error.HttpHeadersInvalid,
        error.TooManyHttpRedirects,
        error.RedirectRequiresResend,
        error.HttpRedirectLocationMissing,
        error.HttpRedirectLocationOversize,
        error.HttpRedirectLocationInvalid,
        error.HttpContentEncodingUnsupported,
        error.HttpChunkInvalid,
        error.HttpChunkTruncated,
        error.HttpHeadersOversize,
        error.UnsupportedUriScheme,
        error.OutOfMemory,
        error.CertificateBundleLoadFailure,
        => error.Permanent,
        else => error.Transient,
    };
}

pub fn parseRetryAfterSeconds(value: []const u8) ?u64 {
    std.debug.assert(value.len < 256);
    std.debug.assert(MAX_RETRY_AFTER_SECS > 0);

    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(u64, trimmed, 10) catch null;
}

pub fn parseRetryAfterFromHead(head: http.Client.Response.Head) ?u64 {
    std.debug.assert(MAX_RETRY_AFTER_SECS > 0);
    std.debug.assert(MAX_FETCH_ATTEMPTS > 0);

    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
            return parseRetryAfterSeconds(header.value);
        }
    }
    return null;
}

pub fn computeBackoffMs(attempt: u32, retry_after_seconds: ?u64, random: std.Random) i64 {
    std.debug.assert(attempt < 63);
    std.debug.assert(JITTER_PERCENT < 100);

    const base_ms: u64 = BASE_BACKOFF_MS << @as(u6, @intCast(attempt));
    const jitter_range_ms: u64 = @divFloor(base_ms * JITTER_PERCENT, 100);
    const jitter_signed: i64 = random.intRangeAtMost(
        i64,
        -@as(i64, @intCast(jitter_range_ms)),
        @as(i64, @intCast(jitter_range_ms)),
    );
    const exponential_ms: i64 = @as(i64, @intCast(base_ms)) + jitter_signed;
    std.debug.assert(exponential_ms > 0);

    if (retry_after_seconds) |seconds| {
        const capped_seconds: u64 = @min(seconds, MAX_RETRY_AFTER_SECS);
        const retry_ms: i64 = @as(i64, @intCast(capped_seconds)) * 1000;
        return @max(retry_ms, exponential_ms);
    }
    return exponential_ms;
}

/// Performs the provider-independent transport portion of one HTTP attempt.
/// Header storage is borrowed only for this call and remains alive through the
/// success callback, which runs before the request and client are destroyed.
pub fn performOneHttpAttempt(
    comptime T: type,
    options: *const AttemptOptions,
    context: anytype,
) Io.Cancelable!AttemptOutcome(T) {
    std.debug.assert(options.request_body_size_max > 0);
    std.debug.assert(options.request_body.len <= options.request_body_size_max);
    std.debug.assert(options.label.len > 0);

    var client = http.Client{ .allocator = options.allocator, .io = options.io };
    defer client.deinit();

    var request = client.request(options.method, options.uri, .{
        .headers = options.headers,
        .extra_headers = options.extra_headers,
    }) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        return switch (classifyRequestError(err)) {
            error.Transient => .{ .transient = null },
            error.Permanent => .{ .terminal = context.requestFailed() },
        };
    };
    defer request.deinit();

    request.sendBodyComplete(options.request_body) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        return .{ .transient = null };
    };

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = request.receiveHead(&redirect_buffer) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        return switch (classifyReceiveHeadError(err)) {
            error.Transient => .{ .transient = null },
            error.Permanent => .{ .terminal = context.receiveHeadFailed() },
        };
    };

    if (response.head.status == options.expected_status) {
        return .{ .terminal = try context.consumeOkResponse(&response) };
    } else {
        switch (classifyHttpStatus(response.head.status)) {
            error.Transient => {
                const retry_after_seconds = parseRetryAfterFromHead(response.head);
                log.info("{s} HTTP {d} is retryable", .{
                    options.label,
                    @intFromEnum(response.head.status),
                });
                return .{ .transient = retry_after_seconds };
            },
            error.Permanent => {
                return .{ .terminal = context.requestRejected(response.head.status) };
            },
        }
    }
}

pub fn readBoundedResponse(
    allocator: Allocator,
    response: *http.Client.Response,
    size_max: u32,
) ![]u8 {
    std.debug.assert(size_max > 0);
    std.debug.assert(@intFromPtr(response) != 0);

    var transfer_buffer: [64]u8 = undefined;
    var reader = response.reader(&transfer_buffer);
    const data = try reader.allocRemaining(allocator, Io.Limit.limited(size_max));
    std.debug.assert(data.len <= size_max);
    std.debug.assert(data.len <= std.math.maxInt(u32));
    return data;
}

pub fn fetchWithRetry(
    comptime T: type,
    io: Io,
    random: std.Random,
    context: anytype,
    give_up: T,
    label: []const u8,
) Io.Cancelable!T {
    comptime std.debug.assert(MAX_FETCH_ATTEMPTS > 0);
    std.debug.assert(label.len > 0);

    var attempt: u32 = 0;
    while (attempt < MAX_FETCH_ATTEMPTS) : (attempt += 1) {
        switch (try context.attempt()) {
            .terminal => |value| return value,
            .transient => |retry_after_seconds| {
                if (attempt + 1 >= MAX_FETCH_ATTEMPTS) {
                    log.info(
                        "{s} request: transient failure on final attempt {d}/{d}, giving up",
                        .{ label, attempt + 1, MAX_FETCH_ATTEMPTS },
                    );
                    return give_up;
                }

                const sleep_ms = computeBackoffMs(attempt, retry_after_seconds, random);
                log.info(
                    "{s} request: transient failure on attempt {d}/{d}, backing off {d}ms{s}",
                    .{
                        label,
                        attempt + 1,
                        MAX_FETCH_ATTEMPTS,
                        sleep_ms,
                        if (retry_after_seconds != null) " (Retry-After honored)" else "",
                    },
                );
                try io.sleep(Io.Duration.fromMilliseconds(sleep_ms), .awake);
            },
        }
    }
    unreachable;
}

pub fn seedBackoffPrng(io: Io) std.Random.DefaultPrng {
    std.debug.assert(MAX_FETCH_ATTEMPTS > 0);
    std.debug.assert(BASE_BACKOFF_MS > 0);

    const timestamp = Io.Clock.Timestamp.now(io, .awake);
    const nanoseconds: i96 = timestamp.raw.toNanoseconds();
    const seed: u64 = @bitCast(@as(i64, @truncate(nanoseconds)));
    return std.Random.DefaultPrng.init(seed);
}
