import Foundation

/// Runs the map's event scripts (see Scripts.swift for the format). What the game does with each
/// node follows the editor's descriptions (campaign_editor strings.*) and the exe's targets.
public final class ScriptState {
    public var mapEvents: [MapEvent] = []
    /// The map's placed events (what event triggers and Pandora's boxes run, by name), as play changed them.
    public var placedEvents: [MapEvent] = []
    /// Town events by town index.
    public var townEvents: [Int: [MapEvent]] = [:]
    /// The map heroes' own events (the hero record's lists, 0x7321a0), by hero name.
    public var heroEvents: [String: [MapEvent]] = [:]
    /// The placed hero armies' own events (the army record's lists, 0x523710), by the name of
    /// the army's first hero (heroless and neutral armies' events are not run).
    public var armyEvents: [String: [MapEvent]] = [:]
    public var numbers: [String: Int] = [:]
    public var flags: [String: Bool] = [:]
    /// Texts the scripts showed, for the message box (oldest first).
    public var messages: [String] = []
    /// The scenario texts the scripts set (nil = the map's own).
    public var victoryText: String?, lossText: String?
    public var standardVictoryOn = true
    var rng = GameRandom(seed: 4271)
    public init() {}
}

/// Who an event runs for: the player it concerns ("current"), the object's owner and the
/// other side ("opposing": the player who took the town, beat the army).
public struct ScriptContext {
    public var current: Int
    public var owner: Int?
    public var opposing: Int?
    public var town: Int?
    public var hero: Hero?
    /// The army "this hero" leads or travels in, when it is not `hero` itself (a companion's event).
    public var army: Hero?
    public init(current: Int, owner: Int? = nil, opposing: Int? = nil, town: Int? = nil, hero: Hero? = nil, army: Hero? = nil) {
        self.current = current; self.owner = owner; self.opposing = opposing; self.town = town; self.hero = hero; self.army = army
    }
}

extension GameState {
    /// Material order of the scripts (as the creature table's cost columns).
    static let scriptMaterials = ["Gold", "Wood", "Ore", "Crystal", "Sulfur", "Mercury", "Gems"]

    /// Take the map's and the towns' events.
    public func loadScripts() {
        scripts.mapEvents = map.events
        scripts.placedEvents = map.placedEvents
        for (i, t) in towns.enumerated() {
            if let o = map.objects.first(where: { ($0.type == "town" || $0.type == "random_town") && $0.x == t.x && $0.y == t.y && $0.level == t.z }),
               let ev = o.town?.events, !ev.isEmpty { scripts.townEvents[i] = ev }
        }
        for o in map.objects {
            for h in o.heroes where !h.name.isEmpty && !h.events.isEmpty { scripts.heroEvents[h.name] = h.events }
            if let lead = o.heroes.first?.name, !lead.isEmpty, !o.armyEvents.isEmpty { scripts.armyEvents[lead] = o.armyEvents }
        }
        if ProcessInfo.processInfo.environment["H4DEBUG"] != nil {
            print("scripts: \(scripts.mapEvents.count) map events (\(scripts.mapEvents.map { $0.name })), \(scripts.townEvents.values.map { $0.count }.reduce(0, +)) town events")
        }
    }

    var human: Int { map.humanColour }

    func player(_ sel: Int, _ c: ScriptContext) -> Int? {
        switch sel {
        case 0: return c.owner
        case 1: return c.current
        case 2: return c.opposing
        default: return sel - 3
        }
    }
    func applies(_ e: MapEvent, to p: Int) -> Bool { e.players == 0 || e.players & (1 << p) != 0 }
    /// An event's player filter (0x7d2d70 / 0x726960): a computer player needs the computer flag
    /// (flags bit 1), the human the human flag (bit 0), and the colour's bit in the mask.
    func filterTakes(_ e: MapEvent, colour p: Int) -> Bool {
        guard (0..<6).contains(p) else { return false }
        return e.flags & (p == human ? 1 : 2) != 0 && e.players & (1 << p) != 0
    }
    /// A timed event is due today (0x88c630 with the game's 0-based day +0xec): on its first day,
    /// and after it every `repeat` days when that is not 0.
    func isDue(_ e: MapEvent) -> Bool {
        guard case .timed(let first, let rep) = e.kind else { return false }
        return day == first || (day > first && rep > 0 && (day - first) % rep == 0)
    }

