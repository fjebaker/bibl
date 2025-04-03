const std = @import("std");
const farbe = @import("farbe");
const clippy = @import("clippy");
const datetime = @import("datetime");

const find = @import("find.zig");

const logger = std.log.scoped(.bibl);

test "main" {
    _ = find;
}

const AUTHOR_COLOR = farbe.Farbe.init().fgRgb(193, 156, 0);
const HIGHLIGHT_COLOR = farbe.Farbe.init().fgRgb(58, 150, 221);
const ERROR_COLOR = farbe.Farbe.init().fgRgb(255, 0, 0);

const USAGE =
    \\bibl: a command line bibliography and library manager
;

const PDFError = error{ OffsetTooBig, MissingXRef };
const BiblError = error{ NoTrailer, NoMetadataFound, NoAuthors };

pub const clippy_options: clippy.Options = .{
    .errorFn = writeError,
};

const AddArguments = clippy.Arguments(
    &.{
        .{
            .arg = "path",
            .help = "Path to the PDF file to add to the library.",
            .required = true,
        },
        .{
            .arg = "author",
            .help = "Authors seperated by `+`, e.g. `Author1+Author2`",
        },
        .{
            .arg = "year",
            .argtype = i32,
            .help = "Publication year",
        },
        .{
            .arg = "title",
            .help = "Title of the paper",
        },
    },
);

const InfoArguments = clippy.Arguments(
    &.{
        .{
            .arg = "path",
            .display_name = "path [path ...]",
            .help = "Path(s) to the PDF file(s) to read the metadata from.",
            .required = true,
        },
        .{
            .arg = "--raw",
            .help =
            \\Do not do any string manipulation, print extracted
            \\information in standard plaintext.
            ,
        },
    },
);

const ListArguments = clippy.Arguments(&.{
    .{
        .arg = "--sort how",
        .help = "How to sort the listed items.",
    },
    .{
        .arg = "--last",
        .help = "Sort by last modified (alias for `--sort=modified`)",
    },
    .{
        .arg = "-r/--reverse",
        .help = "Reverse the order.",
    },
});

const HelpArguments = clippy.Arguments(&.{
    .{ .arg = "--help", .help = "Print help message" },
});

const FindArguments = clippy.Arguments(&.{});

const Commands = clippy.Commands(union(enum) {
    add: AddArguments,
    info: InfoArguments,
    list: ListArguments,
    find: FindArguments,
});

const SortStrategy = enum {
    author,
    title,
    created,
    modified,
};

/// Caller owns the memory
fn getRootDir(allocator: std.mem.Allocator) ![]const u8 {
    return try std.process.getEnvVarOwned(allocator, "BIBL_LIBRARY");
}

pub const State = struct {
    allocator: std.mem.Allocator,
    root_path: []const u8,
    dir: std.fs.Dir,
    overflow_args: []const []const u8,
    library: Library,

    pub fn init(allocator: std.mem.Allocator, overflow_args: []const []const u8) !*State {
        const root_path = try getRootDir(allocator);
        errdefer allocator.free(root_path);

        const ptr = try allocator.create(State);
        errdefer allocator.destroy(ptr);

        ptr.* = .{
            .allocator = allocator,
            .root_path = root_path,
            .dir = try std.fs.cwd().openDir(root_path, .{ .iterate = true }),
            .overflow_args = overflow_args,
            .library = Library.init(allocator),
        };
        return ptr;
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.root_path);
        self.dir.close();
        self.library.deinit();
        self.allocator.destroy(self);
    }

    pub fn loadLibrary(self: *State) !void {
        var walker = try self.dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |item| {
            switch (item.kind) {
                .file => {
                    _ = self.library.loadParsePaper(self.dir, item.path) catch |err| {
                        switch (err) {
                            BiblError.NoAuthors,
                            BiblError.NoMetadataFound,
                            BiblError.NoTrailer,
                            => continue,
                            else => return err,
                        }
                    };
                },
                else => {},
            }
        }
    }
};

