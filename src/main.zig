const std = @import("std");
const farbe = @import("farbe");
const clippy = @import("clippy");
const datetime = @import("datetime");
const find = @import("find.zig");

const PDFTokenizer = @import("pdf.zig").PDFTokenizer;
const PDFFile = @import("pdf.zig").PDFFile;
const PDFError = @import("pdf.zig").PDFError;
const MetadataMap = @import("pdf.zig").MetadataMap;
const parseMetadataMap = @import("pdf.zig").parseMetadataMap;

const StringMap = std.StringArrayHashMap([]const u8);

test "main" {
    _ = find;
    _ = @import("pdf.zig");
}

const AUTHOR_COLOR = farbe.Farbe.init().fgRgb(193, 156, 0);
const HIGHLIGHT_COLOR = farbe.Farbe.init().fgRgb(58, 150, 221);
const ERROR_COLOR = farbe.Farbe.init().fgRgb(255, 0, 0);

const USAGE =
    \\bibl: a command line bibliography and library manager
;

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

const MigrateArguments = clippy.Arguments(&.{});

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
    migrate: MigrateArguments,
});

const SortStrategy = enum {
    author,
    title,
    created,
    modified,
};

pub const SplitOptions = struct {
    split_spaces: bool = false,
};

/// Split a list of authors either by spaces or by `+`. Caller owns the memory
pub fn splitAuthors(allocator: std.mem.Allocator, author_string: []const u8, opts: SplitOptions) ![][]const u8 {
    var authors = try allocator.alloc(
        []const u8,
        std.mem.count(u8, author_string, " ") + std.mem.count(u8, author_string, "+") + 1,
    );

    var itt = std.mem.tokenizeAny(u8, author_string, if (opts.split_spaces) "+ " else "+");
    var i: usize = 0;

    var has_et_al: bool = false;
    while (itt.next()) |a| : (i += 1) {
        if (std.mem.eql(u8, a, "et al.")) {
            has_et_al = true;
        }
        authors[i] = a;
    }

    if (i != authors.len) {
        if (!has_et_al) {
            authors[i] = "et al.";
            i += 1;
        }
        return authors[0..i];
    }

    return authors;
}
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

pub fn mmapWrite(dir: std.fs.Dir, filename: []const u8) !MemoryMappedFile {
    return _mmap(dir, filename, .read_write);
}

pub fn mmap(dir: std.fs.Dir, filename: []const u8) !MemoryMappedFile {
    return _mmap(dir, filename, .read_only);
}

