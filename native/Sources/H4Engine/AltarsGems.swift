import Foundation

/// A dialog in which the player picks which hero of the army takes an object's gift: an altar's
/// skill (t_dialog_altar, layers.dialog.altars) or a magic gem (t_dialog_magic_gem,
/// layers.dialog.pick_hero). re/altar_gem_spec.md.
public struct HeroPick {
    public enum Kind {
        /// An altar of this primary skill (0...8): its 82-px icon at basic and the skill's name.
        case altar(skill: Int)
        /// A magic gem by subtype (0 opal, 1 sapphire, 2 ruby, 3 emerald): its stat icon and "+6" / "+2".
        case gem(kind: Int)
    }
    public let kind: Kind
    public let title: String, text: String
    /// The heroes offered, one ring each, and whether each ring can be chosen.
    public let heroes: [Hero], enabled: [Bool]
    /// OK with the chosen hero (the dialog closes; the object is used up).
    public let ok: (Hero) -> Void
}

/// A picture a message box shows under its text, with its caption (t_basic_dialog items).
public enum MessagePicture {
    /// A skill at a level (0 basic ... 4 grandmaster) in its frame, captioned "Basic Tactics" (0x55c750).
    case skill(Int, level: Int)
    /// A hero's portrait in its ring, captioned with the name (0x64ddb0).
    case hero(Hero)
    /// A material gained: layers.icons.materials.32 captioned "+300 gold" (0x55a040, "%+i %s").
    case material(Int, amount: Int)
    /// An artifact: its icon captioned with its name, bare or in button.frame_52 (0x55c300).
    case artifact(Int, framed: Bool)
}

extension GameState {
    /// The material pictures of a reward: one per material gained, gold, wood, ore, crystal,
    /// sulfur, mercury, gems in that order (0x55a3e0).
    func materialPictures(_ items: [(Int, Int)]) -> [MessagePicture] {
        var n = [Int](repeating: 0, count: 7)
        for (m, k) in items where m >= 0 && m < 7 { n[m] += k }
        return (0..<7).filter { n[$0] != 0 }.map { .material($0, amount: n[$0]) }
    }
    /// An object's message with its pictures, and its name as the title when `titled` (t_basic_dialog).
    func sayWith(_ p: MapScene.Placed, _ key: String, _ subs: [String: String] = [:], titled: Bool = true, pictures: [MessagePicture]) {
        guard let t = objectText(p, key, subs) else { return }
        scripts.messages.append(t)
        if titled, let name = objectText(p, "name") { messageTitles[t] = name }
        if !pictures.isEmpty { messagePictures[t] = pictures }
    }
}

extension GameState {
    /// The skill steps an altar of `family` can give a hero (t_dialog_altar's OK, 0x66e480): the
    /// primary at basic when the hero lacks it, else every skill of the family below grandmaster whose
    /// next level's requirements hold, in skill order (levels 0 basic ... 4 grandmaster).
    func altarSteps(_ h: Hero, family: Int) -> [(skill: Int, level: Int)] {
        if h.skill(id: family) == 0 { return h.meets(family, 0) ? [(family, 0)] : [] }
        return (0..<36).compactMap { i in
            guard RuleTables.primary(of: i) == family else { return nil }
            let l = h.skill(id: i)   // the next level (0 basic ... 4 grandmaster)
            return l < 5 && h.meets(i, l) ? (i, l) : nil
        }
    }
    /// The hero may take something from the altar (0x42d830's test): a new primary while it knows
    /// fewer than five, or a step in the family it knows.
    func altarEligible(_ h: Hero, family: Int) -> Bool {
        if h.skill(id: family) == 0 { return (0..<9).filter { h.skill(id: $0) > 0 }.count < 5 }
        return !altarSteps(h, family: family).isEmpty
    }

