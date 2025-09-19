const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = std.fs.Dir;
const File = std.fs.File;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

var stdout_buffer: [4 * 1024]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
var stdout = &stdout_writer.interface;

const JunitErr = error{
    EndOfTests,
    InvalidXml,
    NotJunit,
    OutOfMemory,
};

const JunitTestSuite = struct {
    name: []const u8,
    failures: usize,
    errors: usize,
    timestamp: []const u8,
    file: []const u8,
    testCases: []TestCase,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        var buf: [200]u8 = undefined;
        _ = try writer.write("{testsuite");
        if (self.name.len > 0) {
            _ = try writer.write(" name = ");
            _ = try writer.write(self.name);
        }
        if (self.failures > 0) {
            _ = try writer.write(" failures = ");
            const out = std.fmt.bufPrint(&buf, "{d}", .{self.failures}) catch unreachable;
            _ = try writer.write(out);
        }
        _ = try writer.write("}");
    }
};

const ShrinkList = struct {
    items: []TestCase,

    fn remove(self: *ShrinkList, ix: usize) TestCase {
        if (self.items.len - 1 == ix) return self.pop().?;

        const old_item = self.items[ix];
        self.items[ix] = self.pop().?;
        return old_item;
    }

    pub fn pop(self: *ShrinkList) ?TestCase {
        if (self.items.len == 0) return null;
        const val = self.items[self.items.len - 1];
        self.items.len -= 1;
        return val;
    }
};

const TestCase = struct {
    name: []const u8,
    message: []const u8,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        _ = try writer.write("{testcase");
        if (self.name.len > 0) {
            _ = try writer.write(" name = ");
            _ = try writer.write(self.name);
        }
        if (self.message.len > 0) {
            _ = try writer.write(" message = ");
            _ = try writer.write(self.message);
        }
        _ = try writer.write("}");
    }
};

fn countScalar(haystack: []u8, needle: u8) usize {
    var i: usize = 0;
    var found: usize = 0;

    while (std.mem.indexOfScalarPos(u8, haystack, i, needle)) |idx| {
        i = idx + 1;
        found += 1;
    }

    return found;
}

fn readHeader(reader: *Reader) JunitErr!void {
    const header = reader.peekDelimiterInclusive('>') catch |err| {
        std.log.err("Problem reading xml: {any}", .{err});
        return JunitErr.InvalidXml;
    };

    if (!std.mem.startsWith(u8, header, "<?xml ")) return JunitErr.InvalidXml;
    if (!std.mem.startsWith(u8, header[6..], "version=\"1.0\"")) return JunitErr.InvalidXml;
    if (!std.mem.endsWith(u8, header, "?>")) return JunitErr.InvalidXml;

    reader.toss(header.len + 1);
}

/// Reads the xml file for failing tests in a test suite
fn readResults(allocator: Allocator, reader: *Reader) JunitErr!*JunitTestSuite {
    const line = reader.takeDelimiterExclusive('>') catch |err| {
        std.log.err("Problem reading xml: {any}", .{err});
        return JunitErr.InvalidXml;
    };

    // top-level object could either be `testsuites` or singular `testsuite`
    if (!std.mem.startsWith(u8, line, "<testsuite")) return JunitErr.NotJunit;

    var testSuite = try allocator.create(JunitTestSuite);
    testSuite.errors = 0;
    testSuite.failures = 0;

    var iter = std.mem.tokenizeScalar(u8, line, ' ');
    _ = iter.next();

    while (iter.next()) |token| {
        const ix = std.mem.indexOfScalar(u8, token, '=') orelse return JunitErr.InvalidXml;
        const value = token[ix + 2 .. token.len - 1];
        if (std.mem.eql(u8, token[0..ix], "name")) {
            testSuite.name = try allocator.dupe(u8, value);
        }
        if (std.mem.eql(u8, token[0..ix], "file")) {
            testSuite.file = try allocator.dupe(u8, value);
        }
        if (std.mem.eql(u8, token[0..ix], "timestamp")) {
            testSuite.timestamp = try allocator.dupe(u8, value);
        }
        if (std.mem.eql(u8, token[0..ix], "failures")) {
            testSuite.failures = std.fmt.parseInt(usize, value, 10) catch return JunitErr.InvalidXml;
        }
        if (std.mem.eql(u8, token[0..ix], "errors")) {
            testSuite.errors = std.fmt.parseInt(usize, value, 10) catch return JunitErr.InvalidXml;
        }
    }
    reader.toss(1);

    testSuite.testCases = try allocator.alloc(TestCase, (testSuite.errors + testSuite.failures));

    return testSuite;
}

fn dropProperties(reader: *Reader) (Reader.DelimiterError || JunitErr)!void {
    _ = try reader.discardDelimiterExclusive('<');
    const props = try reader.takeDelimiterInclusive('>');
    if (!std.mem.startsWith(u8, props, "<properties")) {
        return JunitErr.NotJunit;
    }
    if (std.mem.endsWith(u8, props, "/>")) return;
    while (true) {
        _ = try reader.discardDelimiterExclusive('<');
        const line = try reader.takeDelimiterInclusive('>');
        if (std.mem.eql(u8, "</properties>", line)) return;
    }
}

