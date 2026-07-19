package main

import NS "core:sys/darwin/Foundation"
import "base:intrinsics"

foreign import CoreGraphics "system:CoreGraphics.framework"

@(default_calling_convention = "c")
foreign CoreGraphics {
	CGWindowLevelForKey :: proc(key: i32) -> i32 ---
}

// kCGDesktopWindowLevelKey: above the wallpaper image, below the desktop icons.
CG_DESKTOP_WINDOW_LEVEL_KEY :: i32(2)

// Turns the Cocoa window backing the SDL window into a live wallpaper:
// pinned at the desktop window level on every Space, click-through, hidden
// from the Dock, Cmd+Tab, and the window cycle. A desktop-level window never
// becomes key, so no keyboard or mouse input reaches the app in this mode.
wallpaper_configure_window :: proc(win: ^NS.Window) {
	level := NS.Integer(CGWindowLevelForKey(CG_DESKTOP_WINDOW_LEVEL_KEY))
	intrinsics.objc_send(nil, win, "setLevel:", level)
	intrinsics.objc_send(nil, win, "setIgnoresMouseEvents:", NS.BOOL(true))
	intrinsics.objc_send(nil, win, "setHasShadow:", NS.BOOL(false))
	win->setCollectionBehavior({.CanJoinAllSpaces, .Stationary, .IgnoresCycle})
	NS.Application.sharedApplication()->setActivationPolicy(.Accessory)
}
