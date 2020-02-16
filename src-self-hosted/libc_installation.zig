const std = @import("std");
const builtin = @import("builtin");
const util = @import("util.zig");
const Target = std.Target;
const fs = std.fs;
const Allocator = std.mem.Allocator;
const Batch = std.event.Batch;

const is_darwin = Target.current.isDarwin();
const is_windows = Target.current.isWindows();
const is_freebsd = Target.current.isFreeBSD();
const is_netbsd = Target.current.isNetBSD();
const is_linux = Target.current.isLinux();
const is_dragonfly = Target.current.isDragonFlyBSD();
const is_gnu = Target.current.isGnu();

usingnamespace @import("windows_sdk.zig");

/// See the render function implementation for documentation of the fields.
pub const LibCInstallation = struct {
    include_dir: ?[:0]const u8 = null,
    sys_include_dir: ?[:0]const u8 = null,
    crt_dir: ?[:0]const u8 = null,
    static_crt_dir: ?[:0]const u8 = null,
    msvc_lib_dir: ?[:0]const u8 = null,
    kernel32_lib_dir: ?[:0]const u8 = null,

    pub const FindError = error{
        OutOfMemory,
        FileSystem,
        UnableToSpawnCCompiler,
        CCompilerExitCode,
        CCompilerCrashed,
        CCompilerCannotFindHeaders,
        LibCRuntimeNotFound,
        LibCStdLibHeaderNotFound,
        LibCKernel32LibNotFound,
        UnsupportedArchitecture,
    };

    pub fn parse(
        allocator: *Allocator,
        libc_file: []const u8,
        stderr: *std.io.OutStream(fs.File.WriteError),
    ) !LibCInstallation {
        var self: LibCInstallation = .{};

        const fields = std.meta.fields(LibCInstallation);
        const FoundKey = struct {
            found: bool,
            allocated: ?[:0]u8,
        };
        var found_keys = [1]FoundKey{FoundKey{ .found = false, .allocated = null }} ** fields.len;
        errdefer {
            self = .{};
            for (found_keys) |found_key| {
                if (found_key.allocated) |s| allocator.free(s);
            }
        }

        const contents = try std.io.readFileAlloc(allocator, libc_file);
        defer allocator.free(contents);

        var it = std.mem.tokenize(contents, "\n");
        while (it.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var line_it = std.mem.separate(line, "=");
            const name = line_it.next() orelse {
                try stderr.print("missing equal sign after field name\n", .{});
                return error.ParseError;
            };
            const value = line_it.rest();
            inline for (fields) |field, i| {
                if (std.mem.eql(u8, name, field.name)) {
                    found_keys[i].found = true;
                    if (value.len == 0) {
                        @field(self, field.name) = null;
                    } else {
                        found_keys[i].allocated = try std.mem.dupeZ(allocator, u8, value);
                        @field(self, field.name) = found_keys[i].allocated;
                    }
                    break;
                }
            }
        }
        inline for (fields) |field, i| {
            if (!found_keys[i].found) {
                try stderr.print("missing field: {}\n", .{field.name});
                return error.ParseError;
            }
        }
        if (self.include_dir == null) {
            try stderr.print("include_dir may not be empty\n", .{});
            return error.ParseError;
        }
        if (self.sys_include_dir == null) {
            try stderr.print("sys_include_dir may not be empty\n", .{});
            return error.ParseError;
        }
        if (self.crt_dir == null and is_darwin) {
            try stderr.print("crt_dir may not be empty for {}\n", .{@tagName(Target.current.getOs())});
            return error.ParseError;
        }
        if (self.static_crt_dir == null and is_windows and is_gnu) {
            try stderr.print("static_crt_dir may not be empty for {}-{}\n", .{
                @tagName(Target.current.getOs()),
                @tagName(Target.current.getAbi()),
            });
            return error.ParseError;
        }
        if (self.msvc_lib_dir == null and is_windows and !is_gnu) {
            try stderr.print("msvc_lib_dir may not be empty for {}-{}\n", .{
                @tagName(Target.current.getOs()),
                @tagName(Target.current.getAbi()),
            });
            return error.ParseError;
        }
        if (self.kernel32_lib_dir == null and is_windows and !is_gnu) {
            try stderr.print("kernel32_lib_dir may not be empty for {}-{}\n", .{
                @tagName(Target.current.getOs()),
                @tagName(Target.current.getAbi()),
            });
            return error.ParseError;
        }

        return self;
    }

    pub fn render(self: LibCInstallation, out: *std.io.OutStream(fs.File.WriteError)) !void {
        @setEvalBranchQuota(4000);
        const include_dir = self.include_dir orelse "";
        const sys_include_dir = self.sys_include_dir orelse "";
        const crt_dir = self.crt_dir orelse "";
        const static_crt_dir = self.static_crt_dir orelse "";
        const msvc_lib_dir = self.msvc_lib_dir orelse "";
        const kernel32_lib_dir = self.kernel32_lib_dir orelse "";

        try out.print(
            \\# The directory that contains `stdlib.h`.
            \\# On POSIX-like systems, include directories be found with: `cc -E -Wp,-v -xc /dev/null`
            \\include_dir={}
            \\
            \\# The system-specific include directory. May be the same as `include_dir`.
            \\# On Windows it's the directory that includes `vcruntime.h`.
            \\# On POSIX it's the directory that includes `sys/errno.h`.
            \\sys_include_dir={}
            \\
            \\# The directory that contains `crt1.o` or `crt2.o`.
            \\# On POSIX, can be found with `cc -print-file-name=crt1.o`.
            \\# Not needed when targeting MacOS.
            \\crt_dir={}
            \\
            \\# The directory that contains `crtbegin.o`.
            \\# On POSIX, can be found with `cc -print-file-name=crtbegin.o`.
            \\# Not needed when targeting MacOS.
            \\static_crt_dir={}
            \\
            \\# The directory that contains `vcruntime.lib`.
            \\# Only needed when targeting MSVC on Windows.
            \\msvc_lib_dir={}
            \\
            \\# The directory that contains `kernel32.lib`.
            \\# Only needed when targeting MSVC on Windows.
            \\kernel32_lib_dir={}
            \\
        , .{
            include_dir,
            sys_include_dir,
            crt_dir,
            static_crt_dir,
            msvc_lib_dir,
            kernel32_lib_dir,
        });
    }

    /// Finds the default, native libc.
    pub fn findNative(allocator: *Allocator) !LibCInstallation {
        var self: LibCInstallation = .{};

        if (is_windows) {
            if (is_gnu) {
                var batch = Batch(FindError!void, 3, .auto_async).init();
                batch.add(&async self.findNativeIncludeDirPosix(allocator));
                batch.add(&async self.findNativeCrtDirPosix(allocator));
                batch.add(&async self.findNativeStaticCrtDirPosix(allocator));
                try batch.wait();
            } else {
                var sdk: *ZigWindowsSDK = undefined;
                switch (zig_find_windows_sdk(&sdk)) {
                    .None => {
                        defer zig_free_windows_sdk(sdk);

                        var batch = Batch(FindError!void, 5, .auto_async).init();
                        batch.add(&async self.findNativeMsvcIncludeDir(allocator, sdk));
                        batch.add(&async self.findNativeMsvcLibDir(allocator, sdk));
                        batch.add(&async self.findNativeKernel32LibDir(allocator, sdk));
                        batch.add(&async self.findNativeIncludeDirWindows(allocator, sdk));
                        batch.add(&async self.findNativeCrtDirWindows(allocator, sdk));
                        try batch.wait();
                    },
                    .OutOfMemory => return error.OutOfMemory,
                    .NotFound => return error.NotFound,
                    .PathTooLong => return error.NotFound,
                }
            }
        } else {
            try blk: {
                var batch = Batch(FindError!void, 2, .auto_async).init();
                errdefer batch.wait() catch {};
                batch.add(&async self.findNativeIncludeDirPosix(allocator));
                if (is_freebsd or is_netbsd) {
                    self.crt_dir = try std.mem.dupeZ(allocator, u8, "/usr/lib");
                } else if (is_linux or is_dragonfly) {
                    batch.add(&async self.findNativeCrtDirPosix(allocator));
                }
                break :blk batch.wait();
            };
        }
        return self;
    }

    /// Must be the same allocator passed to `parse` or `findNative`.
    pub fn deinit(self: *LibCInstallation, allocator: *Allocator) void {
        const fields = std.meta.fields(LibCInstallation);
        inline for (fields) |field| {
            if (@field(self, field.name)) |payload| {
                allocator.free(payload);
            }
        }
        self.* = undefined;
    }

    fn findNativeIncludeDirPosix(self: *LibCInstallation, allocator: *Allocator) FindError!void {
        const dev_null = if (is_windows) "nul" else "/dev/null";
        const cc_exe = std.os.getenvZ("CC") orelse default_cc_exe;
        const argv = [_][]const u8{
            cc_exe,
            "-E",
            "-Wp,-v",
            "-xc",
            dev_null,
        };
        const max_bytes = 1024 * 1024;
        const exec_res = std.ChildProcess.exec(allocator, &argv, null, null, max_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.UnableToSpawnCCompiler,
        };
        defer {
            allocator.free(exec_res.stdout);
            allocator.free(exec_res.stderr);
        }
        switch (exec_res.term) {
            .Exited => |code| if (code != 0) return error.CCompilerExitCode,
            else => return error.CCompilerCrashed,
        }

        var it = std.mem.tokenize(exec_res.stderr, "\n\r");
        var search_paths = std.ArrayList([]const u8).init(allocator);
        defer search_paths.deinit();
        while (it.next()) |line| {
            if (line.len != 0 and line[0] == ' ') {
                try search_paths.append(line);
            }
        }
        if (search_paths.len == 0) {
            return error.CCompilerCannotFindHeaders;
        }

        const include_dir_example_file = "stdlib.h";
        const sys_include_dir_example_file = if (is_windows) "sys\\types.h" else "sys/errno.h";

        var path_i: usize = 0;
        while (path_i < search_paths.len) : (path_i += 1) {
            // search in reverse order
            const search_path_untrimmed = search_paths.at(search_paths.len - path_i - 1);
            const search_path = std.mem.trimLeft(u8, search_path_untrimmed, " ");
            var search_dir = fs.cwd().openDirList(search_path) catch |err| switch (err) {
                error.FileNotFound,
                error.NotDir,
                error.NoDevice,
                => continue,

                else => return error.FileSystem,
            };
            defer search_dir.close();

            if (self.include_dir == null) {
                if (search_dir.accessZ(include_dir_example_file, .{})) |_| {
                    self.include_dir = try std.mem.dupeZ(allocator, u8, search_path);
                } else |err| switch (err) {
                    error.FileNotFound => {},
                    else => return error.FileSystem,
                }
            }

            if (self.sys_include_dir == null) {
                if (search_dir.accessZ(sys_include_dir_example_file, .{})) |_| {
                    self.sys_include_dir = try std.mem.dupeZ(allocator, u8, search_path);
                } else |err| switch (err) {
                    error.FileNotFound => {},
                    else => return error.FileSystem,
                }
            }

            if (self.include_dir != null and self.sys_include_dir != null) {
                // Success.
                return;
            }
        }

        return error.LibCStdLibHeaderNotFound;
    }

    fn findNativeIncludeDirWindows(self: *LibCInstallation, allocator: *Allocator, sdk: *ZigWindowsSDK) !void {
        var search_buf: [2]Search = undefined;
        const searches = fillSearch(&search_buf, sdk);

        var result_buf = try std.Buffer.initSize(allocator, 0);
        defer result_buf.deinit();

        for (searches) |search| {
            result_buf.shrink(0);
            const stream = &std.io.BufferOutStream.init(&result_buf).stream;
            try stream.print("{}\\Include\\{}\\ucrt", .{ search.path, search.version });

            var dir = fs.cwd().openDirList(result_buf.toSliceConst()) catch |err| switch (err) {
                error.FileNotFound,
                error.NotDir,
                error.NoDevice,
                => continue,

                else => return error.FileSystem,
            };
            defer dir.close();

            dir.accessZ("stdlib.h", .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return error.FileSystem,
            };

            self.include_dir = result_buf.toOwnedSlice();
            return;
        }

        return error.LibCStdLibHeaderNotFound;
    }

    fn findNativeCrtDirWindows(self: *LibCInstallation, allocator: *Allocator, sdk: *ZigWindowsSDK) FindError!void {
        var search_buf: [2]Search = undefined;
        const searches = fillSearch(&search_buf, sdk);

        var result_buf = try std.Buffer.initSize(allocator, 0);
        defer result_buf.deinit();

        const arch_sub_dir = switch (builtin.arch) {
            .i386 => "x86",
            .x86_64 => "x64",
            .arm, .armeb => "arm",
            else => return error.UnsupportedArchitecture,
        };

        for (searches) |search| {
            result_buf.shrink(0);
            const stream = &std.io.BufferOutStream.init(&result_buf).stream;
            try stream.print("{}\\Lib\\{}\\ucrt\\{}", .{ search.path, search.version, arch_sub_dir });

            var dir = fs.cwd().openDirList(result_buf.toSliceConst()) catch |err| switch (err) {
                error.FileNotFound,
                error.NotDir,
                error.NoDevice,
                => continue,

                else => return error.FileSystem,
            };
            defer dir.close();

            dir.accessZ("ucrt.lib", .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return error.FileSystem,
            };

            self.crt_dir = result_buf.toOwnedSlice();
            return;
        }
        return error.LibCRuntimeNotFound;
    }

    fn findNativeCrtDirPosix(self: *LibCInstallation, allocator: *Allocator) FindError!void {
        self.crt_dir = try ccPrintFileName(allocator, "crt1.o", .only_dir);
    }

    fn findNativeStaticCrtDirPosix(self: *LibCInstallation, allocator: *Allocator) FindError!void {
        self.static_crt_dir = try ccPrintFileName(allocator, "crtbegin.o", .only_dir);
    }

    fn findNativeKernel32LibDir(self: *LibCInstallation, allocator: *Allocator, sdk: *ZigWindowsSDK) FindError!void {
        var search_buf: [2]Search = undefined;
        const searches = fillSearch(&search_buf, sdk);

        var result_buf = try std.Buffer.initSize(allocator, 0);
        defer result_buf.deinit();

        const arch_sub_dir = switch (builtin.arch) {
            .i386 => "x86",
            .x86_64 => "x64",
            .arm, .armeb => "arm",
            else => return error.UnsupportedArchitecture,
        };

        for (searches) |search| {
            result_buf.shrink(0);
            const stream = &std.io.BufferOutStream.init(&result_buf).stream;
            try stream.print("{}\\Lib\\{}\\um\\{}", .{ search.path, search.version, arch_sub_dir });

            var dir = fs.cwd().openDirList(result_buf.toSliceConst()) catch |err| switch (err) {
                error.FileNotFound,
                error.NotDir,
                error.NoDevice,
                => continue,

                else => return error.FileSystem,
            };
            defer dir.close();

            dir.accessZ("kernel32.lib", .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return error.FileSystem,
            };

            self.kernel32_lib_dir = result_buf.toOwnedSlice();
            return;
        }
        return error.LibCKernel32LibNotFound;
    }
};

