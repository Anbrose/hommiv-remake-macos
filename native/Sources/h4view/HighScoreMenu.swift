import AppKit
import H4Engine

/// The High Score dialog (t_high_score_dialog 0x6bbf00 / 0x6b9970, layers.dialog.High_Score) and
/// the Campaign Results dialog (t_dialog_campaign_score 0x67de50, layers.dialog.campaign_Score), in
/// the menu (re/end_sequence_spec.md §8). The high scores: five rows of ten (scroll), a tab per
/// list (Standard / Campaign), Reset (with confirm_reset.high_score), Okay; a just-entered result
/// shows first with its name editable, written back and saved on Okay (0x6bb290).
extension MenuView {
    static let highScoreSize = (w: 800, h: 600)

    func openHighScores(standard: Bool, newEntry: Int?) {
        let rules = menuRules
        var t = HighScores.load(highScoresURL()) { defaultHighScores(rules) }
        if let k = newEntry {   // the result just entered: its name editable (+0x4c, not in the file)
            if standard, k < t.standard.count { t.standard[k].isNew = true; highScoreName = t.standard[k].name }
            else if !standard, k < t.campaign.count { t.campaign[k].isNew = true; highScoreName = t.campaign[k].name }
        }
        highScores = t
        highScoreStandard = standard
        highScoreScroll = newEntry.map { min($0, 5) } ?? 0
        confirmingReset = false
        screen = .highScores
    }
    var highScoreList: [HighScores.Entry] { (highScoreStandard ? highScores?.standard : highScores?.campaign) ?? [] }

    func drawHighScores() {
        guard let f = layers("dialog.High_Score") else { return }
        let (ox, oy) = dialogOrigin(MenuView.highScoreSize.w, MenuView.highScoreSize.h)
        func l(_ n: String) -> UILayer? { MenuKit.find(f, n) }
        draw(kit.image(l("Background"), "dialog.High_Score", ox, oy))
        if let t = l("Title_Text") { draw(kit.text(text("title.high_score", "High Score"), UIRect(t, ox, oy), MenuKit.Style(min(t.height, 24), just: 1, vcentre: true))) }
        let list = highScoreList
        guard let p1 = l("Position_1") else { return }
        for row in 0..<5 {
            let k = highScoreScroll + row
            guard k < list.count, let pr = l("Position_\(row + 1)") else { continue }
            let e = list[k], dy = pr.y - p1.y
            if let ring = l("Creature_Ring"), let port = l("Creature_Portrait"), e.rank >= 0, e.rank < RuleTables.creatureIds.count,
               let icon = MenuKit.find(layers("icons.creatures.52"), RuleTables.creatureIds[e.rank]) {
                draw(kit.imageAt(icon, "icons.creatures.52", ox + port.x, oy + port.y + dy))
                draw(kit.image(ring, "dialog.High_Score", ox, oy + dy))
            }
            func cell(_ s: String, _ n: String, just: Int = 0) {
                guard let b = l(n) else { return }
                draw(kit.text(s, UIRect(ox + b.x, oy + b.y + dy, b.width, b.height), MenuKit.Style(min(b.height - 6, 20), just: just, vcentre: true)))
            }
            cell("\(k + 1)", "Rank_Text", just: 1)
            cell(text("days.high_score", "Days") + ": " + e.days, "Days_Text")
            cell(text("score.high_score", "Score") + ": " + e.score, "Score_Text")
            cell(e.isNew ? highScoreName + (Int(Date().timeIntervalSinceReferenceDate * 2) % 2 == 0 ? "|" : " ") : e.name, "Player_Text")
            cell(e.map, "Map_Text")
        }
        if let s = l("Scrollbar") { draw(kit.vScrollbar(ox + s.x, oy + s.y, s.height, first: highScoreScroll, visible: 5, total: list.count)) }
        largeButton(text("reset.high_score", "Reset"), l("Reset_Button"), ox, oy)
        largeButton(text("standard.high_score", "Standard"), l("Standard_Button"), ox, oy, enabled: !highScoreStandard)
        largeButton(text("campaign.high_score", "Campaign"), l("Campaign_Button"), ox, oy, enabled: highScoreStandard)
        if let ok = l("OK_Button") { draw(kit.button("ok", look(UIRect(ox + ok.x, oy + ok.y, 76, 44)), ox + ok.x, oy + ok.y)) }
        if confirmingReset { drawConfirmReset() }
    }

