//! Bounded line editor (Milestone 1.5, console & shell core).
//!
//! A fixed 256-byte line buffer with no allocation and no libc. Feed it
//! console bytes one at a time; it echoes editing back and reports when a
//! complete line is ready (CR/LF), when the line was cancelled (Ctrl-C),
//! or that it is still mid-line. Input beyond the buffer is **refused**
//! (bell + `rejected` flag), never silently truncated mid-word.
//!
//! The editor is deliberately dumb about terminals: it emits the classic
//! `\b \b` erase pair for backspace, `\r\n` on submit, `^C\r\n` on cancel,
//! and the ASCII bell (0x07) when an action is refused. Every byte stream
//! is deterministic, so host tests assert it exactly.

const std = @import("std");
const console = @import("console.zig");

/// Fixed line capacity in bytes (march step 10: "Fixed 256-byte line
/// buffer"). `max_line` bytes fit exactly; the next byte is refused.
pub const max_line: usize = 256;

pub const LineResult = enum {
    /// Byte consumed; the line is still being edited.
    none,
    /// A complete line is in `buffer[0..len]` (terminated by CR or LF).
    submitted,
    /// Ctrl-C cleared the line; the buffer is empty again.
    cancelled,
};

pub const LineEditor = struct {
    buffer: [max_line]u8 = undefined,
    len: usize = 0,
    /// True when at least one input byte was refused because the buffer
    /// was full. Survives until `nextLine`/`reset`; the shell prints an
    /// overflow notice for the submitted line.
    rejected: bool = false,
    /// Set when the last submitted line ended in CR. The LF half of a
    /// CRLF pair arrives on the very next feed and is swallowed, so one
    /// Enter produces one line. Kept by `nextLine` (a submit is normally
    /// followed by the pair's LF), cleared by `reset` and by any other
    /// input byte.
    submitted_cr: bool = false,

    /// Full reset: empty line, clear flags and the CRLF swallow window.
    pub fn reset(self: *LineEditor) void {
        self.len = 0;
        self.rejected = false;
        self.submitted_cr = false;
    }

    /// Prepare for the next line after a submit. Keeps the CRLF swallow
    /// window open so the pair's LF is not mistaken for a new empty line.
    pub fn next_line(self: *LineEditor) void {
        self.len = 0;
        self.rejected = false;
    }

    /// Feed one console byte. Echoes editing onto `con` as it goes.
    pub fn feed(self: *LineEditor, con: console.Console, byte: u8) LineResult {
        // LF immediately after a CR-submitted line is the same Enter.
        if (self.submitted_cr and byte == '\n') {
            self.submitted_cr = false;
            return .none;
        }
        if (byte == '\r' or byte == '\n') {
            con.puts("\r\n");
            self.submitted_cr = byte == '\r';
            return .submitted;
        }
        if (byte == 0x08 or byte == 0x7f) { // backspace / DEL
            if (self.len > 0) {
                self.len -= 1;
                con.puts("\x08 \x08"); // erase the echoed character
            } else {
                con.putc(0x07); // nothing to delete: bell
            }
            self.submitted_cr = false;
            return .none;
        }
        if (byte == 0x03) { // Ctrl-C: cancel the whole line
            con.puts("^C\r\n");
            self.reset();
            return .cancelled;
        }
        self.submitted_cr = false;
        if (byte == '\t' or (byte >= 0x20 and byte <= 0x7e)) {
            if (self.len < max_line) {
                self.buffer[self.len] = byte;
                self.len += 1;
                con.putc(byte);
            } else {
                // Buffer full: refuse, never truncate mid-word.
                self.rejected = true;
                con.putc(0x07);
            }
        }
        // Other control bytes are ignored: not echoed, not appended.
        return .none;
    }
};

// ---------------------------------------------------------------------------
// Tests (host-side; no hardware)
// ---------------------------------------------------------------------------

test "lineedit: empty line submits immediately on LF" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\n'));
    try std.testing.expectEqual(@as(usize, 0), editor.len);
    try std.testing.expectEqualStrings("\r\n", mock.contents());
    try std.testing.expect(!editor.rejected);
}

