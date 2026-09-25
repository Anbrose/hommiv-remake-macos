import Foundation

/// Adventure objects, phase 2: teachers, schools, shrines, tunnels, portals, whirlpools, keys.
extension GameState {
    static let magicPrimaries = [4, 5, 6, 7, 8], mightPrimaries = [0, 1, 2, 3]
    static let magicSecondaries = Array(21...35), mightSecondaries = Array(9...20)

    /// Skills and spells picked when the game starts.
    func setupTeaching(_ p: MapScene.Placed, _ st: inout ObjectState) {
        func pick(_ pool: [Int], _ n: Int) -> [Int] {
            var left = pool, out: [Int] = []
            for _ in 0..<n where !left.isEmpty { out.append(left.remove(at: rng(left.count))) }
            return out
        }
        switch (p.type, p.subtype) {
        case ("teacher", _):   // an altar teaches its family: tactician, trainer, scout, noble, priest, scholar, lich, sorcerer, druid
            let subs = ["tactician", "trainer", "scout", "noble", "priest", "scholar", "lich", "sorcerer", "druid"]
            st.skills = [subs.firstIndex(of: p.subtype) ?? rng(9)]
        case ("random_teacher", _): st.skills = [rng(9)]
        case ("school", "witchs_hut"): st.skills = pick(GameState.magicPrimaries, 1)
        case ("school", "beastmasters_hut"): st.skills = pick(GameState.mightPrimaries, 1)
        case ("school", "school_of_magic"): st.skills = pick(GameState.magicPrimaries, 2)
        case ("school", "school_of_war"): st.skills = pick(GameState.mightPrimaries, 2)
        case ("school", "magic_university"): st.skills = pick(GameState.magicSecondaries, 4)
        case ("school", "war_college"): st.skills = pick(GameState.mightSecondaries, 4)
        case ("school", _): break
        default:   // a shrine: a teachable spell of its school and level (0x46b310)
            let lower = p.name.lowercased()
            let schools = ["life", "order", "death", "chaos", "nature"]
            let school = schools.first { lower.contains(".\($0)") } ?? schools[rng(5)]
            let lv = Int(p.subtype.filter(\.isNumber)) ?? Int(lower.filter(\.isNumber).suffix(1)) ?? 1
            let pool = RuleTables.spells.indices.filter { RuleTables.spells[$0].school == school && RuleTables.spells[$0].level == lv && RuleTables.spells[$0].has("Teach") }
            if !pool.isEmpty { st.spell = pool[rng(pool.count)] }
        }
    }

    /// Tunnels pair surface to underground by the nearest distance, each once (0x46ebe0).
    func linkTunnels() {
        guard scenes.count > 1 else { return }
        let gates = scenes.indices.map { l in scenes[l].placed.filter { $0.type == "subterranean_gate" }.map { (l, $0) } }
        var pairs: [(d: Int, a: String, b: String)] = []
        for (_, a) in gates[0] { for (_, b) in gates[1] {
            let dx = a.cellX - b.cellX, dy = a.cellY - b.cellY
            pairs.append((dx * dx + dy * dy, "0|\(a.cellX)|\(a.cellY)", "1|\(b.cellX)|\(b.cellY)"))
        } }
        var linked: Set<String> = []
        for pr in pairs.sorted(by: { $0.d < $1.d }) where !linked.contains(pr.a) && !linked.contains(pr.b) {
            linked.formUnion([pr.a, pr.b])
            objectStates[pr.a, default: ObjectState()].partner = pr.b
            objectStates[pr.b, default: ObjectState()].partner = pr.a
        }
    }

    func skillLabel(_ s: Int, _ l: Int) -> String {
        let k = RuleTables.skillIds[s]
        return tables?.skillTexts["\(k)_\(RuleTables.skillLevelNames[l])"]?.name ?? k
    }
    /// Learn (skill, level) and what comes with it.
    func teach(_ h: Hero, _ s: Int, _ l: Int) {
        h.learn(s, level: l)
        h.grantSchoolSpells(random: &random)
        h.reconsiderClass()
        floaters.append((skillLabel(s, l), h.x, h.y))
    }

