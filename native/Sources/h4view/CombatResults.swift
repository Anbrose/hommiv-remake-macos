import Foundation
import H4Engine

/// The combat results dialog (layers.dialog.combat_results; combat_ui_spec §D) and the retreat
/// and surrender questions. The dialog is centred; all its texts are Prose_Antique, black with the
/// (200,200,200) halo, centred: the title (23, v-centred), the outcome sentence (20, v-centred),
/// Victorious / Defeated (27 / 25) and the two Casualties labels (27); the battle's movie at
/// Cut_Scene's top-left (intro once, then its loop) under Cut_Scene_Frame; each army's portrait
/// (82) with its top-left at Winner_ / Loser_Portrait under its frame; each side's losses as
/// control.creature_select rings at the hero_i_of_n places; OK at ok_button's top-left.
extension Renderer {
    var resultsOrigin: (Int, Int) { ((AdventureUI.width - 798) / 2, (AdventureUI.height - 599) / 2) }

    /// The result code's parts (+0xfc): kind 0 fight, 1 retreat, 2 surrender, 3 gate, 8 everyone died;
    /// the winning side (the local player is side 0).
    func combatOutcome(_ cs: CombatScreen, _ b: Battle) -> (kind: Int, winner: Int) {
        let alive = { (side: Int) in b.units.contains { $0.side == side && $0.alive && !$0.summoned } }
        if !alive(0) && !alive(1) { return (8, 1) }
        if cs.surrendered { return (2, 1) }
        if b.retreated { return (1, 1) }
        return (0, (b.finished ?? false) ? 0 : 1)
    }
    /// The outcome sentence and the movie (switch 0x6aca74, table 0xa68868).
    func outcomeText(_ cs: CombatScreen, _ b: Battle, kind: Int, won: Bool) -> (text: String, intro: String?, loop: String) {
        let town = cs.retreatTown.flatMap { t in game.flatMap { $0.towns.indices.contains(t) ? $0.towns[t].name : nil } } ?? ""
        let heroes = cs.hero.map { [$0] + $0.companions } ?? []
        func fill(_ s: String) -> String {
            s.replacingOccurrences(of: "%Hero_names", with: heroes.map { $0.name }.joined(separator: ", "))
             .replacingOccurrences(of: "%Hero_name", with: heroes.first?.name ?? "")
             .replacingOccurrences(of: "%town_name", with: town)
        }
        var movie: (String?, String)
        var line: String
        switch (kind, won) {
        case (8, _): line = text("both_died.combat", "Everyone died!"); movie = ("lose_battle_intro", "lose_battle_loop")
        case (1, false):
            line = fill(heroes.count > 1 ? text("player_retreats.combat", "%Hero_names retreat shamefully to %town_name.") : text("one_hero_retreats.combat", "%Hero_name retreats shamefully to %town_name."))
            movie = ("retreat_intro", "retreat_loop")
        case (2, false): line = fill(text("player_surrenders.combat", "The enemy accepts your terms and permits your army to return to %town_name.")); movie = (nil, "surrender_loop")
        case (3, false): line = fill(text("player_heroes_gate.combat", "%Hero_names magically gated to %town_name.")); movie = ("townportal_intro", "townportal_loop")
        case (3, true): line = text("enemy_heroes_gate.combat", "The enemy magically gated away from battle, hoping for better odds the next time you meet."); movie = ("win_battle_intro", "win_battle_loop")
        case (1, true), (2, true): line = text("enemy_retreats.combat", "Your enemy quickly flees from your sight."); movie = ("win_battle_intro", "win_battle_loop")
        case (_, true): line = text("player_won_battle.combat", "You have vanquished your foe!"); movie = ("win_battle_intro", "win_battle_loop")
        default: line = text("player_loses_battle.combat", "Sadly, you have succumbed to a stronger foe and lost the battle!"); movie = ("lose_battle_intro", "lose_battle_loop")
        }
        // a town battle: capturing the town if the attacker won, else its defence
        if cs.siegeTown != nil { movie = (b.finished ?? false) ? ("capture_town_intro", "capture_town_loop") : ("defend_town_intro", "defend_town_loop") }
        return (line, movie.0, movie.1)
    }