const default_cc_exe = if (is_windows) "cc.exe" else "cc";

/// caller owns returned memory
pub fn ccPrintFileName(
    allocator: *Allocator,
    o_file: []const u8,
    want_dirname: enum { full_path, only_dir },
) ![:0]u8 {
    const cc_exe = std.os.getenvZ("CC") orelse default_cc_exe;
    const arg1 = try std.fmt.allocPrint(allocator, "-print-file-name={}", .{o_file});
    defer allocator.free(arg1);
    const argv = [_][]const u8{ cc_exe, arg1 };

    const max_bytes = 1024 * 1024;
    const exec_res = std.ChildProcess.exec(allocator, &argv, null, null, max_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnableToSpawnCCompiler,
    };
    defer {
        allocator.free(exec_res.stdout);
        allocator.free(exec_res.stderr);
    }
    switch (exec_res.term) {
        .Exited => |code| if (code != 0) return error.CCompilerExitCode,
        else => return error.CCompilerCrashed,
    }

    var it = std.mem.tokenize(exec_res.stdout, "\n\r");
    const line = it.next() orelse return error.LibCRuntimeNotFound;
    switch (want_dirname) {
        .full_path => return std.mem.dupeZ(allocator, u8, line),
        .only_dir => {
            const dirname = fs.path.dirname(line) orelse return error.LibCRuntimeNotFound;
            return std.mem.dupeZ(allocator, u8, dirname);
        },
    }
}

const Search = struct {
    path: []const u8,
    version: []const u8,
};

fn fillSearch(search_buf: *[2]Search, sdk: *ZigWindowsSDK) []Search {
    var search_end: usize = 0;
    if (sdk.path10_ptr) |path10_ptr| {
        if (sdk.version10_ptr) |version10_ptr| {
            search_buf[search_end] = Search{
                .path = path10_ptr[0..sdk.path10_len],
                .version = version10_ptr[0..sdk.version10_len],
            };
            search_end += 1;
        }
    }
    if (sdk.path81_ptr) |path81_ptr| {
        if (sdk.version81_ptr) |version81_ptr| {
            search_buf[search_end] = Search{
                .path = path81_ptr[0..sdk.path81_len],
                .version = version81_ptr[0..sdk.version81_len],
            };
            search_end += 1;
        }
    }
    return search_buf[0..search_end];
}