fn writeError(err: anyerror, comptime fmt: []const u8, args: anytype) !void {
    const stderr = std.io.getStdErr();
    const color = stderr.isTty();

    const writer = stderr.writer();

    if (color) try ERROR_COLOR.writeOpen(writer);
    try writer.print("BiblError {any}", .{err});
    if (color) try ERROR_COLOR.writeClose(writer);

    try writer.writeAll(": ");
    try writer.print(fmt, args);
    try writer.writeAll("\n");

    std.process.cleanExit();
    return err;
}

const MemoryMappedFile = struct {
    file: std.fs.File,
    ptr: []align(std.heap.pageSize()) const u8,

    pub fn deinit(self: MemoryMappedFile) void {
        std.posix.munmap(self.ptr);
        self.file.close();
    }
};

fn findMetadataIndex(allocator: std.mem.Allocator, file: []const u8) !usize {
    // now we want to read the Info section
    if (std.mem.lastIndexOf(u8, file, "/Info")) |info_offset| {
        const info_index = info_offset + 5;

        var token_itt = std.mem.tokenizeScalar(u8, file[info_index..], ' ');
        const indicator = token_itt.next().?;

        if (indicator.len > 1 and std.mem.eql(u8, indicator[0..2], "<<")) {
            return info_index;
        } else {
            // find the index of the object
            const value = token_itt.next().?;

            const target_obj = try std.fmt.allocPrint(
                allocator,
                "{s} {s} obj",
                .{ indicator, value },
            );
            defer allocator.free(target_obj);

            if (std.mem.lastIndexOf(
                u8,
                file[0..info_index],
                target_obj,
            )) |index| return index;
        }
    }

    return BiblError.NoMetadataFound;
}

const StringMap = std.StringArrayHashMap([]const u8);

pub const MetadataMap = struct {
    start_offset: usize,
    end_offset: usize,
    map: StringMap,

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

    pub fn deinit(self: *MetadataMap) void {
        self.map.deinit();
        self.* = undefined;
    }
};