    /// confirm_reset.high_score as a yes / no box (0x844ec0) over the dialog.
    var confirmBox: (r: UIRect, yes: UIRect, no: UIRect) {
        let w = 420, h = 150, x = (1024 - w) / 2, y = (768 - h) / 2
        return (UIRect(x, y, w, h), UIRect(x + w / 2 - 166 - 8, y + h - 52, 166, 40), UIRect(x + w / 2 + 8, y + h - 52, 166, 40))
    }
    func drawConfirmReset() {
        let b = confirmBox
        draw(kit.fill(b.r, (40, 30, 10), level: 13))
        draw(kit.text(text("confirm_reset.high_score", "Reset high scores to defaults?"), UIRect(b.r.x + 16, b.r.y + 16, b.r.w - 32, 60), MenuKit.Style(18, colour: (255, 255, 255), just: 1, vcentre: true)))
        draw(kit.largeButton(text("yes.dialog", "Yes"), b.yes.x, b.yes.y, look(b.yes)))
        draw(kit.largeButton(text("no.dialog", "No"), b.no.x, b.no.y, look(b.no)))
    }

    func clickHighScores(_ x: Float, _ y: Float) {
        if confirmingReset {
            let b = confirmBox
            if b.yes.contains(x, y) {   // 0x6bb300: the defaults, saved, shown
                let t = defaultHighScores(menuRules)
                t.save(highScoresURL())
                highScores = t; highScoreScroll = 0; confirmingReset = false
            } else if b.no.contains(x, y) { confirmingReset = false }
            return
        }
        guard let f = layers("dialog.High_Score") else { return }
        let (ox, oy) = dialogOrigin(MenuView.highScoreSize.w, MenuView.highScoreSize.h)
        func l(_ n: String) -> UILayer? { MenuKit.find(f, n) }
        if hit(l("Reset_Button"), ox, oy, x, y, w: 166, h: 40) { confirmingReset = true; return }
        if hit(l("Standard_Button"), ox, oy, x, y, w: 166, h: 40), !highScoreStandard { commitHighScoreName(); highScoreStandard = true; highScoreScroll = 0; return }
        if hit(l("Campaign_Button"), ox, oy, x, y, w: 166, h: 40), highScoreStandard { commitHighScoreName(); highScoreStandard = false; highScoreScroll = 0; return }
        if let s = l("Scrollbar"), let d = kit.vScrollbarHit(ox + s.x, oy + s.y, s.height, x, y) {
            highScoreScroll = max(0, min(highScoreList.count - 5, highScoreScroll + d)); return
        }
        if hit(l("OK_Button"), ox, oy, x, y, w: 76, h: 44) { commitHighScoreName(); highScores = nil; screen = .main }
    }
    /// Okay (0x6bb290): the new entry takes the typed name and the lists are saved.
    func commitHighScoreName() {
        guard var t = highScores else { return }
        var changed = false
        for k in t.standard.indices where t.standard[k].isNew { t.standard[k].name = highScoreName; t.standard[k].isNew = false; changed = true }
        for k in t.campaign.indices where t.campaign[k].isNew { t.campaign[k].name = highScoreName; t.campaign[k].isNew = false; changed = true }
        if changed { t.save(highScoresURL()) }
        highScores = t
    }
    func highScoreKey(_ e: NSEvent) -> Bool {
        guard case .highScores = screen else { return false }
        guard highScoreList.contains(where: { $0.isNew }) else { return false }
        switch e.keyCode {
        case 36, 76: commitHighScoreName(); highScores = nil; screen = .main
        case 51: if !highScoreName.isEmpty { highScoreName.removeLast() }
        default:
            if let c = e.characters, highScoreName.count < 31 { highScoreName += c.filter { $0.isLetter || $0.isNumber || " -_'.!".contains($0) } }
        }
        needsDisplay = true
        return true
    }

    // MARK: Campaign Results

