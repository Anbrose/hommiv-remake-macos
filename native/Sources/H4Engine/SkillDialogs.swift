import Foundation

/// The selection dialogs of the teaching objects (re/schools_spec.md): t_dialog_beastmaster (huts),
/// t_dialog_school_of_magic (schools), t_seminary_window (universities), t_dialog_war_institute
/// (Library / Veteran's Guild) and t_dialog_tree_of_knowledge. The UI draws it and passes the clicks
/// on; what may be ticked, what it costs and what Learn / Buy does live here.
public final class SkillDialog {
    public enum Kind: Equatable {
        /// A Witch's / Beastmaster's hut and its primary (taught at basic, free).
        case hut(skill: Int)
        /// A School of Magic / War and its two primaries (2000 each, one class per hero for good).
        case school(skills: [Int])
        /// A Magic / War University and its four secondaries (2000 each).
        case university(skills: [Int])
        /// The Library (magic) / Veteran's Guild: a known skill one level up, 2000 per hero.
        case library(magic: Bool)
        /// The Tree of Knowledge: a level for `price` of the material (0 gold, 6 gems) per hero.
        case tree(material: Int, price: Int)
    }
    public let kind: Kind
    public let place: MapScene.Placed
    public let title: String, text: String
    /// The army's heroes, one portrait each.
    public let heroes: [Hero]
    /// The portraits ticked (huts, schools, library, tree: several heroes at once).
    public var ticked: [Bool]
    /// The skill chosen: the school's radio (0 or 1), the university's slot (0...3).
    public var choice = 0
    /// The university's hero (its ring row is a single choice).
    public var hero: Int? = nil
    /// The visiting army's cell: the Tree's Paid message stands above it (0x476c75).
    public var anchor: (x: Int, y: Int)? = nil
    init(kind: Kind, place: MapScene.Placed, title: String, text: String, heroes: [Hero]) {
        self.kind = kind; self.place = place; self.title = title; self.text = text; self.heroes = heroes
        ticked = heroes.map { _ in false }
    }
}

extension GameState {
    func primaryCount(_ h: Hero) -> Int { (0..<9).filter { h.skill(id: $0) > 0 }.count }