    /// An army set off a placed event by name (0x4de2e0): every placed event of that name (names
    /// compare without case, 0x879620) whose filter takes the player whose turn it is (0x726960:
    /// the human or computer flag, flags bit 0 / bit 1, and the colour's bit in the mask) runs.
    /// One that ran a "remove event" action (0x835f70 sets 0xa8d9a0) is replaced by an empty
    /// event, so it never does anything again; the others run every time.
    func runPlacedEvents(named name: String, hero: Hero) {
        let colour = actingColour, human = isHumanActing
        for i in scripts.placedEvents.indices where scripts.placedEvents[i].name.caseInsensitiveCompare(name) == .orderedSame {
            let e = scripts.placedEvents[i]
            guard e.enabled, e.flags & (human ? 1 : 2) != 0, colour >= 0, colour < 6, e.players & (1 << colour) != 0 else { continue }
            run(event: &scripts.placedEvents[i], ScriptContext(current: colour, hero: hero))
            runContinuous()   // 0x4de569: the continuous events after each one (0x4ddf30)
        }
    }

    // MARK: triggers

    /// A new day: timed events that are due, then the continuous ones.
    public func runDayEvents() {
        let ctx = ScriptContext(current: human)
        // 0x4ddc9f: each due event whose filter takes the player whose turn it is
        for i in scripts.mapEvents.indices where scripts.mapEvents[i].enabled && isDue(scripts.mapEvents[i]) && filterTakes(scripts.mapEvents[i], colour: human) {
            run(event: &scripts.mapEvents[i], ctx)
        }
        runOwnedTimedEvents(for: human)
        runContinuous()
    }

    /// A player's turn starts: the timed events of the towns (0x7d5750), armies (0x523710) and heroes (0x7321a0) it
    /// owns -- each due one whose filter takes the owner runs, the owner being the player whose
    /// turn it is ("current" and "owner" both), its message shown to that player (0x705ca0).
    public func runOwnedTimedEvents(for colour: Int) {
        for t in scripts.townEvents.keys.sorted() where t < towns.count && towns[t].owner == colour {
            for i in scripts.townEvents[t]!.indices {
                let e = scripts.townEvents[t]![i]
                guard e.enabled, isDue(e), towns[t].owner == colour, filterTakes(e, colour: colour) else { continue }
                run(event: &scripts.townEvents[t]![i], ScriptContext(current: colour, owner: colour, town: t))
            }
        }
        for name in scripts.armyEvents.keys.sorted() {   // 0x523710
            guard let army = (heroes + enemyHeroes).first(where: { a in a.owner == colour && a.members.contains { $0.name == name } }) else { continue }
            for i in scripts.armyEvents[name]!.indices {
                let e = scripts.armyEvents[name]![i]
                guard e.enabled, isDue(e), filterTakes(e, colour: colour) else { continue }
                run(event: &scripts.armyEvents[name]![i], ScriptContext(current: colour, owner: colour, hero: army.members.first, army: army))
            }
        }
        for name in scripts.heroEvents.keys.sorted() {
            guard let army = (heroes + enemyHeroes).first(where: { a in a.owner == colour && a.members.contains { $0.name == name } }),
                  let h = army.members.first(where: { $0.name == name }) else { continue }
            for i in scripts.heroEvents[name]!.indices {
                let e = scripts.heroEvents[name]![i]
                guard e.enabled, isDue(e), filterTakes(e, colour: colour) else { continue }
                run(event: &scripts.heroEvents[name]![i], ScriptContext(current: colour, owner: colour, hero: h, army: army))
            }
        }
    }
    /// Continuous events: checked after anything happens (the day, a capture, a battle).
    public func runContinuous() {
        let ctx = ScriptContext(current: human)
        for i in scripts.mapEvents.indices where scripts.mapEvents[i].enabled && applies(scripts.mapEvents[i], to: human) {
            if case .continuous = scripts.mapEvents[i].kind { run(event: &scripts.mapEvents[i], ctx) }
        }
        for (t, list) in scripts.townEvents {
            for i in list.indices where list[i].enabled {
                if case .continuous = list[i].kind {
                    let c = ScriptContext(current: human, owner: towns[t].owner, town: t)
                    run(event: &scripts.townEvents[t]![i], c)
                }
            }
        }
    }
    /// A town's standard event (slot 1 when captured, 3 when visited).
    public func runTownEvent(_ town: Int, slot: Int, previousOwner: Int? = nil, hero: Hero? = nil) {
        guard let list = scripts.townEvents[town] else { return }
        for i in list.indices where list[i].enabled {
            if case .builtin(let s) = list[i].kind, s == slot, applies(list[i], to: human) {
                let c = ScriptContext(current: human, owner: towns[town].owner, opposing: previousOwner ?? human, town: town, hero: hero)
                run(event: &scripts.townEvents[town]![i], c)
            }
        }
        runContinuous()
    }

