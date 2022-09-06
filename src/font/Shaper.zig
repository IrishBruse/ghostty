//! This struct handles text shaping.
const Shaper = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const harfbuzz = @import("harfbuzz");
const Atlas = @import("../Atlas.zig");
const Face = @import("main.zig").Face;
const Group = @import("main.zig").Group;
const GroupCache = @import("main.zig").GroupCache;
const Library = @import("main.zig").Library;
const Style = @import("main.zig").Style;
const Presentation = @import("main.zig").Presentation;
const terminal = @import("../terminal/main.zig");

const log = std.log.scoped(.font_shaper);

/// The font group to use under the covers
group: *GroupCache,

/// The buffer used for text shaping. We reuse it across multiple shaping
/// calls to prevent allocations.
hb_buf: harfbuzz.Buffer,

/// The shared memory used for shaping results.
cell_buf: []Cell,

/// The cell_buf argument is the buffer to use for storing shaped results.
/// This should be at least the number of columns in the terminal.
pub fn init(group: *GroupCache, cell_buf: []Cell) !Shaper {
    return Shaper{
        .group = group,
        .hb_buf = try harfbuzz.Buffer.create(),
        .cell_buf = cell_buf,
    };
}

pub fn deinit(self: *Shaper) void {
    self.hb_buf.destroy();
}

/// Returns an iterator that returns one text run at a time for the
/// given terminal row. Note that text runs are are only valid one at a time
/// for a Shaper struct since they share state.
pub fn runIterator(self: *Shaper, row: terminal.Screen.Row) RunIterator {
    return .{ .shaper = self, .row = row };
}

/// Shape the given text run. The text run must be the immediately previous
/// text run that was iterated since the text run does share state with the
/// Shaper struct.
///
/// The return value is only valid until the next shape call is called.
///
/// If there is not enough space in the cell buffer, an error is returned.
pub fn shape(self: *Shaper, run: TextRun) ![]Cell {
    // TODO: we do not want to hardcode these
    const hb_feats = &[_]harfbuzz.Feature{
        harfbuzz.Feature.fromString("dlig").?,
        harfbuzz.Feature.fromString("liga").?,
    };

    const face = self.group.group.faceFromIndex(run.font_index);
    harfbuzz.shape(face.hb_font, self.hb_buf, hb_feats);

    // If our buffer is empty, we short-circuit the rest of the work
    // return nothing.
    if (self.hb_buf.getLength() == 0) return self.cell_buf[0..0];
    const info = self.hb_buf.getGlyphInfos();
    const pos = self.hb_buf.getGlyphPositions() orelse return error.HarfbuzzFailed;

    // This is perhaps not true somewhere, but we currently assume it is true.
    // If it isn't true, I'd like to catch it and learn more.
    assert(info.len == pos.len);

    // Convert all our info/pos to cells and set it.
    if (info.len > self.cell_buf.len) return error.OutOfMemory;
    //log.warn("info={} pos={} run={}", .{ info.len, pos.len, run });

    // x is the column that we currently occupy. We start at the offset.
    var x: u16 = run.offset;

    for (info) |v, i| {
        // The number of codepoints is used as the cell "width". If
        // we're the last cell, this is remaining otherwise we use cluster numbers
        // to detect since we set the cluster number to the column it
        // originated.
        const cp_width = @maximum(1, if (i == info.len - 1)
            (run.max_cluster - v.cluster) + 1 // + 1 because we're zero indexed
        else width: {
            const next_cluster = info[i + 1].cluster;
            break :width next_cluster - v.cluster;
        });

        self.cell_buf[i] = .{
            .x = x,
            .glyph_index = v.codepoint,
            .width = @intCast(u8, cp_width),
        };

        // Increase x by the amount of codepoints we replaced so that
        // we retain the grid.
        x += @intCast(u16, cp_width);

        //log.warn("i={} info={} pos={} cell={}", .{ i, v, pos[i], self.cell_buf[i] });
    }

    return self.cell_buf[0..info.len];
}

pub const Cell = struct {
    /// The column that this cell occupies. Since a set of shaper cells is
    /// always on the same line, only the X is stored. It is expected the
    /// caller has access to the original screen cell.
    x: u16,

    /// The glyph index for this cell. The font index to use alongside
    /// this cell is available in the text run.
    glyph_index: u32,

    /// The width that this cell consumes.
    width: u8,
};

/// A single text run. A text run is only valid for one Shaper and
/// until the next run is created.
pub const TextRun = struct {
    /// The offset in the row where this run started
    offset: u16,

    /// The total number of cells produced by this run.
    cells: u16,

    /// The maximum cluster value used
    max_cluster: u16,

    /// The font index to use for the glyphs of this run.
    font_index: Group.FontIndex,
};