    /// A portrait can be ticked (or, at a university, chosen).
    public func skillDialogEnabled(_ d: SkillDialog, _ k: Int) -> Bool {
        guard k < d.heroes.count else { return false }
        let h = d.heroes[k], key = objectKey(d.place)
        switch d.kind {
        case .hut(let s): return h.skill(id: s) == 0 && primaryCount(h) < 5
        case .school(let s):   // 0x6f1c30, for the skill chosen
            return !h.visitedObjects.contains(key) && h.skill(id: s[d.choice]) == 0 && primaryCount(h) < 5
        case .university: return true
        case .library(let magic): return !h.visitedObjects.contains(key) && !libraryCandidates(h, magic: magic).isEmpty
        case .tree: return h.level < 70 && !h.visitedObjects.contains(key)
        }
    }
    /// A portrait's balloon: the hero's name, or why it cannot be ticked.
    public func skillDialogTip(_ d: SkillDialog, _ k: Int) -> String {
        guard k < d.heroes.count else { return "" }
        let h = d.heroes[k]
        if skillDialogEnabled(d, k) { return h.name }
        switch d.kind {
        case .hut(let s):
            let key = h.skill(id: s) > 0 ? "already_known.beastmaster" : "brain_full.beastmaster"
            return text(key, "").replacingOccurrences(of: "%hero_name", with: h.name)
        case .school(let s):
            if h.visitedObjects.contains(objectKey(d.place)) { return objectText(d.place, "help_visited") ?? "" }
            if h.skill(id: s[d.choice]) > 0 { return objectText(d.place, "help.already_knows") ?? "" }
            return objectText(d.place, "help.rejected") ?? ""
        case .library, .tree: return objectText(d.place, "help.rejected") ?? ""
        case .university: return h.name
        }
    }
    /// Tick or untick a portrait (an enabled one only); the university chooses its hero.
    public func skillDialogToggle(_ d: SkillDialog, _ k: Int) {
        guard skillDialogEnabled(d, k) else { return }
        if case .university = d.kind { d.hero = k; return }
        d.ticked[k].toggle()
    }
    /// The school's skill radio: the other skill, its portraits re-evaluated (0x6f1c30).
    public func skillDialogChoose(_ d: SkillDialog, _ i: Int) {
        d.choice = i
        if case .school = d.kind { for k in d.heroes.indices { d.ticked[k] = skillDialogEnabled(d, k) } }   // the enabled ones ticked again
    }
    /// The heroes ticked that Learn / Buy would take.
    func skillDialogChosen(_ d: SkillDialog) -> [Hero] {
        d.heroes.indices.filter { d.ticked[$0] && skillDialogEnabled(d, $0) }.map { d.heroes[$0] }
    }
    /// The material and the total Learn / Buy costs now (gold 0, gems 6).
    public func skillDialogCost(_ d: SkillDialog) -> (material: Int, amount: Int) {
        switch d.kind {
        case .hut: return (0, 0)
        case .school, .library: return (0, 2000 * skillDialogChosen(d).count)
        case .university: return (0, universityStatus(d).cost)
        case .tree(let m, let p): return (m, p * skillDialogChosen(d).count)
        }
    }
    /// Learn / Buy can be pressed: a hut with a hero ticked; elsewhere 0 < cost <= what the kingdom has.
    public func skillDialogCanLearn(_ d: SkillDialog) -> Bool {
        if case .hut = d.kind { return !skillDialogChosen(d).isEmpty }
        let c = skillDialogCost(d)
        return c.amount > 0 && c.amount <= resources[GameState.materialNames[c.material], default: 0]
    }
    /// The school's Learn balloon follows the cost (0x6f23c0): help.learn, help.denied when it is more
    /// than the gold, nothing at 0; the other dialogs keep shared.learn / shared.buy (nil).
    public func skillDialogLearnTip(_ d: SkillDialog) -> String? {
        guard case .school = d.kind else { return nil }
        let c = skillDialogCost(d).amount
        if c == 0 { return "" }
        return objectText(d.place, c <= resources["Gold", default: 0] ? "help.learn" : "help.denied") ?? ""
    }
    /// Learn / Buy (0x670940, 0x6f20a0, 0x840770, 0x704970, 0x6fc980). The hut, the library and the
    /// tree close their dialog; a school and a university stay open for more.
    public func skillDialogLearn(_ d: SkillDialog) {
        guard skillDialogCanLearn(d) else { return }
        let p = d.place, key = objectKey(p)
        switch d.kind {
        case .hut(let s):
            let learners = skillDialogChosen(d)
            skillDialog = nil
            for h in learners { teach(h, s, 0) }
            sayWith(p, "accept", ["%skill_name": skillLabel(s, 0)], titled: false, pictures: [.skill(s, level: 0)] + learners.map { .hero($0) })
        case .school(let sk):
            let s = sk[d.choice], learners = skillDialogChosen(d)
            for h in learners { teach(h, s, 0); h.visitedObjects.insert(key) }
            resources["Gold", default: 0] -= 2000 * learners.count
            skillDialogChoose(d, d.choice)   // the portraits refreshed: the learners are done here
            sayWith(p, "paid", ["%skill_name": skillLabel(s, 0)], titled: false, pictures: [.skill(s, level: 0)] + learners.map { .hero($0) })
        case .university:
            guard let k = d.hero, let o = universitySlot(d.heroes[k], d.place, d.choice) else { return }
            let h = d.heroes[k]
            resources["Gold", default: 0] -= 2000
            let t = text("learned_skill_university.dialog", "Your hero is now skilled in %skill_name.").replacingOccurrences(of: "%skill_name", with: skillLabel(o.skill, o.level))
            scripts.messages.append(t)
            messagePictures[t] = [.skill(o.skill, level: o.level), .hero(h)]
            teach(h, o.skill, o.level)
            h.universitySlots["\(key)|\(d.choice)"] = [o.skill, o.level]
        case .library(let magic):
            let learners = skillDialogChosen(d)
            skillDialog = nil
            resources["Gold", default: 0] -= 2000 * learners.count
            var pics: [MessagePicture] = []
            for h in learners {
                let c = libraryCandidates(h, magic: magic), i = c[rng(c.count)], l = h.skill(id: i)
                teach(h, i, l)
                pics.append(.skill(i, level: l))
                h.visitedObjects.insert(key)
            }
            sayWith(p, "paid", titled: false, pictures: pics)
        case .tree(let m, let price):
            let buyers = skillDialogChosen(d)
            skillDialog = nil
            for h in buyers { h.visitedObjects.insert(key) }
            resources[GameState.materialNames[m], default: 0] -= price * buyers.count
            let t = sayWith(p, "Paid", ["%material": materialList([(m, price * buyers.count)])], titled: false, pictures: buyers.map { .hero($0) })
            if let t = t, let a = d.anchor { messageAnchors[t] = a }   // above the army, as the visit's own messages
            for h in buyers {   // 0x72c420: a full level's width, or up to the next level
                let lo = Hero.experienceTable[min(70, h.level)], hi = Hero.experienceTable[min(70, h.level + 1)]
                giveExperience(h.experience >= lo ? hi - lo : hi - h.experience, toOnly: h)
            }
        }
    }

    // MARK: the Library / Veteran's Guild

