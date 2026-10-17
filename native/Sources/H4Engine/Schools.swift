import Foundation

/// Witch's and Beastmaster's huts, Schools of Magic / War, the universities, the Library and the
/// Veteran's Guild, spell shrines: their visits as heroes4.exe makes them (re/schools_spec.md).
/// Their selection dialogs are SkillDialogs.swift.
extension GameState {
    /// A hut (0x58ae80): free, its primary at basic for the heroes who lack it and know fewer than
    /// five primaries. no_heroes; then already_known when any hero knows it, else cannot_learn, both
    /// with the skill's picture; else the hut's sound and t_dialog_beastmaster with every hero, those
    /// who can learn ticked. The computer's heroes learn at once.
    func visitHut(_ hero: Hero, _ p: MapScene.Placed, _ st: ObjectState) {
        guard let s = st.skills.first else { return }
        let heroes = armyHeroes(hero)
        let subs = ["%skill_name": skillLabel(s, 0)]
        if heroes.isEmpty { say(p, "no_heroes", subs); return }
        let learners = heroes.filter { $0.skill(id: s) == 0 && primaryCount($0) < 5 }
        if !isHumanActing { for h in learners { teach(h, s, 0) }; return }
        guard !learners.isEmpty else {
            sayWith(p, heroes.contains { $0.skill(id: s) > 0 } ? "already_known" : "cannot_learn", subs, titled: false, pictures: [.skill(s, level: 0)])
            return
        }
        dialogueSound(29)
        let d = SkillDialog(kind: .hut(skill: s), place: p, title: objectText(p, "name", subs) ?? "", text: objectText(p, "initial", subs) ?? "", heroes: heroes)
        for k in heroes.indices { d.ticked[k] = skillDialogEnabled(d, k) }   // 0x6508d0: every enabled hero ticked
        skillDialog = d
    }

    /// A School of Magic / War (0x819560): the sound first; Empty without a hero or without one who
    /// can learn (fewer than five primaries, one of the two skills unknown, no class taken here yet);
    /// else t_dialog_school_of_magic: the two skills, the heroes to tick, 2000 gold each.
    func visitSchool(_ hero: Hero, _ p: MapScene.Placed, _ st: ObjectState) {
        let key = objectKey(p)
        let heroes = armyHeroes(hero)
        let eligible = heroes.filter { h in !h.visitedObjects.contains(key) && primaryCount(h) < 5 && st.skills.contains { h.skill(id: $0) == 0 } }
        if !isHumanActing {   // the computer: the first class it can pay for (valuation 0x51a3d0 not reversed)
            for h in eligible {
                guard resources["Gold", default: 0] >= 2000 else { break }
                guard let s = st.skills.first(where: { h.skill(id: $0) == 0 }) else { continue }
                resources["Gold", default: 0] -= 2000; teach(h, s, 0); h.visitedObjects.insert(key)
            }
            return
        }
        dialogueSound(29)
        if eligible.isEmpty || st.skills.count < 2 { say(p, "Empty"); return }
        let d = SkillDialog(kind: .school(skills: Array(st.skills.prefix(2))), place: p, title: objectText(p, "name") ?? "",
                            text: objectText(p, "Initial") ?? "", heroes: heroes)
        skillDialogChoose(d, 0)   // icon_1 chosen, its heroes ticked
        skillDialog = d
    }

    /// A university (0x7660a0): the sound, help.empty without a hero, else t_seminary_window: the four
    /// slots for the hero chosen, a status line, 2000 gold a class, several per visit.
    func visitUniversity(_ hero: Hero, _ p: MapScene.Placed, _ st: ObjectState) {
        let heroes = armyHeroes(hero)
        if !isHumanActing {   // 0x7671e0: a skill the hero lacks whose basic requirements hold (valuation not reversed: the first)
            for h in heroes {
                for s in st.skills where h.skill(id: s) == 0 && h.meets(s, 0) {
                    guard resources["Gold", default: 0] >= 2000 else { return }
                    resources["Gold", default: 0] -= 2000; teach(h, s, 0)
                }
            }
            return
        }
        dialogueSound(29)
        if heroes.isEmpty { say(p, "help.empty"); return }
        let d = SkillDialog(kind: .university(skills: st.skills), place: p, title: objectText(p, "name") ?? "", text: "", heroes: heroes)
        d.hero = 0   // the first hero chosen
        skillDialog = d
    }

    /// The Library / Veteran's Guild (0x8c9fd0): a known skill of its kind (basic to expert) one
    /// level up, at random per hero, 2000 gold each, once per hero. The sound first; Empty when the
    /// heroes have nothing to learn here, need_hero without one; else t_dialog_war_institute with
    /// the heroes who can, ticked.
    func visitLibrary(_ hero: Hero, _ p: MapScene.Placed) {
        let key = objectKey(p)
        let magic = p.subtype == "library"
        let heroes = armyHeroes(hero)
        let fresh = heroes.filter { !$0.visitedObjects.contains(key) && !libraryCandidates($0, magic: magic).isEmpty }
        if !isHumanActing {   // the computer pays nothing (0x8c9fd0's AI path), gold >= 2000 only gates it
            guard resources["Gold", default: 0] >= 2000 else { return }
            for h in fresh { let c = libraryCandidates(h, magic: magic); let i = c[rng(c.count)]; teach(h, i, h.skill(id: i)); h.visitedObjects.insert(key) }
            return
        }
        dialogueSound(10)
        guard !fresh.isEmpty else { say(p, heroes.isEmpty ? "need_hero" : "Empty"); return }
        let d = SkillDialog(kind: .library(magic: magic), place: p, title: objectText(p, "name") ?? "", text: objectText(p, "Initial") ?? "", heroes: heroes)
        for k in heroes.indices { d.ticked[k] = skillDialogEnabled(d, k) }
        skillDialog = d
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
