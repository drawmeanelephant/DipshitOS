//! VirelaiOS Conforming 8-bit PNG Decoder.
//!
//! Milestone 23 / Issue #824 (IMG3).
//! Freestanding, zero-heap PNG decoder.
//! Supports Grayscale (type 0), Truecolor RGB (type 2), and Truecolor+Alpha RGBA (type 6).
//! Reconstructs scanlines across all 5 PNG filter types (None, Sub, Up, Average, Paeth)
//! and decodes directly into 32-bpp B8G8R8X8_UNORM format.

const std = @import("std");
const crc32 = @import("crc32.zig");
const flate = @import("flate.zig");

pub const PngError = error{
    HeaderMagic,
    TruncatedInput,
    BufferTooSmall,
    InvalidCrc,
    UnsupportedBitDepth,
    UnsupportedColorType,
    UnsupportedInterlace,
    CorruptStream,
    InvalidBlockType,
    InvalidHuffmanTree,
    InvalidDistance,
    InvalidZlibHeader,
    Adler32Mismatch,
};

pub const PngHeader = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    compression_method: u8,
    filter_method: u8,
    interlace_method: u8,
};

pub const PNG_SIGNATURE = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

/// Maximum row bytes supported by the static row buffers (e.g. up to 1024 pixels * 4 = 4096 bytes).
pub const MAX_ROW_BYTES: usize = 4096;
/// Default BSS workspace for IDAT assembly and decompression.
pub const DECOMPRESS_BUF_SIZE: usize = 256 * 1024;
var bss_idat_buf: [128 * 1024]u8 = undefined;
var bss_decomp_buf: [DECOMPRESS_BUF_SIZE]u8 = undefined;
var bss_prev_row: [MAX_ROW_BYTES]u8 = undefined;
var bss_cur_row: [MAX_ROW_BYTES]u8 = undefined;