    func run(event e: inout MapEvent, _ c: ScriptContext) {
        if !e.message.isEmpty, c.current == human { scripts.messages.append(e.message) }   // (0x705ca0: shown to that player)
        var removed = false
        exec(e.action, c, &removed)
        if removed { e.enabled = false }
    }

    // MARK: actions

    func exec(_ n: ScriptNode, _ c: ScriptContext, _ removed: inout Bool) {
        guard outcome == nil else { return }
        switch n.keyword {
        case "seq": for a in n.nodes(0) { exec(a, c, &removed) }
        case "if":
            if let cond = n.node(0), truth(cond, c) { if let a = n.node(1) { exec(a, c, &removed) } }
            else if let a = n.node(2) { exec(a, c, &removed) }
        case "ask":   // a yes/no question: yes runs the first action (the box waits for the answer)
            let yes = n.node(1)
            question = (n.text(0), { [weak self] in
                guard let self = self, let a = yes else { return }
                var r = false; self.exec(a, c, &r)
            })
        case "text":
            if !n.text(0).isEmpty, c.current == human { scripts.messages.append(n.text(0)) }
            for a in n.nodes(1) { exec(a, c, &removed) }
        case "win":   // 0x837990: the player's team wins
            if let p = player(n.int(0), c) { scriptWin(p) }
        case "lose":  // 0x837a30: the player is marked lost, then the end check
            if let p = player(n.int(0), c) { scriptLose(p) }
        // (set_v_msg / set_l_msg / clear_*_msg: the older names, read the same way -- taken as the
        // same texts, inferred; the exe never shows them when the game ends, end_sequence_spec 3)
        case "set_vc_text", "set_v_msg": scripts.victoryText = n.text(1)
        case "set_lc_text", "set_l_msg": scripts.lossText = n.text(1)
        case "clear_vc_text", "clear_v_msg": scripts.victoryText = ""
        case "clear_lc_text", "clear_l_msg": scripts.lossText = ""
        case "enable_vc": scripts.standardVictoryOn = true
        case "disable_vc": scripts.standardVictoryOn = false
        case "give_material", "take_material":
            guard player(n.int(0), c) == human else { return }
            let sign = n.keyword == "give_material" ? 1 : -1
            for (i, v) in n.ints(1).enumerated() where v != 0 && i < GameState.scriptMaterials.count {
                let m = GameState.scriptMaterials[i]
                resources[m] = max(0, resources[m, default: 0] + sign * v)
            }
        case "give_creature", "take_creature":   // (army, creature, count): army 0 this, 1 the town's garrison, 2 opposing
            guard n.int(1) < RuleTables.creatureIds.count, let def = tables?.creature(RuleTables.creatureIds[n.int(1)]) else { return }
            let give = n.keyword == "give_creature"
            func change(_ stacks: inout [Hero.Stack], room: Int) {
                if let k = stacks.firstIndex(where: { $0.creature == def.keyword }) {
                    stacks[k].count += give ? n.int(2) : -n.int(2)
                    if stacks[k].count <= 0 { stacks.remove(at: k) }
                } else if give, stacks.count < room { stacks.append(Hero.Stack(creature: def.keyword, count: n.int(2))) }
            }
            switch n.int(0) {   // (0x836d40, as scriptArmyHeroes)
            case 1:
                guard let t = c.town else { return }
                change(&towns[t].garrison, room: Hero.armySlots - towns[t].garrisonHeroes.count)
            case 0, 2:
                guard let h = n.int(0) == 0 ? scriptArmy(c) : (c.town != nil ? c.hero : nil) else { return }
                change(&h.army, room: Hero.armySlots - 1)
                refreshMovement(h)
            default: return
            }
        case "inc_exp":   // one hero's experience (t_script_increase_experience), then its levels
            guard let h = scriptHero(n.int(0), c) else { return }
            if c.current == human { giveExperience(n.int(1), toOnly: h) }
            else { h.experience += n.int(1); _ = h.levelUp(to: min(70, Hero.level(for: h.experience)), tables: tables, random: &random) }
        case "set_num": if let v = n.node(1) { scripts.numbers[n.text(0)] = number(v, c) }
        case "set_bool": if let v = n.node(1) { scripts.flags[n.text(0)] = truth(v, c) }
        case "rem_event", "rem_this": removed = true
        case "gosub":
            if let i = scripts.mapEvents.firstIndex(where: { $0.name == n.text(0) }) { run(event: &scripts.mapEvents[i], c) }
        case "build":
            if let t = c.town, let b = RuleTables.buildingIds[towns[t].alignment]?[n.int(0)] { towns[t].buildings.insert(b) }
        case "change_owner":
            if let t = c.town { towns[t].owner = n.int(0) < 6 ? n.int(0) : nil; towns[t].owned = towns[t].owner == human }
        case "combat":   // a fight with the script's army; then its win or lose action
            let stacks = n.army(1).compactMap { $0 }.filter { $0.creature >= 0 && $0.creature < RuleTables.creatureIds.count && $0.count > 0 }
            guard let h = c.hero ?? heroes.first, let lead = stacks.first else { return }
            var m = Monster(x: h.x, y: h.y, name: "script", creature: RuleTables.creatureIds[lead.creature], count: lead.count,
                            extra: stacks.dropFirst().map { (RuleTables.creatureIds[$0.creature], $0.count) })
            m.z = h.z; m.bank = "script"
            monsters.append(m)
            scriptBattle = (n.node(2), n.node(3), c)
            if let p = scene.placed.first(where: { $0.cellX == h.x && $0.cellY == h.y }) ?? scene.triggers.first(where: { $0.cellX == h.x && $0.cellY == h.y }) ?? scene.placed.first { fight(hero: h, monsterAt: monsters.count - 1, p) }
        case "give_artifact":
            guard let h = c.hero ?? heroes.first else { return }
            for a in n.ints(1) { give(artifact: a, to: h) }
        case "rem_artifact":
            guard let h = c.hero ?? heroes.first else { return }
            for a in n.ints(1) { if let k = h.backpack.firstIndex(of: a) { h.backpack.remove(at: k) } else if let k = h.equipped.firstIndex(of: a) { h.equipped[k] = nil } }
        case "give_spell":
            if let h = c.hero ?? heroes.first, n.int(1) < RuleTables.spells.count { h.spells.insert(n.int(1)) }
        case "give_skill", "inc_skill":   // (hero, skill, level): learn it at the level, or one level more
            guard let h = c.hero ?? heroes.first, n.int(1) < 36 else { return }
            let lv = n.keyword == "give_skill" ? min(4, n.int(2)) : min(4, h.skill(id: n.int(1)))
            h.learn(n.int(1), level: lv); h.grantSchoolSpells(random: &random); h.reconsiderClass()
        case "inc_level":
            guard let h = c.hero ?? heroes.first else { return }
            for _ in 0..<max(0, n.int(1)) { giveExperience(max(0, Hero.experienceTable[min(70, h.level + 1)] - h.experience), toOnly: h) }
        case "inc_luck", "dec_luck":
            if let h = c.hero ?? heroes.first { h.armyLuck["script", default: 0] += (n.keyword == "inc_luck" ? 1 : -1) * n.int(1) }
        case "inc_morale", "dec_morale":
            if let h = c.hero ?? heroes.first { h.armyMorale["script", default: 0] += (n.keyword == "inc_morale" ? 1 : -1) * n.int(1) }
        case "inc_mana", "dec_mana":
            if let h = c.hero ?? heroes.first { h.spellPoints = max(0, spellPoints(h) + (n.keyword == "inc_mana" ? 1 : -1) * n.int(1)) }
        case "inc_move":
            if let h = c.hero ?? heroes.first { h.movement = max(0, h.movement + Float(n.int(1))) }
        case "detonate": detonate(n.text(0))
        case "no_op": break
        default:
            if ProcessInfo.processInfo.environment["H4DEBUG"] != nil { print("script: '\(n.keyword)' not run") }
        }
    }