    /// An altar (t_adv_altar 0x42d830): the heroes who can learn pick one in the altar dialog; OK
    /// teaches that hero a random step of the family and the altar is gone. Without a hero who can,
    /// the altar asks whether to destroy it.
    func visitAltar(_ hero: Hero, _ p: MapScene.Placed, _ st: ObjectState) {
        guard let family = st.skills.first else { return }
        let heroes = armyHeroes(hero)
        let eligible = heroes.filter { altarEligible($0, family: family) }
        guard !eligible.isEmpty else {
            // no hero: no_heroes; heroes who cannot: denied (dead heroes, dead_heroes, are not modelled)
            let key = heroes.isEmpty ? "no_heroes" : "denied"
            if let t = objectText(p, key) { question = (t, { [weak self] in self?.remove(p) }) }
            return
        }
        if !isHumanActing {   // the computer (0x42df30): its best hero takes it at once (valuation not reversed: the first)
            learnAtAltar(eligible[0], family: family, p, message: false)
            return
        }
        let title = objectText(p, "name") ?? "Altar"
        let text = objectText(p, "Initial") ?? ""
        // every eligible ring is enabled (the dialog's test, 0x66d2d6, holds for each of them)
        heroPick = HeroPick(kind: .altar(skill: family), title: title, text: text, heroes: eligible,
                            enabled: eligible.map { _ in true }, ok: { [weak self] h in self?.learnAtAltar(h, family: family, p, message: true) })
        dialogueSound(29)
    }
    /// The altar's OK (0x66e480): one of the hero's steps at random (the game's generator), the
    /// "learned" message with the skill and the hero, the skill learned, the altar removed.
    func learnAtAltar(_ h: Hero, family: Int, _ p: MapScene.Placed, message: Bool) {
        let steps = altarSteps(h, family: family)
        guard !steps.isEmpty else { return }
        let s = steps[rng(steps.count)]
        if message, let t = objectText(p, "learned_skill") {
            scripts.messages.append(t)
            messagePictures[t] = [.skill(s.skill, level: s.level), .hero(h)]
        }
        h.learn(s.skill, level: s.level)
        h.grantSchoolSpells(random: &random)
        h.reconsiderClass()
        remove(p)
    }

    /// A magic gem (t_adv_magic_gem 0x4453d0): every hero of the army is offered; the chosen one gets
    /// +6 spell points / defense / attack or +2 speed for good and the gem is gone. With no hero the
    /// army is asked whether to destroy it.
    func visitGem(_ hero: Hero, _ p: MapScene.Placed) {
        let kinds = ["opal_of_magic", "sapphire_of_health", "ruby_of_offense", "emerald_of_speed"]
        let kind = kinds.firstIndex(of: p.subtype) ?? 3
        let heroes = armyHeroes(hero)
        guard !heroes.isEmpty else {
            if let t = objectText(p, "no heroes") { question = (t, { [weak self] in self?.remove(p) }) }
            return
        }
        if !isHumanActing {   // the computer's best hero (valuation 0x519560..0x519700 not reversed: the first)
            applyGem(heroes[0], kind: kind); remove(p)
            return
        }
        heroPick = HeroPick(kind: .gem(kind: kind), title: objectText(p, "name") ?? "", text: objectText(p, "initial") ?? "",
                            heroes: heroes, enabled: heroes.map { _ in true }, ok: { [weak self] h in self?.applyGem(h, kind: kind); self?.remove(p) })
        dialogueSound(15)
    }
    /// The gem's effect (0x6bffe0): opal +6 spell points (and up to 6 more now, not above the
    /// maximum, when below it), sapphire +6 defense, ruby +6 attack, emerald +2 speed.
    func applyGem(_ h: Hero, kind: Int) {
        switch kind {
        case 0:
            let cur = spellPoints(h)
            h.spellPointBonus += 6
            let mx = maxSpellPoints(h)
            if cur < mx { h.spellPoints = min(cur + 6, mx) }
        case 1: h.defenseBonus += 6
        case 2: h.attackBonus += 6
        default: h.speedBonus += 2
        }
    }
}
