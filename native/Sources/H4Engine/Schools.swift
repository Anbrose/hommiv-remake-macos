import Foundation

/// Witch's and Beastmaster's huts, Schools of Magic / War, the universities, the Library and the
/// Veteran's Guild, spell shrines: their visits as heroes4.exe makes them (re/schools_spec.md).
/// The original's own selection dialogs (beastmaster, school_of_magic, magic_university,
/// war_institute) are not built yet: the huts and the library take every eligible hero (the
/// dialogs preselect all of them), the schools and universities offer their choice list.
extension GameState {
    private func primaries(_ h: Hero) -> Int { (0..<9).filter { h.skill(id: $0) > 0 }.count }

    /// A hut (0x58ae80): free, its primary at basic for every hero who lacks it and knows fewer than
    /// five primaries. no_heroes; then already_known when any hero knows it, else cannot_learn, both
    /// with the skill's picture; on success the hut's sound and `accept` with the skill and the learners.
    func visitHut(_ hero: Hero, _ p: MapScene.Placed, _ st: ObjectState) {
        guard let s = st.skills.first else { return }
        let heroes = armyHeroes(hero)
        let subs = ["%skill_name": skillLabel(s, 0)]
        if heroes.isEmpty { say(p, "no_heroes", subs); return }
        let learners = heroes.filter { $0.skill(id: s) == 0 && primaries($0) < 5 }
        if !isHumanActing { for h in learners { teach(h, s, 0) }; return }
        guard !learners.isEmpty else {
            sayWith(p, heroes.contains { $0.skill(id: s) > 0 } ? "already_known" : "cannot_learn", subs, titled: false, pictures: [.skill(s, level: 0)])
            return
        }
        dialogueSound(29)
        for h in learners { teach(h, s, 0) }
        sayWith(p, "accept", subs, titled: false, pictures: [.skill(s, level: 0)] + learners.map { .hero($0) })
    }

    /// A School of Magic / War (0x819560): the sound first; Empty without a hero or without one who
    /// can learn (fewer than five primaries, one of the two skills unknown, no class taken here yet).
    /// A class costs 2000 gold and marks the hero for good; `paid` shows the skill and the hero.
    func visitSchool(_ hero: Hero, _ p: MapScene.Placed, _ st: ObjectState) {
        let key = objectKey(p)
        let heroes = armyHeroes(hero)
        var options: [(Hero, Int)] = []
        for h in heroes where !h.visitedObjects.contains(key) && primaries(h) < 5 {
            for s in st.skills where h.skill(id: s) == 0 { options.append((h, s)) }
        }
        if !isHumanActing {   // the computer: the first class it can pay for (valuation 0x51a3d0 not reversed)
            for (h, s) in options where !h.visitedObjects.contains(key) && resources["Gold", default: 0] >= 2000 {
                resources["Gold", default: 0] -= 2000; teach(h, s, 0); h.visitedObjects.insert(key)
            }
            return
        }
        dialogueSound(29)
        if options.isEmpty { say(p, "Empty"); return }
        choice = (objectText(p, "Initial") ?? "", options.map { "\($0.0.name): \(skillLabel($0.1, 0)) (2000)" }, { [weak self] k in
            guard let self = self else { return }
            guard self.resources["Gold", default: 0] >= 2000 else { self.say(p, "help.denied"); return }   // (the exe's Learn is disabled)
            self.resources["Gold", default: 0] -= 2000
            let o = options[k]
            self.teach(o.0, o.1, 0); o.0.visitedObjects.insert(key)
            self.sayWith(p, "paid", ["%hero_name": o.0.name, "%skill_name": self.skillLabel(o.1, 0)], titled: false, pictures: [.skill(o.1, level: 0), .hero(o.0)])
        })
    }

