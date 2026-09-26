import Foundation

/// Runs the map's event scripts (see Scripts.swift for the format). What the game does with each
/// node follows the editor's descriptions (campaign_editor strings.*) and the exe's targets.
public final class ScriptState {
    public var mapEvents: [MapEvent] = []
    /// Town events by town index.
    public var townEvents: [Int: [MapEvent]] = [:]
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
    public init(current: Int, owner: Int? = nil, opposing: Int? = nil, town: Int? = nil, hero: Hero? = nil) {
        self.current = current; self.owner = owner; self.opposing = opposing; self.town = town; self.hero = hero
    }
}

extension GameState {
    /// Material order of the scripts (as the creature table's cost columns).
    static let scriptMaterials = ["Gold", "Wood", "Ore", "Crystal", "Sulfur", "Mercury", "Gems"]

    /// Take the map's and the towns' events.
    public func loadScripts() {
        scripts.mapEvents = map.events
        for (i, t) in towns.enumerated() {
            if let o = map.objects.first(where: { ($0.type == "town" || $0.type == "random_town") && $0.x == t.x && $0.y == t.y && $0.level == level }),
               let ev = o.town?.events, !ev.isEmpty { scripts.townEvents[i] = ev }
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

    // MARK: triggers

    /// A new day: timed events that are due, then the continuous ones.
    public func runDayEvents() {
        let ctx = ScriptContext(current: human)
        for i in scripts.mapEvents.indices where scripts.mapEvents[i].enabled && applies(scripts.mapEvents[i], to: human) {
            if case .timed(let first, let rep) = scripts.mapEvents[i].kind, day >= first,
               day == first || (rep > 0 && (day - first) % rep == 0) {
                run(event: &scripts.mapEvents[i], ctx)
            }
        }
        runContinuous()
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
        if !e.message.isEmpty { scripts.messages.append(e.message) }
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
            if !n.text(0).isEmpty { scripts.messages.append(n.text(0)) }
            for a in n.nodes(1) { exec(a, c, &removed) }
        case "win", "lose":
            guard let p = player(n.int(0), c) else { return }
            let mine = p == human || map.teams[p] != nil && map.teams[p] == map.teams[human]
            if mine == (n.keyword == "win") {
                outcome = true
                log.append(scripts.victoryText ?? map.victoryText ?? text("default_victory_condition", "Victory!"))
            } else {
                outcome = false
                log.append(scripts.lossText ?? map.lossText ?? text("default_loss_condition", "Defeat."))
            }
        case "set_vc_text": scripts.victoryText = n.text(1)
        case "set_lc_text": scripts.lossText = n.text(1)
        case "clear_vc_text": scripts.victoryText = ""
        case "clear_lc_text": scripts.lossText = ""
        case "enable_vc": scripts.standardVictoryOn = true
        case "disable_vc": scripts.standardVictoryOn = false
        case "give_material", "take_material":
            guard player(n.int(0), c) == human else { return }
            let sign = n.keyword == "give_material" ? 1 : -1
            for (i, v) in n.ints(1).enumerated() where v != 0 && i < GameState.scriptMaterials.count {
                let m = GameState.scriptMaterials[i]
                resources[m] = max(0, resources[m, default: 0] + sign * v)
            }
        case "give_creature", "take_creature":
            guard let h = c.hero ?? heroes.first, n.int(1) < RuleTables.creatureIds.count, let def = tables?.creature(RuleTables.creatureIds[n.int(1)]) else { return }
            if n.keyword == "give_creature" { _ = add(def.keyword, n.int(2), to: h) }
            else if let k = h.army.firstIndex(where: { $0.creature == def.keyword }) {
                h.army[k].count -= n.int(2)
                if h.army[k].count <= 0 { h.army.remove(at: k) }
            }
        case "inc_exp": if let h = c.hero ?? heroes.first { giveExperience(n.int(1), to: h) }
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
            if let p = scene.placed.first(where: { $0.cellX == h.x && $0.cellY == h.y }) ?? scene.placed.first { fight(hero: h, monsterAt: monsters.count - 1, p) }
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
        case "no_op": break
        default:
            if ProcessInfo.processInfo.environment["H4DEBUG"] != nil { print("script: '\(n.keyword)' not run") }
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
        case "is_eliminated":
            guard let p = player(n.int(0), c) else { return false }
            let hasTown = towns.contains { $0.owner == p }
            return p == human ? (!hasTown && heroes.isEmpty) : !hasTown
        case "owns_town":
            guard let p = player(n.int(0), c) else { return false }
            return towns.contains { $0.owner == p && $0.name.caseInsensitiveCompare(n.text(1)) == .orderedSame }
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
