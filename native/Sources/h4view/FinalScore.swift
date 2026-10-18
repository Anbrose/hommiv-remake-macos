import AppKit
import H4Engine

/// Where the high-score lists are kept (the game's data\high_scores.dat, here beside the saves).
func highScoresURL() -> URL {
    Renderer.savesDirectory.deletingLastPathComponent().appendingPathComponent("high_scores.dat")
}

/// The built-in lists with the creature ranks of a rule table.
func defaultHighScores(_ t: RuleTables?) -> HighScores {
    HighScores.defaults(strings: t?.strings ?? [:]) { score in
        ScenarioScore.rank(score: score, scale: 1000) { id in t?.creature(RuleTables.creatureIds[id])?.experience ?? 0 }
    }
}

/// The Final Score dialog after a won single scenario (t_score_dialog, ctor 0x6f4bf0, init 0x6f7bc0,
/// layers.dialog.win; re/end_sequence_spec.md §8): the nine categories with their icons, the map's
/// and the player's difficulty, the best hero, the total, the rank creature and the name to enter
/// ("Cheater", not editable, after a cheat). Close (0x6f51d0) enters the result into the standard
/// list; if it makes the list the High Score dialog follows, otherwise the main menu.
final class FinalScoreDialog {
    let score: ScenarioScore
    let cheated: Bool
    let mapName: String
    var name: String
    let townAlignment: String
    init(score: ScenarioScore, cheated: Bool, mapName: String, name: String, townAlignment: String) {
        self.score = score; self.cheated = cheated; self.mapName = mapName; self.name = name; self.townAlignment = townAlignment
    }
}

extension Renderer {
    static let scoreDifficultyKeys = ["easy", "normal", "hard", "expert", "impossible"]
    static let scoreDifficultyNames = ["Novice", "Intermediate", "Advanced", "Expert", "Champion"]

    func openFinalScore(_ g: GameState) {
        let s = g.scenarioScore(team: g.winningTeam ?? g.team(of: g.map.humanColour))
        let me = g.map.humanColour
        let align = g.towns.first { g.townOwner($0) == me }?.alignment
            ?? g.heroes.first?.alignment ?? "life"
        finalScore = FinalScoreDialog(score: s, cheated: g.cheated, mapName: g.map.name,
                                      name: text("player.new_game", "Player"), townAlignment: align)
    }

    var finalScoreOrigin: (Int, Int) { ((1024 - 800) / 2, (768 - 600) / 2) }

