import Foundation

/// The click of heroes4.exe's buttons (sound.miscellaneous.button, dialogue sound 0x1f; table 0x5022a0,
/// played through 0x85e300 / 0x85cff0). Only the button classes play it, each from its own handlers:
/// * t_button (vtable 0x97e0a4; t_menu_button and t_scrollbar_button inherit it): the left press
///   0x5a0dd0 (slot 0x24), when the button is neither down (+0x138) nor disabled (+0xe4), before its
///   press handler (+0xd0); a double click (0x5a0f50) presses again. The release 0x5a0ee0 runs the
///   click handler (+0xcc) without a sound. A hot key in its key list (+0x128, matched by 0x7d2a60:
///   Enter / Esc on every OK / Cancel, end_turn, defend, wait, ...) plays it too, then clicks (0x5a0c00).
/// * t_toggle_button (0x995c9c): the press 0x88d0b0 and its hot key 0x88cef0, when enabled, not locked
///   (+0x178), and not a stay-down button (+0x179) that is down already.
/// * t_scrollbar's arrows: their press handlers 0x83b2e0 / 0x83b410 step and play it once more, on
///   top of the t_button press (one click heard).
/// * Silent: disabled buttons, the right button (0x721860), t_blacksmith_button (0x59e610 / 0x59e650),
///   keys the screens take themselves (the map's 0x4bd536, the town's 0x8b8160, the combat grid
///   toggle), and everything that is not a button (t_scroll_menu rows, lists, rings, portraits, the map).
/// The screens are drawn afresh each frame: a button's pictures carry `.button`, a modal window's
/// pictures `.modal` (nothing drawn before them takes a press), a non-modal window's `.window` (it
/// hides what is under it). A press clicks when the topmost button under it is enabled and no
/// window drawn after that button is under it.
enum PressRole: Equatable {
    /// A button's picture; false when the button is disabled.
    case button(Bool)
    /// A window over what was drawn before it, where it is (the scroll menu).
    case window
    /// A modal window: nothing drawn before it takes a press.
    case modal
}

struct PressTarget {
    var x: Int, y: Int, w: Int, h: Int
    var role: PressRole
    func contains(_ px: Float, _ py: Float) -> Bool { px >= Float(x) && px < Float(x + w) && py >= Float(y) && py < Float(y + h) }

    /// The targets of one frame's pictures, bottom to top: a modal window drops everything before it.
    static func collect<S: Sequence>(_ pictures: S) -> [PressTarget] where S.Element == (x: Int, y: Int, w: Int, h: Int, role: PressRole?) {
        var out: [PressTarget] = []
        for p in pictures {
            guard let r = p.role else { continue }
            if r == .modal { out.removeAll(); continue }
            if p.w > 0 && p.h > 0 { out.append(PressTarget(x: p.x, y: p.y, w: p.w, h: p.h, role: r)) }
        }
        return out
    }
    /// Whether a left press at (x, y) clicks.
    static func clicks(_ targets: [PressTarget], _ x: Float, _ y: Float) -> Bool {
        guard let top = targets.last(where: { $0.contains(x, y) }) else { return false }
        return top.role == .button(true)
    }
}

extension Array where Element == Quad {
    /// These pictures are a button's (a disabled one is silent).
    func button(_ enabled: Bool = true) -> [Quad] { map { var q = $0; q.press = .button(enabled); return q } }
    /// These pictures are a modal window's: its first one shuts out what was drawn before (an empty window adds nothing).
    func modal() -> [Quad] {
        guard var first = first else { return self }
        first.press = .modal; first.w = 0; first.h = 0; first.alpha = 0
        return [first] + self
    }
    /// These pictures are a window over what was drawn before, where they are.
    func window() -> [Quad] { map { var q = $0; if q.press == nil { q.press = .window }; return q } }
}
extension Array where Element == UIItem {
    func button(_ enabled: Bool = true) -> [UIItem] { map { var it = $0; it.press = .button(enabled); return it } }
    func window() -> [UIItem] { map { var it = $0; if it.press == nil { it.press = .window }; return it } }
}

extension Renderer {
    /// A button state's name: only Disabled is silent.
    static func enabledState(_ state: String) -> Bool { state.lowercased() != "disabled" }
    /// This frame's buttons and windows (the screen chrome, `uiList`).
    func collectPressTargets(_ list: [Quad]) {
        pressTargets = PressTarget.collect(list.lazy.map { ($0.x, $0.y, $0.w, $0.h, $0.press) })
    }
    /// A left press: the button click when it lands on an enabled button drawn last frame (0x5a0dd0).
    func pressSound(x: Float, y: Float) {
        if PressTarget.clicks(pressTargets, x, y) { buttonClick() }
    }
    /// The click itself, also for a button's hot key (0x5a0c00, 0x88cef0).
    func buttonClick() { sound?.play("miscellaneous.button") }
}
