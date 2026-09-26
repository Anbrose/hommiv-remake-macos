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
        case "creature_bank":
            visitBank(hero, p, st)
        case "sign", "ocean_bottle":
            // the map's own text (a bottle is read once and gone); the sign passes sound id 20 (0x46db80)
            let t = record(for: p)?.text
            scripts.messages.append(t?.isEmpty == false ? t! : objectText(p, "help") ?? "")
            dialogueSound(20)
            if p.type == "ocean_bottle" { remove(p) }
        case "prison":
            // the prisoner joins the army if there is room (0x467b00)
            guard let mh = record(for: p)?.prisoner else { remove(p); return true }
            let slots = 1 + hero.companions.count + hero.army.count
            let name = mh.name.isEmpty ? "the prisoner" : mh.name
            guard slots < Hero.armySlots else { say(p, "Denied", ["%hero_name": name]); return true }
            let freed = Hero.fromMap(mh, alignment: hero.alignment, x: hero.x, y: hero.y, tables: tables, random: &random)
            freed.owner = hero.owner; freed.z = hero.z
            hero.companions.append(freed)
            say(p, "Initial", ["%hero_name": freed.name])
            dialogueSound(25)
            remove(p)
        case "pandoras_box":
            // the map's placed event of that name: its message, question, guards and rewards
            if let name = record(for: p)?.text, var e = map.placedEvents.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                run(event: &e, ScriptContext(current: actingColour, hero: hero))
            }
            remove(p)
        case "seers_hut", "quest_gate", "quest_guard":
            visitQuest(hero, p, &st)
        case "lighthouse":
            if st.owner == actingColour { say(p, "empty") } else { st.owner = actingColour; st.countdown = -1; say(p, "initial") }
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

    // MARK: creature banks (heroes4.exe 0x648980, table.creature_banks)

    /// Guards at their initial counts, the treasure worth 3 x their gold cost, then as many
    /// days' growth as rng() % 36 (0x649710).
    func setupBank(_ p: MapScene.Placed, _ st: inout ObjectState) {
        guard let t = tables, let b = t.banks[p.subtype] else { return }
        st.guardCreatures = b.guards.map { $0.creature }
        st.guardCounts = b.guards.map { $0.initial }
        st.guardFractions = b.guards.map { _ in 0 }
        let v = b.guards.reduce(0.0) { $0 + Double($1.initial * (t.creature($1.creature)?.gold ?? 0)) }
        st.initialWorth = Int((3 * v + 0.5).rounded(.down)); st.worth = st.initialWorth
        growBank(&st, days: rng(36))
    }
    /// Growth (0x64ae30): each guard type gains Per Day x days (in 1/256), whole creatures join
    /// and add 3 x their cost to the treasure.
    func growBank(_ st: inout ObjectState, days: Int) {
        guard days > 0, let t = tables else { return }
        let key = st.guardCreatures.joined(separator: ",")
        guard let b = t.banks.values.first(where: { $0.guards.map { $0.creature }.joined(separator: ",") == key }) else { return }
        for (i, g) in b.guards.enumerated() where i < st.guardCounts.count {
            st.guardFractions[i] += Int((g.perDay * 256 * Double(days)).rounded())
            let n = st.guardFractions[i] >> 8
            if n > 0 { st.guardCounts[i] += n; st.guardFractions[i] &= 0xff; st.worth += n * (t.creature(g.creature)?.gold ?? 0) * 3 }
        }
    }
    /// The treasure: the initial part split by the Initial percentages, what growth added by the
    /// Added ones, each material bought at its value (gold rounded down to 250s); the artifact share
    /// buys artifacts within the maximums (0x64af80).
    func bankTreasure(_ p: MapScene.Placed, _ st: ObjectState) -> (materials: [Int], artifacts: [Int]) {
        guard let t = tables, let b = t.banks[p.subtype] else { return ([Int](repeating: 0, count: 7), []) }
        let initialPart = Double(st.initialWorth), addedPart = Double(max(0, st.worth - st.initialWorth))
        let si = Double(max(1, b.initial.reduce(0, +))), sa = Double(max(1, b.added.reduce(0, +)))
        var mats = [Int](repeating: 0, count: 7)
        var carry = 0.0
        for m in (0..<7).reversed() {
            let worth = Double(b.initial[m]) * initialPart / si + Double(b.added[m]) * addedPart / sa + carry
            let amount = Int(worth) / GameState.materialValue[m]
            carry = worth - Double(amount * GameState.materialValue[m])
            mats[m] = amount
        }
        mats[0] = mats[0] / 250 * 250
        var artWorth = Double(b.initial[7]) * initialPart / si + Double(b.added[7]) * addedPart / sa
        var arts: [Int] = []
        let levels = [("treasure", b.maxima[4]), ("minor", b.maxima[5]), ("major", b.maxima[6])]
        var left = levels.map { $0.1 }
        while arts.count < max(0, b.maxima[7]) {
            let options = levels.indices.filter { left[$0] > 0 }
            guard let li = options.first(where: { i in artifactPool(level: levels[i].0).contains { (t.artifacts[RuleTables.artifactIds[$0]]?.cost ?? 0) <= Int(artWorth) } }) else { break }
            let pool = artifactPool(level: levels[li].0).filter { (t.artifacts[RuleTables.artifactIds[$0]]?.cost ?? 0) <= Int(artWorth) }
            let a = pool[rng(pool.count)]
            arts.append(a); left[li] -= 1; artWorth -= Double(t.artifacts[RuleTables.artifactIds[a]]?.cost ?? 0)
        }
        return (mats, arts)
    }
    func visitBank(_ hero: Hero, _ p: MapScene.Placed, _ st: ObjectState) {
        dialogueSound(2)
        guard st.guardCounts.contains(where: { $0 > 0 }) else { say(p, "empty"); return }
        let names = zip(st.guardCreatures, st.guardCounts).filter { $0.1 > 0 }.map { c, n -> String in
            let d = tables?.creature(c); return "\(n) \(n == 1 ? d?.name ?? c : d?.plural ?? c)" }
        let list = names.count <= 1 ? names.first ?? "" : names.dropLast().joined(separator: ", ") + " and " + names.last!
        let text = objectText(p, "Initial", ["%the_creatures": list, "%creatures": list, "%Creatures": list]) ?? "Fight them?"
        question = (text, { [weak self] in
            guard let self = self else { return }
            // the guards as one army to fight: the first stack leads, the rest follow it
            let stacks = zip(st.guardCreatures, st.guardCounts).filter { $0.1 > 0 }
            guard let lead = stacks.first else { return }
            var m = Monster(x: p.cellX, y: p.cellY, name: p.name, creature: lead.0, count: lead.1, extra: stacks.dropFirst().map { ($0.0, $0.1) })
            m.z = self.level; m.bank = self.objectKey(p)
            self.monsters.append(m)
            self.fight(hero: hero, monsterAt: self.monsters.count - 1, p)
        })
    }
    /// The bank's guards beaten: the treasure is the winner's, the bank empty for 28 days.
    func bankDefeated(_ hero: Hero, _ p: MapScene.Placed, key: String) {
        guard var st = objectStates[key] else { return }
        let loot = bankTreasure(p, st)
        for (m, n) in loot.materials.enumerated() where n > 0 { gain(m, n, at: hero) }
        for a in loot.artifacts { give(artifact: a, to: hero) }
        var items = (0..<7).filter { loot.materials[$0] > 0 }.map { materialList([($0, loot.materials[$0])]) }
        items += loot.artifacts.map { artifactName($0, article: true) }
        say(p, "defeat", ["%reward_list": items.joined(separator: ", ")])
        st.guardCounts = st.guardCounts.map { _ in 0 }; st.guardFractions = st.guardFractions.map { _ in 0 }
        st.worth = 0; st.initialWorth = 0; st.countdown = 28
        objectStates[key] = st
    }

    /// Debugging: a bank's guards and what it would give now.
    public func debugBank(_ p: MapScene.Placed) -> String {
        guard let st = objectStates[objectKey(p)] else { return "-" }
        let t = bankTreasure(p, st)
        return "guards \(zip(st.guardCreatures, st.guardCounts).map { "\($0.1) \($0.0)" }) worth \(st.worth) treasure \(t.materials) artifacts \(t.artifacts.map { artifactName($0) })"
    }

    /// The map record of a placed object.
    func record(for p: MapScene.Placed) -> MapObject? {
        map.objects.first { $0.x == p.cellX && $0.y == p.cellY && $0.level == level && $0.type == p.type }
    }
    /// A quest (0x7ee2a0): the first visit shows the proposal; when the condition holds the quest is
    /// done -- a gate or guard lets the army through (it is gone), a hut gives its reward -- else
    /// the "not yet" text. Texts: name, objective, proposal, not yet; then the completion text.
    func visitQuest(_ hero: Hero, _ p: MapScene.Placed, _ st: inout ObjectState) {
        guard let r = record(for: p), r.questTexts.count >= 4 else { say(p, "help"); return }
        dialogueSound(17)
        if st.used { scripts.messages.append(r.questTexts.count > 5 ? r.questTexts[5] : (objectText(p, "completed") ?? r.questTexts[1])); return }
        let c = ScriptContext(current: actingColour, hero: hero)
        let first = st.countdown == 0
        st.countdown = 1
        if first, !r.questTexts[2].isEmpty { scripts.messages.append(r.questTexts[2]) }
        if let cond = r.questCondition, truth(cond, c) {
            st.used = true
            if r.questTexts.count > 4, !r.questTexts[4].isEmpty { scripts.messages.append(r.questTexts[4]) }
            var removed = false
            if let a = r.questAction2 { exec(a, c, &removed) }
            if let a = r.questAction { exec(a, c, &removed) }
            if p.type != "seers_hut" { remove(p) }
        } else if !first {
            scripts.messages.append(r.questTexts[3])
        }
    }
    /// An event trigger on a cell the army stepped onto: its placed event runs once.
    func stepped(_ hero: Hero, onto x: Int, _ y: Int) {
        guard let p = scene.placed.first(where: { $0.type == "event_trigger" && $0.cellX == x && $0.cellY == y }),
              let name = record(for: p)?.text, objectStates[objectKey(p)]?.used != true,
              var e = map.placedEvents.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        objectStates[objectKey(p), default: ObjectState()].used = true
        run(event: &e, ScriptContext(current: actingColour, hero: hero))
    }
}
