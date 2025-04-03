const std = @import("std");
const StringMap = std.StringArrayHashMap([]const u8);
const logger = std.log.scoped(.pdf);

pub const PDFError = error{ OffsetTooBig, MissingXRef };

pub const MetadataMap = struct {
    start_offset: usize,
    end_offset: usize,
    map: StringMap,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) MetadataMap {
        const arena = std.heap.ArenaAllocator.init(allocator);
        return .{
            .start_offset = 0,
            .end_offset = 0,
            .map = StringMap.init(allocator),
            .arena = arena,
        };
    }

    pub fn write(self: *const MetadataMap, writer: anytype) !void {
        try writer.writeAll("\n<<\n");

        var itt = self.map.iterator();
        while (itt.next()) |kv| {
            try writer.print("/{s} ", .{kv.key_ptr.*});
            if (kv.value_ptr.*.len > 0 and kv.value_ptr.*[0] == '/') {
                try writer.writeAll(kv.value_ptr.*);
            } else {
                try writer.print("({s})", .{kv.value_ptr.*});
            }
            try writer.writeAll("\n");
        }

        try writer.writeAll(">>");
    }

    pub fn put(self: *MetadataMap, key: []const u8, value: []const u8) !void {
        const alloc = self.arena.allocator();
        try self.map.put(try alloc.dupe(u8, key), try alloc.dupe(u8, value));
    }

    pub fn deinit(self: *MetadataMap) void {
        self.arena.deinit();
        self.map.deinit();
        self.* = undefined;
    }
};

pub fn parseMetadataMap(
    allocator: std.mem.Allocator,
    all_contents: []const u8,
    index: usize,
) !MetadataMap {
    const contents = all_contents[index..];

    var itt = PDFTokenizer.init(contents);
    // skip ahead to the start of the map
    while (itt.peek()) |token| {
        if (token.len > 1 and std.mem.eql(u8, token, "<<")) {
            break;
        }
        _ = itt.next();
    }

    var meta_map = MetadataMap.init(allocator);
    errdefer meta_map.deinit();
    meta_map.start_offset = itt.index + index;

    while (itt.next()) |token| {
        if (token.len > 1 and std.mem.eql(u8, token, ">>")) {
            // map end
            break;
        }

        if (token[0] == '/') {
            const value = b: {
                if (itt.peek()) |p| {
                    // eat the opening '('
                    if (p[0] == '(') {
                        _ = itt.next();
                        const value_start = itt.index;
                        while ((itt.next())) |n| {
                            if (n.len == 1 and n[0] == ')') break;
                        }
                        break :b itt.content[value_start .. itt.index - 1];
                    } else {
                        break :b itt.next().?;
                    }
                }
                unreachable;
            };

            try meta_map.put(token[1..], value);
        }
    }

    meta_map.end_offset = itt.index + index;
    return meta_map;
}

fn testParseMap(expected_keys: []const []const u8, expected_values: []const []const u8, string: []const u8) !void {
    var map = try parseMetadataMap(std.testing.allocator, string, 0);
    defer map.deinit();

    for (expected_keys, map.map.keys(), expected_values, map.map.values()) |exp, acc, exp_v, acc_v| {
        try std.testing.expectEqualStrings(exp, acc);
        try std.testing.expectEqualStrings(exp_v, acc_v);
    }
}

test "metedata-map" {
    try testParseMap(
        &.{ "Time", "Hello" },
        &.{ "something", "world" },
        "<</Time something /Hello world>>",
    );
}

