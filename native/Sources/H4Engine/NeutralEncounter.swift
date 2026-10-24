import Foundation

/// An army meeting a wandering stack, as heroes4.exe's t_army 0x522560 handles it
/// (re/neutral_encounter_spec.md). It runs for both ways of meeting: the hero walking into the
/// stack (the stack's trigger, 0x522520) and the stack charging the hero (t_enemy_army_attack
/// 0x5474d0); either way the stack is `this` and the hero's army the other, and the hero's army
/// fights as the attacker. In order: the hero turns to it, Charm / Diplomacy offers (0x521780),
/// then "the enemy turns to flee" (0x52272c), then the battle (0x5e9620 / 0x80a080).
extension GameState {
    /// The buttons of dialog.enemy_runs (t_dialog_enemy_runs 0x6ae440): run 0x6aede0 sets +0xcc
    /// (let them run), fight 0x6aee00 clears +0xcc and +0xcd, quick_combat 0x6aee20 sets +0xcd.
    public enum FleeChoice { case letThemRun, fight, quickCombat }

    /// 0x52276e..0x52278a: the dialog when worth(stack) x 5.0 ([0x97aca0]) <= worth(army),
    /// both 0x642160 of the creature arrays.
    public static func stackRuns(stackWorth: Float, armyWorth: Float) -> Bool { stackWorth * 5 <= armyWorth }

    /// The stack's creatures in its slot order (its first creature, then the escort).
    func stacks(of m: Monster) -> [Hero.Stack] {
        ([(m.creature, m.count)] + m.extra.map { ($0.creature, $0.count) }).filter { $0.1 > 0 }.map { Hero.Stack(creature: $0.0, count: $0.1) }
    }
    /// 0x642160 of a wandering stack (no heroes: count x experience per stack).
    func aiWorth(of m: Monster) -> Float { aiArmyValue(stacks(of: m).map { .stack($0) }) }

    /// Does the stack turn to flee (0x522727..0x5227b8)? The Quick Combat option off (0x7c9100,
    /// [0xac117b]; the remake's quickCombatOnly), the stack without an owner (0x44c930), the
    /// army a human player's (0x44c970: owner's +0x88 clear), and the stack worth at most a fifth
    /// of the army. Nothing about the creatures (no kind that never runs), nothing from the map.
    public func enemyRunsOffered(hero: Hero, monsterAt i: Int) -> Bool {
        guard !quickCombatOnly, i < monsters.count, monsters[i].bank == nil, hero.owner == map.humanColour else { return false }
        return GameState.stackRuns(stackWorth: aiWorth(of: monsters[i]), armyWorth: aiArmyValue(armySlots(hero)))
    }

    /// The question is put (pendingFlee) instead of the battle; true when it was.
    func offerFlight(hero: Hero, monsterAt i: Int, _ p: MapScene.Placed) -> Bool {
        guard enemyRunsOffered(hero: hero, monsterAt: i) else { return false }
        pendingFlee = (hero, i, p)
        return true
    }

    /// The answer (0x522953: +0xcc run, +0xcd quick, handed to 0x80a080). Let Them Run: the
    /// battle object still runs its end (0x80a33a -> 0x80a94f) with code 4, the defender beaten,
    /// without a fight: the score counts a won battle (0x809c20), the stack is emptied (0x63f830)
    /// and leaves the map, nobody fell so nobody gains experience (0x7fe8a0 shares the losses'
    /// 0x6411d0 value: 0), and no results dialog shows (only the combat window 0x571db0 and the
    /// quick combat 0x848490 open it). Fight: the combat screen. Quick Combat: the quick battle.
    public func resolveFlee(_ choice: FleeChoice) {
        guard let f = pendingFlee else { return }
        pendingFlee = nil
        guard f.monster < monsters.count else { return }
        switch choice {
        case .fight: startBattle(hero: f.hero, monsterAt: f.monster, f.placed, quick: false)
        case .quickCombat: startBattle(hero: f.hero, monsterAt: f.monster, f.placed, quick: true)
        case .letThemRun:
            finishBattle(hero: f.hero, monsterAt: f.monster, f.placed, won: true, army: f.hero.army, monstersLeft: 0, experience: 0, rounds: 0)
        }
    }
}

// MARK: Charm and Diplomacy (0x521780)

