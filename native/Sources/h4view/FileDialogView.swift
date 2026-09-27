import Foundation
import H4Engine

/// The save / load file dialog (menus_spec D1; base ctor 0x6af000): the Background, Cancel and
/// Save / Load large buttons at their locations' top-left, eleven row toggles at the `line NN`
/// top-lefts (the name in Prose_Antique 30 left in file_name, the time centred in file_time, black
/// with the halo; the selected row two translucent blue boxes with white text and a black halo),
/// the scrollbar at scrollbar_location, the title in 34, the save dialog's edit box in 30.
/// Shared by the adventure screen and the main menu's Load Game.
enum FileDialogView {
    enum Hit { case none, cancel, ok, row(Int), scroll(Int) }
    static func layout(_ kit: MenuKit, save: Bool) -> LayerFile? { kit.file(save ? "dialog.save_game" : "dialog.load_game") }
    /// "%x %I:%M %p", e.g. "09/27/26 03:45 PM".
    static let timeFormat: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MM/dd/yy hh:mm a"; return f
    }()

    static func items(_ kit: MenuKit, save: Bool, files: [(name: String, date: Date)], scroll: Int, selected: Int?, name: String, ox: Int, oy: Int) -> [UIItem] {
        guard let d = layout(kit, save: save) else { return [] }
        func l(_ n: String) -> UILayer? { MenuKit.find(d, n) }
        var out = kit.image(l("Background"), save ? "save_game" : "load_game", ox, oy)
        if let c = l("cancel_location") { out += kit.largeButton(kit.t("cancel", "Cancel"), ox + c.x, oy + c.y, .released) }
        if let first = l("line 01"), let fn = l("file_name"), let ft = l("file_time") {
            let n = UIRect(fn.x - first.x, fn.y - first.y, fn.width, fn.height), tm = UIRect(ft.x - first.x, ft.y - first.y, ft.width, ft.height)
            for row in 0..<11 {
                let k = scroll + row
                guard k < files.count, let line = l(String(format: "line %02d", row + 1)) else { continue }
                let rx = ox + line.x, ry = oy + line.y
                let time = timeFormat.string(from: files[k].date)
                let nr = n.offset(rx, ry), tr = tm.offset(rx, ry)
                if selected == k {
                    out += kit.fill(nr) + kit.text(files[k].name, nr, MenuKit.Style(nr.h, colour: (255, 255, 255), halo: (0, 0, 0)))
                    out += kit.fill(tr) + kit.text(time, tr, MenuKit.Style(tr.h, colour: (255, 255, 255), halo: (0, 0, 0), just: 1))
                } else {
                    out += kit.text(files[k].name, nr, MenuKit.Style(nr.h))
                    out += kit.text(time, tr, MenuKit.Style(tr.h, just: 1))
                }
            }
        }
        if let s = l("scrollbar_location") { out += kit.vScrollbar(ox + s.x, oy + s.y, s.height, first: scroll, visible: 11, total: files.count) }
        if let b = l(save ? "save_location" : "load_location") {
            out += kit.largeButton(save ? kit.t("Save.dialog", "Save") : kit.t("load.dialog", "Load"), ox + b.x, oy + b.y, .released)
        }
        if let tl = l("title") { out += kit.text(save ? kit.t("save_game.dialog", "Save Game") : kit.t("load_game.dialog", "Load Game"), UIRect(tl, ox, oy), MenuKit.Style(tl.height, just: 1), clip: false) }
        if save, let e = l("edit_box") {
            let caret = Int(Date().timeIntervalSince1970 * 2) % 2 == 0 ? "|" : ""
            out += kit.text(name + caret, UIRect(e, ox, oy), MenuKit.Style(e.height))
        }
        return out
    }

    static func hit(_ kit: MenuKit, save: Bool, files: Int, scroll: Int, ox: Int, oy: Int, _ x: Float, _ y: Float) -> Hit {
        guard let d = layout(kit, save: save) else { return .none }
        func inside(_ n: String) -> Bool {
            guard let l = MenuKit.find(d, n) else { return false }
            return UIRect(l, ox, oy).contains(x, y)
        }
        if inside("cancel_location") { return .cancel }
        if inside(save ? "save_location" : "load_location") { return .ok }
        if let first = MenuKit.find(d, "line 01"), let ft = MenuKit.find(d, "file_time") {
            for row in 0..<11 where scroll + row < files {
                guard let line = MenuKit.find(d, String(format: "line %02d", row + 1)) else { continue }
                if UIRect(ox + line.x, oy + line.y, ft.x + ft.width - first.x, line.height).contains(x, y) { return .row(scroll + row) }
            }
        }
        if let s = MenuKit.find(d, "scrollbar_location"), let dir = kit.vScrollbarHit(ox + s.x, oy + s.y, s.height, x, y) { return .scroll(dir) }
        return .none
    }
}