/// Tokenizer PDF post-script
pub const PDFTokenizer = struct {
    content: []const u8,
    index: usize = 0,

    pub fn init(content: []const u8) PDFTokenizer {
        return .{ .content = content };
    }

    /// Peek to the next element without advancing the index
    pub fn peek(self: *PDFTokenizer) ?[]const u8 {
        const index = self.index;
        const n = self.next();
        self.index = index;
        return n;
    }

    /// Obtain the next element or null.
    pub fn next(self: *PDFTokenizer) ?[]const u8 {
        var start = self.index;
        while (self.index < self.content.len) {
            switch (self.content[self.index]) {
                ' ', '\r', '\n' => {
                    if (self.index - start > 0) {
                        return self.content[start..self.index];
                    } else {
                        start = self.index + 1;
                    }
                },
                '\\' => {
                    // skip the next character
                    self.index += 1;
                },
                '[', ']', '(', ')' => {
                    if (self.index - start == 0) {
                        self.index += 1;
                    }
                    return self.content[start..self.index];
                },
                '<', '>' => {
                    const n = self.content[self.index + 1];
                    if (self.index == start) {
                        if (n == '>' or n == '<') {
                            self.index += 2;
                            return self.content[start..self.index];
                        }
                    } else {
                        return self.content[start..self.index];
                    }
                },
                else => {},
            }
            self.index += 1;
        }

        return null;
    }
};

fn testPDFTokenize(
    expected: []const []const u8,
    string: []const u8,
) !void {
    var itt = PDFTokenizer.init(string);
    var list = std.ArrayList([]const u8).init(std.testing.allocator);
    defer list.deinit();

    while (itt.next()) |token| try list.append(token);

    for (expected, list.items) |e, acc|
        try std.testing.expectEqualStrings(e, acc);
}

test "pdf-tokenize" {
    try testPDFTokenize(
        &.{ "<<", "/Key", "(", "value", ")", ">>" },
        "<< /Key (value) >>",
    );
    try testPDFTokenize(
        &.{ "<<", "/Key", "(", "value", "things", ")", ">>" },
        "<< /Key (value things) >>",
    );
    try testPDFTokenize(
        &.{ "<<", "/Key", "[", "value", "things", "]", ">>" },
        "<< /Key [value things] >>",
    );
    try testPDFTokenize(
        &.{ "<<", "/Key", "[", "value", "things", "]", ">>" },
        "<</Key [value things]>>",
    );
}

/// Used to apply a new slice of text to the PDF source at a given offset
const DiffChunk = struct {
    offset: usize,
    old: []const u8,
    new: []const u8,
};

const ChunkOrXref = union(enum) {
    chunk: DiffChunk,
    xref: PDFFile.XRefTable,
    startxref: PDFFile.StartXRef,

    fn getOffset(self: ChunkOrXref) usize {
        return switch (self) {
            .chunk => |c| c.offset,
            .xref => |c| c.start_offset,
            .startxref => |c| c.start_offset,
        };
    }

    fn getEndOffset(self: ChunkOrXref) usize {
        return switch (self) {
            .chunk => |c| c.old.len + c.offset,
            .xref => |c| c.end_offset,
            .startxref => |c| c.end_offset,
        };
    }

    pub fn sort_offset(_: void, lhs: ChunkOrXref, rhs: ChunkOrXref) bool {
        return lhs.getOffset() < rhs.getOffset();
    }
};