pub const RunIterator = struct {
    shaper: *Shaper,
    row: terminal.Screen.Row,
    i: usize = 0,

    pub fn next(self: *RunIterator, alloc: Allocator) !?TextRun {
        if (self.i >= self.row.lenCells()) return null;

        // Track the font for our curent run
        var current_font: Group.FontIndex = .{};

        // Reset the buffer for our current run
        self.shaper.hb_buf.reset();
        self.shaper.hb_buf.setContentType(.unicode);

        // Go through cell by cell and accumulate while we build our run.
        var j: usize = self.i;
        var max_cluster: usize = j;
        while (j < self.row.lenCells()) : (j += 1) {
            const cell = self.row.getCell(j);

            // Ignore empty cells
            if (cell.empty()) continue;

            // If we're a spacer, then we ignore it but increase the max cluster
            // size so that the width calculation is correct.
            if (cell.attrs.wide_spacer_tail) {
                max_cluster = j;
                continue;
            }

            const style: Style = if (cell.attrs.bold)
                .bold
            else
                .regular;

            // Determine the presentation format for this glyph.
            const presentation: ?Presentation = if (cell.attrs.grapheme) p: {
                var it = self.row.codepointIterator(j);
                while (it.next()) |cp| {
                    if (cp == 0xFE0E) break :p Presentation.text;
                    if (cp == 0xFE0F) break :p Presentation.emoji;
                }

                break :p null;
            } else null;

            // Determine the font for this cell. We'll use fallbacks
            // manually here to try replacement chars and then a space
            // for unknown glyphs.
            const font_idx_opt = (try self.shaper.group.indexForCodepoint(
                alloc,
                cell.char,
                style,
                presentation,
            )) orelse (try self.shaper.group.indexForCodepoint(
                alloc,
                0xFFFD,
                style,
                .text,
            )) orelse
                try self.shaper.group.indexForCodepoint(alloc, ' ', style, .text);
            const font_idx = font_idx_opt.?;
            //log.warn("char={x} idx={}", .{ cell.char, font_idx });
            if (j == self.i) current_font = font_idx;

            // If our fonts are not equal, then we're done with our run.
            if (font_idx.int() != current_font.int()) break;

            // Continue with our run
            self.shaper.hb_buf.add(cell.char, @intCast(u32, j));

            // If this cell is part of a grapheme cluster, add all the grapheme
            // data points.
            if (cell.attrs.grapheme) {
                var it = self.row.codepointIterator(j);
                while (it.next()) |cp| {
                    self.shaper.hb_buf.add(cp, @intCast(u32, j));
                }
            }

            max_cluster = j;
        }

        // Finalize our buffer
        self.shaper.hb_buf.guessSegmentProperties();

        // Move our cursor. Must defer since we use self.i below.
        defer self.i = j;

        return TextRun{
            .offset = @intCast(u16, self.i),
            .cells = @intCast(u16, j - self.i),
            .max_cluster = @intCast(u16, max_cluster),
            .font_index = current_font,
        };
    }
};

test "run iterator" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    {
        // Make a screen with some data
        var screen = try terminal.Screen.init(alloc, 3, 5, 0);
        defer screen.deinit();
        try screen.testWriteString("ABCD");

        // Get our run iterator
        var shaper = testdata.shaper;
        var it = shaper.runIterator(screen.getRow(.{ .screen = 0 }));
        var count: usize = 0;
        while (try it.next(alloc)) |_| count += 1;
        try testing.expectEqual(@as(usize, 1), count);
    }

    // Spaces should be part of a run
    {
        var screen = try terminal.Screen.init(alloc, 3, 10, 0);
        defer screen.deinit();
        try screen.testWriteString("ABCD   EFG");

        var shaper = testdata.shaper;
        var it = shaper.runIterator(screen.getRow(.{ .screen = 0 }));
        var count: usize = 0;
        while (try it.next(alloc)) |_| count += 1;
        try testing.expectEqual(@as(usize, 1), count);
    }

    {
        // Make a screen with some data
        var screen = try terminal.Screen.init(alloc, 3, 5, 0);
        defer screen.deinit();
        try screen.testWriteString("A😃D");

        // Get our run iterator
        var shaper = testdata.shaper;
        var it = shaper.runIterator(screen.getRow(.{ .screen = 0 }));
        var count: usize = 0;
        while (try it.next(alloc)) |_| {
            count += 1;

            // All runs should be exactly length 1
            try testing.expectEqual(@as(u32, 1), shaper.hb_buf.getLength());
        }
        try testing.expectEqual(@as(usize, 3), count);
    }
}