pub const PDFTokenizer = struct {
    content: []const u8,
    index: usize = 0,

    pub fn init(content: []const u8) PDFTokenizer {
        return .{ .content = content };
    }

    pub fn peek(self: *PDFTokenizer) ?[]const u8 {
        const index = self.index;
        const n = self.next();
        self.index = index;
        return n;
    }

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
                '(', ')' => {
                    if (self.index - start == 0) {
                        self.index += 1;
                    }
                    return self.content[start..self.index];
                },
                '<', '>' => {
                    const n = self.content[self.index + 1];
                    if (n == '>' or n == '<') {
                        self.index += 2;
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

fn parseMetadataMap(
    allocator: std.mem.Allocator,
    all_contents: []const u8,
    index: usize,
) !MetadataMap {
    const contents = all_contents[index..];
    var map = StringMap.init(allocator);
    errdefer map.deinit();

    var itt = PDFTokenizer.init(contents);
    // skip ahead to the start of the map
    while (itt.peek()) |token| {
        if (token.len > 1 and std.mem.eql(u8, token, "<<")) {
            break;
        }
        _ = itt.next();
    }

    const start_offset = itt.index;

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

            try map.put(token[1..], value);
        }
    }
    return .{
        .start_offset = start_offset + index,
        .end_offset = itt.index + index,
        .map = map,
    };
}

pub fn mmap(dir: std.fs.Dir, filename: []const u8) !MemoryMappedFile {
    const file = try dir.openFile(filename, .{});
    errdefer file.close();
    const stat = try file.stat();

    const ptr = try std.posix.mmap(
        null,
        stat.size,
        std.posix.PROT.READ,
        .{ .TYPE = .SHARED },
        file.handle,
        0,
    );

    return .{ .file = file, .ptr = ptr };
}

pub const Paper = struct {
    authors: []const []const u8 = &.{},
    year: u32 = 0,
    title: []const u8 = "",
    tags: []const []const u8 = &.{},
    abspath: []const u8 = "",

    created: u64,
    modified: u64,

    allocator: std.mem.Allocator,

    fn parseInfo(self: *Paper, info_map: StringMap) !void {
        if (info_map.get("Author")) |f| {
            const author_field = try self.allocator.dupe(u8, f);
            const split = std.mem.indexOfScalar(u8, author_field, ' ') orelse author_field.len;

            const author_string = author_field[0..split];
            var authors = try self.allocator.alloc(
                []const u8,
                std.mem.count(u8, author_string, "+") + 1,
            );

            var itt = std.mem.tokenizeScalar(u8, author_string, '+');
            var i: usize = 0;
            while (itt.next()) |a| : (i += 1) {
                authors[i] = a;
            }

            for (authors[i..]) |*a| a.* = "et al.";

            self.authors = authors;

            const year_string = author_field[split + 1 ..];
            if (year_string.len > 0) {
                self.year = try std.fmt.parseInt(u32, year_string, 10);
            }
        }

        if (info_map.get("Title")) |f| {
            const title = try self.allocator.dupe(u8, f);
            self.title = title;
        }
        if (info_map.get("Keywords")) |f| {
            const keywords = try self.allocator.dupe(u8, f);
            var tags = try self.allocator.alloc(
                []const u8,
                std.mem.count(u8, keywords, " ") + 1,
            );

            var itt = std.mem.tokenizeScalar(u8, keywords, ' ');
            var i: usize = 0;
            while (itt.next()) |t| : (i += 1) {
                tags[i] = t;
            }

            self.tags = tags;
        }
    }
};

/// Represents library that has been parsed into memory
pub const Library = struct {
    arena: std.heap.ArenaAllocator,
    papers: std.ArrayList(Paper),

    pub fn init(allocator: std.mem.Allocator) Library {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .papers = std.ArrayList(Paper).init(allocator),
        };
    }

    pub fn deinit(self: *Library) void {
        self.arena.deinit();
        self.papers.deinit();
        self.* = undefined;
    }

    /// Loads, parsers, copies relevant information, and closes the file again
    /// so that no dangling fd is open.
    pub fn loadParsePaper(self: *Library, dir: std.fs.Dir, path: []const u8) !Paper {
        const file = try mmap(dir, path);
        defer file.deinit();

        const abspath = try dir.realpathAlloc(self.arena.allocator(), path);
        const stat = try file.file.stat();
        return try self.parsePaper(abspath, file.ptr, stat);
    }

    fn parsePaper(self: *Library, abspath: []const u8, contents: []const u8, stat: std.fs.File.Stat) !Paper {
        const allocator = self.arena.allocator();
        const index = try findMetadataIndex(allocator, contents);

        var map = (try parseMetadataMap(allocator, contents, index)).map;
        defer map.deinit();

        var paper: Paper = .{
            .allocator = allocator,
            .abspath = abspath,
            .modified = @intCast(@divFloor(@abs(stat.mtime), std.time.ns_per_ms)),
            .created = @intCast(@divFloor(@abs(stat.ctime), std.time.ns_per_ms)),
        };

        try paper.parseInfo(map);
        if (paper.authors.len == 0) return BiblError.NoAuthors;

        try self.papers.append(paper);
        return paper;
    }
};

fn tagColour(tag: []const u8) farbe.Farbe {
    const hash: u24 = @truncate(std.hash.Wyhash.hash(0, tag));
    return farbe.Farbe.init().fgRgb(
        @intCast((hash >> 16) & 0b11111111),
        @intCast((hash >> 8) & 0b11111111),
        @intCast(hash & 0b11111111),
    );
}