    func combatResultQuads() -> [Quad] {
        guard let cs = combat, let b = cs.battle, let d = ui?.dialog("Combat_results"), cs.result != nil else { return [] }
        let (ox, oy) = resultsOrigin
        let (kind, winner) = combatOutcome(cs, b)
        let won = winner == 0 && kind != 8
        let halo: RGB = (200, 200, 200)
        var out: [Quad] = []
        if let bg = layer(d, "Background") { out.append(image(bg, key: "dlg|results|Background", ox + bg.x, oy + bg.y)) }
        func t(_ s: String, _ slot: String, _ size: Int, v: Bool) { out += textWindow(s, in: layer(d, slot), ox, oy, font: proseFont(size), centre: true, vcentre: v, halo: halo) }
        t(text("combat_results_title.combat", "Combat Results"), "Title", 23, v: true)
        let o = outcomeText(cs, b, kind: kind, won: won)
        t(o.text, "Combat_Results_Text", 20, v: true)
        t(kind == 8 ? text("defeated.combat", "Defeated") : text("victorious.combat", "Victorious"), "Victor", 28, v: false)
        t(text("defeated.combat", "Defeated"), "Defeated", 26, v: false)
        t(text("creatures_lost_victor.combat", "Casualties"), "Victor_Losses", 28, v: false)
        t(text("creatures_lost_loser.combat", "Casualties"), "Defeated_Losses", 28, v: false)
        // the movie: its intro once, then the loop, at Cut_Scene's top-left
        if let slot = layer(d, "Cut_Scene"), let movies = movies {
            let since = cs.resultShownAt ?? Date()
            if cs.resultShownAt == nil { cs.resultShownAt = since }
            let t = Date().timeIntervalSince(since)
            var frame: (Movie, Int, String)? = nil
            let intro = o.intro.flatMap { movies.movie($0) }
            if let m = intro, Int(t * m.fps) < m.frames.count { frame = (m, Int(t * m.fps), o.intro!) }
            else if let loop = movies.movie(o.loop), !loop.frames.isEmpty {
                let start = intro.map { Double($0.frames.count) / $0.fps } ?? 0
                frame = (loop, Int((t - start) * loop.fps) % loop.frames.count, o.loop)
            } else if let m = intro { frame = (m, m.frames.count - 1, o.intro!) }
            if let (m, i, name) = frame {
                out.append(Quad(texture: uiTexture("movie|\(name)|\(i)", { m.frames[i] }), x: ox + slot.x, y: oy + slot.y, w: m.width, h: m.height))
            }
        }
        // the armies' portraits under their frames
        func leader(_ side: Int) -> Battle.Unit? { b.units.first { $0.side == side && $0.stats.isHero } ?? b.units.first { $0.side == side && !$0.summoned } }
        for (side, slot) in [(winner, "Winner_Portrait"), (1 - winner, "Loser_Portrait")] {
            if let u = leader(side), let p = unitPortrait(u, size: 82), let l = layer(d, slot) { out.append(image(p, key: "p82|\(p.name)", ox + l.x, oy + l.y)) }
        }
        for n in ["Winner_Frame", "Loser_Frame"] { if let l = layer(d, n) { out.append(image(l, key: "dlg|results|\(n)", ox + l.x, oy + l.y)) } }
        // the casualties: every stack that lost creatures (a hero that fell), as rings at hero_i_of_n
        if let sel = combat?.layers("control.creature_select"), let ring = sel["Ring_Released"] {
            for (side, slot) in [(winner, "Winner_Rings"), (1 - winner, "Loser_Rings")] {
                guard let origin = layer(d, slot) else { continue }
                let lost = b.units.filter { $0.side == side && !$0.summoned }.compactMap { u -> (Battle.Unit, Int)? in
                    let n = u.stats.isHero ? (u.alive ? 0 : 1) : u.initialCount - u.stats.count
                    return n > 0 ? (u, n) : nil
                }.prefix(7)
                for (k, (u, n)) in lost.enumerated() {
                    guard let pos = sel["hero_\(k + 1)_of_\(lost.count)"] else { continue }
                    let bx = ox + origin.x + pos.x, by = oy + origin.y + pos.y
                    if let hi = sel["hero_icon"], let p = unitPortrait(u, size: 52) { out.append(image(p, key: "icon|\(p.name)", bx + hi.x - ring.x, by + hi.y - ring.y)) }
                    out.append(image(ring, key: "creature_select|Ring_Released", bx, by))
                    if !u.stats.isHero, let inset = sel["inset"], let box = sel["inset_text"] {
                        out.append(image(inset, key: "creature_select|inset", bx + inset.x - ring.x, by + inset.y - ring.y))
                        out += textWindow("\(n)", bx + box.x - ring.x, by + box.y - ring.y, box.width, box.height, font: proseFont(13), centre: true, colour: Renderer.insetColour)
                    }
                }
            }
        }
        if let l = layer(d, "Cut_Scene_Frame") { out.append(image(l, key: "dlg|results|Cut_Scene_Frame", ox + l.x, oy + l.y)) }
        out += buttonAt("ok", "Released", layer(d, "ok_button"), ox, oy)
        return out
    }
    /// The casualty count's colour (the caller's argument [G]: dark on the light inset).
    static let insetColour: RGB = (0, 0, 0)