    /// The army an action's "this army" names: the event's army, the human's first one for the
    /// human's own events without one (kept from before; inferred), none for a computer player's.
    func scriptArmy(_ c: ScriptContext) -> Hero? {
        c.army ?? c.hero ?? (c.current == human && c.town == nil ? heroes.first : nil)
    }
    /// The hero an action names: 0 this hero, 1 the first in this army, 3 the first in the
    /// garrison (2, 4-9 -- opposing, most / least powerful -- fall back to this hero).
    func scriptHero(_ sel: Int, _ c: ScriptContext) -> Hero? {
        switch sel {
        case 1: return scriptArmy(c)?.members.first
        case 3: return c.town.flatMap { towns[$0].garrisonHeroes.first }
        default: return c.hero ?? scriptArmy(c)?.members.first
        }
    }

    /// The heroes of the army an expression names (0x836d40): 0 this army -- the event's army, or
    /// for a town's event the army visiting / taking it --, 1 the town's garrison, 2 the opposing
    /// army (in a town's event the visitor again).
    func scriptArmyHeroes(_ sel: Int, _ c: ScriptContext) -> [Hero] {
        switch sel {
        case 0: return scriptArmy(c)?.members ?? []
        case 1: return c.town.map { towns[$0].garrisonHeroes } ?? []
        case 2: return c.town != nil ? c.hero?.members ?? [] : []
        default: return []
        }
    }
    /// Every living hero on the map: in the armies, the garrisons and the towns' prisons.
    var livingHeroNames: [String] {
        var out: [String] = []
        for a in heroes + enemyHeroes { out += a.members.map(\.name) }
        for t in towns {
            for a in t.garrisonHeroes { out += a.members.map(\.name) }
            out += t.prisoners.map(\.name)
        }
        return out
    }
    /// A hero still held in a prison: a prison on the map not yet opened, or a town's prison.
    func isImprisoned(_ name: String) -> Bool {
        func same(_ s: String) -> Bool { s.caseInsensitiveCompare(name) == .orderedSame }
        if towns.contains(where: { $0.prisoners.contains { same($0.name) } }) { return true }
        for o in map.objects where o.type == "prison" {
            guard let h = o.prisoner, same(h.name), o.level < scenes.count else { continue }
            if scenes[o.level].placed.contains(where: { $0.type == "prison" && $0.cellX == o.x && $0.cellY == o.y }) { return true }
        }
        return false
    }
    /// A hero of the map who is nowhere any more (beaten, his army gone; the exe's hero +0x61c).
    /// Heroes the map never placed (carried over, hired) are not counted (inferred).
    func isDead(_ name: String) -> Bool {
        func same(_ s: String) -> Bool { s.caseInsensitiveCompare(name) == .orderedSame }
        let placed = map.objects.contains { o in o.heroes.contains { same($0.name) } || (o.prisoner.map { same($0.name) } ?? false) }
            || towns.contains { $0.garrisonHeroes.contains { same($0.name) } }
        return placed && !livingHeroNames.contains(where: same) && !isImprisoned(name)
    }
    /// detonate (t_script_delete_adv_objects, 0x4df4b0): every deletion marker of that name
    /// (t_adv_object_deletion_marker, 0x44a730 -> 0x4df2f0 records its point under its name) takes
    /// the objects standing on its cell off the map.
    func detonate(_ name: String) {
        for o in map.objects where o.type == "deletion_marker" && (o.text ?? "") == name && o.level < scenes.count {
            let sc = scenes[o.level]
            let hit = sc.placed.filter { $0.type != "deletion_marker" && o.x >= $0.cellX && o.x < $0.cellX + $0.sprite.footprint.w && o.y >= $0.cellY && o.y < $0.cellY + $0.sprite.footprint.h }
            for p in hit {
                sc.remove(p)
                if o.level < passabilities.count { for i in 0..<p.sprite.footprint.w { for j in 0..<p.sprite.footprint.h { passabilities[o.level].free(p.cellX + i, p.cellY + j) } } }
            }
        }
    }

