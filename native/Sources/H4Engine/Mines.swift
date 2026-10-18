import Foundation

// A mine's visit as heroes4.exe's t_mine has it (re/mine_capture_spec.md): visit 0x79c7f0, the
// claim 0x79cf30, the battle's end 0x79cdf0.
extension GameState {
    static let minePrefix = "mine|"

    /// Debugging: a mine visited as `hero` would (no walking); false when p is no mine.
    public func debugVisitMine(hero: Hero, _ p: MapScene.Placed) -> Bool {
        guard let i = mine(for: p) else { return false }
        if ProcessInfo.processInfo.environment["H4GUARDED"] != nil, mines[i].guards.isEmpty { mines[i].guards = [Hero.Stack(creature: "peasant", count: 12)] }
        visitMine(hero, i, p)
        return true
    }

    /// The material a mine yields (its index in materialNames).
    func mineMaterial(_ i: Int) -> Int { GameState.materialNames.firstIndex(of: mines[i].resource) ?? 0 }

    /// The mine belongs to the colour or to an ally of it (same team, 0x79ca62..0x79cab5).
    func mineFriendly(_ i: Int, to colour: Int) -> Bool {
        guard let o = mines[i].owner else { return false }
        if o == colour { return true }
        if let t = map.teams[colour], map.teams[o] == t { return true }
        return false
    }

    /// The guards as "25 pikemen, 10 archers" (0x739770 for %creatures / %the_creatures).
    func mineGuardText(_ i: Int) -> String {
        mines[i].guards.filter { $0.count > 0 }.map { g in
            let d = tables?.creature(g.creature); return "\(g.count) \(g.count == 1 ? d?.name ?? g.creature : d?.plural ?? g.creature)"
        }.joined(separator: ", ")
    }

    /// 0x79c7f0. A human player's army plays miscellaneous.flag_mine first, whatever follows
    /// (0x79ca0b; the only use of that sound in the game). The visitor's or an ally's mine: the
    /// garrison window (0x7d61d0, not made here). Another's or nobody's with guards: the human is
    /// asked `initial_guarded` above the army, the computer fights at once. Unguarded: claimed.
    func visitMine(_ hero: Hero, _ i: Int, _ p: MapScene.Placed) {
        let me = actingColour, cell = (hero.x, hero.y)
        hero.target = nil
        if isHumanActing { sounds.append("miscellaneous.flag_mine") }
        if mineFriendly(i, to: me) { return }
        if mines[i].guards.contains(where: { $0.count > 0 }) {
            let words = mineGuardText(i)
            let subs = ["%creatures": words, "%the_creatures": words]
            let fight: () -> Void = { [weak self] in
                guard let self = self else { return }
                let stacks = self.mines[i].guards.filter { $0.count > 0 }
                guard let lead = stacks.first else { return }
                var m = Monster(x: p.cellX, y: p.cellY, name: p.name, creature: lead.creature, count: lead.count,
                                extra: stacks.dropFirst().map { ($0.creature, $0.count) })
                m.z = self.level; m.bank = GameState.minePrefix + "\(i)"
                self.monsters.append(m)
                self.fight(hero: hero, monsterAt: self.monsters.count - 1, p)
            }
            if isHumanActing {
                question = (objectText(p, "initial_guarded", subs) ?? "Fight the guards?", fight)
                questionAnchor = cell
                questionTitle = objectText(p, "name")
            } else { fight() }
            return
        }
        claimMine(hero, i, p, defeat: false)
    }

    /// 0x79cf30: the army needs a living hero, else (human) `no_heroes`, centred on the screen
    /// without a title (0x844ce0(text, true, "")). Claimed (vtable +0xb4): the computer is done;
    /// the human gets a box titled with the mine's name, `initial` -- `defeat` after beating the
    /// guards -- with %material "1000 gold", a picture of the material captioned "+1000 gold/day"
    /// (0x55a040(material, amount, plus, per day)) and OK, standing above the army (0x8760f0,
    /// 0x5595d0(.., 1, 2)).
    func claimMine(_ hero: Hero, _ i: Int, _ p: MapScene.Placed, defeat: Bool, guards: String = "") {
        let human = isHumanActing
        guard !hero.members.isEmpty else {
            if human, let t = objectText(p, "no_heroes") { scripts.messages.append(t) }
            return
        }
        mines[i].owner = actingColour; mines[i].owned = human
        guard human else { return }
        let m = mineMaterial(i), n = mines[i].amount
        let subs = ["%material": materialList([(m, n)]), "%the_creatures": guards, "%creatures": guards]
        guard let t = objectText(p, defeat ? "defeat" : "initial", subs) else { return }
        scripts.messages.append(t)
        messageTitles[t] = objectText(p, "name")
        messagePictures[t] = [.material(m, amount: n, perDay: true)]
        messageAnchors[t] = (hero.x, hero.y)
    }

    /// 0x79cdf0, the guards' battle is over: lost, what is left of them stays; won, the mine is
    /// claimed with the `defeat` text (a heroless army: `no_heroes`).
    func mineBattleOver(_ hero: Hero, _ i: Int, _ p: MapScene.Placed, won: Bool, leadLeft: Int) {
        guard i < mines.count else { return }
        let words = mineGuardText(i)
        if won {
            mines[i].guards = []
            claimMine(hero, i, p, defeat: true, guards: words)
        } else if let k = mines[i].guards.firstIndex(where: { $0.count > 0 }) {
            mines[i].guards[k].count = max(1, leadLeft)
        }
    }
}
