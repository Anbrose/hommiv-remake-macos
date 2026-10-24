import Foundation
import AppKit
import H4Engine

/// The adventure panel's System Menu and Game Menu (menus_spec D3): t_scroll_menus
/// (layers.dialog.scroll_menu, the same pop-up as the main menu's New Game list) opened with their
/// right edge at the pressed button's top-left; a click on an entry runs it, anywhere else closes it.
/// Also the scenario information window (Dialog.scenario_Information, menus_spec C.4).
struct PopupMenu {
    var items: [(title: String, action: () -> Void)]
    /// The pressed button's top-left: the menu's right edge and top.
    var x: Int, y: Int
    var opened = Date()
}

extension Renderer {
    /// The window machinery over the game's archives (updates, x2, then heroes4).
    var kit: MenuKit? {
        guard let ui = ui else { return nil }
        if let k = kitStore { return k }
        let k = MenuKit(archives: ui.overlays.reversed() + [ui.archive], strings: { [weak self] in self?.game?.tables?.strings ?? [:] })
        kitStore = k
        return k
    }
    func quads(_ items: [UIItem]) -> [Quad] {
        items.map { Quad(texture: uiTexture($0.key, $0.make), x: $0.x, y: $0.y, w: $0.w, h: $0.h, press: $0.press) }
    }
    /// The scenario information window, while open.
    static var scenarioInfoOpen = false

    func openSystemMenu() {
        var items: [(String, () -> Void)] = []
        let menuArgs: (String) -> () -> Void = { screen in { [weak self] in guard let self = self, let a = self.archivePath else { return }; self.relaunch([a, "--menu", "--screen", screen]) } }
        items.append((text("new_scenario", "New Scenario"), menuArgs("scenarios")))
        items.append((text("new_campaign", "New Campaign"), menuArgs("campaigns:0")))
        items.append((text("load_game", "Load Game"), { [weak self] in self?.openSaveDialog(.load) }))
        items.append((text("save_game", "Save Game"), { [weak self] in self?.openSaveDialog(.save) }))
        // (Retire is a multiplayer entry: a single-player game has none)
        items.append((text("restart_game", "Restart Game"), { [weak self] in self?.restartScenario() }))
        items.append((text("options", "Game Settings"), { [weak self] in guard let self = self else { return }; self.optionsOpen = self.settings }))
        items.append((text("main_menu", "Main Menu"), { [weak self] in guard let self = self, let a = self.archivePath else { return }; self.relaunch([a, "--menu"]) }))
        items.append((text("quit", "Quit"), { NSApp.terminate(nil) }))
        let b = ui?.hotspot("System_menu_button")
        menu = PopupMenu(items: items, x: b?.x ?? 959, y: b?.y ?? 26)
    }
    func openGameMenu() {
        var items: [(String, () -> Void)] = []
        items.append((text("scenario_information", "Scenario Information"), { Renderer.scenarioInfoOpen = true }))
        items.append((text("kingdom_overview", "Kingdom Overview"), { [weak self] in self?.overview = KingdomOverview() }))
        items.append((text("quests", "Quest Log"), { [weak self] in self?.unavailable("quests", "Quest Log") }))
        items.append((text("marketplace", "Marketplace"), { [weak self] in self?.market = MarketState(k: 3) }))
        items.append((text("thieves_guild", "Thieves Guild"), { [weak self] in self?.thievesGuildOpen = true }))
        items.append((text("trade", "Trade"), { [weak self] in self?.unavailable("trade", "Trade") }))
        items.append((text("view_world", "View World"), { [weak self] in self?.unavailable("view_world", "View World") }))
        items.append((text("view_puzzle", "View Puzzle"), { [weak self] in
            guard let self = self, let g = self.game else { return }
            self.puzzle = Renderer.obeliskColours.first { (g.obeliskVisits[$0] ?? 0) > 0 }
            if self.puzzle == nil { self.prompt = (self.text("no_obelisks_visited.dialog", "You have not visited any obelisks."), false, nil) }
        }))
        items.append((text("dig_treasure", "Dig for Treasure"), { [weak self] in if let g = self?.game, let h = g.heroes.first { g.dig(h) } }))
        items.append((text("view_caravans", "View Caravans"), { [weak self] in self?.openCaravanView(nil) }))
        items.append((text("replay_turn", "Replay Turn"), { [weak self] in self?.unavailable("replay_turn", "Replay Turn") }))
        let b = ui?.hotspot("Game_menu_button")
        menu = PopupMenu(items: items, x: b?.x ?? 963, y: b?.y ?? 71)
    }
    /// An entry this build has no window for yet.
    private func unavailable(_ key: String, _ fallback: String) {
        toasts.append(("\(text(key, fallback)): not available yet", Date().addingTimeInterval(3)))
    }
    /// Start the scenario again from its beginning, with the choices it was started with
    /// (the same way loading does, without the save).
    func restartScenario() {
        guard var all = launchArgs, all.count >= 2 else { return }
        if let k = all.firstIndex(of: "--load"), k + 1 < all.count { all.removeSubrange(k...k + 1) }
        prompt = (text("restart_game.misc", "Are you sure you want to restart?  Your current game will be lost."), true, { [weak self] in self?.relaunch(all) })
    }