    /// Retreat (0x632cf0 / 0x57a5b0): only heroes can retreat; to the nearest town, losing all the
    /// troops, after "wish_to_retreat.combat" (Yes / No); refusals as OK notices.
    func askRetreat() {
        guard let cs = combat, let b = cs.battle, let g = game else { return }
        guard let h = cs.hero, b.units.contains(where: { $0.side == 0 && $0.stats.isHero && $0.alive }) else {
            prompt = (text("no_heroes.misc", "Only heroes can retreat from combat.  To keep creatures, you must surrender instead."), false, nil); return
        }
        guard let town = g.retreatTown(for: h) else {
            prompt = (text("no_town_after_retreat.combat", "You must have a town to retreat."), false, nil); return
        }
        cs.retreatTown = town
        let q = text("wish_to_retreat.combat", "Are you sure you want to retreat to %town_name?  You will lose all your troops!")
            .replacingOccurrences(of: "%town_name", with: g.towns[town].name)
        prompt = (q, true, { [weak self] in b.retreat(); self?.combat?.pump() })
    }

    /// Surrender (0x632e80 / 0x57b1f0): neutral armies take none ("no_surrender_to_neutral.misc");
    /// else "wish_to_surrender.combat" at the army's cost, "insufficient_gold.combat" when it is
    /// more than the treasury, "no_town_after_surrender.combat" without a town.
    func askSurrender() {
        guard let cs = combat, let b = cs.battle, let g = game else { return }
        guard cs.enemy != nil, let h = cs.hero else {
            prompt = (text("no_surrender_to_neutral.misc", "The enemy shows no interest in allowing you to surrender."), false, nil); return
        }
        guard let town = g.retreatTown(for: h) else {
            prompt = (text("no_town_after_surrender.combat", "You do not have a town to return to, so you cannot surrender."), false, nil); return
        }
        // the cost: what the surviving creatures would cost to hire [G]
        let cost = b.units.filter { $0.side == 0 && $0.alive && !$0.stats.isHero && !$0.summoned }.reduce(0) { $0 + $1.stats.count * (g.tables?.creature($1.keyword)?.gold ?? 0) }
        guard g.resources["Gold", default: 0] >= cost else {
            prompt = (text("insufficient_gold.combat", "You don't have enough gold to surrender."), false, nil); return
        }
        cs.retreatTown = town
        let q = text("wish_to_surrender.combat", "Do you wish to surrender at a cost of %surrender_cost gold?  Any heroes and creatures will return to %town_name.")
            .replacingOccurrences(of: "%surrender_cost", with: "\(cost)").replacingOccurrences(of: "%town_name", with: g.towns[town].name)
        prompt = (q, true, { [weak self] in
            g.resources["Gold", default: 0] -= cost
            cs.surrendered = true
            b.retreat(); self?.combat?.pump()
        })
    }

