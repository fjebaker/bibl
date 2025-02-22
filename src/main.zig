const std = @import("std");
const farbe = @import("farbe");
const clippy = @import("clippy").ClippyInterface(.{});

const AUTHOR_COLOR = farbe.Farbe.init().fgRgb(193, 156, 0);
const HIGHLIGHT_COLOR = farbe.Farbe.init().fgRgb(58, 150, 221);

const Commands = clippy.Commands(.{
    .commands = &.{
        .{
            .name = "info",
            .help = "Print information about a file.",
            .args = &.{
                .{
                    .arg = "path",
                    .help = "Path to the PDF file to read the metadata from",
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
        },
    },
});

const MemoryMappedFile = struct {
    file: std.fs.File,
    ptr: []align(std.mem.page_size) const u8,

    pub fn deinit(self: MemoryMappedFile) void {
        std.posix.munmap(self.ptr);
        self.file.close();
    }
};

const Error = error{ NoTrailer, NoMetadataFound };

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

    return Error.NoMetadataFound;
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

pub fn mmap(filename: []const u8) !MemoryMappedFile {
    const file = try std.fs.cwd().openFile(filename, .{});
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

    allocator: std.mem.Allocator,
    info_map: StringMap,

    fn parseInfo(self: *Paper) !void {
        if (self.info_map.get("Author")) |author_field| {
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

        if (self.info_map.get("Title")) |title| self.title = title;
        if (self.info_map.get("Keywords")) |keywords| {
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

    pub fn parsePaper(self: *Library, contents: []const u8) !Paper {
        const allocator = self.arena.allocator();
        const index = try findMetadataIndex(allocator, contents);

        var map = try parseMetadataMap(allocator, contents[index..]);
        errdefer map.deinit();

        var paper: Paper = .{ .allocator = allocator, .info_map = map };
        try paper.parseInfo();

        return paper;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    var itt = clippy.ArgIterator.init(raw_args);
    // eat the name
    _ = try itt.next();
    const command = try Commands.parseAll(&itt);

    var library = Library.init(allocator);
    defer library.deinit();

    switch (command.commands) {
        .info => |args| {
            const file = try mmap(args.path);
            defer file.deinit();

            const paper = try library.parsePaper(file.ptr);

            var buffered = std.io.bufferedWriter(std.io.getStdOut().writer());
            var writer = buffered.writer();

            if (args.raw) {
                try writer.writeAll(paper.info_map.get("Title") orelse "");
                try writer.writeAll("\n");
                try writer.writeAll(paper.info_map.get("Author") orelse "");
                try writer.writeAll("\n");
                try writer.writeAll(paper.info_map.get("Keywords") orelse "");
                try writer.writeAll("\n");
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
                    try AUTHOR_COLOR.write(writer, "{s}", .{tag});
                    if (i != paper.tags.len - 1) {
                        try writer.writeAll(" ");
                    }
                }
                try writer.writeAll("\n");
            }

            try buffered.flush();
        },
    }

    // let the OS cleanup for us
    std.process.cleanExit();
}