extension GameState {
    /// What a hero's Charm or Diplomacy sways from a wandering stack, and what it costs (dialog
    /// 0x699960; re/neutral_encounter_spec.md §2).
    public struct JoinOffer {
        public let hero: Hero, monster: Int, placed: MapScene.Placed
        /// Swayed by Charm (free), by Diplomacy (for `cost` gold); either may be empty, not both.
        public var charm: [Hero.Stack], diplomacy: [Hero.Stack]
        /// The best heroes' skill levels (vt+0x50, 0 basic .. 4 grandmaster; -1 -> 0).
        public var charmLevel: Int, diplomacyLevel: Int
        /// 0x69a530: half the swayed creatures' gold price, floored.
        public var cost: Int
        public init(hero: Hero, monster: Int, placed: MapScene.Placed, charm: [Hero.Stack], diplomacy: [Hero.Stack], charmLevel: Int, diplomacyLevel: Int, cost: Int) {
            self.hero = hero; self.monster = monster; self.placed = placed; self.charm = charm; self.diplomacy = diplomacy
            self.charmLevel = charmLevel; self.diplomacyLevel = diplomacyLevel; self.cost = cost
        }
    }

    /// 0x732140 cases 0x73216c / 0x732185: Charm power = [0x9891e8][level + 1], Diplomacy twice it.
    public static let charmPower = [0, 15, 20, 25, 30, 35]
    /// The experience a hero can sway at hero level 1 (0x97aa6c Charm, 0x97aa84 Diplomacy).
    public static let charmExperience = [60, 120, 180, 240, 300], diplomacyExperience = [120, 240, 360, 480, 600]

    /// A skill's power (0x732250): the table by level plus the worn artifacts' skill bonuses
    /// (0x7254d0: effects of type 0x32 for that skill).
    func swayPower(_ h: Hero, skill: String) -> Int {
        let lv = h.skill(skill)
        guard lv > 0 else { return 0 }
        let base = GameState.charmPower[min(5, lv)] * (skill == "diplomacy" ? 2 : 1)
        let id = RuleTables.skillIds.firstIndex(of: skill) ?? -1
        let bonus = h.equipped.compactMap { $0 }.flatMap { RuleTables.effects(ofArtifact: $0) }.filter { $0.type == 0x32 && $0.skill == id }.reduce(0) { $0 + $1.amount }
        return base + bonus
    }
    /// 0x641bd0: the army's hero with the most power in the skill (the first of equals; none at 0).
    func bestSwayer(_ h: Hero, skill: String) -> Hero? {
        var best: Hero? = nil, most = 0
        for m in h.members { let p = swayPower(m, skill: skill); if p > most { most = p; best = m } }
        return best
    }

    /// One skill's catch over the stack's creatures (0x52195a / 0x521b1c): per creature
    /// n = count x (power - resistance) / 100, at most what the experience left pays for at the
    /// creature's experience each; the hero's allowance is base + base x (hero level - 1) / 10.
    static func sway(_ stacks: [Hero.Stack], margin: Int, allowance: Int, allowed: (String) -> Bool, experience: (String) -> Int) -> [Hero.Stack] {
        var left = allowance, out: [Hero.Stack] = []
        for s in stacks where allowed(s.creature) {
            var n = s.count * margin / 100
            guard n > 0 else { continue }
            let each = max(1, experience(s.creature))
            n = min(n, left / each)
            guard n > 0 else { continue }
            left -= each * n
            if let k = out.firstIndex(where: { $0.creature == s.creature }) { out[k].count += n } else { out.append(Hero.Stack(creature: s.creature, count: n)) }
        }
        return out
    }

