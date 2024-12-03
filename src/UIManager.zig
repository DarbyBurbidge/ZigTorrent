const std = @import("std");
const capy = @import("capy");

// This is required for your app to build to WebAssembly and other particular architectures
pub usingnamespace capy.cross_platform;
var window: ?capy.Window = undefined;
var fullscreen = false;

pub fn main() !void {
    try capy.init();
    window = try capy.Window.init();

    try window.?.set(capy.column(.{ .spacing = 10 }, .{
        capy.row(.{ .spacing = 5 }, .{ capy.button(.{ .label = "Toggle Fullscreen", .onclick = @ptrCast(&toggleFullscreen) }), capy.expanded(capy.textArea(.{ .text = "Hello World!" })) }),
    }));
    window.?.setTitle("Hello");
    window.?.setFullscreen(capy.Window.FullscreenMode{ .borderless = null });
    fullscreen = true;
    window.?.show();

    capy.runEventLoop();
}

fn toggleFullscreen(button: *capy.Button) !void {
    _ = button;
    if (fullscreen == true) {
        window.?.setFullscreen(capy.Window.FullscreenMode.none);
        fullscreen = false;
    } else {
        window.?.setFullscreen(capy.Window.FullscreenMode{ .borderless = null });
        fullscreen = true;
    }
}
