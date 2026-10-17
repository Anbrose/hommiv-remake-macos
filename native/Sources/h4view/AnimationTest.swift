import Foundation
import H4Engine

/// Snapshot hook for the combat presentation (debugging): H4ANIM="orc:30,titan:2" stages the first
/// hero's army (H4ARMY) against those stacks; H4ANIMACT is a ';' list of actions played in turn on a
/// fixed clock -- "shoot:<attacker>:<target>", "melee:<attacker>:<target>", "cast:<spell>[@x,y][:<target>[:<caster>]]",
/// "fx:<unit>:<name>[:damage]", "tele:<unit>:x,y", "disp:<unit>:x,y", "revive:<unit>:n", "phantom:<unit>" (units by keyword, a
/// target on the other side); H4ANIMHERO="archery:2,class:3,align:chaos,sex:female" the first hero's skills, class, alignment and sex; H4ANIMT="0.3,0.6" the times (s) of the frames written next to the
/// snapshot path as <name>_<t>.png; H4ANIMLOG prints the playback's timeline.
func runAnimationTest(_ spec: String, game g: GameState, cs: CombatScreen, hero: Hero, out: String, renderer: Renderer, render: (String) -> Void) {
    let defenders: [(String, Int)] = spec.split(separator: ",").compactMap { p in
        let q = p.split(separator: ":"); return q.count == 2 ? Int(q[1]).map { (String(q[0]), $0) } : nil }
    // H4ANIMHERO="archery:2,class:3,align:chaos,sex:female": the first hero's skills (by family), class (by id), alignment, sex
    for p in (ProcessInfo.processInfo.environment["H4ANIMHERO"] ?? "").split(separator: ",") {
        let q = p.split(separator: ":"); guard q.count == 2 else { continue }
        if q[0] == "align" { hero.alignment = String(q[1]); continue }
        if q[0] == "sex" { hero.actor = hero.actor.replacingOccurrences(of: "_female", with: "_male").replacingOccurrences(of: "_male", with: "_\(q[1])"); continue }
        guard let v = Int(q[1]) else { continue }
        if q[0] == "class" { hero.heroClass = v } else { hero.skills[String(q[0])] = v }
    }
    cs.startTest(game: g, hero: hero, defenders: defenders)
    guard let b = cs.battle else { print("no battle"); return }
    let env = ProcessInfo.processInfo.environment
    print("units: " + b.units.map { "\($0.id):\($0.keyword)x\($0.stats.count)@(\($0.x),\($0.y)) s\($0.side)" }.joined(separator: " "))
    func unit(_ k: String, side: Int?, dead: Bool = false) -> Battle.Unit? {
        b.units.first { ($0.keyword == k || $0.actor.lowercased() == k.lowercased() || "\($0.id)" == k) && (side == nil || $0.side == side) && ($0.alive || dead) }
    }
    let base = Date()
    cs.traceStart = base
    var now = base
    cs.clock = now
    _ = b.takeEvents()
    func act(_ a: String) {
        let p = a.split(separator: ":").map(String.init)
        guard let kind = p.first else { return }
        switch kind {
        case "shoot", "melee":
            guard p.count >= 3, let u = unit(p[1], side: nil), let t = b.units.first(where: { ($0.keyword == p[2] || "\($0.id)" == p[2]) && $0.side != u.side && $0.alive }) else { print("no such units: \(a)"); return }
            b.putFirst(u.id)
            print("\(kind) \(u.keyword) -> \(t.keyword): \(kind == "shoot" ? b.shoot(t.id) : b.attack(t.id))")
        case "cast":
            // "cast:<spell>[@x,y][:<target>[:<caster>]]": a hero caster knows every spell; a creature
            // caster (by keyword or id, either side) casts with its own spells
            let byCaster = p.count >= 4 ? unit(p[3], side: nil) : nil
            guard p.count >= 2, let spell = Int(p[1].split(separator: "@")[0]), let u = byCaster ?? b.units.first(where: { $0.side == 0 && $0.caster != nil }) else { print("no caster"); return }
            b.putFirst(u.id)
            if var c = u.caster {
                if u.stats.isHero { c.spells = Array(0..<RuleTables.spells.count); for k in ["chaos", "life", "order", "death", "nature"] { c.skills[k] = 5 } }
                c.spellPoints = max(c.spellPoints, 500); u.caster = c
            }
            var cell: (Int, Int)? = nil
            if let at = p[1].split(separator: "@").dropFirst().first { let xy = at.split(separator: ",").compactMap { Int($0) }; if xy.count == 2 { cell = (xy[0], xy[1]) } }
            // a living stack, else a dead one (the Bodies spells, Resurrection)
            let named = p.count >= 3 && !p[2].isEmpty ? b.units.filter { $0.keyword == p[2] || "\($0.id)" == p[2] } : []
            let target = named.first { $0.alive } ?? named.first
            print("cast \(RuleTables.spells[spell].name): \(b.cast(spell, on: target?.id ?? (cell == nil && !Battle.untargeted(spell) ? b.units.first { $0.side == 1 && $0.alive }?.id : nil), at: cell, tables: g.tables))")
        case "fx":
            // an ability effect as the battle emits it: "fx:<unit>:<name>[:damage]"
            guard p.count >= 3, let u = unit(p[1], side: nil) else { return }
            let d = p.count >= 4 ? Int(p[3]) ?? 0 : 0
            let k = d > 0 ? u.stats.take(d) : 0
            cs.take([.effect(unit: u.id, name: p[2], damage: d, killed: k, left: u.stats.count)])
            return
        case "tele", "disp", "revive", "phantom":
            // presentation only: the event as the battle would emit it
            guard p.count >= 2, let u = unit(p[1], side: nil, dead: kind == "revive"), let caster = b.units.first(where: { $0.side == 0 && $0.caster != nil }) else { return }
            let xy = p.count >= 3 ? p[2].split(separator: ",").compactMap { Int($0) } : []
            let spell = ["tele": 178, "disp": 28, "revive": 133, "phantom": 18][kind]!
            var evs: [Battle.Event] = [.cast(unit: caster.id, spell: spell, targets: [u.id])]
            switch kind {
            case "tele": evs.append(.teleported(unit: u.id, from: (u.x, u.y), to: (xy.first ?? u.x, xy.last ?? u.y)))
            case "disp": evs.append(.displaced(unit: u.id, from: (u.x, u.y), to: (xy.first ?? u.x, xy.last ?? u.y)))
            case "revive": evs.append(.revived(unit: u.id, spell: spell, count: Int(p.count >= 3 ? p[2] : "5") ?? 5, rose: p.count >= 4))
            default: evs.append(.phantom(unit: u.id, of: u.id))
            }
            cs.take(evs)
            return
        default: print("unknown action \(a)")
        }
    }
    let actions = (env["H4ANIMACT"] ?? "").split(separator: ";").map(String.init)
    let times = (env["H4ANIMT"] ?? "0.5").split(separator: ",").compactMap { Double($0) }.sorted()
    // every action but the last played out first; the frame times count from the last one
    func step(until end: Date?) {
        var lastBusy = cs.busy
        var guardN = 0
        while guardN < 12000 {
            guardN += 1
            if let e = end { if now >= e { break } } else if !cs.busy { break }
            now = end.map { min($0, now.addingTimeInterval(0.005)) } ?? now.addingTimeInterval(0.005)
            cs.clock = now
            cs.update(now: now)
            if cs.busy != lastBusy, env["H4ANIMLOG"] != nil { print(String(format: "  %.3f s: %@", now.timeIntervalSince(base), cs.busy ? "busy" : "idle")) }
            lastBusy = cs.busy
        }
    }
    for (k, a) in actions.enumerated() {
        act(a)
        let ev = b.takeEvents()
        if env["H4ANIMLOG"] != nil { for e in ev { print("  \(e)") } }
        cs.take(ev)
        if k < actions.count - 1 { step(until: nil) }
    }
    let start = now
    let stem = (out as NSString).deletingPathExtension
    for t in times {
        step(until: start.addingTimeInterval(t))
        if env["H4ANIMLOG"] != nil {
            for m in cs.missiles { print("  missile \(m.model) pos \(m.pos) delta \(m.delta) left \(m.remaining) facing \(m.facing)") }
            print(String(format: "t=%.3f missiles %d windows %@ field %@ states %@", t, cs.missiles.count, cs.windows.map { "\($0.name)@\($0.unit)" }.joined(separator: ","),
                         cs.fieldActors.map { $0.model }.joined(separator: ","), cs.unitState.map { "\($0.key):\($0.value.state)" }.joined(separator: ",")))
        }
        // H4ANIMAIM="<spell>@x,y": the spell being aimed with the pointer at that canvas point
        if let aim = env["H4ANIMAIM"], let sp = Int(aim.split(separator: "@")[0]), let xy = aim.split(separator: "@").last?.split(separator: ",").compactMap({ Float($0) }), xy.count == 2 {
            if let u = b.current, u.side == 0, var c = u.caster { c.spells = Array(0..<RuleTables.spells.count); c.spellPoints = 500; for k in ["chaos", "life", "order", "death", "nature"] { c.skills[k] = 5 }; u.caster = c }
            renderer.casting = sp
            print("aim: \(renderer.combatCursor(x: xy[0], y: xy[1])) area \(renderer.combatArea.map { Array($0) } ?? [])")
        }
        render(String(format: "%@_%.2f.png", stem, t))
    }
}