test "shape" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x1F44D, buf[buf_idx..]); // Thumbs up plain
    buf_idx += try std.unicode.utf8Encode(0x1F44D, buf[buf_idx..]); // Thumbs up plain
    buf_idx += try std.unicode.utf8Encode(0x1F3FD, buf[buf_idx..]); // Medium skin tone

    // Make a screen with some data
    var screen = try terminal.Screen.init(alloc, 3, 10, 0);
    defer screen.deinit();
    try screen.testWriteString(buf[0..buf_idx]);

    // Get our run iterator
    var shaper = testdata.shaper;
    var it = shaper.runIterator(screen.getRow(.{ .screen = 0 }));
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        try testing.expectEqual(@as(u32, 3), shaper.hb_buf.getLength());
        _ = try shaper.shape(run);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape inconsolata ligs" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    {
        var screen = try terminal.Screen.init(alloc, 3, 5, 0);
        defer screen.deinit();
        try screen.testWriteString(">=");

        var shaper = testdata.shaper;
        var it = shaper.runIterator(screen.getRow(.{ .screen = 0 }));
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;

            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 1), cells.len);
            try testing.expectEqual(@as(u8, 2), cells[0].width);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    {
        var screen = try terminal.Screen.init(alloc, 3, 5, 0);
        defer screen.deinit();
        try screen.testWriteString("===");

        var shaper = testdata.shaper;
        var it = shaper.runIterator(screen.getRow(.{ .screen = 0 }));
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;

            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 1), cells.len);
            try testing.expectEqual(@as(u8, 3), cells[0].width);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

test "shape emoji width" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    {
        var screen = try terminal.Screen.init(alloc, 3, 5, 0);
        defer screen.deinit();
        try screen.testWriteString("👍");

        var shaper = testdata.shaper;
        var it = shaper.runIterator(screen.getRow(.{ .screen = 0 }));
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;

            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 1), cells.len);
            try testing.expectEqual(@as(u8, 2), cells[0].width);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

test "shape variation selector VS15" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x270C, buf[buf_idx..]); // Victory sign (default text)
    buf_idx += try std.unicode.utf8Encode(0xFE0E, buf[buf_idx..]); // ZWJ to force text

    // Make a screen with some data
    var screen = try terminal.Screen.init(alloc, 3, 10, 0);
    defer screen.deinit();
    try screen.testWriteString(buf[0..buf_idx]);

    // Get our run iterator
    var shaper = testdata.shaper;
    var it = shaper.runIterator(screen.getRow(.{ .screen = 0 }));
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        try testing.expectEqual(@as(u32, 2), shaper.hb_buf.getLength());

        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u8, 1), cells[0].width);
        try testing.expectEqual(@as(u8, 1), cells[1].width);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape variation selector VS16" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x270C, buf[buf_idx..]); // Victory sign (default text)
    buf_idx += try std.unicode.utf8Encode(0xFE0F, buf[buf_idx..]); // ZWJ to force color

    // Make a screen with some data
    var screen = try terminal.Screen.init(alloc, 3, 10, 0);
    defer screen.deinit();
    try screen.testWriteString(buf[0..buf_idx]);

    // Get our run iterator
    var shaper = testdata.shaper;
    var it = shaper.runIterator(screen.getRow(.{ .screen = 0 }));
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        try testing.expectEqual(@as(u32, 2), shaper.hb_buf.getLength());

        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 1), cells.len);

        // TODO: this should pass, victory sign is width one but
        // after forcing color it is width 2
        //try testing.expectEqual(@as(u8, 2), cells[0].width);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

const TestShaper = struct {
    alloc: Allocator,
    shaper: Shaper,
    cache: *GroupCache,
    lib: Library,
    cell_buf: []Cell,

    pub fn deinit(self: *TestShaper) void {
        self.shaper.deinit();
        self.cache.deinit(self.alloc);
        self.alloc.destroy(self.cache);
        self.alloc.free(self.cell_buf);
        self.lib.deinit();
    }
};

/// Helper to return a fully initialized shaper.
fn testShaper(alloc: Allocator) !TestShaper {
    const testFont = @import("test.zig").fontRegular;
    const testEmoji = @import("test.zig").fontEmoji;
    const testEmojiText = @import("test.zig").fontEmojiText;

    var lib = try Library.init();
    errdefer lib.deinit();

    var cache_ptr = try alloc.create(GroupCache);
    errdefer alloc.destroy(cache_ptr);
    cache_ptr.* = try GroupCache.init(alloc, try Group.init(alloc));
    errdefer cache_ptr.*.deinit(alloc);

    // Setup group
    try cache_ptr.group.addFace(alloc, .regular, try Face.init(lib, testFont, .{ .points = 12 }));
    try cache_ptr.group.addFace(alloc, .regular, try Face.init(lib, testEmoji, .{ .points = 12 }));
    try cache_ptr.group.addFace(alloc, .regular, try Face.init(lib, testEmojiText, .{ .points = 12 }));

    var cell_buf = try alloc.alloc(Cell, 80);
    errdefer alloc.free(cell_buf);

    var shaper = try init(cache_ptr, cell_buf);
    errdefer shaper.deinit();

    return TestShaper{
        .alloc = alloc,
        .shaper = shaper,
        .cache = cache_ptr,
        .lib = lib,
        .cell_buf = cell_buf,
    };
}
