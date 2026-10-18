import Foundation

// Experience for sneaking past wandering armies, as heroes4.exe's army mover gives it
// (re/stealth_xp_spec.md): after every step (t_army_mover vtable +0x10 = 0x546300) the armies
// whose zone the army's stealth hides it from are "eluded" (0x546050) -- each living hero of the
// army is paid once per army a part of what beating it would have earned -- and when the move
// ends (end_move 0x5469d0 -> 0x546720) the player is told and the levels are taken.

extension GameState {
    /// Debugging: the army (with companions up to `heroes` heroes) eludes the nearest wandering
    /// stack and its move ends.
    public func debugElude(_ h: Hero, heroes n: Int) {
        let names = ["Gwenneth", "Lysander"]
        while h.members.count < min(n, 3) {
            let c = Hero(actor: "hero.life_magic_female", x: h.x, y: h.y, movement: 1)
            c.name = names[h.companions.count % 2]; c.keyword = h.keyword; c.alignment = h.alignment
            h.companions.append(c)
        }
        guard let i = guardStacks.min(by: { abs(monsters[$0].x - h.x) + abs(monsters[$0].y - h.y) < abs(monsters[$1].x - h.x) + abs(monsters[$1].y - h.y) }) else { return }
        elude(h, i)
        finishEluded(h)
    }

    /// What beating the army would earn (0x6411d0): every stack's creatures times their
    /// experience (a creature 0x63d920; heroes (level + 1) x 100, none in a wandering army).
    func experienceValue(of m: Monster) -> Int {
        var v = 0
        for (c, n) in [(m.creature, m.count)] + m.extra.map({ ($0.creature, $0.count) }) where n > 0 {
            v += n * (tables?.creature(c)?.experience ?? 0)
        }
        return v
    }

    /// The share of that value an eluding hero is paid (0x546050): value / divisor + 0.5,
    /// truncated; the divisor is 4, times the difficulty factor (0x7f4520 of game +0x64c) for an
    /// army of a human player.
    func eludedExperience(_ value: Int, human: Bool) -> Int {
        let divisor = human ? GameState.difficultyFactor[min(4, max(0, difficulty))] * 4.0 : 4.0
        return Int(Double(value) / divisor + 0.5)
    }

    /// The army has stepped onto a new cell (0x546300): an owned army with a living hero and
    /// stealth 1 or more (Advanced Stealth and up, no creature without the ability) eludes every
    /// wandering army standing in the 4 x 4 cells x - 2 ..< x + 2, y - 2 ..< y + 2 of its level
    /// (the exe's loops stop short of + 2) whose scouting + 1 is below that stealth -- the armies
    /// that have no zone against it (GuardZones.flood).
    func markEluded(_ h: Hero) {
        guard (0..<6).contains(h.owner), !h.members.isEmpty else { return }
        let s = stealth(of: h)
        guard s >= 1 else { return }
        for i in monsters.indices {
            let m = monsters[i]
            guard m.z == h.z, m.bank == nil, m.count > 0,
                  m.x >= h.x - 2, m.x < h.x + 2, m.y >= h.y - 2, m.y < h.y + 2,
                  scouting(of: m) + 1 < s else { continue }
            elude(h, i)
        }
    }

    /// 0x546050: every living hero of the army that has not eluded this army before (0x733e20:
    /// the army's id into the hero's set) gets the share at once (hero +0x630); the mover keeps
    /// the sum per hero for the end of the move.
    func elude(_ h: Hero, _ i: Int) {
        let human = h.owner == map.humanColour
        let n = eludedExperience(experienceValue(of: monsters[i]), human: human)
        for member in h.members where member.eluded.insert(monsters[i].uid).inserted {
            member.experience += n
            if let k = h.eludedGains.firstIndex(where: { $0.hero === member }) { h.eludedGains[k].amount += n }
            else { h.eludedGains.append((member, n)) }
        }
    }

    /// The move is over (end_move 0x5469d0 -> 0x546720), before the object it led to is used:
    /// for a human player a box centred on the screen (0x5596f0) tells who gained -- one picture
    /// per hero with the gain, `stealth_use_singular.misc` for one hero, `stealth_use_plural.misc`
    /// for more -- then the heroes take the levels they reached (0x642970), the computer's at once.
    func finishEluded(_ h: Hero) {
        guard !h.eludedGains.isEmpty else { return }
        let gains = h.eludedGains
        h.eludedGains = []
        if h.owner == map.humanColour {
            let t = gains.count == 1
                ? heroText("stealth_use_singular.misc", "%Hero_name has gained experience from using %his Stealth skill.", gains[0].hero)
                : heroText("stealth_use_plural.misc", "%Hero_names have gained experience from using their Stealth skills.", gains.map(\.hero))
            scripts.messages.append(t)
            messagePictures[t] = gains.map { .heroExperience($0.hero, amount: $0.amount) }
            for g in gains where Hero.level(for: g.hero.experience) > g.hero.level && !levelUpQueue.contains(where: { $0 === g.hero }) { levelUpQueue.append(g.hero) }
            nextLevelUp()
        } else {
            for g in gains { _ = g.hero.levelUp(to: min(70, Hero.level(for: g.hero.experience)), tables: tables, random: &random) }
        }
    }

    /// A strings.Text message with one hero's substitutions (0x738fd0: %hero_name, %his, ...;
    /// a capital first letter capitalises the value, 0x74fb30).
    func heroText(_ key: String, _ fallback: String, _ hero: Hero) -> String {
        heroText(key, fallback, [hero])
    }
    /// The same for several heroes: %hero_names joins their names as 0x74f2d0 builds the list --
    /// the second joined with " and ", every further one with ", " ("A and B, C").
    func heroText(_ key: String, _ fallback: String, _ heroes: [Hero]) -> String {
        var t = text(key, fallback)
        guard let last = heroes.last else { return t }
        var names = ""
        for (k, h) in heroes.enumerated() { names = k == 0 ? h.name : names + (k == 1 ? " \(text("and.dialog", "and")) " : ", ") + h.name }
        let female = last.actor.lowercased().hasSuffix("_female")
        let subs: [(String, String)] = [("%hero_names", names), ("%hero_name", last.name), ("%himself", female ? "herself" : "himself"),
                                        ("%him", female ? "her" : "him"), ("%his", female ? "her" : "his"), ("%he", female ? "she" : "he")]
        for (k, v) in subs {
            let cap = "%" + k.dropFirst().prefix(1).uppercased() + k.dropFirst(2)
            t = t.replacingOccurrences(of: cap, with: v.prefix(1).uppercased() + v.dropFirst())
            t = t.replacingOccurrences(of: k, with: v)
        }
        return t
    }
}
