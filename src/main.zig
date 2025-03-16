const std = @import("std");
const farbe = @import("farbe");
const clippy = @import("clippy");
const datetime = @import("datetime");

const find = @import("find.zig");

test "main" {
    _ = find;
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
        .arg = "-r/--reverse",
        .help = "Reverse the order.",
    },
});

const HelpArguments = clippy.Arguments(&.{
    .{ .arg = "--help", .help = "Print help message" },
});

const FindArguments = clippy.Arguments(&.{});

const Commands = clippy.Commands(union(enum) {
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

const StringMap = std.StringHashMap([]const u8);
fn parseMetadataMap(allocator: std.mem.Allocator, contents: []const u8) !StringMap {
    var map = StringMap.init(allocator);
    errdefer map.deinit();

    var itt = std.mem.tokenizeAny(u8, contents, "\n\r");
    // skip ahead to the start of the map
    while (itt.peek()) |peeked| {
        const token = std.mem.trim(u8, peeked, " \n\r");
        if (token.len > 1 and std.mem.eql(u8, token, "<<")) {
            break;
        }
        _ = itt.next();
    }

    while (itt.next()) |next_token| {
        const token = std.mem.trim(u8, next_token, " \n\r");
        if (token.len > 1 and std.mem.eql(u8, token, ">>")) {
            // map end
            break;
        }

        if (token[0] == '/') {
            if (std.mem.indexOfScalar(u8, token, ' ')) |index| {
                const value = switch (token[index + 1]) {
                    '/' => token[index + 2 ..],
                    '(' => token[index + 2 .. token.len - 1],
                    else => token,
                };
                try map.put(token[1..index], value);
            }
        }
    }
    return map;
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

        var map = try parseMetadataMap(allocator, contents[index..]);
        defer map.deinit();

        var paper: Paper = .{
            .allocator = allocator,
            .abspath = abspath,
            .modified = @intCast(@divFloor(@abs(stat.atime), std.time.ns_per_ms)),
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
                const sort = std.meta.stringToEnum(
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
