import Foundation
import AppKit
import H4Engine

/// Saving and loading (layers.dialog.save_game / load_game): eleven file lines with name and
/// time, the name being typed in the save dialog's edit box, Save / Load and Cancel. Games are
/// kept as .h4s files in ~/Library/Application Support/h4view/Saves; a new day autosaves to
/// "Autosave This Turn" after moving the previous one to "Autosave Last Turn" (the original's
/// names, strings auto_save_this_turn / auto_save_last_turn). Loading starts the game again on
/// the save's map and puts the saved state over it.
struct SaveDialog {
    enum Mode { case save, load }
    var mode: Mode
    var files: [(name: String, date: Date)]
    var selected: Int?
    var name: String
    var scroll = 0
}

extension Renderer {
    static var savesDirectory: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("h4view/Saves")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func savedGames() -> [(name: String, date: Date)] {
        let dir = savesDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "h4s" }.map { url in
            (url.deletingPathExtension().lastPathComponent, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast)
        }.sorted { $0.date > $1.date }
    }

    func openSaveDialog(_ mode: SaveDialog.Mode) {
        guard game != nil, !inCombat else { return }
        saveDialog = SaveDialog(mode: mode, files: Renderer.savedGames(), selected: nil, name: mode == .save ? (game?.map.name ?? "Game") : "")
    }

    /// Write the game to a named save.
    func save(as name: String) {
        guard let g = game, let path = mapPath else { return }
        let file = Renderer.savesDirectory.appendingPathComponent("\(name).h4s")
        do { try g.snapshot(mapPath: path).write(to: file) } catch { g.log.append("Could not save \(name): \(error.localizedDescription)") }
    }
    /// A new day: the previous autosave becomes "last turn", this one "this turn".
    func autosave() {
        guard let g = game else { return }
        let this = g.tables?.strings["auto_save_this_turn.misc"].map { ($0 as NSString).deletingPathExtension } ?? "Autosave This Turn"
        let last = g.tables?.strings["auto_save_last_turn.misc"].map { ($0 as NSString).deletingPathExtension } ?? "Autosave Last Turn"
        let dir = Renderer.savesDirectory
        let a = dir.appendingPathComponent("\(this).h4s"), b = dir.appendingPathComponent("\(last).h4s")
        if FileManager.default.fileExists(atPath: a.path) { try? FileManager.default.removeItem(at: b); try? FileManager.default.moveItem(at: a, to: b) }
        save(as: this)
    }
    /// Load: start the game again on the save's map with the save laid over it.
    func load(_ name: String) {
        let file = Renderer.savesDirectory.appendingPathComponent("\(name).h4s")
        guard let s = try? SaveGame.read(file), let archive = archivePath else { return }
        let app = Bundle.main.bundleURL
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.arguments = [archive, s.mapPath, "--load", file.path]
        cfg.createsNewApplicationInstance = true
        if app.pathExtension == "app" {
            NSWorkspace.shared.openApplication(at: app, configuration: cfg) { _, _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
        } else {   // run from the build folder: start the executable itself
            let p = Process(); p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); p.arguments = cfg.arguments
            try? p.run(); NSApp.terminate(nil)
        }
    }

    var saveOrigin: (Int, Int) { ((AdventureUI.width - 799) / 2, (AdventureUI.height - 598) / 2) }

    func saveDialogQuads() -> [Quad] {
        guard let sd = saveDialog, let ui = ui, let d = ui.dialog(sd.mode == .save ? "save_game" : "load_game") else { return [] }
        let (ox, oy) = saveOrigin
        var out = dialogImages(d, key: sd.mode == .save ? "save" : "load", at: ox, oy)
        let strings = game?.tables?.strings ?? [:]
        out += centred(sd.mode == .save ? strings["save_game.dialog"] ?? "Save Game" : strings["load_game.dialog"] ?? "Load Game", in: d["title"], at: ox, oy, font: ui.font(22))
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm"
        for row in 0..<11 {
            let k = sd.scroll + row
            guard k < sd.files.count, let line = d[String(format: "line %02d", row + 1)], let nameSlot = d["file_name"], let timeSlot = d["file_time"] else { continue }
            let y = oy + line.y
            if sd.selected == k { out.append(Quad(texture: shade, x: ox + nameSlot.x, y: y, w: timeSlot.x + timeSlot.width - nameSlot.x, h: line.height)) }
            let colour: (UInt8, UInt8, UInt8) = sd.selected == k ? (255, 236, 160) : (40, 24, 8)
            let f = sd.files[k]
            out.append(Quad(texture: uiTexture("savename|\(f.name)|\(colour.0)", { ui.dateFont.render(f.name, colour: colour) }), x: ox + nameSlot.x + 36, y: y + (line.height - ui.dateFont.size) / 2, w: ui.dateFont.measure(f.name), h: ui.dateFont.size))
            let t = fmt.string(from: f.date)
            out.append(Quad(texture: uiTexture("savetime|\(t)|\(colour.0)", { ui.dateFont.render(t, colour: colour) }), x: ox + timeSlot.x + 8, y: y + (line.height - ui.dateFont.size) / 2, w: ui.dateFont.measure(t), h: ui.dateFont.size))
        }
        if sd.mode == .save, let box = d["edit_box"] {
            let text = sd.name + (Int(Date().timeIntervalSince1970 * 2) % 2 == 0 ? "|" : "")
            out.append(Quad(texture: uiTexture("saveedit|\(text)", { ui.dateFont.render(text, colour: (40, 24, 8)) }), x: ox + box.x + 8, y: oy + box.y + (box.height - ui.dateFont.size) / 2, w: ui.dateFont.measure(text), h: ui.dateFont.size))
        }
        // OK (save / load) and Cancel: the game's check and cross buttons in their places
        for (slot, btn) in [(sd.mode == .save ? "save_location" : "load_location", "ok"), ("cancel_location", "cancel")] {
            guard let l = d[slot], let b = ui.button(btn) else { continue }
            out.append(Quad(texture: uiTexture("button|\(btn)|Released", { b.bitmap }), x: ox + l.x + (l.width - b.width) / 2, y: oy + l.y + (l.height - b.height) / 2, w: b.width, h: b.height))
        }
        return out
    }

    /// A click while the dialog is open (canvas coordinates); returns true when it was open.
    func saveDialogClick(x: Float, y: Float, double: Bool) -> Bool {
        guard var sd = saveDialog, let ui = ui, let d = ui.dialog(sd.mode == .save ? "save_game" : "load_game") else { return false }
        let (ox, oy) = saveOrigin
        func inside(_ n: String) -> Bool {
            guard let l = d[n] else { return false }
            return x >= Float(ox + l.x) && x < Float(ox + l.x + l.width) && y >= Float(oy + l.y) && y < Float(oy + l.y + l.height)
        }
        if inside("cancel_location") { saveDialog = nil; sound?.play("miscellaneous.button"); return true }
        if inside(sd.mode == .save ? "save_location" : "load_location") { sound?.play("miscellaneous.button"); confirmSaveDialog(); return true }
        if let nameSlot = d["file_name"], let timeSlot = d["file_time"] {
            for row in 0..<11 {
                guard let line = d[String(format: "line %02d", row + 1)] else { continue }
                let k = sd.scroll + row
                if k < sd.files.count, x >= Float(ox + nameSlot.x), x < Float(ox + timeSlot.x + timeSlot.width), y >= Float(oy + line.y), y < Float(oy + line.y + line.height) {
                    sd.selected = k
                    if sd.mode == .save { sd.name = sd.files[k].name }
                    saveDialog = sd
                    if double { confirmSaveDialog() }
                    return true
                }
            }
        }
        if inside("scrollbar_location"), let bar = d["scrollbar_location"] {
            let up = y < Float(oy + bar.y + bar.height / 2)
            sd.scroll = max(0, min(max(0, sd.files.count - 11), sd.scroll + (up ? -1 : 1)))
            saveDialog = sd
        }
        return true
    }

    func confirmSaveDialog() {
        guard let sd = saveDialog else { return }
        switch sd.mode {
        case .save:
            let name = sd.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            if sd.files.contains(where: { $0.name == name }) {
                let q = (game?.tables?.strings["overwrite.dialog"] ?? "Overwrite %file_name?").replacingOccurrences(of: "%file_name", with: name)
                saveDialog = nil
                prompt = (q, true, { [weak self] in self?.save(as: name) })
            } else { save(as: name); saveDialog = nil }
        case .load:
            guard let k = sd.selected, k < sd.files.count else { return }
            saveDialog = nil
            load(sd.files[k].name)
        }
    }

    /// Typing in the save dialog's edit box.
    func saveDialogKey(_ e: NSEvent) -> Bool {
        guard var sd = saveDialog else { return false }
        switch e.keyCode {
        case 53: saveDialog = nil
        case 36, 76: confirmSaveDialog()
        case 51: if sd.mode == .save, !sd.name.isEmpty { sd.name.removeLast(); saveDialog = sd }
        default:
            if sd.mode == .save, let chars = e.characters, sd.name.count < 40 {
                let ok = chars.filter { $0.isLetter || $0.isNumber || " -_'.".contains($0) }
                if !ok.isEmpty { sd.name += ok; saveDialog = sd }
            }
        }
        return true
    }
}