fn printPaperInfo(writer: anytype, paper: Paper, raw: bool) !void {
    if (raw) {
        try writer.writeAll(paper.title);
        try writer.writeAll("\n");

        for (0.., paper.authors) |i, auth| {
            try writer.writeAll(auth);
            if (i != paper.authors.len - 1) {
                try writer.writeAll("+");
            }
        }
        try writer.print(" {d}", .{paper.year});
        try writer.writeAll("\n");

        for (0.., paper.tags) |i, tag| {
            try writer.writeAll(tag);
            if (i != paper.authors.len - 1) {
                try writer.writeAll(" ");
            }
        }
    } else {
        for (0.., paper.authors) |i, auth| {
            try AUTHOR_COLOR.write(writer, "{s}", .{auth});
            if (i != paper.authors.len - 1) {
                try writer.writeAll(", ");
            }
        }
        try writer.print(" {d}", .{paper.year});
        try writer.writeAll("\n");

        try writer.writeAll("Title   : ");
        try writer.writeAll(paper.title);
        try writer.writeAll("\n");

        try writer.writeAll("Tags    : ");
        for (0.., paper.tags) |i, tag| {
            const tag_color = tagColour(tag);
            try tag_color.write(writer, "@{s}", .{tag});
            if (i != paper.tags.len - 1) {
                try writer.writeAll(" ");
            }
        }
        try writer.writeAll("\n");

        const created = datetime.datetime.Datetime.fromTimestamp(@intCast(paper.created));
        const modified = datetime.datetime.Datetime.fromTimestamp(@intCast(paper.modified));
        try writer.print("Created : {d: >4}-{d:0>2}-{d:0>2} (Modified: {d: >4}-{d:0>2}-{d:0>2})", .{
            created.date.year,
            created.date.month,
            created.date.day,

            modified.date.year,
            modified.date.month,
            modified.date.day,
        });
        try writer.writeAll("\n");
    }
}

fn findInFiles(
    state: *State,
    writer: anytype,
    args: FindArguments.Parsed,
) !void {
    _ = args;
    try state.loadLibrary();
    const outcome = try find.searchPrompt(
        state.allocator,
        state.library.papers.items,
    );

    if (outcome) |oc| {
        const paper = state.library.papers.items[oc.index];
        try openInReader(state.allocator, paper.abspath);
        try writer.print("Opening: '{s}'\n", .{paper.abspath});
    } else {
        try writer.writeAll("Nothing selected.\n");
    }
}

fn openInReader(allocator: std.mem.Allocator, abspath: []const u8) !void {
    var child = std.process.Child.init(&.{ "okular", abspath }, allocator);
    child.stderr_behavior = std.process.Child.StdIo.Ignore;
    child.stdin_behavior = std.process.Child.StdIo.Ignore;
    child.stdout_behavior = std.process.Child.StdIo.Ignore;
    try child.spawn();
}

fn listFiles(
    state: *State,
    writer: anytype,
    args: ListArguments.Parsed,
    sort: SortStrategy,
) !void {
    try state.loadLibrary();

    const Ctx = struct {
        how: SortStrategy,
        reverse: bool,
        fn lessThan(self: *@This(), lhs: Paper, rhs: Paper) bool {
            const b = switch (self.how) {
                .author => std.ascii.lessThanIgnoreCase(lhs.authors[0], rhs.authors[0]),
                .title => std.ascii.lessThanIgnoreCase(lhs.title, rhs.title),
                .created => lhs.created < rhs.created,
                .modified => lhs.modified < rhs.modified,
            };
            return if (self.reverse) !b else b;
        }
    };

    var ctx: Ctx = .{ .how = sort, .reverse = args.reverse };
    std.sort.heap(Paper, state.library.papers.items, &ctx, Ctx.lessThan);

    for (state.library.papers.items) |paper| {
        try printPaperInfo(writer, paper, false);
        try writer.writeAll("\n");
    }
}

const PDFFile = struct {
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

        /// Write the cross-refernece table to the writer, given a map of byte
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
                    var byte_delta: i64 = 0;
                    for (deltas.values()) |v| byte_delta += v;
                    try writer.print(
                        "startxref\n{d}\n%%EOF",
                        .{@as(i64, @intCast(c.location)) + byte_delta},
                    );
                },
                .xref => |xr| {
                    var ref_buf = std.ArrayList(u8).init(alloc);
                    defer ref_buf.deinit();

                    try xr.write(ref_buf.writer(), deltas);

                    const xr_slice = ref_buf.items;

                    try writer.writeAll(xr_slice);

                    const old_len = xr.end_offset - xr.start_offset;
                    const delta = @as(i64, @intCast(xr_slice.len)) - @as(i64, @intCast(old_len));

                    std.debug.assert(delta == 0);
                    if (delta > 0) {
                        deltas.putAssumeCapacityNoClobber(chunk.getEndOffset(), delta);
                    }
                },
            }
        }
    }

    pub fn deinit(self: *PDFFile) void {
        for (self.xrefs.items) |*xref_table| {
            xref_table.entries.deinit();
        }
        self.xrefs.deinit();
        self.starts.deinit();
    }
};

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

