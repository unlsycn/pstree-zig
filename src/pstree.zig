const std = @import("std");

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();
const Allocator = std.mem.Allocator;
const Pid = std.os.pid_t;

const Proc = struct {
    pid: Pid,
    name: [16]u8, // name longer than 16 are silently truncated
    ppid: Pid,

    children: std.ArrayList(Pid),

    const Self = @This();
    pub fn init(allocator: Allocator) Self {
        return .{ .pid = undefined, .name = undefined, .ppid = undefined, .children = std.ArrayList(Pid).init(allocator) };
    }

    pub fn deinit(self: *Self) void {
        self.children.deinit();
    }
};

const ProcMap = std.AutoHashMap(Pid, Proc);

pub fn main() !void {
    var args = std.process.args();
    defer args.deinit();
    _ = args.skip();

    var flags = PrintTreeOptions{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--show-pids")) {
            flags.show_pids = true;
        }
        if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--numeric-sort"))
            flags.numeric_sort = true;
        if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            return stderr.print("pstree (unlsycn) 1.0\n", .{});
        }
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == std.heap.Check.leak) {
        std.debug.print("> [error] memory leaked\n", .{});
    };
    const allocator = gpa.allocator();

    var map = try walkDirectory("/proc", allocator);
    defer {
        var map_iter = map.valueIterator();
        while (map_iter.next()) |entry| {
            entry.deinit();
        }
        map.deinit();
    }

    try printTree(map, 1, 0, flags);
}

fn walkDirectory(comptime path: []const u8, allocator: Allocator) !ProcMap {
    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();
    var dir_iter = dir.iterate();

    var map = ProcMap.init(allocator);

    while (try dir_iter.next()) |entry| {
        if (entry.kind != std.fs.File.Kind.directory) continue;

        switch (entry.name[0]) {
            '0'...'9' => {
                const proc = try parseProc(try dir.openDir(entry.name, .{}), allocator);
                try map.put(proc.pid, proc);
            },
            else => {
                continue;
            },
        }
    }

    var map_iter = map.valueIterator();
    // add children to procs
    while (map_iter.next()) |proc| {
        if (proc.pid == 1) continue; // pid 1 is the root
        try map.getPtr(proc.ppid).?.children.append(proc.pid);
    }

    return map;
}

const ParseError = error{UnexpectedInput};

fn parseProc(procDir: std.fs.Dir, allocator: Allocator) !Proc {
    var buffer: [1000]u8 = undefined;

    const stat = try procDir.openFile("stat", .{});
    _ = try stat.readAll(&buffer);

    var proc = Proc.init(allocator);

    // parse name
    const left_paren_index = std.mem.indexOfScalar(u8, &buffer, '(') orelse return ParseError.UnexpectedInput;
    const right_paren_index = std.mem.lastIndexOfScalar(u8, &buffer, ')') orelse return ParseError.UnexpectedInput;
    const name = buffer[left_paren_index + 1 .. right_paren_index];
    std.mem.copyForwards(u8, &proc.name, name);

    var stat_iter = std.mem.tokenizeScalar(u8, &buffer, ' ');

    proc.pid = try std.fmt.parseInt(Pid, stat_iter.next().?, 10);
    stat_iter = std.mem.tokenizeScalar(u8, buffer[right_paren_index..], ' '); //skip name
    for (0..2) |_| {
        _ = stat_iter.next(); //skip state
    }
    proc.ppid = try std.fmt.parseInt(Pid, stat_iter.next().?, 10);

    return proc;
}

const PrintTreeOptions = packed struct {
    show_pids: bool = false,
    numeric_sort: bool = false,
};

fn compareProcByName(map: ProcMap, lhs: Pid, rhs: Pid) bool {
    return std.mem.order(u8, &map.get(lhs).?.name, &map.get(rhs).?.name).compare(std.math.CompareOperator.lt);
}

pub fn printTree(map: ProcMap, current_pid: Pid, depth: usize, flags: PrintTreeOptions) !void {
    const proc = map.get(current_pid).?;

    for (0..depth + 1) |i| {
        if (i + 1 == depth) {
            try stdout.print("┼───", .{});
        } else if (i != depth) {
            try stdout.print("    ", .{});
        }
    }
    if (flags.show_pids) {
        try stdout.print("{s}({d})\n", .{ proc.name, proc.pid });
    } else {
        try stdout.print("{s}\n", .{proc.name});
    }

    // sort children
    if (flags.numeric_sort) {
        std.mem.sort(Pid, proc.children.items, {}, std.sort.asc(Pid));
    } else {
        std.mem.sort(Pid, proc.children.items, map, compareProcByName);
    }

    for (proc.children.items) |child| {
        try printTree(map, child, depth + 1, flags);
    }
}
