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
        guard let sd = saveDialog, let kit = kit else { return [] }
        let (ox, oy) = saveOrigin
        return quads(FileDialogView.items(kit, save: sd.mode == .save, files: sd.files, scroll: sd.scroll, selected: sd.selected, name: sd.name, ox: ox, oy: oy))
    }

    /// A click while the dialog is open (canvas coordinates); returns true when it was open.
    func saveDialogClick(x: Float, y: Float, double: Bool) -> Bool {
        guard var sd = saveDialog, let kit = kit else { return false }
        let (ox, oy) = saveOrigin
        switch FileDialogView.hit(kit, save: sd.mode == .save, files: sd.files.count, scroll: sd.scroll, ox: ox, oy: oy, x, y) {
        case .cancel: saveDialog = nil; sound?.play("miscellaneous.button")
        case .ok: sound?.play("miscellaneous.button"); confirmSaveDialog()
        case .row(let k):
            sd.selected = k
            if sd.mode == .save { sd.name = sd.files[k].name }
            saveDialog = sd
            if double { confirmSaveDialog() }
        case .scroll(let d):
            sd.scroll = max(0, min(max(0, sd.files.count - 11), sd.scroll + d))
            saveDialog = sd
        case .none: break
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