    func finalScoreQuads() -> [Quad] {
        guard let fs = finalScore, let ui = ui, let d = ui.dialog("win") else { return [] }
        let (ox, oy) = finalScoreOrigin
        var out: [Quad] = []
        func img(_ n: String) { if let l = layer(d, n) { out.append(image(l, key: "dlg|win|\(n)", ox + l.x, oy + l.y)) } }
        func txt(_ s: String, _ n: String, lines: Int = 1, centre: Bool = true, halo: RGB? = nil) {
            guard let l = layer(d, n) else { return }
            out += textWindow(s, in: l, ox, oy, font: proseFont(max(9, min(20, l.height / lines))), centre: centre, vcentre: true, halo: halo)
        }
        img("Background")
        txt(text("title.score", "Final Score"), "Title", halo: (200, 200, 200))
        let s = fs.score
        let t = { (k: String, fb: String) in self.text(k, fb) }
        // the icons: the categories' own pictures, the difficulties from icons.difficulty_60
        for n in ["Time", "Battles_Won", "Army_Size", "Wealth", "Quests", "Artifacts", "Exploration"] { img(n) }
        if let slot = layer(d, "Map_Difficulty"), let ic = ui.dialogIcon("difficulty_60", Renderer.difficultyLayers[min(4, max(0, s.mapDifficulty))]) {
            out.append(image(ic, key: "icons.difficulty_60|\(ic.name)", ox + slot.x, oy + slot.y))
        }
        if let slot = layer(d, "Player_Difficulty"), let ic = ui.dialogIcon("difficulty_60", Renderer.difficultyLayers[min(4, max(0, s.playerDifficulty))]) {
            out.append(image(ic, key: "icons.difficulty_60|\(ic.name)", ox + slot.x, oy + slot.y))
        }
        img("\(fs.townAlignment.capitalized)_Town")
        if let slot = layer(d, "Hero_Portrait"), !s.heroKeyword.isEmpty, let p = ui.portrait(keyword: s.heroKeyword, alignment: s.heroAlignment) {
            out.append(image(p, key: "icon|\(p.name)", ox + slot.x, oy + slot.y))
        }
        img("Hero_Frame")
        if let slot = layer(d, "Rank_Icon"), s.rank < RuleTables.creatureIds.count, let p = ui.creatureIcon(RuleTables.creatureIds[s.rank]) {
            out.append(image(p, key: "cicon52|\(p.name)", ox + slot.x, oy + slot.y))
        }
        img("Rank_Frame")
        // the titles and the values (0x6f6530)
        let dn = { (k: Int) in t("\(Renderer.scoreDifficultyKeys[min(4, max(0, k))]).score", Renderer.scoreDifficultyNames[min(4, max(0, k))]) }
        let rows: [(String, String, String, String)] = [
            ("Player_Difficulty", t("player_difficulty_title.score", "Difficulty"), "\(dn(s.playerDifficulty))\n\(s.difficultyBase)%", ""),
            ("Map_Difficulty", t("map_difficulty_title.score", "Map Difficulty"), "\(dn(s.mapDifficulty))\n\(s.mapPercent)%", ""),
            ("Time", t("time_title.score", "Time Taken"), "\(t("week.score", "Week")) \(s.days / 7 + 1)\n\(s.timeScore)", ""),
            ("Battles_Won", t("battles_won_title.score", "Battles Won"), "\(t("battle_won.score", "Won")) \(s.battlesWon)\n\(s.battleScore)", ""),
            ("Army_Size", t("army_size_title.score", "Army Value"), "\(t("army_value.score", "Value")) \(s.armyValue)\n\(s.armyScore)", ""),
            ("Wealth", t("wealth_title.score", "Wealth"), "\(t("gold_value.score", "Gold")) \(s.wealth)\n\(s.wealthScore)", ""),
            ("Quests", t("quests_title.score", "Quests"), "\(t("quests_completed.score", "Completed")) \(s.quests)\n\(s.questScore)", ""),
            ("Artifacts", t("artifacts_title.score", "Artifacts"), "\(t("artifacts_collected.score", "Collected")) \(s.artifacts)\n\(s.artifactScore)", ""),
            ("Exploration", t("exploration_title.score", "Exploration"), "\(Int(s.explored * 100)) \(t("explored.score", "% Explored"))\n\(s.exploreScore)", ""),
            ("Hero", t("hero_title.score", "Best Hero"), "\(s.heroName)\n\(s.heroScore)", ""),
            ("Town", t("town_title.score", "Towns"), "\(t("towns_owned.score", "Owned")) \(s.towns)\n\(s.townScore)", "")]
        for (n, title, value, _) in rows {
            txt(title, "\(n)_Title")
            txt(value, "\(n)_Text", lines: 2)
        }
        txt("\(t("total.score", "Total")): \(s.total)", "Score", centre: false)
        let rankName = s.rank < RuleTables.creatureIds.count ? (game?.tables?.creature(RuleTables.creatureIds[s.rank])?.name ?? RuleTables.creatureIds[s.rank].capitalized) : ""
        txt("\(t("rank.score", "Rank")): \(rankName)", "Rank", centre: false)
        txt("\(t("name.score", "Name")):", "Name", centre: false)
        // the name: an edit box with a caret, or "Cheater"
        txt(fs.cheated ? t("cheater.misc", "Cheater") : fs.name + (Int(Date().timeIntervalSinceReferenceDate * 2) % 2 == 0 ? "|" : " "), "Player", centre: false)
        out += buttonAt("close", "released", layer(d, "Close_Button"), ox, oy)
        return out
    }

    /// Close (0x6f51d0): the result goes into the standard list; a place there opens the High
    /// Score dialog (in the menu, the new entry's name still editable), else the main menu.
    func closeFinalScore() {
        guard let fs = finalScore else { return }
        finalScore = nil
        let url = highScoresURL()
        var table = HighScores.load(url) { defaultHighScores(game?.tables) }
        let name = fs.cheated ? text("cheater.misc", "Cheater") : fs.name
        guard let k = table.insert(map: fs.mapName, days: fs.score.days, score: fs.score.total, name: name, standard: true, rank: fs.score.rank) else {
            leaveToMainMenu(); return
        }
        if !table.save(url) { NSLog("%@", text("high_score_save_problem.misc", "There was a problem saving your high score.")) }
        guard let archive = archivePath else { NSApp.terminate(nil); return }
        relaunch([archive, "--menu", "--high-score", "standard", "\(k)"])
    }

    /// The press and key handling of the window and of the score dialog after it.
    func endGameClick(_ e: NSEvent, in v: NSView) -> Bool {
        if finalScore != nil {
            let p = v.convert(e.locationInWindow, from: nil)
            let scale = Float(v.window?.backingScaleFactor ?? 1)
            let x = Int(Float(p.x) * scale / uiScale), y = Int(Float(v.bounds.height - p.y) * scale / uiScale)
            let (ox, oy) = finalScoreOrigin
            if let d = ui?.dialog("win"), let b = layer(d, "Close_Button"),
               x >= ox + b.x, x < ox + b.x + b.width, y >= oy + b.y, y < oy + b.y + b.height { closeFinalScore() }
            return true
        }
        return skipEndGame()
    }
    func endGameKey(_ e: NSEvent) -> Bool {
        if let fs = finalScore {
            switch e.keyCode {
            case 36, 76: closeFinalScore()
            case 51: if !fs.cheated, !fs.name.isEmpty { fs.name.removeLast() }
            default:
                if !fs.cheated, let c = e.characters, fs.name.count < 31 {
                    fs.name += c.filter { $0.isLetter || $0.isNumber || " -_'.!".contains($0) }
                }
            }
            return true
        }
        return skipEndGame()
    }
}