    func visitMore(_ hero: Hero, _ p: MapScene.Placed, _ st: inout ObjectState) -> Bool {
        let heroes = armyHeroes(hero)
        let key = objectKey(p)
        switch p.type {
        case "teacher", "random_teacher":
            // one free step in the altar's family for one hero, then the altar is gone (0x42d830)
            guard let fam = st.skills.first else { return true }
            var options: [(Hero, Int, Int)] = []
            for h in heroes {
                if h.skill(id: fam) == 0 {
                    if (0..<9).filter({ h.skill(id: $0) > 0 }).count < 5 { options.append((h, fam, 0)) }
                } else {
                    for i in 0..<36 where RuleTables.primary(of: i) == fam && h.skill(id: i) < 5 {
                        let l = h.skill(id: i)   // the next level, 0 basic ... 4
                        if h.meets(i, l) { options.append((h, i, l)) }
                    }
                }
            }
            dialogueSound(29)
            if options.isEmpty { say(p, heroes.isEmpty ? "no_heroes" : "denied"); return true }
            choice = (objectText(p, "Initial") ?? "Choose a skill to learn.", options.map { "\($0.0.name): \(skillLabel($0.1, $0.2))" }, { [weak self] k in
                guard let self = self else { return }
                let o = options[k]
                self.teach(o.0, o.1, o.2)
                self.say(p, "learned_skill", ["%hero_name": o.0.name, "%skill_name": self.skillLabel(o.1, o.2)])
                self.remove(p)
            })
        case "school" where ["witchs_hut", "beastmasters_hut"].contains(p.subtype):
            // free: every hero who can learns the primary at basic (0x58ae80)
            guard let s = st.skills.first else { return true }
            let learners = heroes.filter { h in h.skill(id: s) == 0 && (0..<9).filter({ h.skill(id: $0) > 0 }).count < 5 }
            if heroes.isEmpty { say(p, "no_heroes") }
            else if learners.isEmpty { say(p, heroes.allSatisfy { $0.skill(id: s) > 0 } ? "already_known" : "cannot_learn", ["%skill_name": skillLabel(s, 0)]) }
            else { for h in learners { teach(h, s, 0) }; say(p, "initial", ["%skill_name": skillLabel(s, 0)]) }
            dialogueSound(29)
        case "school" where ["school_of_magic", "school_of_war", "magic_university", "war_college"].contains(p.subtype):
            // a class for 2000 gold: one of the two primaries once per hero, or any of the four secondaries
            let university = p.subtype == "magic_university" || p.subtype == "war_college"
            var options: [(Hero, Int)] = []
            for h in heroes where university || !h.visitedObjects.contains(key) {
                for s in st.skills where h.skill(id: s) == 0 {
                    if university ? h.meets(s, 0) : (0..<9).filter({ h.skill(id: $0) > 0 }).count < 5 { options.append((h, s)) }
                }
            }
            dialogueSound(29)
            if options.isEmpty { say(p, heroes.isEmpty ? "no_heroes" : university ? "university_brain_full" : "Rejected"); return true }
            choice = (objectText(p, "Initial") ?? objectText(p, "help") ?? "Learn a skill for 2000 gold?", options.map { "\($0.0.name): \(skillLabel($0.1, 0)) (2000)" }, { [weak self] k in
                guard let self = self else { return }
                guard self.resources["Gold", default: 0] >= 2000 else { self.say(p, university ? "university_no_money" : "denied"); return }
                self.resources["Gold", default: 0] -= 2000
                let o = options[k]
                self.teach(o.0, o.1, 0); o.0.visitedObjects.insert(key)
                self.say(p, "paid", ["%hero_name": o.0.name, "%skill_name": self.skillLabel(o.1, 0)])
            })
        case "school":   // library, war institute: a random step up for 2000 gold per hero, once each
            let magic = p.subtype == "library"
            let fresh = heroes.filter { !$0.visitedObjects.contains(key) }
            dialogueSound(10)
            guard !fresh.isEmpty else { say(p, heroes.isEmpty ? "need_hero" : "Empty"); return true }
            let total = 2000 * fresh.count
            question = (objectText(p, "Initial") ?? "Pay \(total) gold?", { [weak self] in
                guard let self = self else { return }
                guard self.resources["Gold", default: 0] >= total else { self.say(p, "denied"); return }
                self.resources["Gold", default: 0] -= total
                for h in fresh {
                    h.visitedObjects.insert(key)
                    let steps = (0..<36).filter { i in
                        let fam = RuleTables.primary(of: i)
                        return (magic ? fam >= 4 : fam < 4) && h.skill(id: fam) > 0 && h.skill(id: i) < 5 && h.meets(i, h.skill(id: i))
                    }
                    if !steps.isEmpty { let i = steps[self.rng(steps.count)]; self.teach(h, i, h.skill(id: i)) }
                }
                self.say(p, "paid")
            })
        case "shrine", "random_shrine":
            // every hero whose school skill reaches the spell's level learns it (0x46b8a0)
            guard let sp = st.spell else { return true }
            let def = RuleTables.spells[sp]
            let subs = ["%spell_name": def.name, "%magic_type": def.school.capitalized, "%skill_name": skillLabel(def.schoolSkill, max(0, def.level - 1))]
            let learners = heroes.filter { !$0.spells.contains(sp) && $0.canLearn(sp) }
            if !learners.isEmpty { for h in learners { h.spells.insert(sp) }; say(p, "initial", subs) }
            else if heroes.contains(where: { $0.spells.contains(sp) }) { say(p, "empty", subs) }
            else { say(p, "denied", subs) }
            dialogueSound(22)
        case "subterranean_gate":
            guard let to = st.partner else { say(p, "denied"); return true }
            teleport(hero, to: to, p)
        case "gateway", "teleporter_entrance":
            // to any gateway of the same colour (both ways), or any exit of a portal's colour; the player picks
            let want = p.type == "gateway" ? "gateway" : "teleporter_exit"
            var dests: [String] = []
            for l in scenes.indices { for q in scenes[l].placed where q.type == want && q.subtype == p.subtype && !(l == level && q.cellX == p.cellX && q.cellY == p.cellY) {
                dests.append("\(l)|\(q.cellX)|\(q.cellY)")
            } }
            dialogueSound(14)
            if dests.isEmpty { say(p, "denied"); return true }
            let labels = dests.map { d -> String in let c = d.split(separator: "|"); return "(\(c[1]), \(c[2]))" + (c[0] == "1" ? " underground" : "") }
            choice = (objectText(p, "Initial") ?? "Where to?", labels, { [weak self] k in self?.teleport(hero, to: dests[k], p) })
        case "teleporter_exit":
            say(p, "initial")
        case "whirlpool":
            // a random other whirlpool; each creature type loses a tenth (rounded up), heroes a tenth of their health
            var others: [String] = []
            for l in scenes.indices { for q in scenes[l].placed where q.type == "whirlpool" && !(l == level && q.cellX == p.cellX && q.cellY == p.cellY) { others.append("\(l)|\(q.cellX)|\(q.cellY)") } }
            guard !others.isEmpty else { say(p, "Denied"); return true }
            let to = others[rng(others.count)]
            var types: [String: Int] = [:], order: [String] = []
            for s in hero.army { if types[s.creature] == nil { order.append(s.creature) }; types[s.creature, default: 0] += s.count }
            for (k, c) in order.enumerated() {
                let n = types[c]!
                var loss = n > 1 ? (n + 9) / 10 : 1
                if loss >= n && k == order.count - 1 && heroes.isEmpty && order.dropLast().allSatisfy({ (types[$0] ?? 0) <= 1 }) { loss = n - 1 }
                var left = loss
                for i in hero.army.indices where hero.army[i].creature == c && left > 0 {
                    let t = min(left, hero.army[i].count); hero.army[i].count -= t; left -= t
                }
            }
            hero.army.removeAll { $0.count <= 0 }
            teleport(hero, to: to, p)
        case "keymaster_tent":
            dialogueSound(17)
            if keys.contains(p.subtype) { say(p, "Empty") } else { keys.insert(p.subtype); say(p, "Initial") }
        case "border_gate":
            if keys.contains(p.subtype) { remove(p) }   // the key opens it
            else { say(p, "Denied", ["%keymaster_tent_name": tables?.objectText("keymaster_tent", p.subtype, "name") ?? "Keymaster's Tent"]); dialogueSound(17) }
        case "border_guard":
            dialogueSound(17)
            if keys.contains(p.subtype) { question = (objectText(p, "Accepted") ?? "Open it?", { [weak self] in self?.remove(p) }) }
            else { say(p, "Denied", ["%keymaster_tent_name": tables?.objectText("keymaster_tent", p.subtype, "name") ?? "Keymaster's Tent"]) }
        case "tower", "cartographer":
            say(p, "Initial"); dialogueSound(26)
        case "obelisk":
            say(p, "initial"); dialogueSound(16)
        case "lighthouse":
            if st.owner == map.humanColour { say(p, "empty") } else { st.owner = map.humanColour; st.countdown = -1; say(p, "initial") }
        default:
            return false
        }
        return true
    }

    /// Through a portal: to a free cell next to the destination ("level|x|y"), on its level.
    func teleport(_ hero: Hero, to dest: String, _ from: MapScene.Placed) {
        let c = dest.split(separator: "|").compactMap { Int($0) }
        guard c.count == 3, c[0] < scenes.count else { return }
        let back = level
        level = c[0]
        guard let q = scene.placed.first(where: { $0.cellX == c[1] && $0.cellY == c[2] }) else { level = back; return }
        var cell: (Int, Int)? = nil
        for r in 1...3 where cell == nil {
            for dx in -r...q.sprite.footprint.w - 1 + r { for dy in -r...q.sprite.footprint.h - 1 + r where cell == nil {
                let x = q.cellX + dx, y = q.cellY + dy
                if isVacant((x, y), for: hero), !isDangerous(x, y) || r == 3 { cell = (x, y) }
            } }
        }
        guard let to = cell else { level = back; say(from, "Denied_no_room"); return }
        sounds.append("miscellaneous.teleport_out")
        hero.x = to.0; hero.y = to.1; hero.z = level
        hero.path = []; hero.plan = []; hero.target = nil; hero.progress = 0
        sounds.append("miscellaneous.teleport_in")
        say(from, "Initial")
        jumped = true
    }
}