    /// Leave the combat screen and apply the result to the map.
    func closeCombat() {
        if let cs = combat, let b = cs.battle, let g = game, let h = cs.hero, let town = cs.siegeTown {   // a siege
            let won = b.finished ?? false
            for (hh, u) in zip([h] + h.companions, b.units.filter { $0.side == 0 && $0.stats.isHero }) { if let c = u.caster { hh.spellPoints = c.spellPoints } }
            func survivors(_ side: Int) -> [Hero.Stack] { b.units.filter { $0.side == side && !$0.stats.isHero && $0.alive && !$0.summoned }.map { Hero.Stack(creature: $0.keyword, count: $0.stats.count) } }
            g.finishSiege(hero: h, town: town, won: won, army: survivors(0), garrison: survivors(1), value: b.experience)
            cs.battle = nil; cs.siegeTown = nil
            return
        }
        if let cs = combat, let b = cs.battle, let g = game, let h = cs.hero, let e = cs.enemy {   // an enemy hero's army
            let won = b.finished ?? false
            for (hh, u) in zip([h] + h.companions, b.units.filter { $0.side == 0 && $0.stats.isHero }) { if let c = u.caster { hh.spellPoints = c.spellPoints } }
            func survivors(_ side: Int) -> [Hero.Stack] { b.units.filter { $0.side == side && !$0.stats.isHero && $0.alive && !$0.summoned }.map { Hero.Stack(creature: $0.keyword, count: $0.stats.count) } }
            if cs.surrendered, let town = cs.retreatTown {   // the army returns to the town whole
                let army = survivors(0)
                g.retreat(hero: h, monsterAt: g.monsters.count, monstersLeft: 0, to: town)
                h.army = army; e.army = survivors(1); g.pendingHeroBattle = nil
                cs.battle = nil; cs.enemy = nil
                return
            }
            let loser = won ? 1 : 0
            let value = b.units.filter { $0.side == loser && !$0.stats.isHero }.reduce(0) { $0 + ($1.initialCount - $1.stats.count) * $1.stats.experience }
            g.finishHeroBattle(hero: h, enemy: e, won: won, army: survivors(0), enemyArmy: survivors(1), value: value)
            cs.battle = nil; cs.enemy = nil
            return
        }
        guard let cs = combat, let b = cs.battle, let g = game, let h = cs.hero, let p = cs.placed else { combat?.battle = nil; return }
        if b.retreated, let town = cs.retreatTown {
            g.retreat(hero: h, monsterAt: cs.monsterIndex, monstersLeft: b.units.first { $0.side == 1 }?.stats.count ?? 0, to: town)
            cs.battle = nil; return
        }
        let won = b.finished ?? false
        // the heroes keep the spell points they have left; summoned stacks go
        for (hh, u) in zip([h] + h.companions, b.units.filter { $0.side == 0 && $0.stats.isHero }) { if let c = u.caster { hh.spellPoints = c.spellPoints } }
        let army = b.units.filter { $0.side == 0 && !$0.stats.isHero && $0.alive && !$0.summoned }.map { Hero.Stack(creature: $0.keyword, count: $0.stats.count) }
        let left = b.units.first { $0.side == 1 }?.stats.count ?? 0
        g.finishBattle(hero: h, monsterAt: cs.monsterIndex, p, won: won, army: army, monstersLeft: left, experience: b.experience, rounds: b.round)
        cs.battle = nil
    }
}
