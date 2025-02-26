const std = @import("std");
const fuzzig = @import("fuzzig");
const termui = @import("termui");
const farbe = @import("farbe");

const AUTHOR_PAD = 45;
const TITLE_SIZE = 85;
const NEEDLE_MATCH = 256;

const MAX_AUTHORS = 8;

const HIGHLIGHT_COLOR = farbe.Farbe.init().fgRgb(255, 0, 0).bold();

const Paper = @import("main.zig").Paper;

pub const Action = enum {
    select,
};

const SearchTerms = struct {
    authors: [MAX_AUTHORS][]const u8 = undefined,
    title: [NEEDLE_MATCH]u8 = undefined,

    num_authors: usize = 0,
    title_len: usize = 0,

    fn getAuthors(s: *const SearchTerms) []const []const u8 {
        return s.authors[0..s.num_authors];
    }

    fn getTitle(s: *const SearchTerms) ?[]const u8 {
        const text = std.mem.trim(u8, s.title[0..s.title_len], " ");
        if (text.len == 0) return null;
        return text;
    }

    fn addTitle(s: *SearchTerms, t: []const u8) void {
        if (t.len == 0) return;
        if (s.title_len + t.len < NEEDLE_MATCH) {
            std.mem.copyBackwards(u8, s.title[s.title_len..], t);
            s.title_len += t.len;
        }
    }

    fn addAuthor(s: *SearchTerms, author: []const u8) void {
        if (author.len == 0 or s.num_authors >= MAX_AUTHORS) return;
        s.authors[s.num_authors] = author;
        s.num_authors += 1;
    }

    fn split(s: []const u8) SearchTerms {
        var st = SearchTerms{};

        var start: usize = 0;
        while (std.mem.indexOfAnyPos(u8, s, start, "\\")) |index| {
            st.addTitle(s[start..index]);

            if (s[index] == '\\' and s.len > index) {
                start = std.mem.indexOfScalarPos(u8, s, index, ' ') orelse s.len;
                st.addAuthor(s[index + 1 .. start]);
                // eat the space at the end of the word
                start += 1;
            }

            if (start >= s.len) break;
        }

        if (start < s.len) {
            st.addTitle(s[start..s.len]);
        }
        return st;
    }
};

test "search terms" {
    {
        const terms = SearchTerms.split("hello world");
        try std.testing.expectEqualStrings(
            "hello world",
            terms.getTitle().?,
        );
    }
    {
        const terms = SearchTerms.split("\\Name");
        try std.testing.expectEqualStrings(
            "Name",
            terms.getAuthors()[0],
        );
    }
    {
        const terms = SearchTerms.split("hello \\Name world");
        try std.testing.expectEqualStrings(
            "hello world",
            terms.getTitle().?,
        );
        try std.testing.expectEqualStrings(
            "Name",
            terms.getAuthors()[0],
        );
    }
}

fn writeHighlighted(
    writer: anytype,
    text: []const u8,
    highlight: []const usize,
) !void {
    var hi: usize = 0;
    for (text, 0..) |c, i| {
        if (hi < highlight.len and highlight[hi] == i) {
            try HIGHLIGHT_COLOR.write(writer, "{c}", .{c});
            hi += 1;
        } else {
            try writer.writeByte(c);
        }
    }
}