    /// A university slot for a hero (0x83e470 / 0x83e2f0): the skill at basic, or, when its
    /// requirements are not met, the first unmet requirement (recursively) instead; nil when the hero
    /// already has it or lacks the primary with five primaries known.
    func universityOffer(_ h: Hero, _ s: Int) -> (skill: Int, level: Int)? {
        var cur = (skill: s, level: 0)
        for _ in 0..<8 {
            guard h.skill(id: cur.skill) <= cur.level else { return nil }   // known at that level
            let prim = RuleTables.primary(of: cur.skill)
            if h.skill(id: prim) == 0 && primaries(h) >= 5 { return nil }
            guard let need = Hero.requirements[cur.skill][cur.level].first(where: { h.skill(id: $0.0) < $0.1 + 1 }) else { return cur }
            cur = (need.0, need.1)
        }
        return nil
    }
    /// A university (0x7660a0): four secondaries at 2000 each, several per visit; a slot whose
    /// requirements are unmet offers the requirement instead. help.empty without a hero; success
    /// shows learned_skill_university.dialog with the skill and the hero.
    func visitUniversity(_ hero: Hero, _ p: MapScene.Placed, _ st: ObjectState) {
        let heroes = armyHeroes(hero)
        var options: [(Hero, (skill: Int, level: Int))] = []
        for h in heroes { for s in st.skills { if let o = universityOffer(h, s), !options.contains(where: { $0.0 === h && $0.1 == o }) { options.append((h, o)) } } }
        if !isHumanActing {
            for (h, o) in options where resources["Gold", default: 0] >= 2000 { resources["Gold", default: 0] -= 2000; teach(h, o.skill, o.level) }
            return
        }
        dialogueSound(29)
        if heroes.isEmpty { say(p, "help.empty"); return }
        if options.isEmpty { say(p, "Empty"); return }
        choice = (objectText(p, "Initial") ?? "", options.map { "\($0.0.name): \(skillLabel($0.1.skill, $0.1.level)) (2000)" }, { [weak self] k in
            guard let self = self else { return }
            let o = options[k]
            guard self.resources["Gold", default: 0] >= 2000 else { self.say(p, "university_no_money", ["%hero_name": o.0.name, "%Hero_name": o.0.name, "%skill_name": self.skillLabel(o.1.skill, o.1.level)]); return }
            self.resources["Gold", default: 0] -= 2000
            self.teach(o.0, o.1.skill, o.1.level)
            let t = self.text("learned_skill_university.dialog", "Your hero is now skilled in %skill_name.").replacingOccurrences(of: "%skill_name", with: self.skillLabel(o.1.skill, o.1.level))
            self.scripts.messages.append(t)
            self.messagePictures[t] = [.skill(o.1.skill, level: o.1.level), .hero(o.0)]
        })
    }

    /// The Library / Veteran's Guild (0x8c9fd0): a known skill of its kind (basic to master) one
    /// level up, at random per hero, 2000 gold each, once per hero. The sound first; Empty when the
    /// heroes have nothing to learn here, need_hero without one; `paid` shows each hero's new skill.
    func visitLibrary(_ hero: Hero, _ p: MapScene.Placed) {
        let key = objectKey(p)
        let magic = p.subtype == "library"
        let heroes = armyHeroes(hero)
        func steps(_ h: Hero) -> [Int] {
            (0..<36).filter { i in
                let fam = RuleTables.primary(of: i), l = h.skill(id: i)
                return (magic ? fam >= 4 : fam < 4) && l >= 1 && l <= 4 && h.meets(i, l)
            }
        }
        let fresh = heroes.filter { !$0.visitedObjects.contains(key) && !steps($0).isEmpty }
        if !isHumanActing {   // the computer pays nothing (0x8c9fd0's AI path), gold >= 2000 only gates it
            guard resources["Gold", default: 0] >= 2000 else { return }
            for h in fresh { let c = steps(h); let i = c[rng(c.count)]; teach(h, i, h.skill(id: i)); h.visitedObjects.insert(key) }
            return
        }
        dialogueSound(10)
        guard !fresh.isEmpty else { say(p, heroes.isEmpty ? "need_hero" : "Empty"); return }
        let total = 2000 * fresh.count
        question = (objectText(p, "Initial") ?? "", { [weak self] in
            guard let self = self else { return }
            guard self.resources["Gold", default: 0] >= total else { self.say(p, "help.denied"); return }
            self.resources["Gold", default: 0] -= total
            var pics: [MessagePicture] = []
            for h in fresh {
                h.visitedObjects.insert(key)
                let c = steps(h), i = c[self.rng(c.count)], l = h.skill(id: i)
                self.teach(h, i, l)
                pics.append(.skill(i, level: l))
            }
            self.sayWith(p, "paid", titled: false, pictures: pics)
        })
    }

    /// A spell shrine (0x46b8a0): every hero whose school skill reaches the spell's level learns it;
    /// the computer silently. Titled, the spell's icon, then `initial` with the learners, `empty`, or
    /// `denied` with the skill it needs; sound 22.
    func visitShrine(_ hero: Hero, _ p: MapScene.Placed, _ st: ObjectState) {
        guard let sp = st.spell else { return }
        let def = RuleTables.spells[sp]
        let heroes = armyHeroes(hero)
        let learners = heroes.filter { !$0.spells.contains(sp) && $0.canLearn(sp) }
        for h in learners { h.spells.insert(sp) }
        guard isHumanActing else { return }
        let need = max(0, def.level - 1)
        let subs = ["%spell_name": def.name, "%magic_type": def.school.capitalized, "%skill_name": skillLabel(def.schoolSkill, need), "%spell_level": "\(def.level)"]
        if !learners.isEmpty { sayWith(p, "initial", subs, pictures: [.spell(sp)] + learners.map { .hero($0) }) }
        else if heroes.contains(where: { $0.spells.contains(sp) }) { sayWith(p, "empty", subs, pictures: [.spell(sp)]) }
        else { sayWith(p, "denied", subs, pictures: [.spell(sp)] + (def.schoolSkill >= 0 ? [.skill(def.schoolSkill, level: need)] : [])) }
        dialogueSound(22)
    }
}
