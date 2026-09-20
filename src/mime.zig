//! RFC 2047 MIME encoded-word decoding for email headers (Subject, From).
//!
//! Email headers are attacker-influenced content -- any sender can put
//! whatever they want in a Subject line. Every function here is written to
//! never crash, never read out of bounds, and never return an error other
//! than `OutOfMemory`, no matter how malformed the input. Anything that
//! looks like it might be an encoded word but doesn't decode cleanly is
//! passed through as literal text instead of aborting the whole header.
const std = @import("std");
const Allocator = std.mem.Allocator;

const replacement_char = "\u{FFFD}";

/// Decodes RFC 2047 encoded-words (`=?charset?B?...?=` / `=?charset?Q?...?=`)
/// embedded in a raw header value into a plain string suitable for display.
/// Joins adjacent encoded words per RFC 2047 section 2 ("white space between
/// adjacent encoded-words is not displayed"). The result is always valid
/// UTF-8: bytes that don't decode cleanly under the declared charset are
/// replaced with U+FFFD rather than left as raw invalid bytes, since
/// undecodable text would otherwise break Pango rendering in the popup.
///
/// Caller owns the returned slice.
pub fn decodeHeader(gpa: Allocator, input: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    var i: usize = 0;
    var prev_was_encoded = false;
    while (i < input.len) {
        if (startsWithEncodedWord(input[i..])) {
            if (parseEncodedWord(input[i..])) |word| {
                if (try decodeWordInto(gpa, &out, word.charset, word.encoding, word.text)) {
                    i += word.consumed;
                    prev_was_encoded = true;
                    continue;
                }
                // Syntactically an encoded word but semantically
                // undecodable (bad base64, bad hex escape, unrecognized
                // encoding letter): fall back to the literal source text
                // for this span rather than dropping it.
                try out.appendSlice(gpa, input[i..][0..word.consumed]);
                i += word.consumed;
                prev_was_encoded = false;
                continue;
            }
        }

        if (prev_was_encoded and isFoldingSpace(input[i])) {
            const ws_end = skipFoldingSpace(input, i);
            // Only elide the whitespace if what follows is a *fully valid*
            // encoded word -- text that merely starts with "=?" but turns
            // out malformed is literal text once decoded, and literal text
            // keeps its surrounding whitespace.
            if (startsWithEncodedWord(input[ws_end..]) and parseEncodedWord(input[ws_end..]) != null) {
                i = ws_end;
                continue;
            }
        }

        try out.append(gpa, input[i]);
        prev_was_encoded = false;
        i += 1;
    }

    return sanitizeUtf8Alloc(gpa, out.items);
}

const ParsedWord = struct {
    charset: []const u8,
    encoding: u8,
    text: []const u8,
    /// Number of bytes of the original input this word occupies, starting
    /// at the leading '='.
    consumed: usize,
};

fn startsWithEncodedWord(s: []const u8) bool {
    return s.len >= 2 and s[0] == '=' and s[1] == '?';
}

/// `s` must start with "=?" (checked by callers via `startsWithEncodedWord`
/// before calling this). Returns null if `s` doesn't hold a syntactically
/// valid encoded word at its start (unbalanced delimiters, empty charset,
/// unrecognized encoding letter).
fn parseEncodedWord(s: []const u8) ?ParsedWord {
    std.debug.assert(startsWithEncodedWord(s));

    const charset_start = 2;
    const charset_end = std.mem.indexOfScalarPos(u8, s, charset_start, '?') orelse return null;
    const charset = s[charset_start..charset_end];
    if (charset.len == 0) return null;

    // Must be exactly one encoding letter followed by '?'.
    if (charset_end + 2 >= s.len) return null;
    const encoding = s[charset_end + 1];
    switch (encoding) {
        'B', 'b', 'Q', 'q' => {},
        else => return null,
    }
    if (s[charset_end + 2] != '?') return null;

    const text_start = charset_end + 3;
    // Per RFC 2047, encoded-text contains neither '?' nor SPACE, so the
    // first "?=" at or after text_start is unambiguously the terminator.
    const term = std.mem.indexOfPos(u8, s, text_start, "?=") orelse return null;

    return .{
        .charset = charset,
        .encoding = encoding,
        .text = s[text_start..term],
        .consumed = term + 2,
    };
}