test "lineedit: CR alone submits (no LF required)" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    _ = editor.feed(mock.console(), 'h');
    _ = editor.feed(mock.console(), 'i');
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\r'));
    try std.testing.expectEqualStrings("hi\r\n", mock.contents());
    try std.testing.expectEqual(@as(usize, 2), editor.len);
}

test "lineedit: CRLF pair submits exactly one line" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    _ = editor.feed(mock.console(), 'a');
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\r'));
    editor.next_line();
    // The LF half of the same CRLF pair must not start an empty line.
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), '\n'));
    try std.testing.expectEqual(@as(usize, 0), editor.len);
    try std.testing.expectEqualStrings("a\r\n", mock.contents());
    // A subsequent LF really does start a fresh (empty) line.
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\n'));
}

test "lineedit: backspace deletes and erases" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    _ = editor.feed(mock.console(), 'a');
    _ = editor.feed(mock.console(), 'b');
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), 0x08));
    try std.testing.expectEqual(@as(usize, 1), editor.len);
    try std.testing.expectEqual('a', editor.buffer[0]);
    try std.testing.expectEqualStrings("ab\x08 \x08", mock.contents());
}

test "lineedit: backspace at start is refused with a bell" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), 0x7f));
    try std.testing.expectEqual(@as(usize, 0), editor.len);
    try std.testing.expectEqualStrings("\x07", mock.contents());
}

test "lineedit: 255 and 256 chars fit exactly and submit" {
    var mock = console.MockConsole(1024){};
    var editor = LineEditor{};
    const line_255 = [_]u8{'a'} ** 255;
    for (line_255) |c| try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), c));
    try std.testing.expectEqual(@as(usize, 255), editor.len);
    try std.testing.expect(!editor.rejected);
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\n'));
    editor.next_line();

    const line_256 = [_]u8{'b'} ** 256;
    for (line_256) |c| try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), c));
    try std.testing.expectEqual(@as(usize, 256), editor.len);
    try std.testing.expect(!editor.rejected);
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\n'));
    // The 255-char line was echoed, then the 256-char line: content matches.
    try std.testing.expectEqual(@as(usize, 255 + 256 + 2 * 2), mock.contents().len);
}

test "lineedit: the 257th char is refused, never truncated mid-word" {
    var mock = console.MockConsole(1024){};
    var editor = LineEditor{};
    const line_257 = [_]u8{'c'} ** 257;
    for (line_257) |c| try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), c));
    try std.testing.expectEqual(@as(usize, 256), editor.len); // 257th refused
    try std.testing.expect(editor.rejected);
    // The refusal echoed one bell after the 256 echoed chars.
    try std.testing.expectEqualStrings("c" ** 256 ++ "\x07", mock.contents());
    // The line still submits (with what fit); rejected stays set for the shell.
    try std.testing.expectEqual(LineResult.submitted, editor.feed(mock.console(), '\n'));
    try std.testing.expect(editor.rejected);
}

test "lineedit: ctrl-c cancels and clears" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    _ = editor.feed(mock.console(), 'x');
    _ = editor.feed(mock.console(), 'y');
    try std.testing.expectEqual(LineResult.cancelled, editor.feed(mock.console(), 0x03));
    try std.testing.expectEqual(@as(usize, 0), editor.len);
    try std.testing.expect(!editor.rejected);
    try std.testing.expectEqualStrings("xy^C\r\n", mock.contents());
    // After cancel, a fresh line works.
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), 'z'));
    try std.testing.expectEqual(@as(usize, 1), editor.len);
}

test "lineedit: tab is accepted, other control bytes are ignored" {
    var mock = console.MockConsole(64){};
    var editor = LineEditor{};
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), '\t'));
    try std.testing.expectEqual(@as(usize, 1), editor.len);
    try std.testing.expectEqual('\t', editor.buffer[0]);
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), 0x01));
    try std.testing.expectEqual(LineResult.none, editor.feed(mock.console(), 0x1b));
    try std.testing.expectEqual(@as(usize, 1), editor.len);
    try std.testing.expectEqualStrings("\t", mock.contents());
}