fn readTestcase(alloc: Allocator, reader: *Reader, testCase: *TestCase) (Reader.Error || Reader.DelimiterError || Allocator.Error || JunitErr)!bool {
    // Open <testcase ...>
    _ = try reader.discardDelimiterExclusive('<');
    const line = try reader.takeDelimiterInclusive('>');
    if (!std.mem.startsWith(u8, line, "<testcase")) {
        std.log.info("xml: '{s}'", .{line});
        return JunitErr.EndOfTests;
    }
    if (std.mem.endsWith(u8, line, "/>")) return false; // Self-closing elements don't contain an error

    var iter = std.mem.tokenizeScalar(u8, line, '"');
    _ = iter.next();
    while (iter.next()) |token| {
        testCase.name = try alloc.dupe(u8, token);
        break;
    }

    // Open <failure ...>
    _ = try reader.discardDelimiterExclusive('<');
    const tag = try reader.takeDelimiterInclusive('>');
    iter = std.mem.tokenizeScalar(u8, tag, '"');
    _ = iter.next();
    while (iter.next()) |token| {
        testCase.message = try alloc.dupe(u8, token);
        break;
    }

    // Search for close </testcase>
    var cursor = true;
    while (cursor) {
        _ = try reader.discardDelimiterExclusive('<');
        const closetag = try reader.takeDelimiterInclusive('>');
        cursor = !std.mem.eql(u8, closetag, "</testcase>");
    }
    return true;
}

fn checkJunit(alloc: Allocator, pwd: Dir, path: []const u8) !void {
    var file = try pwd.openFile(path, .{ .mode = .read_only });
    defer file.close();

    var readBuffer: [4 * 1024]u8 = undefined;
    var freader = file.reader(&readBuffer);
    const reader = &freader.interface;

    try readHeader(reader);

    const testSuite = try readResults(alloc, reader);
    if (testSuite.errors + testSuite.failures == 0) {
        return;
    }

    try dropProperties(reader);

    // TODO: Resolve path relative to pwd
    const baseFile = try alloc.dupe(u8, testSuite.name);
    std.mem.replaceScalar(u8, baseFile, '.', '/');
    //
    // HACK: Make it dynamic, take language as config/argument
    const testfpath = try std.mem.concat(alloc, u8, &.{ "src/test/kotlin/", baseFile, ".kt" });
    const testfile = pwd.openFile(testfpath, .{}) catch |err| {
        const here = try pwd.realpathAlloc(alloc, ".");
        std.log.warn("File {s} could not be opened from {s}: {any}", .{ testfpath, here, err });
        return err;
    };

    defer testfile.close();
    var tf_buf: [4 * 1024]u8 = undefined;
    var testreader = testfile.reader(&tf_buf);
    var tfread = &testreader.interface;

    for (0..testSuite.testCases.len) |ix| {
        const testCase: *TestCase = @constCast(&testSuite.testCases[ix]);
        while (!(readTestcase(alloc, reader, testCase) catch {
            return;
        })) {}
    }

    var allTests: ShrinkList = .{ .items = testSuite.testCases };
    std.debug.print("{s} {d}\n", .{ testfpath, allTests.items.len });

    var line: usize = 1;
    while (true) next: {
        const block = tfread.takeDelimiterInclusive('@') catch |err| switch (err) {
            Reader.DelimiterError.EndOfStream => unreachable,
            Reader.DelimiterError.StreamTooLong => {
                line += countScalar(tfread.buffer, '\n');
                tfread.toss(tfread.buffer.len);
                continue;
            },
            else => return err,
        };
        line += countScalar(block, '\n') + 1;
        const annotation = try tfread.takeDelimiterExclusive('\n');
        if (!std.mem.startsWith(u8, "Test", annotation)) continue;
        const testline = try tfread.takeDelimiterInclusive('\n');
        line += 1;

        for (0..allTests.items.len) |ix| {
            const testCase = allTests.items[ix];
            if (std.mem.indexOf(u8, testline, testCase.name)) |pos| {
                @branchHint(.unlikely);
                _ = allTests.remove(ix);
                _ = try stdout.write(testfpath);
                _ = try stdout.writeByte(':');
                _ = try stdout.printInt(line, 10, .lower, .{});
                _ = try stdout.writeByte(':');
                _ = try stdout.printInt(pos, 10, .lower, .{});
                _ = try stdout.writeByte(':');
                _ = try stdout.write(testCase.message);
                _ = try stdout.writeByte('\n');

                if (allTests.items.len == 0) {
                    try stdout.flush();
                    return;
                }

                break :next;
            }
        }
    }
    try stdout.flush();
}

pub fn main() !void {
    var base = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = base.allocator();
    defer _ = base.deinit() == .ok;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var args = std.process.args();
    _ = args.skip(); // first arg is binary name
    const target = args.next() orelse ".";
    var pwd = try std.fs.cwd().openDir(target, .{ .iterate = true });
    defer pwd.close();

    var walker = try pwd.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| switch (entry.kind) {
        .file => {
            if (std.mem.endsWith(u8, entry.basename, ".xml")) {
                checkJunit(alloc, pwd, entry.path) catch |err| {
                    switch (err) {
                        JunitErr.InvalidXml => std.log.err("File {s} is not a valid xml file", .{entry.basename}),
                        JunitErr.NotJunit => {},
                        else => {
                            std.log.debug("Error: {any}", .{err});
                        },
                    }
                    continue;
                };
                _ = arena.reset(.retain_capacity);
            }
        },
        else => {},
    };
}