inline fn paeth_predictor(a: u8, b: u8, c: u8) u8 {
    const p: i32 = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = @abs(p - @as(i32, a));
    const pb = @abs(p - @as(i32, b));
    const pc = @abs(p - @as(i32, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

pub fn decode(bytes: []const u8, out_pixels: []align(1) u32) PngError!PngHeader {
    return decode_with_buffers(
        bytes,
        out_pixels,
        &bss_idat_buf,
        &bss_decomp_buf,
        &bss_prev_row,
        &bss_cur_row,
    );
}

pub fn decode_with_buffers(
    bytes: []const u8,
    out_pixels: []align(1) u32,
    idat_buf: []u8,
    decomp_buf: []u8,
    prev_row: []u8,
    cur_row: []u8,
) PngError!PngHeader {
    if (bytes.len < 8) return error.TruncatedInput;
    if (!std.mem.eql(u8, bytes[0..8], &PNG_SIGNATURE)) return error.HeaderMagic;

    var in_pos: usize = 8;
    var header_opt: ?PngHeader = null;
    var idat_len: usize = 0;

    // Parse PNG Chunks
    while (in_pos + 8 <= bytes.len) {
        const chunk_len = std.mem.readInt(u32, bytes[in_pos..][0..4], .big);
        const chunk_type = bytes[in_pos + 4 .. in_pos + 8];
        in_pos += 8;

        if (in_pos + chunk_len + 4 > bytes.len) return error.TruncatedInput;
        const chunk_data = bytes[in_pos .. in_pos + chunk_len];
        in_pos += chunk_len;

        const expected_crc = std.mem.readInt(u32, bytes[in_pos..][0..4], .big);
        in_pos += 4;

        // Verify CRC over chunk_type + chunk_data
        var running_crc = crc32.update(0xFFFFFFFF, chunk_type);
        running_crc = crc32.update(running_crc, chunk_data);
        if ((running_crc ^ 0xFFFFFFFF) != expected_crc) return error.InvalidCrc;

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (chunk_len != 13) return error.CorruptStream;
            const w = std.mem.readInt(u32, chunk_data[0..4], .big);
            const h = std.mem.readInt(u32, chunk_data[4..8], .big);
            const bit_depth = chunk_data[8];
            const color_type = chunk_data[9];
            const comp = chunk_data[10];
            const filter = chunk_data[11];
            const interlace = chunk_data[12];

            if (bit_depth != 8) return error.UnsupportedBitDepth;
            if (color_type != 0 and color_type != 2 and color_type != 6) return error.UnsupportedColorType;
            if (interlace != 0) return error.UnsupportedInterlace;
            if (comp != 0 or filter != 0) return error.CorruptStream;

            header_opt = .{
                .width = w,
                .height = h,
                .bit_depth = bit_depth,
                .color_type = color_type,
                .compression_method = comp,
                .filter_method = filter,
                .interlace_method = interlace,
            };
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            if (idat_len + chunk_len > idat_buf.len) return error.BufferTooSmall;
            @memcpy(idat_buf[idat_len .. idat_len + chunk_len], chunk_data);
            idat_len += chunk_len;
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }
    }

    const header = header_opt orelse return error.CorruptStream;
    const total_pixels = @as(usize, header.width) * header.height;
    if (out_pixels.len < total_pixels) return error.BufferTooSmall;

    const bpp: usize = switch (header.color_type) {
        0 => 1, // Grayscale
        2 => 3, // Truecolor RGB
        6 => 4, // Truecolor + Alpha
        else => return error.UnsupportedColorType,
    };

    const row_bytes = @as(usize, header.width) * bpp;
    if (row_bytes > prev_row.len or row_bytes > cur_row.len) return error.BufferTooSmall;

    // Decompress the IDAT stream through flate (zlib wrapped)
    const decompressed_size = flate.inflate(idat_buf[0..idat_len], decomp_buf, false) catch |err| switch (err) {
        error.InvalidBlockType => return error.InvalidBlockType,
        error.InvalidHuffmanTree => return error.InvalidHuffmanTree,
        error.InvalidDistance => return error.InvalidDistance,
        error.InvalidZlibHeader => return error.InvalidZlibHeader,
        error.Adler32Mismatch => return error.Adler32Mismatch,
        error.CorruptStream => return error.CorruptStream,
        error.BufferTooSmall => return error.BufferTooSmall,
    };

    const expected_decomp_size = @as(usize, header.height) * (row_bytes + 1);
    if (decompressed_size != expected_decomp_size) return error.CorruptStream;

    // Reconstruct scanlines
    @memset(prev_row[0..row_bytes], 0);

    var y: usize = 0;
    while (y < header.height) : (y += 1) {
        const row_offset = y * (row_bytes + 1);
        const filter_type = decomp_buf[row_offset];
        const raw_row = decomp_buf[row_offset + 1 .. row_offset + 1 + row_bytes];

        var i: usize = 0;
        while (i < row_bytes) : (i += 1) {
            const x = raw_row[i];
            const a = if (i >= bpp) cur_row[i - bpp] else 0;
            const b = prev_row[i];
            const c = if (i >= bpp) prev_row[i - bpp] else 0;

            const val: u8 = switch (filter_type) {
                0 => x,
                1 => x +% a,
                2 => x +% b,
                3 => x +% @as(u8, @truncate((@as(u16, a) + @as(u16, b)) / 2)),
                4 => x +% paeth_predictor(a, b, c),
                else => return error.CorruptStream,
            };
            cur_row[i] = val;
        }

        // Convert scanline to B8G8R8X8 destination pixels
        var x_idx: usize = 0;
        while (x_idx < header.width) : (x_idx += 1) {
            const out_idx = y * header.width + x_idx;
            if (header.color_type == 0) { // Grayscale
                const gray: u32 = cur_row[x_idx];
                out_pixels[out_idx] = 0xFF000000 | (gray << 16) | (gray << 8) | gray;
            } else if (header.color_type == 2) { // RGB
                const r: u32 = cur_row[x_idx * 3 + 0];
                const g: u32 = cur_row[x_idx * 3 + 1];
                const b: u32 = cur_row[x_idx * 3 + 2];
                out_pixels[out_idx] = 0xFF000000 | (r << 16) | (g << 8) | b;
            } else if (header.color_type == 6) { // RGBA
                const r: u32 = cur_row[x_idx * 4 + 0];
                const g: u32 = cur_row[x_idx * 4 + 1];
                const b: u32 = cur_row[x_idx * 4 + 2];
                const a: u32 = cur_row[x_idx * 4 + 3];
                out_pixels[out_idx] = (a << 24) | (r << 16) | (g << 8) | b;
            }
        }

        @memcpy(prev_row[0..row_bytes], cur_row[0..row_bytes]);
    }

    return header;
}

// ---------------------------------------------------------------------------
// Host Unit Tests
// ---------------------------------------------------------------------------

test "png: reject invalid signature and corrupt crc" {
    var out: [16]u32 = undefined;
    try std.testing.expectError(error.HeaderMagic, decode("NOT_A_PNG_FILE", &out));

    const fixture = @embedFile("fixtures/png/solid_rgb_4x4.png");
    var corrupt: [fixture.len]u8 = undefined;
    @memcpy(&corrupt, fixture);
    // Corrupt one byte inside IHDR data
    corrupt[16] ^= 0xFF;
    try std.testing.expectError(error.InvalidCrc, decode(&corrupt, &out));
}

test "png: decode solid rgb 4x4 fixture" {
    const fixture = @embedFile("fixtures/png/solid_rgb_4x4.png");
    var pixels: [16]u32 = undefined;
    const header = try decode(fixture, &pixels);

    try std.testing.expectEqual(@as(u32, 4), header.width);
    try std.testing.expectEqual(@as(u32, 4), header.height);
    try std.testing.expectEqual(@as(u8, 2), header.color_type); // RGB

    // Opaque Red in B8G8R8X8: 0xFFFF0000
    for (pixels) |px| {
        try std.testing.expectEqual(@as(u32, 0xFFFF0000), px);
    }
}

test "png: decode gradient rgba 8x8 fixture" {
    const fixture = @embedFile("fixtures/png/gradient_rgba_8x8.png");
    var pixels: [64]u32 = undefined;
    const header = try decode(fixture, &pixels);

    try std.testing.expectEqual(@as(u32, 8), header.width);
    try std.testing.expectEqual(@as(u32, 8), header.height);
    try std.testing.expectEqual(@as(u8, 6), header.color_type); // RGBA

    // Pixel (0, 0): r=0, g=0, b=0, a=255 -> 0xFF000000
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[0]);

    // Pixel (1, 0): r=32, g=0, b=16, a=128 -> (128 << 24) | (32 << 16) | (0 << 8) | 16 = 0x80200010
    const expected_1_0: u32 = (128 << 24) | (32 << 16) | (0 << 8) | 16;
    try std.testing.expectEqual(expected_1_0, pixels[1]);
}

test "png: decode non-square 12x4 fixture" {
    const fixture = @embedFile("fixtures/png/rect_12x4.png");
    var pixels: [48]u32 = undefined;
    const header = try decode(fixture, &pixels);

    try std.testing.expectEqual(@as(u32, 12), header.width);
    try std.testing.expectEqual(@as(u32, 4), header.height);

    // Pixel (0, 0): r=0, g=0, b=100 -> 0xFF000064
    try std.testing.expectEqual(@as(u32, 0xFF000064), pixels[0]);
}

test "png: decode grayscale 8x8 fixture" {
    const fixture = @embedFile("fixtures/png/gray_8x8.png");
    var pixels: [64]u32 = undefined;
    const header = try decode(fixture, &pixels);

    try std.testing.expectEqual(@as(u32, 8), header.width);
    try std.testing.expectEqual(@as(u32, 8), header.height);
    try std.testing.expectEqual(@as(u8, 0), header.color_type); // Grayscale

    // Pixel (0, 0): gray = 0 -> 0xFF000000
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[0]);

    // Pixel (1, 1): gray = (1+1)*16 = 32 (0x20) -> 0xFF202020
    try std.testing.expectEqual(@as(u32, 0xFF202020), pixels[1 * 8 + 1]);
}
