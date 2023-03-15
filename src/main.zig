const std = @import("std");

const clap = @import("clap");

const MAX_READ_BUF_SIZE = 0x1000;
const VERSION = "v0.0.1";

const Core = struct {
    var target : std.fs.File = undefined;
    var address : usize = 0;
};

fn hexdump(stream: anytype, header: [] const u8, buffer: [] const u8) std.os.WriteError!void {
    // Print a header.
    if (header.len > 0) {
        var hdr: [64] u8 = undefined;
        var offset: usize = (hdr.len / 2) - ((header.len / 2) - 1);

        std.mem.set(u8, hdr[0..hdr.len], ' ');
        std.mem.copy(u8, hdr[offset..hdr.len], header);

        try stream.writeAll(hdr[0..hdr.len]);
        try stream.writeAll("\n");
    }

    var hexb: u32 = 0;
    var ascii: [16] u8 = undefined;
    // First line, first left side (simple number).
    try stream.print("\n  {d:0>4}:  ", .{ hexb });

    // Loop on all values in the buffer (i from 0 to buffer.len).
    var i: u32 = 0;
    while (i < buffer.len) : (i += 1) {
        // Print actual hexadecimal value.
        try stream.print("{X:0>2} ", .{ buffer[i] });

        // What to print (simple ascii text, right side).
        if (buffer[i] >= ' ' and buffer[i] <= '~') {
            ascii[(i % 16)] = buffer[i];
        } else {
            ascii[(i % 16)] = '.';
        }

        // Next input is a multiple of 8 = extra space.
        if ((i + 1) % 8 == 0) {
            try stream.writeAll(" ");
        }

        // No next input: print the right amount of spaces.
        if ((i + 1) == buffer.len) {
            // Each line is 16 bytes to print, each byte takes 3 characters.
            var missing_spaces = 3 * (15 - (i%16));
            // Missing an extra space if the current index % 16 is less than 7.
            if ((i%16) < 7) { missing_spaces += 1; }
            while (missing_spaces > 0) : (missing_spaces -= 1) {
                try stream.writeAll(" ");
            }
        }

        // Every 16 bytes: print ascii text and line return.

        // Case 1: it's been 16 bytes AND it's the last byte to print.
        if ((i + 1) % 16 == 0 and (i + 1) == buffer.len) {
            try stream.print("{s}\n", .{ ascii[0..ascii.len] });
        }
        // Case 2: it's been 16 bytes but it's not the end of the buffer.
        else if ((i + 1) % 16 == 0 and (i + 1) != buffer.len) {
            try stream.print("{s}\n", .{ ascii[0..ascii.len] });
            hexb += 16;
            try stream.print("  {d:0>4}:  ", .{ hexb });
        }
        // Case 3: not the end of the 16 bytes row but it's the end of the buffer.
        else if ((i + 1) % 16 != 0 and (i + 1) == buffer.len) {
            try stream.print(" {s}\n", .{ ascii[0..((i+1) % 16)] });
        }
        // Case 4: not the end of the 16 bytes row and not the end of the buffer.
        //         Do nothing.
    }

    try stream.writeAll("\n");
}

fn strlen(s : []const u8) usize {
    var length : usize = 0;
    for (s) |c| {
        if (c == 0 or c == 0xa) break;
        length += 1;
    }

    return length;
}

fn parseInt(comptime T : type, str : []const u8, radix : u8) !T {
    const length = strlen(str);

    return std.fmt.parseInt(T, str[0..length], radix);
}

fn get_command(buf : []u8) !usize {
    const stdin = std.io.getStdIn();
    return try stdin.read(buf);
}

fn seek_command(cmd : []u8) !void {
    var iter = std.mem.split(u8, cmd, " ");
    _ = iter.next().?;

    if (parseInt(usize, iter.next().?, 0)) |addr| {
        if (Core.target.seekTo(addr)) {
            Core.address = addr;
        } else |err| {
            std.log.err("Could not seek to addr {}, {}", .{addr, err});
        }
    } else |err|{
        std.log.err("{}", .{err});
    }
}

fn read_command(cmd : []u8) !void {
    var iter = std.mem.split(u8, cmd, " ");
    const prefix = iter.next().?;

    var nbytes = parseInt(usize, iter.next().?, 0) catch 0;
    var buffer : [MAX_READ_BUF_SIZE]u8 = undefined;

    // Do no try to read more than available buffer
    if (nbytes > buffer.len) {
        nbytes = buffer.len;
    }

    const read_bytes = try Core.target.reader().readAll(buffer[0..nbytes]);

    if(prefix.len > 1 and prefix[1] == 'x') {
        try hexdump(std.io.getStdOut().writer(), "", buffer[0..read_bytes]);
    } else {
        std.debug.print("{s}\n", .{buffer[0..read_bytes]});
    }

    // seek back to address
    try Core.target.seekTo(Core.address);
}

fn write_command(cmd : []u8) !void {
    if (std.mem.indexOf(u8, cmd, " ")) |index| {
        const data = cmd[(index+1)..];
        _ = try Core.target.write(data);

        // seek back to address
        try Core.target.seekTo(Core.address);
    }
}

fn execute_command(cmd : []u8) !bool {
    switch(cmd[0]) {
        'r', 'p' => try read_command(cmd),
        'q' => return true,
        's' => try seek_command(cmd),
        'w' => try write_command(cmd),
        else => {},
    }

    return false;
}

fn main_loop() !void {
    var buf : [0x100]u8 = undefined;

    while(true) {
        std.debug.print("[0x{X:0>8}]> ", .{Core.address});
        var bytes_read = try get_command(&buf) - 1;
        if (bytes_read <= 0) continue;
        if (try execute_command(buf[0..bytes_read])) break;
    }
}

fn open_or_create_file(filepath : []const u8) !std.fs.File {
    std.log.debug("Trying to open {s}", .{filepath});
    const cwd = std.fs.cwd();
    return cwd.openFile(filepath, .{ .mode = .read_write}) catch |err| {
        if (err == error.FileNotFound) {
            std.log.debug("Trying to create file {s}", .{filepath});
            return try cwd.createFile(filepath, .{.read = true});
        } else {
            return err;
        }
    };
}

pub fn main() anyerror!void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help
        \\      Display this help and exit.
        \\-v, --version
        \\      Output version information and exit.
        \\<file>
        \\
    );

    const stderr = std.io.getStdErr().writer();

    const parsers = comptime .{
        .file = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};

    var res = try clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
    });
    defer res.deinit();

    if (res.args.help) {
        return clap.help(std.io.getStdOut().writer(), clap.Help, &params, .{});
    } else if (res.args.version) {
        std.debug.print("{s}\n", .{VERSION});
        return;
    }

    if (res.positionals.len <= 0) {
        try clap.usage(stderr, clap.Help, &params);
        _ = try stderr.write("\n");
        return error.ArgNotFound;
    }

    for (res.positionals) |pos| {
        std.log.debug("{s}\n", .{pos});
    }

    Core.target = try open_or_create_file(res.positionals[0]);

    defer Core.target.close();

    try main_loop();
}

test "test hexdump" {
    try hexdump(std.io.getStdOut().writer(), "Hello World", "Lorem ipsum dolor sit amet");

    const outfile = try std.fs.cwd().createFile("/tmp/zio-hexdump", .{ });
    defer outfile.close();

    try hexdump(outfile.writer(), "Hello World", "Lorem ipsum dolor sit amet");
}

