const std = @import("std");
const fuzzig = @import("fuzzig");
const termui = @import("termui");

const AUTHOR_PAD = 45;
const TITLE_SIZE = 85;

const Paper = @import("main.zig").Paper;

pub const Action = enum {
    select,
};

fn writeAuthor(
    writer: anytype,
    authors: []const []const u8,
) !usize {
    var len: usize = 0;

    var indicator: bool = true;

    for (0..@min(3, authors.len)) |index| {
        const a = authors[index];

        try writer.writeAll(a);

        len += try std.unicode.calcUtf16LeLen(a);

        // dont write a comma for the last author
        if (index != 2 and index != authors.len - 1) {
            try writer.writeAll(", ");
            len += 2;
        }

        if (indicator and std.mem.eql(u8, a, "et al.")) {
            indicator = false;
        }
    }

    if (indicator and authors.len > 2) {
        try writer.writeAll(", et al.");
        len += 8;
    }

    return len;
}

const Wrapper = struct {
    allocator: std.mem.Allocator,

    input_buffer: [256]u8 = undefined,
    input_index: usize = 0,

    finder: *fuzzig.Ascii,

    action: ?Action = null,
    papers: []const Paper,
    scores: []?i32,
    ordering: []usize,

    // match_indices: [][]usize,

    time: u64 = 0,
    matched: usize = 0,
    update_search: bool = false,

    pub fn deinit(self: *Wrapper) void {
        self.allocator.free(self.scores);
        self.allocator.free(self.ordering);
        self.finder.deinit();
        self.allocator.destroy(self.finder);
        self.* = undefined;
    }

    pub fn init(allocator: std.mem.Allocator, papers: []const Paper) !Wrapper {
        const scores = try allocator.alloc(?i32, papers.len);
        errdefer allocator.free(scores);
        @memset(scores, 0);

        const ordering = try allocator.alloc(usize, papers.len);
        errdefer allocator.free(ordering);
        for (ordering, 0..) |*o, i| o.* = i;

        var finder = try allocator.create(fuzzig.Ascii);
        errdefer allocator.destroy(finder);

        finder.* = try fuzzig.Ascii.init(
            allocator,
            1024,
            256,
            .{ .case_sensitive = false, .wildcard_spaces = true },
        );
        errdefer finder.deinit();

        return .{
            .allocator = allocator,
            .finder = finder,
            .papers = papers,
            .scores = scores,
            .ordering = ordering,
        };
    }

    fn sortOrdering(self: *Wrapper, lhs: usize, rhs: usize) bool {
        const l = self.scores[lhs];
        const r = self.scores[rhs];
        if (l != null and r != null) {
            if (l.? == r.?) {
                switch (std.ascii.orderIgnoreCase(
                    self.papers[lhs].title,
                    self.papers[rhs].title,
                )) {
                    .gt, .eq => return true,
                    .lt => return false,
                }
            }
            return l.? > r.?;
        }
        if (l != null) return true;
        return false;
    }

    pub fn predraw(self: *Wrapper, s: *termui.Selector) anyerror!void {
        const search_string = self.input_buffer[0..self.input_index];

        self.matched = 0;
        if (search_string.len != 0 and self.update_search) {
            for (self.scores, 0..) |*score, i| {
                const sm = self.finder.scoreMatches(
                    self.papers[i].title,
                    search_string,
                );
                if (sm.score) |_| {
                    self.matched += 1;
                }
                score.* = sm.score;
            }
            std.sort.heap(usize, self.ordering, self, Wrapper.sortOrdering);
            s.capSelection(self.matched);
        } else {
            @memset(self.scores, 0);
            self.matched = self.scores.len;
        }

        const duration_formatter = std.fmt.fmtDuration(@abs(self.time * 1000));
        _ = duration_formatter;
        try s.display.printToRowC(0, "Found {d} matches", .{self.matched});

        const status_row = s.display.max_rows - 1;
        try s.display.printToRowC(
            status_row,
            "Find: {s}",
            .{search_string},
        );

        s.cursor_column = 7 + self.input_index;
    }

    pub fn write(
        self: *@This(),
        _: *termui.Selector,
        out: anytype,
        index: usize,
    ) anyerror!void {
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        const writer = buf.writer();

        const paper = self.papers[self.ordering[index]];
        const score = self.scores[self.ordering[index]] orelse return;

        try writer.print("{d: >4} ", .{@abs(score)});
        const author_len = try writeAuthor(writer, paper.authors);
        try writer.writeByteNTimes(' ', AUTHOR_PAD -| author_len);

        try writer.writeAll(paper.title[0..@min(TITLE_SIZE, paper.title.len)]);

        try out.writeAll(buf.items);
    }

    pub fn input(
        self: *@This(),
        s: *termui.Selector,
        key: termui.TermUI.Input,
    ) anyerror!termui.InputHandleOutcome {
        // const index = s.getSelected();
        switch (key) {
            .char => |c| switch (c) {
                termui.ctrl('k'),
                termui.ctrl('u'),
                => {
                    if (self.scores.len - s.selection >= self.matched) return .skip;
                },
                termui.ctrl('j'),
                termui.ctrl('d'),
                termui.ctrl('c'),
                => {},
                termui.Key.Backspace => {
                    self.input_index -|= 1;
                    self.update_search = true;
                },
                else => {
                    if (std.ascii.isPrint(c) and self.input_index <= 255) {
                        self.input_buffer[self.input_index] = c;
                        self.input_index += 1;
                        self.update_search = true;
                    }
                    return .skip;
                },
            },
            else => {},
        }
        return .handle;
    }
};

pub const Outcome = struct {
    index: usize,
    action: Action,
};

pub fn searchPrompt(allocator: std.mem.Allocator, papers: []const Paper) !?Outcome {
    var tui = try termui.TermUI.init(
        std.io.getStdIn(),
        std.io.getStdOut(),
    );
    defer tui.deinit();
    // some sanity things
    tui.out.original.lflag.ISIG = true;
    tui.in.original.lflag.ISIG = true;
    tui.in.original.iflag.ICRNL = true;

    var wrapper = try Wrapper.init(allocator, papers);
    defer wrapper.deinit();

    const choice_index = try termui.Selector.interactAlt(
        &tui,
        &wrapper,
        Wrapper.predraw,
        Wrapper.write,
        Wrapper.input,
        papers.len,
        .{
            .clear = true,
            .max_rows = @max(2, @min(18, papers.len)),
            .pad_below = 2,
            .pad_above = 1,
            .show_cursor = true,
        },
    );

    if (choice_index) |index| {
        return .{
            .index = wrapper.ordering[index],
            .action = wrapper.action orelse .select,
        };
    }
    return null;
}
