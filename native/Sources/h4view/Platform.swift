import Foundation
import CoreGraphics
#if os(macOS)
import AppKit
/// The view class the screens draw into (NSView here, UIView on iOS).
typealias PlatformView = NSView
#else
import UIKit
typealias PlatformView = UIView
#endif

/// A press, drag, release or move of the pointer, in the view's own coordinates with the origin
/// at the bottom left (AppKit's convention, which the map view's handlers were written for). The
/// mac builds it from an NSEvent; the iPhone from a touch (iOSApp.swift).
struct PointerEvent {
    struct Modifiers: OptionSet {
        let rawValue: Int
        static let shift = Modifiers(rawValue: 1)
    }
    var location: CGPoint
    /// The movement since the last drag event (points; y grows downward, as NSEvent's).
    var deltaX: CGFloat = 0, deltaY: CGFloat = 0
    var clickCount = 1
    var modifierFlags: Modifiers = []
}

/// The few things the screens ask of the windowing system.
enum Platform {
    /// The game's Quit. On iOS an app does not end itself: a game goes back to the main menu.
    static func quit() {
        #if os(macOS)
        NSApp.terminate(nil)
        #else
        AppController.shared.quitRequested()
        #endif
    }
    /// Hide the pointer while something is carried (the carried picture stands in for it).
    static func hideCursor() {
        #if os(macOS)
        NSCursor.hide()
        #endif
    }
    static func unhideCursor() {
        #if os(macOS)
        NSCursor.unhide()
        #endif
    }
    /// The options dialog's full-screen switch (always full screen on iOS).
    static func toggleFullScreen() {
        #if os(macOS)
        NSApp.keyWindow?.toggleFullScreen(nil)
        #endif
    }
    /// The context of the view being drawn (in draw(_:)).
    static func currentCGContext() -> CGContext? {
        #if os(macOS)
        return NSGraphicsContext.current?.cgContext
        #else
        return UIGraphicsGetCurrentContext()
        #endif
    }
}

#if os(macOS)
extension PointerEvent {
    /// `deltas` and `clicks` only for the events that carry them (NSEvent raises otherwise).
    init(_ e: NSEvent, in v: NSView, deltas: Bool = false, clicks: Bool = false) {
        location = v.convert(e.locationInWindow, from: nil)
        if deltas { deltaX = e.deltaX; deltaY = e.deltaY }
        if clicks { clickCount = e.clickCount }
        if e.modifierFlags.contains(.shift) { modifierFlags.insert(.shift) }
    }
}
#else
extension UIView {
    /// AppKit's redraw flag, for the shared drawing code.
    var needsDisplay: Bool {
        get { false }
        set { if newValue { setNeedsDisplay() } }
    }
}
extension UIWindow {
    /// AppKit's name for the points-to-pixels factor.
    var backingScaleFactor: CGFloat { screen.scale }
}
#endif