    func menuQuads() -> [Quad] {
        var out = scenarioInfoQuads().modal()
        guard let m = menu, let kit = kit else { return out }
        let elapsed = ProcessInfo.processInfo.environment["H4MENU"] != nil ? 10 : Date().timeIntervalSince(m.opened)
        // (a press off the t_scroll_menu closes it and goes on to the window under it: 0x838d40)
        out += quads(kit.scrollMenu(m.items.map { $0.title }, x: m.x, y: m.y, hover: pointerCanvas, elapsed: elapsed).window())
        return out
    }
    /// A click while a menu is open: runs the entry under it, or closes the menu. True when one was open.
    func menuClick(x: Float, y: Float) -> Bool {
        if Renderer.scenarioInfoOpen { scenarioInfoClick(x: x, y: y); return true }
        guard let m = menu else { return false }
        menu = nil
        if let k = kit?.scrollMenuHit(m.items.map { $0.title }, x: m.x, y: m.y, x, y) { m.items[k].action() }   // (a t_scroll_menu row: no click)
        return true
    }

    // MARK: the scenario information window

    var scenarioInfoOrigin: (Int, Int) { ((AdventureUI.width - 732) / 2, (AdventureUI.height - 482) / 2) }
    /// The player's difficulty, as chosen on the new-game screen (--difficulty, default Intermediate).
    var playerDifficulty: Int {
        min(4, max(0, game?.difficulty ?? 1))
    }
    static let difficultyLayers = ["easy", "Normal", "Hard", "expert", "impossible"]

    func scenarioInfoQuads() -> [Quad] {
        guard Renderer.scenarioInfoOpen, let g = game, let kit = kit, let d = kit.file("Dialog.scenario_Information") else { return [] }
        let (ox, oy) = scenarioInfoOrigin
        var out = kit.image(MenuKit.find(d, "Background"), "scenario_information", ox, oy)
        func tx(_ s: String, _ n: String, _ size: Int) {
            guard let l = MenuKit.find(d, n) else { return }
            out += kit.text(s, UIRect(l, ox, oy), MenuKit.Style(size == 0 ? l.height : size, halo: nil, just: 1), clip: false)
        }
        tx(g.map.name, "map_name", 27)
        tx(kit.t("scene_info_description_title.misc", "Map Description"), "map_description_title", 25)
        tx(g.map.description, "map_description", 18)
        tx(kit.t("scene_info_victory_title.misc", "Win Condition"), "victory_title", 25)
        tx(kit.t("scene_info_loss_title.misc", "Loss Condition"), "loss_title", 25)
        tx(kit.t("scene_info_difficulty.misc", "Difficulty"), "difficulty", 25)
        tx(kit.t("scene_info_player_difficulty.misc", "Player"), "player_difficulty_text", 18)
        tx(kit.t("scene_info_map_difficulty.misc", "Map"), "map_difficulty_text", 18)
        tx(kit.t("scene_info_teams.misc", "Teams"), "teams", 25)
        tx(g.map.victoryText ?? kit.t("default_victory_condition", "Be the only player to own towns."), "victory_condition", 18)
        tx(g.map.lossText ?? kit.t("default_loss_condition", "Lose all towns and armies."), "loss_condition", 18)
        let icons = kit.file("icons.difficulty_60")
        for (slot, v) in [("player_Difficulty", playerDifficulty), ("map_Difficulty", min(4, max(0, g.map.difficulty)))] {
            guard let s = MenuKit.find(d, slot) else { continue }
            out += kit.image(MenuKit.find(icons, Renderer.difficultyLayers[v]), "icons.difficulty_60", ox + s.x, oy + s.y)
        }
        // the players' flags with their team numbers (numbered in order of first appearance)
        let flags = kit.file("icons.flags.55")
        var order: [Int] = []
        for p in g.map.playerSpecs { let t = g.map.teams[p.colour] ?? 100 + p.colour; if !order.contains(t) { order.append(t) } }
        for (k, p) in g.map.playerSpecs.prefix(6).enumerated() {
            guard let s = MenuKit.find(d, "Flag_\(k + 1)") else { continue }
            let team = (order.firstIndex(of: g.map.teams[p.colour] ?? 100 + p.colour) ?? 0) + 1
            out += kit.image(MenuKit.find(flags, AdventureUI.playerColourNames[min(5, p.colour)]), "icons.flags.55", ox + s.x, oy + s.y)
            out += kit.image(MenuKit.find(flags, "team_\(min(6, team))"), "icons.flags.55", ox + s.x, oy + s.y)
        }
        if let b = MenuKit.find(d, "Back") {
            out += kit.largeButton(kit.t("scene_info_back.misc", "Okay"), ox + b.x, oy + b.y, .released)
        }
        return quads(out)
    }
    func scenarioInfoClick(x: Float, y: Float) {
        guard let kit = kit, let b = kit.layer("Dialog.scenario_Information", "Back") else { Renderer.scenarioInfoOpen = false; return }
        let (ox, oy) = scenarioInfoOrigin
        if UIRect(ox + b.x, oy + b.y, 166, 40).contains(x, y) { Renderer.scenarioInfoOpen = false }
    }
}
