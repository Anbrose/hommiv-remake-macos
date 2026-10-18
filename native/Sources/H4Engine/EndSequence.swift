import Foundation

/// The end of a scenario (re/end_sequence_spec.md): who is eliminated and when the game is won
/// or lost (heroes4.exe 0x4c4a50, the turn start 0x4b3710, the day 0x4e5b00), and what the
/// scenario-over routine 0x4c5df0 leads to.
extension GameState {
    /// The players of the map, in the order the exe walks them (game +0x640).
    public var playerColours: [Int] { map.playerSpecs.map(\.colour) }

    /// A player's team (player +0x2b8): the map's team, else a team of its own.
    public func team(of colour: Int) -> Int { map.teams[colour] ?? 100 + colour }

    /// Who owns a town (a town the human took may only carry `owned`).
    public func townOwner(_ t: Town) -> Int? { t.owner ?? (t.owned ? map.humanColour : nil) }

    /// Player +0xa8 (set by 0x7e4880), what the scripts' `is_eliminated` reads (0x830f80).
    public func isEliminated(_ colour: Int) -> Bool { eliminatedPlayers.contains(colour) }

    /// Whether a player has nothing left (0x7e2c40): already eliminated, made to lose by a
    /// script (+0xa9, 0x7e4870), or without towns and without anything on the map (armies,
    /// caravans; the human's heroes resting in a sanctuary).
    public func isDefeated(_ colour: Int) -> Bool {
        if eliminatedPlayers.contains(colour) || lostPlayers.contains(colour) { return true }
        if towns.contains(where: { townOwner($0) == colour }) { return false }
        if caravans.contains(where: { $0.owner == colour }) { return false }
        if colour == map.humanColour { return heroes.isEmpty && sanctuaryGuests.isEmpty }
        return !enemyHeroes.contains { $0.owner == colour }
    }

    /// The team that alone owns every owned town (0x4d87d0), unless only computers own towns.
    public func soleTownTeam() -> Int? {
        var team: Int? = nil, onlyComputers = true
        for c in playerColours {
            guard towns.contains(where: { townOwner($0) == c }) else { continue }
            if let t = team, t != self.team(of: c) { return nil }
            team = self.team(of: c)
            if c == map.humanColour { onlyComputers = false }
        }
        return onlyComputers ? nil : team
    }

    /// Whether the standard victory condition is on (game +0x9b4: the map's flag, then the
    /// scripts' enable / disable actions).
    public var standardVictoryEnabled: Bool { map.standardVictory && scripts.standardVictoryOn }

    /// Has something ended the game (0x4c4a50, after battles, captures, scripts, the day): every
    /// player with nothing left is eliminated, one box names them all ("eliminated.adventure_map",
    /// %name always default_name "A player", %color the colour's name; joined by " and " and a
    /// line break); no human left loses; with the standard victory on, the last player standing
    /// wins, and a team holding every town starts (or loses) its 3 days.
    public func checkScenario() {
        guard outcome == nil else { return }
        var alive = 0, lastTeam: Int? = nil, humanAlive = false, notice = ""
        for c in playerColours {
            if !eliminatedPlayers.contains(c) && !isDefeated(c) {
                alive += 1; lastTeam = team(of: c)
                if c == map.humanColour { humanAlive = true }
            } else if !eliminatedPlayers.contains(c) {
                eliminatedPlayers.insert(c)
                if !notice.isEmpty { notice += text("and.combat", " and ") + "\n" }
                notice += GameState.eliminationText(colour: c, strings: tables?.strings ?? [:])
            }
        }
        if !notice.isEmpty { scripts.messages.append(notice) }
        if !humanAlive { endScenario(won: false, team: nil); return }
        guard standardVictoryEnabled else { return }
        if isHumanActing {
            if alive == 1 { endScenario(won: true, team: lastTeam ?? team(of: map.humanColour)); return }
            if let holder = soleTownTeam() {
                guard victoryTeam == nil else { return }
                scripts.messages.append(text("victory_initiated.adventure_map", "Victory is at hand!  Hold your towns for 3 days and your foes will be defeated!"))
                victoryTeam = holder; victoryDays = 3
            } else if victoryTeam != nil {
                scripts.messages.append(text("victory_terminated.adventure_map", "Your opponent has taken steps to undermine your victory.  A town has been reclaimed!"))
                victoryTeam = nil; victoryDays = 3
            }
        } else if let v = victoryTeam, soleTownTeam() == nil {
            // a computer's move broke the hold: only the holding human's team is told
            if v == team(of: map.humanColour) {
                scripts.messages.append(text("victory_terminated.adventure_map", "Your opponent has taken steps to undermine your victory.  A town has been reclaimed!"))
            }
            victoryTeam = nil; victoryDays = 3
        }
    }