fn writeAuthor(
    writer: anytype,
    authors: []const []const u8,
    match: MatchInfo,
) !usize {
    const author_match_indices = match.getAuthorIndices();
    const author_highlight_length = match.getAuthorHighlightLength();

    var len: usize = 0;
    var indicator: bool = true;

    for (0..@min(3, authors.len)) |index| {
        const a = authors[index];

        // do we need to do highlighting
        if (std.mem.indexOfScalar(usize, author_match_indices, index)) |ind| {
            const highlight_len = author_highlight_length[ind];
            try HIGHLIGHT_COLOR.write(writer, "{s}", .{a[0..highlight_len]});
            try writer.writeAll(a[highlight_len..]);
        } else {
            try writer.writeAll(a);
        }

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

const MatchInfo = struct {
    num_matches: usize = 0,
    buf: []usize,

    num_author_match: usize = 0,
    author_indices: []usize,
    author_highlight_length: []usize,

    pub fn getAuthorIndices(m: *const MatchInfo) []const usize {
        return m.author_indices[0..m.num_author_match];
    }

    pub fn getAuthorHighlightLength(m: *const MatchInfo) []const usize {
        return m.author_highlight_length[0..m.num_author_match];
    }

    pub fn setNoMatches(m: *MatchInfo) void {
        m.num_matches = 0;
        m.num_author_match = 0;
    }

    pub fn setAuthorMatch(m: *MatchInfo, index: usize, hl_len: usize) void {
        if (m.num_author_match >= MAX_AUTHORS) return;
        m.author_indices[m.num_author_match] = index;
        m.author_highlight_length[m.num_author_match] = hl_len;
        m.num_author_match += 1;
    }

    pub fn get(m: *const MatchInfo) []const usize {
        return m.buf[0..m.num_matches];
    }
};

fn matchAuthors(authors: []const []const u8, searches: []const []const u8, mi: *MatchInfo) bool {
    mi.num_author_match = 0;

    for (searches) |searched_author| {
        if (searched_author.len == 0) continue;
        var matches: bool = false;
        for (0.., authors) |index, has_author| {
            // cannot match this author if the searched one is longer
            if (searched_author.len > has_author.len) continue;
            const len = @min(searched_author.len, has_author.len);

            if (std.ascii.eqlIgnoreCase(searched_author[0..len], has_author[0..len])) {
                matches = true;
                mi.setAuthorMatch(index, len);
                break;
            }
        }

        // must match all authors
        if (!matches) {
            mi.num_author_match = 0;
            return false;
        }
    }

    if (mi.num_author_match == 0) return false;
    return true;
}

const Wrapper = struct {
    allocator: std.mem.Allocator,

    input_buffer: [NEEDLE_MATCH]u8 = undefined,
    input_index: usize = 0,

    finder: *fuzzig.Ascii,

    action: ?Action = null,
    papers: []const Paper,
    scores: []?i32,
    ordering: []usize,

    match_buffer: []usize,
    match_indices: []MatchInfo,

    time: u64 = 0,
    matched: usize = 0,
    update_search: bool = false,

    line_buffer: [1024]u8 = undefined,

    pub fn deinit(self: *Wrapper) void {
        self.allocator.free(self.scores);
        self.allocator.free(self.ordering);
        self.allocator.free(self.match_buffer);
        self.allocator.free(self.match_indices);
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
            NEEDLE_MATCH,
            .{ .case_sensitive = false, .wildcard_spaces = true },
        );
        errdefer finder.deinit();

        const stride = 2 * MAX_AUTHORS + NEEDLE_MATCH;
        const match_buffer = try allocator.alloc(usize, stride * papers.len);
        errdefer allocator.free(match_buffer);

        const match_indices = try allocator.alloc(MatchInfo, papers.len);
        errdefer allocator.free(match_indices);

        for (match_indices, 0..) |*mi, i| {
            const buf = match_buffer[i * stride .. (i + 1) * stride];
            mi.* = .{
                .buf = buf[0..NEEDLE_MATCH],
                .author_indices = buf[NEEDLE_MATCH .. NEEDLE_MATCH + MAX_AUTHORS],
                .author_highlight_length = buf[NEEDLE_MATCH + MAX_AUTHORS ..],
            };
        }

        var self: Wrapper = .{
            .allocator = allocator,
            .finder = finder,
            .papers = papers,
            .scores = scores,
            .ordering = ordering,
            .match_buffer = match_buffer,
            .match_indices = match_indices,
        };

        // sort the initial ordering
        std.sort.heap(usize, self.ordering, &self, Wrapper.sortOrdering);

        return self;
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

    fn resetMatches(self: *Wrapper) void {
        @memset(self.scores, 0);
        for (self.match_indices) |*mi| mi.setNoMatches();
        self.matched = self.scores.len;
    }

    pub fn predraw(self: *Wrapper, s: *termui.Selector) anyerror!void {
        if (self.update_search) {
            self.update_search = false;
            const search_terms = SearchTerms.split(self.input_buffer[0..self.input_index]);

            var timer = try std.time.Timer.start();

            if (search_terms.getTitle()) |fuzzy_string| {
                for (self.match_indices, self.scores, 0..) |*mi, *score, i| {
                    const sm = self.finder.scoreMatches(
                        self.papers[i].title,
                        fuzzy_string,
                    );

                    std.mem.copyBackwards(usize, mi.buf, sm.matches);
                    mi.num_matches = sm.matches.len;

                    score.* = sm.score;
                }
            } else {
                self.resetMatches();
            }

            const authors = search_terms.getAuthors();
            if (authors.len > 0) {
                for (self.papers, self.scores, self.match_indices) |paper, *score, *mi| {
                    if (!matchAuthors(paper.authors, authors, mi)) {
                        score.* = null;
                    }
                }
            }

            self.matched = 0;
            for (self.scores) |score| {
                if (score != null) self.matched += 1;
            }
            s.capSelection(self.matched);

            // sort canonically
            std.sort.heap(usize, self.ordering, self, Wrapper.sortOrdering);
            self.time = timer.lap();
        } else if (self.input_index == 0) {
            self.resetMatches();
        }

        try s.display.printToRowC(0, "Found {d} matches", .{self.matched});

        const status_row = s.display.max_rows - 1;
        try s.display.printToRowC(
            status_row - 1,
            "Duration: {s}",
            .{std.fmt.fmtDuration(self.time)},
        );
        try s.display.printToRowC(
            status_row,
            "Find: {s}",
            .{self.input_buffer[0..self.input_index]},
        );

        s.cursor_column = 7 + self.input_index;
    }

    pub fn write(
        self: *@This(),
        _: *termui.Selector,
        out: anytype,
        index: usize,
    ) anyerror!void {
        const score = self.scores[self.ordering[index]] orelse return;
        const paper = self.papers[self.ordering[index]];
        const match_indices = self.match_indices[self.ordering[index]];

        var fbs = std.io.fixedBufferStream(&self.line_buffer);
        const writer = fbs.writer();

        try writer.print("{d: >4} ", .{@abs(score)});
        const author_len = try writeAuthor(writer, paper.authors, match_indices);
        try writer.writeByteNTimes(' ', AUTHOR_PAD -| author_len);

        try writer.print("({d: >4}) ", .{paper.year});

        try writeHighlighted(
            writer,
            paper.title[0..@min(TITLE_SIZE, paper.title.len)],
            match_indices.get(),
        );

        try out.writeAll(fbs.getWritten());
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
                // forward to be handled
                termui.ctrl('j'),
                termui.ctrl('d'),
                termui.Key.Enter,
                termui.ctrl('c'),
                => {},
                termui.ctrl('w') => {
                    const index = std.mem.lastIndexOfScalar(
                        u8,
                        std.mem.trimRight(u8, self.input_buffer[0..self.input_index], " "),
                        ' ',
                    ) orelse 0;
                    self.input_index = index;
                    self.update_search = true;
                    return .skip;
                },
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