    // MARK: expressions

    func truth(_ n: ScriptNode, _ c: ScriptContext) -> Bool {
        switch n.keyword {
        case "true": return true
        case "false": return false
        case "and": return truth(n.node(0)!, c) && truth(n.node(1)!, c)
        case "or": return truth(n.node(0)!, c) || truth(n.node(1)!, c)
        case "not": return !truth(n.node(0)!, c)
        case "==", "<", ">", "<=", ">=":
            let a = number(n.node(0)!, c), b = number(n.node(1)!, c)
            switch n.keyword { case "==": return a == b; case "<": return a < b; case ">": return a > b; case "<=": return a <= b; default: return a >= b }
        case "is_color": return player(n.int(0), c) == n.int(1)
        case "is_human": return player(n.int(0), c) == human
        case "is_computer": return player(n.int(0), c).map { $0 != human } ?? false
        case "is_eliminated":   // player +0xa8 (0x830f80)
            return player(n.int(0), c).map { isEliminated($0) } ?? false
        case "owns_town":
            guard let p = player(n.int(0), c) else { return false }
            return towns.contains { $0.owner == p && $0.name.caseInsensitiveCompare(n.text(1)) == .orderedSame }
        case "has_artifact":
            // 0x82c660 reads a flag (1: a player, 0: a hero target) and the target; the player form
            // (0x82c4a0) asks each of the player's armies (+0x10) whether it carries the artifact
            // (army vfunc +0x30: its heroes' worn and backpack items); the hero form (0x82c3f0)
            // looks through one hero's items
            let art = n.int(2)
            func holds(_ h: Hero) -> Bool { h.equipped.contains(art) || h.backpack.contains(art) }
            if n.int(0) != 0 {
                guard player(n.int(1), c) == human else { return false }
                return heroes.contains { a in holds(a) || a.members.contains(where: holds) }
            }
            return c.hero.map { a in holds(a) || a.members.contains(where: holds) } ?? false
        case "has_hero":   // (army, name): the army holds a hero of that name (t_script_army_has_hero)
            let name = n.text(1)
            return scriptArmyHeroes(n.int(0), c).contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        case "is_imprisoned": return isImprisoned(n.text(0))
        case "is_dead": return isDead(n.text(0))
        case "owns_hero": return player(n.int(0), c) == human && heroes.contains { $0.name.caseInsensitiveCompare(n.text(1)) == .orderedSame }
        case "is_alignment":
            guard let p = player(n.int(0), c), p < 6, let spec = map.playerSpecs.first(where: { $0.colour == p }) else { return false }
            return spec.alignments & (1 << n.int(1)) != 0
        case "var": return scripts.flags[n.text(0)] ?? false
        default: return false   // heroes and artifacts of other players are not modelled
        }
    }