    /// What the Library (magic) / Veteran's Guild may raise for a hero (0x8cb4f0 over 0x729e30):
    /// every skill of its kind the hero knows at basic to expert whose next level's requirements hold.
    func libraryCandidates(_ h: Hero, magic: Bool) -> [Int] {
        (0..<36).filter { i in
            let fam = RuleTables.primary(of: i), l = h.skill(id: i)
            return (magic ? fam >= 4 : fam < 4) && l >= 1 && l <= 4 && h.meets(i, l)
        }
    }

    // MARK: the universities

    /// A university's four slots for a hero (0x83e470): each starts as {skill i, basic}, or what the
    /// hero took in that slot here (hero+0x7c4); then, in slot order, 0x83e2f0 may swap in an
    /// alternate.
    public func universitySlots(_ h: Hero, _ p: MapScene.Placed) -> [(skill: Int, level: Int, alternate: Bool, stored: Bool)] {
        guard let st = objectStates[objectKey(p)] else { return [] }
        let key = objectKey(p)
        var slots: [(skill: Int, level: Int)] = st.skills.indices.map { i in
            if let r = h.universitySlots["\(key)|\(i)"], r.count == 2 { return (r[0], r[1]) }
            return (st.skills[i], 0)
        }
        /// 0x83e2f0: unchanged when the hero lacks the skill's primary with five primaries known, when
        /// its requirements hold or the hero has it; else the first requirement (0x8559f0) that no slot
        /// shows, itself resolved the same way. A slot showing a requirement is resolved first (the
        /// exe stores that back), and the requirement is passed over while the slot still shows it.
        func resolve(_ s: (skill: Int, level: Int), _ depth: Int = 0) -> (skill: Int, level: Int) {
            guard depth < 8 else { return s }
            if h.skill(id: RuleTables.primary(of: s.skill)) == 0 && primaryCount(h) >= 5 { return s }
            if h.meets(s.skill, s.level) || h.lv(s.skill) >= s.level { return s }
            for need in Hero.requirements[s.skill][s.level] {
                let r = (skill: need.0, level: need.1)
                var shown = false
                for j in stride(from: slots.count - 1, through: 0, by: -1) where slots[j] == r {
                    slots[j] = resolve(slots[j], depth + 1)
                    if slots[j] == r { shown = true; break }
                }
                if !shown { return resolve(r, depth + 1) }
            }
            return s
        }
        for i in slots.indices { slots[i] = resolve(slots[i]) }
        return slots.indices.map { i in
            let stored = h.universitySlots["\(key)|\(i)"]?.count == 2
            return (slots[i].skill, slots[i].level, slots[i] != (st.skills[i], 0), stored)
        }
    }
    public func universitySlot(_ h: Hero, _ p: MapScene.Placed, _ i: Int) -> (skill: Int, level: Int, alternate: Bool, stored: Bool)? {
        let s = universitySlots(h, p)
        return i < s.count ? s[i] : nil
    }
    /// The status line of the slot chosen and its cost (0x83fa40): 2000 only for a slot the hero can take.
    public func universityStatus(_ d: SkillDialog) -> (text: String, cost: Int) {
        guard case .university(let skills) = d.kind else { return ("", 0) }
        let p = d.place
        func say(_ key: String, _ subs: [String: String]) -> String { objectText(p, key, subs) ?? "" }
        guard let k = d.hero, k < d.heroes.count else { return (say("university_no_heroes", [:]), 0) }
        let h = d.heroes[k]
        guard let o = universitySlot(h, p, d.choice) else { return ("", 0) }
        let he = h.isFemale ? "she" : "he"
        var subs = ["%hero_name": h.name, "%Hero_name": h.name, "%skill_name": skillLabel(o.skill, o.level),
                    "%he": he, "%He": he.capitalized]
        if h.skill(id: o.skill) > o.level { return (say(o.stored ? "university_learned_here" : "university_skill_known", subs), 0) }
        if resources["Gold", default: 0] < 2000 { return (say("university_no_money", subs), 0) }
        if h.skill(id: RuleTables.primary(of: o.skill)) == 0 && primaryCount(h) >= 5 { return (say("university_brain_full", subs), 0) }
        if let need = Hero.requirements[o.skill][o.level].first(where: { h.lv($0.0) < $0.1 }) {
            subs["%required_skill_name"] = skillLabel(need.0, need.1)
            return (say("university_not_qualified", subs), 0)
        }
        if o.alternate, d.choice < skills.count {
            subs["%advanced_skill_name"] = skillLabel(skills[d.choice], 0)
            return (say("university_alternate_skill", subs), 2000)
        }
        return (say("university_legal_skill", subs), 2000)
    }
}

extension Hero {
    /// The hero's sex as its adventure model shows it ("hero.<model>_<might|magic>_female").
    var isFemale: Bool { actor.lowercased().hasSuffix("_female") }
}