/// Abstraction representing diff'd structure of a PDF file used to writing
/// changes back to the filesystem
pub const PDFFile = struct {
    const StartXRef = struct {
        start_offset: usize,
        end_offset: usize,
        location: usize,
    };
    const XRefTable = struct {
        const XRef = struct {
            offset: usize,
            // How old the object is
            generation: usize,
            // true: normal in-use, false: free object
            in_use: bool,
        };
        // the offsets of the table itself
        start_offset: usize,
        end_offset: usize,

        // the start offset and number of entries:  maps the first index to the
        // number of entries
        headers: std.AutoArrayHashMap(usize, usize),
        // the entries in the table
        entries: std.AutoArrayHashMap(usize, XRef),

        /// Write the cross-reference table to the writer, given a map of byte
        /// changes at specific offsets.
        pub fn write(
            self: XRefTable,
            writer: anytype,
            deltas: std.AutoArrayHashMap(usize, i64),
        ) !void {
            try writer.writeAll("xref\n");
            var header_itt = self.headers.iterator();

            while (header_itt.next()) |h| {
                const first = h.key_ptr.*;
                const length = h.value_ptr.*;
                try writer.print("{d} {d}\n", .{ first, length });

                for (0..length) |i| {
                    const xref = self.entries.get(first + i).?;
                    const offset = xref.offset;

                    var byte_delta: i64 = 0;
                    for (deltas.keys()) |k| {
                        if (k <= offset) {
                            byte_delta += deltas.get(k).?;
                        }
                    }

                    try writer.print("{d:0>10} {d:0>5} {c} \n", .{
                        @as(usize, @intCast(@as(i64, @intCast(offset)) + byte_delta)),
                        xref.generation,
                        @as(u8, if (xref.in_use) 'n' else 'f'),
                    });
                }
            }
            try writer.writeAll("trailer");
        }
    };

    contents: []const u8,
    allocator: std.mem.Allocator,
    xrefs: std.ArrayList(XRefTable),
    starts: std.ArrayList(StartXRef),

    pub fn init(allocator: std.mem.Allocator, contents: []const u8) PDFFile {
        const xrefs = std.ArrayList(XRefTable).init(allocator);
        const starts = std.ArrayList(StartXRef).init(allocator);
        return .{
            .contents = contents,
            .allocator = allocator,
            .xrefs = xrefs,
            .starts = starts,
        };
    }

    fn parseXrefOffset(self: *const PDFFile, start: usize) !StartXRef {
        var itt = PDFTokenizer.init(self.contents[start..]);
        // throw away the 'startxref'
        _ = itt.next();
        // get the byte offset of the xref table
        const location = try std.fmt.parseInt(usize, itt.next().?, 10);
        return .{
            .start_offset = start,
            .end_offset = itt.index + start,
            .location = location,
        };
    }

    /// Parse the cross-reference tables
    pub fn parseXrefTables(self: *PDFFile) !void {
        var end: usize = self.contents.len;

        // TODO: this is a workaround for EXIFTOOL that can occasionally write
        // a 'startxref' that is beyond th eend of the file. If this is the
        // case, we just read the next 'startxref' to find the next table
        while (std.mem.lastIndexOf(u8, self.contents[0..end], "startxref")) |start| {
            end = start;

            const startxref = try self.parseXrefOffset(start);
            const offset = startxref.location;
            if (offset >= self.contents.len) {
                logger.warn(
                    "startxref offset: {d} is bigger than size of file ({d})",
                    .{ offset, self.contents.len },
                );
                continue;
            }

            var itt = PDFTokenizer.init(self.contents[offset..]);

            if (!std.mem.eql(u8, "xref", itt.next().?)) {
                logger.err("xref: invalid format", .{});
                return PDFError.MissingXRef;
            }

            var table: XRefTable = undefined;
            table.start_offset = offset;

            var headers = std.AutoArrayHashMap(usize, usize).init(self.allocator);
            errdefer headers.deinit();

            var entries = std.AutoArrayHashMap(usize, XRefTable.XRef).init(self.allocator);
            errdefer entries.deinit();

            var header_start: usize = 0;
            var header_number_entries: usize = 0;

            var i: usize = 0;
            while (itt.next()) |token| {
                if (std.mem.eql(u8, token, "trailer")) break;
                const v1 = try std.fmt.parseInt(usize, token, 10);
                const v2 = try std.fmt.parseInt(usize, itt.next().?, 10);
                const v3 = itt.peek().?;

                if (v3[0] == 'n' or v3[0] == 'f') {
                    const xref: XRefTable.XRef = .{
                        .offset = v1,
                        .generation = v2,
                        .in_use = itt.next().?[0] == 'n',
                    };
                    entries.putAssumeCapacityNoClobber(header_start + i, xref);

                    i += 1;
                } else {
                    if (i != header_number_entries) {
                        logger.warn(
                            "xref: expected {d} entries, only found {d}\n",
                            .{ header_number_entries, i },
                        );
                    }

                    i = 0;
                    header_start = v1;
                    header_number_entries = v2;

                    try headers.put(header_start, header_number_entries);
                    try entries.ensureUnusedCapacity(header_number_entries);
                }
            }

            table.end_offset = table.start_offset + itt.index;

            table.headers = headers;
            table.entries = entries;
            try self.xrefs.append(table);
            try self.starts.append(startxref);
        }
    }

    pub const PDFWriteOptions = struct {
        start_index: usize = 0,
        metadata: ?MetadataMap = null,
    };

    /// Write the remaining parts of a PDF file, optionally with new metadata.
    /// The first parts of the PDF should ideally be copied by the filesystem
    /// or be from a truncated file.
    pub fn writeRestFile(self: *const PDFFile, writer: anytype, opts: PDFWriteOptions) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        // text buffer for writing temporary strings
        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();

        var chunks = std.ArrayList(ChunkOrXref).init(alloc);
        defer chunks.deinit();

        if (opts.metadata) |meta| {
            try meta.write(buf.writer());
            // append the metadata chunk
            try chunks.append(
                .{ .chunk = .{
                    .offset = meta.start_offset,
                    .new = try buf.toOwnedSlice(),
                    .old = self.contents[meta.start_offset..meta.end_offset],
                } },
            );
        }

        for (self.xrefs.items) |xref| {
            try chunks.append(.{ .xref = xref });
        }

        for (self.starts.items) |s| {
            try chunks.append(.{ .startxref = s });
        }

        std.sort.heap(ChunkOrXref, chunks.items, {}, ChunkOrXref.sort_offset);

        // then add the PDF text chunks inbetween
        const last = chunks.items.len;
        for (1..last) |i| {
            const c1 = chunks.items[i - 1];
            const c2 = chunks.items[i];

            const start = c1.getEndOffset();
            const end = c2.getOffset();

            const slice = self.contents[start..end];
            try chunks.append(
                .{ .chunk = .{ .offset = start, .new = slice, .old = slice } },
            );
        }

        // TODO: remove this sort and just insert the chunks in the right place
        std.sort.heap(ChunkOrXref, chunks.items, {}, ChunkOrXref.sort_offset);

        var deltas = std.AutoArrayHashMap(usize, i64).init(alloc);
        defer deltas.deinit();
        try deltas.ensureUnusedCapacity(chunks.items.len);

        const start = if (opts.metadata) |meta|
            meta.start_offset
        else
            opts.start_index;

        for (chunks.items) |chunk| {
            if (chunk.getEndOffset() <= start) continue;
            switch (chunk) {
                .chunk => |c| {
                    try writer.writeAll(c.new);
                    const delta = @as(i64, @intCast(c.new.len)) - @as(i64, @intCast(c.old.len));
                    deltas.putAssumeCapacityNoClobber(chunk.getEndOffset(), delta);
                },
                .startxref => |c| {
                    var ref_buf = std.ArrayList(u8).init(alloc);
                    defer ref_buf.deinit();

                    var byte_delta: i64 = 0;

                    var itt = deltas.iterator();
                    while (itt.next()) |kv| {
                        const offset = kv.key_ptr.*;
                        const delta = kv.value_ptr.*;
                        if (offset <= c.location) byte_delta += delta;
                    }

                    try ref_buf.writer().print(
                        "startxref\n{d}\n%%EOF",
                        .{@as(i64, @intCast(c.location)) + byte_delta},
                    );

                    try writer.writeAll(ref_buf.items);

                    const old_len = c.end_offset - c.start_offset;
                    const delta = @as(i64, @intCast(ref_buf.items.len)) - @as(i64, @intCast(old_len));

                    if (delta != 0) {
                        deltas.putAssumeCapacityNoClobber(chunk.getEndOffset(), delta);
                    }
                },
                .xref => |xr| {
                    var ref_buf = std.ArrayList(u8).init(alloc);
                    defer ref_buf.deinit();

                    try xr.write(ref_buf.writer(), deltas);

                    const xr_slice = ref_buf.items;

                    try writer.writeAll(xr_slice);

                    const old_len = xr.end_offset - xr.start_offset;
                    const delta = @as(i64, @intCast(xr_slice.len)) - @as(i64, @intCast(old_len));

                    if (delta != 0) {
                        deltas.putAssumeCapacityNoClobber(chunk.getEndOffset(), delta);
                    }
                },
            }
        }
    }

    pub fn deinit(self: *PDFFile) void {
        for (self.xrefs.items) |*xref_table| {
            xref_table.entries.deinit();
            xref_table.headers.deinit();
        }
        self.xrefs.deinit();
        self.starts.deinit();
    }
};