extension Renderer {
    /// The scenario is over (campaign_spec §2.5): a won campaign scenario hands its heroes on and goes
    /// to the epilogue and the next scenario's screen; anything else back to the main menu.
    func scenarioOver(won: Bool) {
        guard let g = game else { return }
        let text = won ? (g.map.victoryText ?? g.tables?.strings["victory.misc"] ?? "Victory!") : (g.map.lossText ?? g.tables?.strings["defeat.misc"] ?? "You have been defeated.")
        prompt = (text, false, { [weak self] in
            guard let self = self, let archive = self.archivePath else { NSApp.terminate(nil); return }
            var menuArgs = ["--menu"]
            if won, let c = g.campaign {
                let file = Renderer.savesDirectory.deletingLastPathComponent().appendingPathComponent("carryover.json")
                if let d = try? JSONEncoder().encode(g.carryOut()) { try? d.write(to: file) }
                menuArgs += ["--next", "\(c.id)", "\(c.index)", "--carry", file.path]
            }
            self.relaunch([archive] + menuArgs)
        })
    }
    /// Start this program again with other arguments (a new game, the menu).
    func relaunch(_ all: [String]) {
        let app = Bundle.main.bundleURL
        if app.pathExtension == "app" {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.arguments = all; cfg.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: app, configuration: cfg) { _, _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
        } else {
            let p = Process(); p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); p.arguments = all
            try? p.run(); NSApp.terminate(nil)
        }
    }
}