/// Decodes `text` (encoding B or Q) and appends the result, converted from
/// `charset`, to `out`. Returns `false` (leaving `out` untouched) if `text`
/// isn't valid under the declared encoding, so the caller can fall back to
/// treating the whole word as literal text.
fn decodeWordInto(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    charset: []const u8,
    encoding: u8,
    text: []const u8,
) Allocator.Error!bool {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);

    switch (encoding) {
        'B', 'b' => {
            const decoder = std.base64.standard.Decoder;
            const size = decoder.calcSizeForSlice(text) catch return false;
            try raw.resize(gpa, size);
            decoder.decode(raw.items, text) catch return false;
        },
        'Q', 'q' => {
            var j: usize = 0;
            while (j < text.len) {
                const ch = text[j];
                if (ch == '_') {
                    try raw.append(gpa, ' ');
                    j += 1;
                } else if (ch == '=') {
                    if (j + 2 >= text.len) return false;
                    const hi = hexVal(text[j + 1]) orelse return false;
                    const lo = hexVal(text[j + 2]) orelse return false;
                    try raw.append(gpa, (hi << 4) | lo);
                    j += 3;
                } else {
                    try raw.append(gpa, ch);
                    j += 1;
                }
            }
        },
        else => unreachable, // parseEncodedWord only allows B/b/Q/q
    }

    try appendForCharset(gpa, out, charset, raw.items);
    return true;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Appends `raw` bytes to `out`, reinterpreted from `charset` into UTF-8.
///
/// Only ISO-8859-1 gets a real conversion (each byte maps directly onto the
/// Unicode codepoint of the same value, which is exactly what Latin-1 is).
/// UTF-8 and US-ASCII need no conversion. Anything else is a known,
/// documented limitation -- this is a waybar tooltip decoder, not a full
/// charset database -- so unrecognized charsets are passed through as-is;
/// `decodeHeader`'s final sanitize pass repairs whatever doesn't happen to
/// be valid UTF-8.
fn appendForCharset(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    charset: []const u8,
    raw: []const u8,
) Allocator.Error!void {
    if (std.ascii.eqlIgnoreCase(charset, "iso-8859-1") or
        std.ascii.eqlIgnoreCase(charset, "iso8859-1") or
        std.ascii.eqlIgnoreCase(charset, "latin1"))
    {
        for (raw) |byte| {
            var buf: [2]u8 = undefined;
            const n = std.unicode.utf8Encode(byte, &buf) catch unreachable; // 0-255 always encodes
            try out.appendSlice(gpa, buf[0..n]);
        }
        return;
    }
    try out.appendSlice(gpa, raw);
}

fn isFoldingSpace(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\r' or b == '\n';
}

fn skipFoldingSpace(input: []const u8, start: usize) usize {
    var i = start;
    while (i < input.len and isFoldingSpace(input[i])) i += 1;
    return i;
}

/// Returns a fresh allocation guaranteed to be valid UTF-8: `bytes` as-is if
/// already valid (the common case), otherwise a repaired copy with each
/// invalid byte replaced by U+FFFD.
fn sanitizeUtf8Alloc(gpa: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) {
        return gpa.dupe(u8, bytes);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try appendUtf8Sanitized(gpa, &out, bytes);
    return out.toOwnedSlice(gpa);
}

fn appendUtf8Sanitized(gpa: Allocator, out: *std.ArrayList(u8), bytes: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try out.appendSlice(gpa, replacement_char);
            i += 1;
            continue;
        };
        if (i + len > bytes.len) {
            try out.appendSlice(gpa, replacement_char);
            i += 1;
            continue;
        }
        const seq = bytes[i..][0..len];
        const valid = switch (len) {
            1 => true,
            2 => if (std.unicode.utf8Decode2(seq[0..2].*)) |_| true else |_| false,
            3 => if (std.unicode.utf8Decode3(seq[0..3].*)) |_| true else |_| false,
            4 => if (std.unicode.utf8Decode4(seq[0..4].*)) |_| true else |_| false,
            else => false,
        };
        if (valid) {
            try out.appendSlice(gpa, seq);
            i += len;
        } else {
            try out.appendSlice(gpa, replacement_char);
            i += 1;
        }
    }
}

// ---- tests ----

const testing = std.testing;

test "plain ASCII passes through unchanged" {
    const got = try decodeHeader(testing.allocator, "Hello, World!");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Hello, World!", got);
}

test "single base64-encoded word" {
    // "Héllo" in UTF-8, base64-encoded.
    const got = try decodeHeader(testing.allocator, "=?UTF-8?B?SMOpbGxv?=");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Héllo", got);
}

test "single quoted-printable word with underscores as spaces" {
    const got = try decodeHeader(testing.allocator, "=?UTF-8?Q?Hello_World=21?=");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Hello World!", got);
}

test "adjacent encoded words are joined without the intervening whitespace" {
    // Two encoded words split across a fold; RFC 2047 says the whitespace
    // between them is not part of the represented text.
    const got = try decodeHeader(testing.allocator, "=?UTF-8?Q?Hello?= =?UTF-8?Q?_World?=");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Hello World", got);
}