    /// The offer (0x521780) when the army's experience value (0x6411d0) is at least three times
    /// the stack's. The stack's own resistance is its heroes' power (0x641c70): 0 for a wandering
    /// stack. Charm needs more than half of max(Diplomacy resistance, 2 x Charm resistance) and
    /// never takes undead, mechanical creatures, mermaids or sea monsters; Diplomacy needs more
    /// than that maximum and never takes mermaids, sea monsters or a creature whose alignment is
    /// opposed (0x51ecf0 == 3) to anything in the hero's army.
    public func joinOffer(hero: Hero, monsterAt i: Int, _ p: MapScene.Placed) -> JoinOffer? {
        guard let t = tables, i < monsters.count, monsters[i].bank == nil else { return nil }
        let m = monsters[i]
        guard armyValue(hero) >= 3 * experienceValue(of: m) else { return nil }
        var pool: [Hero.Stack] = []   // the stack's creatures, merged by kind (0x6410d0)
        for s in stacks(of: m) { if let k = pool.firstIndex(where: { $0.creature == s.creature }) { pool[k].count += s.count } else { pool.append(s) } }
        let resist = 0   // max(Diplomacy resistance, 2 x Charm resistance): no heroes in a wandering stack
        let exp = { (c: String) in t.creature(c)?.experience ?? 0 }
        func abilities(_ c: String) -> [String] { RuleTables.creatureAbilities[c.lowercased()] ?? [] }
        let never: Set<String> = ["mermaid", "sea monster"]   // creature ids 0x26 and 0x34
        var charm: [Hero.Stack] = [], diplomacy: [Hero.Stack] = []
        var charmLevel = 0, diplomacyLevel = 0
        if let c = bestSwayer(hero, skill: "charm"), swayPower(c, skill: "charm") > resist / 2 {
            charmLevel = c.skill("charm") - 1
            let base = GameState.charmExperience[charmLevel]
            charm = GameState.sway(pool, margin: swayPower(c, skill: "charm") - resist / 2, allowance: base + (c.level - 1) * base / 10,
                                   allowed: { !never.contains($0) && !abilities($0).contains("undead") && !abilities($0).contains("mechanical") }, experience: exp)
        }
        if let d = bestSwayer(hero, skill: "diplomacy"), swayPower(d, skill: "diplomacy") > resist {
            diplomacyLevel = d.skill("diplomacy") - 1
            let base = GameState.diplomacyExperience[diplomacyLevel]
            var present: [Int] = hero.members.map { $0.alignment }.compactMap { Battle.alignments.firstIndex(of: $0.lowercased()) }
            present += hero.army.filter { $0.count > 0 }.compactMap { t.creature($0.creature).flatMap { Battle.alignments.firstIndex(of: $0.alignment.lowercased()) } }
            let opposed = Set((0..<6).filter { j in present.contains { Battle.relation(j, $0) == 3 } })
            diplomacy = GameState.sway(pool, margin: swayPower(d, skill: "diplomacy") - resist, allowance: base + (d.level - 1) * base / 10,
                                       allowed: { c in !never.contains(c) && !opposed.contains(Battle.alignments.firstIndex(of: t.creature(c)?.alignment.lowercased() ?? "") ?? -1) },
                                       experience: exp)
        }
        guard !charm.isEmpty || !diplomacy.isEmpty else { return nil }
        let cost = diplomacy.reduce(0) { $0 + $1.count * (t.creature($1.creature)?.gold ?? 0) } >> 1
        return JoinOffer(hero: hero, monster: i, placed: p, charm: charm, diplomacy: diplomacy, charmLevel: charmLevel, diplomacyLevel: diplomacyLevel, cost: cost)
    }

    /// The human player's offer is put (pendingJoin); the computer's armies weigh it instead
    /// (0x521c26, not modelled: they fight). True when the question waits.
    func offerJoin(hero: Hero, monsterAt i: Int, _ p: MapScene.Placed) -> Bool {
        guard hero.owner == map.humanColour, !isComputer(hero.owner), let o = joinOffer(hero: hero, monsterAt: i, p) else { return false }
        pendingJoin = o
        return true
    }

    /// The answer (0x52216c): 0 close (nothing), 1 Charm's OK, 2 Diplomacy's Buy (disabled when
    /// the gold is short). The creatures leave the stack (0x522470) and join the army (0x6410d0:
    /// the same kind, else a free place); what finds no place is offered by 0x6b5dc0 [the remake
    /// drops it]. Diplomacy pays the cost first (0x7e3d80). Then the encounter goes on: the
    /// flight question, then the battle.
    public func resolveJoin(_ pick: Int) {
        guard let o = pendingJoin else { return }
        pendingJoin = nil
        guard o.monster < monsters.count else { return }
        let taken = pick == 1 ? o.charm : pick == 2 ? o.diplomacy : []
        if pick == 2 {
            guard resources["Gold", default: 0] >= o.cost else { return encounterGoesOn(o) }
            resources["Gold", default: 0] -= o.cost
        }
        for s in taken {
            var n = s.count
            var m = monsters[o.monster]
            if m.creature == s.creature { let k = min(n, m.count); m.count -= k; n -= k }
            for j in m.extra.indices where n > 0 && m.extra[j].creature == s.creature { let k = min(n, m.extra[j].count); m.extra[j].count -= k; n -= k }
            monsters[o.monster] = m
            if let k = o.hero.army.firstIndex(where: { $0.creature == s.creature }) { o.hero.army[k].count += s.count }
            else if o.hero.members.count + o.hero.army.count < Hero.armySlots { o.hero.army.append(s) }
        }
        if !taken.isEmpty { refreshMovement(o.hero) }
        encounterGoesOn(o)
    }
    func encounterGoesOn(_ o: JoinOffer) {
        if offerFlight(hero: o.hero, monsterAt: o.monster, o.placed) { return }
        startBattle(hero: o.hero, monsterAt: o.monster, o.placed, quick: quickCombatOnly)
    }
}