    /// "%name (%color) has been eliminated!" for one player (0x4c4c9a).
    public static func eliminationText(colour: Int, strings: [String: String]) -> String {
        let names = ["red", "green", "blue", "orange", "purple", "teal", "gray"]
        let fallback = ["red", "green", "blue", "orange", "purple", "teal", "neutral"]
        let k = min(max(colour, 0), 6)
        return substitute(strings["eliminated.adventure_map"] ?? "%name (%color) has been eliminated!",
                          ["%color": strings["\(names[k]).adventure_map"] ?? fallback[k],
                           "%name": strings["default_name.adventure_map"] ?? "A player"])
    }

    /// The day ends (0x4e5b00): a running hold loses a day.
    func victoryNewDay() {
        if victoryTeam != nil { victoryDays = (victoryDays ?? 3) - 1 }
    }

    /// The human's turn starts (0x4b3710): his team's hold either wins now or tells the days
    /// left; another team's hold warns him he must take a town back.
    func victoryTurnStart() {
        guard outcome == nil, let v = victoryTeam else { return }
        let d = victoryDays ?? 0
        if v == team(of: map.humanColour) {
            if d <= 0 { endScenario(won: true, team: v); return }
            scripts.messages.append(d == 1 ? text("victory_pending_singular.adventure_map", "Hold your towns for one more day to win the game!")
                : text("victory_pending_plural.adventure_map", "Hold your towns for another %days days to win the game!").replacingOccurrences(of: "%days", with: "\(d)"))
        } else {
            scripts.messages.append(d == 1 ? text("defeat_pending_singular.adventure_map", "You have lost all of your towns and are in danger of being defeated.  You have one day left to reclaim a town!")
                : text("defeat_pending_plural.adventure_map", "You have lost all of your towns and are in danger of being defeated.  You have %days days left to reclaim a town!").replacingOccurrences(of: "%days", with: "\(d)"))
        }
    }

    /// The scenario is over (0x4c5df0): the outcome and the winning team (+0x32c / +0x330),
    /// the game-over flag (+0x23d); nothing more happens on the map. Once over, it stays over.
    public func endScenario(won: Bool, team: Int?) {
        guard outcome == nil else { return }
        outcome = won
        winningTeam = team
    }

    /// The script `win` action (0x837990): the named player's team wins; the human wins with it
    /// or loses.
    func scriptWin(_ p: Int) {
        let mine = p == map.humanColour || team(of: p) == team(of: map.humanColour)
        endScenario(won: mine, team: team(of: p))
    }

    /// The script `lose` action (0x837a30): the player is marked lost (+0xa9) and the game checks
    /// for the end at once -- he is eliminated with the usual box, and the human loses.
    func scriptLose(_ p: Int) {
        lostPlayers.insert(p)
        checkScenario()
    }
}

/// What follows the win / lose movie (0x4c5850).
public enum EndStep: Equatable {
    /// The Final Score dialog (0x6f4bf0), then the main menu.
    case finalScore
    /// The next campaign scenario starts (0x4a3dd0, a new adventure frame).
    case nextScenario
    /// The campaign is over: its closing dialog (0x67de50), then the main menu.
    case campaignComplete
    /// Back to the main menu (0x4b6bf0).
    case mainMenu

    /// The steps after the movie: a loss (or a lost campaign scenario) goes to the menu; a won
    /// single scenario shows its score; a won campaign scenario goes on to the next one, or ends
    /// the campaign.
    public static func after(won: Bool, campaign: Bool, hasNextScenario: Bool, campaignFinished: Bool) -> [EndStep] {
        guard won else { return [.mainMenu] }
        guard campaign else { return [.finalScore, .mainMenu] }
        if hasNextScenario { return [.nextScenario] }
        return campaignFinished ? [.campaignComplete, .mainMenu] : [.mainMenu]
    }

    /// The movie the win / lose window plays once (table 0xa50f70: no intro, no loop).
    public static func movie(won: Bool) -> String { won ? "win_game" : "lose_game" }
}