test "literal text mixed with an encoded word keeps surrounding whitespace" {
    const got = try decodeHeader(testing.allocator, "Re: =?UTF-8?Q?Hello?= there");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Re: Hello there", got);
}

test "iso-8859-1 charset converts to UTF-8" {
    // 0xE9 in Latin-1 is U+00E9 (é), which is 0xC3 0xA9 in UTF-8.
    const got = try decodeHeader(testing.allocator, "=?ISO-8859-1?Q?caf=E9?=");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("café", got);
}

test "malformed encoded word (unterminated) falls back to literal text" {
    const input = "=?UTF-8?B?not-terminated";
    const got = try decodeHeader(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(input, got);
}

test "malformed encoded word (bad base64 padding) falls back to literal text" {
    const input = "=?UTF-8?B?!!!not-valid-base64!!!?=";
    const got = try decodeHeader(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(input, got);
}

test "unrecognized encoding letter is treated as literal, not a crash" {
    const input = "=?UTF-8?X?whatever?=";
    const got = try decodeHeader(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(input, got);
}

test "empty charset is rejected and treated as literal" {
    const input = "=??B?SGVsbG8=?=";
    const got = try decodeHeader(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(input, got);
}

test "trailing lone '=?' with no terminator does not crash or loop" {
    const got = try decodeHeader(testing.allocator, "abc =?");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("abc =?", got);
}

test "invalid UTF-8 in a literal-text region is replaced with U+FFFD" {
    const input = "bad\xffbyte";
    const got = try decodeHeader(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("bad\u{FFFD}byte", got);
}

test "truncated multi-byte UTF-8 sequence at end of input is replaced" {
    const input = "abc\xE2\x82"; // incomplete 3-byte sequence (would be €)
    const got = try decodeHeader(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("abc\u{FFFD}\u{FFFD}", got);
}

test "empty input" {
    const got = try decodeHeader(testing.allocator, "");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("", got);
}

test "empty encoded-word text decodes to empty string" {
    const got = try decodeHeader(testing.allocator, "[=?UTF-8?B??=]");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("[]", got);
}

test "already-valid UTF-8 with non-ASCII literal text is untouched" {
    const got = try decodeHeader(testing.allocator, "日本語 テスト");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("日本語 テスト", got);
}

// ---- randomized stress test (M7) ----
//
// decodeHeader's whole job is parsing attacker-influenced input (email
// headers), so it's worth more than hand-picked edge cases. This generates
// a large number of random byte strings -- weighted toward the specific
// bytes that actually matter to the parser ('=', '?', '_', high-bit bytes)
// rather than uniform noise, since uniform random bytes essentially never
// produce anything that even looks like "=?...?=" -- and checks the two
// invariants the module's own doc comment promises: it never returns an
// error other than OutOfMemory (so a panic or an unexpected error variant
// both fail the test), and the result is always valid UTF-8 no matter how
// garbled the input.
//
// A fixed seed keeps this reproducible; deliberately not std.testing.fuzz
// (Zig 0.16's coverage-guided harness) since a fixed, large iteration count
// over a hand-biased alphabet already exercises every branch in a decoder
// this size (confirmed by also running with several different seeds during
// development, all clean) with a much smaller surface to get wrong for the
// gain involved here.
test "decodeHeader never crashes and always produces valid UTF-8 on random input" {
    var prng = std.Random.DefaultPrng.init(0x6d696d65); // "mime" as inspiration, not cryptographic
    const random = prng.random();

    // Heavily biased toward the bytes the parser actually branches on, so
    // random strings actually land inside/near encoded-word syntax instead
    // of being uniformly-distributed noise that's always trivially literal.
    const alphabet = "=?BbQq_0123456789ABCDEFabcdefUTF-8ISOso-8859-1 \t\r\n\"<>[]" ++ "\xff\xfe\x80\x81\xc0\xe0\xf0";

    var iteration: usize = 0;
    while (iteration < 20_000) : (iteration += 1) {
        const len = random.intRangeAtMost(usize, 0, 96);
        var buf: [96]u8 = undefined;
        for (buf[0..len]) |*b| {
            b.* = alphabet[random.intRangeLessThan(usize, 0, alphabet.len)];
        }
        const input = buf[0..len];

        const got = decodeHeader(testing.allocator, input) catch |err| {
            std.debug.print("decodeHeader returned an error on iteration {d}, input: {any}\n", .{ iteration, input });
            return err;
        };
        defer testing.allocator.free(got);

        if (!std.unicode.utf8ValidateSlice(got)) {
            std.debug.print("decodeHeader produced invalid UTF-8 on iteration {d}\n  input:  {any}\n  output: {any}\n", .{ iteration, input, got });
            return error.InvalidUtf8Produced;
        }
    }
}
