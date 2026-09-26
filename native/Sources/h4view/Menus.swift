import Foundation
import AppKit
import H4Engine

/// The adventure panel's menus (System menu, Game menu): a list of the game's entries in the
/// generic dialog frame beside the panel; a click on an entry runs it, anywhere else closes it.
struct PopupMenu {
    var items: [(title: String, action: () -> Void)]
    var x: Int, y: Int
    static let lineHeight = 26, width = 220
    var height: Int { 40 + items.count * PopupMenu.lineHeight }
}

extension Renderer {

    func openSystemMenu() {
        var items: [(String, () -> Void)] = []
        items.append((text("save_game", "Save Game"), { [weak self] in self?.openSaveDialog(.save) }))
        items.append((text("load_game", "Load Game"), { [weak self] in self?.openSaveDialog(.load) }))
        items.append((text("options.main_menu", "Options"), { [weak self] in guard let self = self else { return }; self.optionsOpen = self.settings }))
        items.append((text("restart_game", "Restart Scenario"), { [weak self] in self?.restartScenario() }))
        items.append((text("quit", "Quit"), { NSApp.terminate(nil) }))
        menu = PopupMenu(items: items, x: AdventureUI.mapViewportWidth - PopupMenu.width - 8, y: 20)
    }
    func openGameMenu() {
        var items: [(String, () -> Void)] = []
        items.append((text("scenario_info", "Scenario Info"), { [weak self] in self?.showScenarioInfo() }))
        menu = PopupMenu(items: items, x: AdventureUI.mapViewportWidth - PopupMenu.width - 8, y: 64)
    }
    func showScenarioInfo() {
        guard let g = game else { return }
        var t = g.map.name
        if !g.map.description.isEmpty { t += "\n\n" + g.map.description }
        prompt = (t, false, nil)
    }
    /// Start the scenario again from its beginning (the same way loading does).
    func restartScenario() {
        guard let archive = archivePath, let map = mapPath else { return }
        prompt = ("Restart this scenario?  Your current game will be lost.", true, {
            let cfg = NSWorkspace.OpenConfiguration(); cfg.arguments = [archive, map]; cfg.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
        })
    }

    func menuQuads() -> [Quad] {
        guard let m = menu, let ui = ui else { return [] }
        var out = frameQuads(x: m.x, y: m.y, w: PopupMenu.width, h: m.height)
        for (i, item) in m.items.enumerated() {
            let w = ui.dateFont.measure(item.title)
            out.append(Quad(texture: uiTexture("menu|\(item.title)", { ui.dateFont.render(item.title, colour: (40, 24, 8)) }),
                            x: m.x + (PopupMenu.width - w) / 2, y: m.y + 22 + i * PopupMenu.lineHeight, w: w, h: ui.dateFont.size))
        }
        return out
    }
    /// A click while a menu is open: runs the entry under it, or closes the menu. True when one was open.
    func menuClick(x: Float, y: Float) -> Bool {
        guard let m = menu else { return false }
        menu = nil
        let row = (Int(y) - m.y - 18) / PopupMenu.lineHeight
        if x >= Float(m.x), x < Float(m.x + PopupMenu.width), row >= 0, row < m.items.count, Int(y) >= m.y + 18 {
            sound?.play("miscellaneous.button")
            m.items[row].action()
        }
        return true
    }
}