fn _mmap(dir: std.fs.Dir, filename: []const u8, mode: std.fs.File.OpenMode) !MemoryMappedFile {
    const file = try dir.openFile(filename, .{ .mode = mode });
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

    /// Create a new paper entry, auto populating default fields
    pub fn new(authors: []const []const u8, year: u32, title: []const u8) Paper {
        const now = std.time.milliTimestamp();
        return .{
            .authors = authors,
            .year = year,
            .title = title,
            .abspath = "",
            .created = now,
            .modified = now,
        };
    }

    /// Create a canonical file name for this item. Caller owns memory
    pub fn canonicalise(self: *const Paper, allocator: std.mem.Allocator) ![]const u8 {
        var title_itt = std.mem.splitAny(u8, self.title, " ");
        const author_name = switch (self.authors.len) {
            0 => unreachable,
            1 => try allocator.dupe(u8, self.authors[0]),
            2 => try std.fmt.allocPrint(
                allocator,
                "{s}_and_{s}",
                .{ self.authors[0], self.authors[1] },
            ),
            else => try std.fmt.allocPrint(
                allocator,
                "{s}_{s}_et_al",
                .{ self.authors[0], self.authors[1] },
            ),
        };
        defer allocator.free(author_name);

        const t1 = title_itt.next().?;
        if (title_itt.next()) |t2| {
            return std.fmt.allocPrint(
                allocator,
                "{s}_{d}_{s}_{s}.pdf",
                .{ author_name, self.year, t1, t2 },
            );
        } else {
            return std.fmt.allocPrint(
                allocator,
                "{s}_{d}_{s}.pdf",
                .{ author_name, self.year, t1 },
            );
        }
    }

    /// Modify the metadata of a given metadata map to reflect this paper.
    pub fn insertInto(self: *const Paper, allocator: std.mem.Allocator, meta: *MetadataMap) !void {
        const year = try std.fmt.allocPrint(allocator, "{d}", .{self.year});
        defer allocator.free(year);

        const author_list = try std.mem.join(allocator, "+", self.authors);
        defer allocator.free(author_list);

        const tag_list = try std.mem.join(allocator, " ", self.tags);
        defer allocator.free(tag_list);

        try meta.put("Author", .{ .text = author_list, .kind = .string });
        try meta.put("PubDate", .{ .text = year, .kind = .string });
        try meta.put("Title", .{ .text = self.title, .kind = .string });
        try meta.put("Keywords", .{ .text = tag_list, .kind = .string });
    }

    fn parseInfo(self: *Paper, allocator: std.mem.Allocator, info_map: MetadataMap.MapInternal) !void {
        if (info_map.get("Author")) |author| {
            self.authors = try splitAuthors(allocator, author.text, .{});
        }

        if (info_map.get("PubDate")) |pubdate| {
            self.year = try std.fmt.parseInt(u32, pubdate.text, 10);
        }

        if (info_map.get("Title")) |title| {
            self.title = title.text;
        }

        if (info_map.get("Keywords")) |keywords| {
            const num_tags = if (keywords.text.len == 0) 0 else std.mem.count(u8, keywords.text, " ") + 1;
            var tags = try allocator.alloc(
                []const u8,
                num_tags,
            );

            var itt = std.mem.tokenizeScalar(u8, keywords.text, ' ');
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
            .abspath = abspath,
            .modified = @intCast(@divFloor(@abs(stat.mtime), std.time.ns_per_ms)),
            .created = @intCast(@divFloor(@abs(stat.ctime), std.time.ns_per_ms)),
        };

        try paper.parseInfo(allocator, map);
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

    try meta.map.put("Author", .{ .text = "Someone+Else 2021", .kind = .string });
    try meta.map.put("Title", .{ .text = "This is a new title", .kind = .string });

    const stat = try file.file.stat();
    _ = stat;

    const out_file = try std.fs.cwd().createFile("new.pdf", .{});

    // copy everything before the first item
    _ = try file.file.copyRangeAll(0, out_file, 0, meta.start_offset);
    try out_file.seekTo(meta.start_offset);

    try pdf.writeRestFile(out_file.writer(), .{ .metadata = meta });
}

fn writeUpdateMetadata(
    allocator: std.mem.Allocator,
    file: MemoryMappedFile,
    meta: MetadataMap,
) !void {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var pdf = PDFFile.init(allocator, file.ptr);
    defer pdf.deinit();

    pdf.parseXrefTables() catch |err| {
        switch (err) {
            PDFError.MissingXRef => {
                std.debug.print("MISSING OFFSET: assuming we can just continue...\n", .{});
                pdf.clearXrefs();
            },
            else => return err,
        }
    };

    // write new metadata into a buffer
    try pdf.writeRestFile(buffer.writer(), .{ .metadata = meta });

    try std.posix.ftruncate(file.file.handle, meta.start_offset);

    try file.file.seekTo(meta.start_offset);
    // std.debug.print("{s}\n", .{buffer.items});
    try file.file.writer().writeAll(buffer.items);
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
            .migrate => {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const alloc = arena.allocator();
                try state.loadLibrary();
                const papers = state.library.papers.items;
                for (papers) |paper| {
                    _ = paper;
                    _ = alloc;
                    // if (std.mem.containsAtLeast(u8, paper.abspath, 1, "Uttley_Malzac")) {
                    //     std.debug.print("   {s} ->", .{std.fs.path.basename(paper.abspath)});
                    //     const filename = std.fs.path.basename(paper.abspath);

                    //     const file = try mmapWrite(state.dir, filename);
                    //     defer file.deinit();

                    //     const index = try findMetadataIndex(allocator, file.ptr);
                    //     var meta = try parseMetadataMap(allocator, file.ptr, index);
                    //     defer meta.deinit();

                    //     paper.authors = &.{ "Uttley", "Malzac" };
                    //     paper.year = 2025;

                    //     try paper.insertInto(alloc, &meta);

                    //     try writeUpdateMetadata(allocator, file, meta);

                    //     const new_filename = try paper.canonicalise(alloc);
                    //     try state.dir.rename(std.fs.path.basename(paper.abspath), new_filename);
                    //     std.debug.print(" Done\n", .{});
                    // }
                }
            },
        }
    }
    try buffered.flush();

    // let the OS cleanup for us
    std.process.cleanExit();
}