    func number(_ n: ScriptNode, _ c: ScriptContext) -> Int {
        switch n.keyword {
        case "lit": return n.int(0)
        case "rand":
            let lo = n.int(0), hi = n.int(1)
            return hi > lo ? lo + scripts.rng.next() % (hi - lo + 1) : lo
        case "+": return number(n.node(0)!, c) + number(n.node(1)!, c)
        case "-": return number(n.node(0)!, c) - number(n.node(1)!, c)
        case "*": return number(n.node(0)!, c) * number(n.node(1)!, c)
        case "/": let d = number(n.node(1)!, c); return d == 0 ? 0 : number(n.node(0)!, c) / d
        case "%": let d = number(n.node(1)!, c); return d == 0 ? 0 : number(n.node(0)!, c) % d
        case "neg": return -number(n.node(0)!, c)
        case "day": return day
        case "dow": return dayOfWeek
        case "week": return (day - 1) / 7 + 1
        case "wom": return week
        case "month": return month
        case "player": return player(n.int(0), c) ?? -1
        case "materials":
            guard player(n.int(0), c) == human, n.int(1) < GameState.scriptMaterials.count else { return 0 }
            return resources[GameState.scriptMaterials[n.int(1)], default: 0]
        case "creatures":
            guard let h = c.hero ?? heroes.first, n.int(1) < RuleTables.creatureIds.count else { return 0 }
            let kw = RuleTables.creatureIds[n.int(1)]
            return h.army.filter { $0.creature.lowercased() == kw }.reduce(0) { $0 + $1.count }
        case "total_creatures": return (c.hero ?? heroes.first)?.army.reduce(0) { $0 + $1.count } ?? 0
        case "total_heroes": return heroes.count
        case "exp_level": return (c.hero ?? heroes.first)?.level ?? 0
        case "var": return scripts.numbers[n.text(0)] ?? 0
        default: return 0
        }
    }
}