    /// The scenarios' scores so far (the carry-over file of the scenario just won).
    func campaignScores(_ carry: String?) -> [CampaignScore] {
        carry.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }.flatMap { try? JSONDecoder().decode(Carryover.self, from: $0) }?.scores ?? []
    }
    func drawCampaignResults(_ id: Int, _ carry: String?) {
        guard let f = layers("dialog.campaign_Score") else { return }
        let (ox, oy) = dialogOrigin(800, 600)
        func l(_ n: String) -> UILayer? { MenuKit.find(f, n) }
        draw(kit.image(l("Background"), "dialog.campaign_Score", ox, oy))
        if let t = l("Title") { draw(kit.text(text("title.campaign_score", "Campaign Results"), UIRect(t, ox, oy), MenuKit.Style(min(t.height, 22), just: 1, vcentre: true))) }
        let scores = campaignScores(carry), c = campaign(id)
        let total = ScenarioScore.campaign(scores)
        guard let line1 = l("Line_1") else { return }
        func row(_ marker: UILayer?, _ name: String, _ value: String) {
            guard let m = marker else { return }
            let dy = m.y - line1.y
            if let bg = l("Map_Background") { draw(kit.image(bg, "dialog.campaign_Score", ox, oy + dy)) }
            if let n = l("Map_Name") { draw(kit.text(name, UIRect(ox + n.x, oy + n.y + dy, n.width, n.height), MenuKit.Style(min(n.height - 4, 20), vcentre: true))) }
            if let s = l("Map_Score") { draw(kit.text(value, UIRect(ox + s.x, oy + s.y + dy, s.width, s.height), MenuKit.Style(min(s.height - 4, 20), just: 2, vcentre: true))) }
        }
        let n = c?.count ?? scores.count
        for k in 0..<min(6, n) {
            let i = campaignResultsScroll + k
            guard i < n else { break }
            let name = scenarioMap(id, i)?.name ?? ""
            row(l("Line_\(k + 1)"), name, i < scores.count ? "\(scores[i].score)" : "")
        }
        row(l("map_average"), text("average.campaign_score", "Average Score"), "\(total.average)")
        row(l("multiplier"), "", "x5")
        row(l("Campaign"), c?.name ?? "", "\(total.score)")
        if n > 6, let s = l("Scrollbar") { draw(kit.vScrollbar(ox + s.x, oy + s.y, s.height, first: campaignResultsScroll, visible: 6, total: n)) }
        if let b = l("Close_Button") { draw(kit.button("close", look(UIRect(ox + b.x, oy + b.y, 76, 44)), ox + b.x, oy + b.y)) }
    }
    /// Close (0x67fa10): the campaign's result goes into the campaign list; a place opens the High
    /// Score dialog on that tab, otherwise the main menu.
    func clickCampaignResults(_ id: Int, _ carry: String?, _ x: Float, _ y: Float) {
        guard let f = layers("dialog.campaign_Score") else { return }
        let (ox, oy) = dialogOrigin(800, 600)
        func l(_ n: String) -> UILayer? { MenuKit.find(f, n) }
        let n = campaign(id)?.count ?? 0
        if n > 6, let s = l("Scrollbar"), let d = kit.vScrollbarHit(ox + s.x, oy + s.y, s.height, x, y) {
            campaignResultsScroll = max(0, min(n - 6, campaignResultsScroll + d)); return
        }
        guard hit(l("Close_Button"), ox, oy, x, y, w: 76, h: 44) else { return }
        let total = ScenarioScore.campaign(campaignScores(carry))
        let rules = menuRules
        var t = HighScores.load(highScoresURL()) { defaultHighScores(rules) }
        let rank = ScenarioScore.rank(score: total.score, scale: 5000) { k in rules?.creature(RuleTables.creatureIds[k])?.experience ?? 0 }
        let name = text("player.new_game", "Player")
        if let k = t.insert(map: campaign(id)?.name ?? "", days: total.days, score: total.score, name: name, standard: false, rank: rank) {
            t.save(highScoresURL())
            highScoreName = name
            openHighScores(standard: false, newEntry: k)
        } else { screen = .main }
    }

    /// After a won campaign scenario: its epilogue if it has one (0x771276), then the next
    /// scenario's briefing, or after the last the Campaign Results.
    func afterScenarioWon(id: Int, index: Int, carry: String?) {
        if let m = scenarioMap(id, index), let e = m.epilogue, !e.text.isEmpty { screen = .epilogue(id: id, index: index, carry: carry); return }
        afterEpilogue(id: id, index: index, carry: carry)
    }
    func afterEpilogue(id: Int, index: Int, carry: String?) {
        if let c = campaign(id), index + 1 < c.count { screen = .briefing(id: id, index: index + 1, carry: carry) }
        else { campaignResultsScroll = 0; screen = .campaignResults(id: id, carry: carry) }
    }
}
