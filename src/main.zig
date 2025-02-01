const std = @import("std");
const clippy = @import("clippy").ClippyInterface(.{});

const Arguments = clippy.Arguments(&.{.{
    .arg = "path",
    .help = "Path to the PDF file to read the metadata from",
    .required = true,
}});

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    var itt = clippy.ArgIterator.init(raw_args);
    // eat the name
    _ = try itt.next();
    const args = try Arguments.parseAll(&itt);

    const file = try mmap(args.path);
    defer file.deinit();

    const index = try findMetadataIndex(allocator, file.ptr);

    var map = try parseMetadataMap(allocator, file.ptr[index..]);
    defer map.deinit();

    var buffered = std.io.bufferedWriter(std.io.getStdOut().writer());
    var writer = buffered.writer();

    try writer.writeAll(map.get("Title") orelse "");
    try writer.writeAll("\n");
    try writer.writeAll(map.get("Author") orelse "");
    try writer.writeAll("\n");
    try writer.writeAll(map.get("Keywords") orelse "");
    try writer.writeAll("\n");

    try buffered.flush();

    // let the OS cleanup for us
    std.process.cleanExit();
}