fn addPaper(state: *State, args: AddArguments.Parsed) !void {
    var arena = std.heap.ArenaAllocator.init(state.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try state.loadLibrary();

    const dir = std.fs.cwd();
    const file = try mmap(dir, args.path);
    defer file.deinit();

    var pdf = PDFFile.init(alloc, file.ptr);
    defer pdf.deinit();

    try pdf.parseXrefTables();

    const index = try findMetadataIndex(alloc, file.ptr);
    var meta = try parseMetadataMap(alloc, file.ptr, index);
    defer meta.deinit();

    try meta.map.put("Author", "Someone+Else 2021");
    try meta.map.put("Title", "This is a new title");

    const stat = try file.file.stat();
    _ = stat;

    const out_file = try std.fs.cwd().createFile("new.pdf", .{});

    // copy everything before the first item
    _ = try file.file.copyRangeAll(0, out_file, 0, meta.start_offset);
    try out_file.seekTo(meta.start_offset);

    try pdf.writeRestFile(out_file.writer(), .{ .metadata = meta });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    var overflow = std.ArrayList([]const u8).init(allocator);
    defer overflow.deinit();

    const Ctx = struct {
        fn handleArg(l: *std.ArrayList([]const u8), p: *const Commands, arg: clippy.Arg) anyerror!void {
            if (arg.flag) try p.throwError(clippy.ParseError.InvalidFlag, "{s}", .{arg.string});
            try l.append(arg.string);
        }
    };

    var itt = clippy.ArgumentIterator.init(raw_args[1..]);
    var help_itt = itt;

    // first we parse to see if help was given
    const help_parsed = try HelpArguments.initParseAll(&help_itt, .{ .forgiving = true });

    var buffered = std.io.bufferedWriter(std.io.getStdOut().writer());
    const writer = buffered.writer();

    if (help_parsed.help) {
        try writer.writeAll(USAGE);
        try writer.writeAll("\n\n");
        try Commands.writeHelp(writer, .{});
    } else {
        var parser = Commands.init(&itt, .{});
        const command = try parser.parseAllCtx(&overflow, .{ .unhandled_arg = Ctx.handleArg });

        var state = try State.init(allocator, overflow.items);
        defer state.deinit();

        switch (command) {
            .add => |args| {
                try addPaper(state, args);
            },
            .info => |args| {
                const dir = std.fs.cwd();
                const p1 = try state.library.loadParsePaper(dir, args.path);

                try printPaperInfo(writer, p1, args.raw);
                try writer.writeAll("\n");
                for (overflow.items) |path| {
                    const paper = try state.library.loadParsePaper(dir, path);
                    try printPaperInfo(writer, paper, args.raw);
                    try writer.writeAll("\n");
                }
            },
            .list => |args| {
                const sort: SortStrategy = b: {
                    if (args.last) {
                        if (args.sort) |srt| {
                            if (!std.mem.eql(u8, "modified", srt)) {
                                try parser.throwError(
                                    clippy.ParseError.DuplicateFlag,
                                    "Cannot specify both --last and --sort={s}",
                                    .{srt},
                                );
                            }
                        }
                        break :b .modified;
                    } else {
                        break :b std.meta.stringToEnum(
                            SortStrategy,
                            args.sort orelse "author",
                        ) orelse {
                            try parser.throwError(
                                clippy.ParseError.InvalidFlag,
                                "Failed to parse sort strategy: '{s}'",
                                .{args.sort.?},
                            );
                            unreachable;
                        };
                    }
                };
                try listFiles(state, writer, args, sort);
            },
            .find => |args| {
                try findInFiles(state, writer, args);
            },
        }
    }
    try buffered.flush();

    // let the OS cleanup for us
    std.process.cleanExit();
}
