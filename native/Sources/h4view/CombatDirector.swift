import Foundation
import H4Engine

/// The battle's events turned into the original's presentation: each action starts when everything
/// the previous one set going has ended (0x56b310); within an action the pieces overlap as the exe
/// times them (the spell released on the caster's hit frame, missiles landing a tick after they
/// arrive, every target of a mass spell in the same frame).
extension CombatScreen {
    /// Queue new events. The battle has already moved the units, so a unit about to move is held
    /// where it starts until its move plays (otherwise it shows at its end for a frame and jumps back).
    func take(_ events: [Battle.Event]) {
        for e in events {
            if case .move(let id, _, let from, _) = e, unitPos[id] == nil, shownPos[id] == nil { shownPos[id] = (Float(from.0), Float(from.1)) }
            if case .teleported(let id, let from, _) = e, shownPos[id] == nil { shownPos[id] = (Float(from.0), Float(from.1)) }
            if case .displaced(let id, let from, _) = e, shownPos[id] == nil { shownPos[id] = (Float(from.0), Float(from.1)) }
            if case .die(let id) = e { pendingDeaths.insert(id) }
            // a summoned stack is not there before the spell is released
            if case .summon(let id) = e { hidden.insert(id) }
            if case .phantom(let id, _) = e { hidden.insert(id) }
            // a stack keeps the count it had until the blow or spell that cuts it lands on screen
            switch e {
            case .melee(_, let t, _, let k, let l), .shoot(_, let t, _, let k, let l), .effect(let t, _, _, let k, let l), .spellHit(let t, _, _, let k, let l):
                if shownCount[t] == nil { shownCount[t] = l + k }
            default: break
            }
            // the unit whose action this is stays the active one until it has played out
            if acting == nil {
                switch e {
                case .move(let id, _, _, _), .melee(let id, _, _, _, _), .shoot(let id, _, _, _, _), .cast(let id, _, _), .gateHit(let id, _, _), .defend(let id), .wait(let id), .morale(let id, _):
                    acting = id
                default: break
                }
            }
        }
        queue += events
    }

    /// Advance the playback to `now`.
    func update(now: Date) {
        guard let b = battle else { return }
        advance(to: now)
        updateMoves(now)
        // the next action: only when nothing is pending
        var guardN = 0
        while holds == 0, !queue.isEmpty, guardN < 500 {
            guardN += 1
            begin(queue.removeFirst(), now: now)
            advance(to: now)
        }
        if holds == 0, queue.isEmpty { pump(); if !queue.isEmpty { update(now: now); return } }
        if holds == 0, queue.isEmpty {
            shownPos.removeAll(); shownCount.removeAll(); acting = nil; lastBlow = nil
            // the icy tint lasts while the stack is frozen (removing effect 186 resets it, 0x5f24c7)
            for (id, t) in tints where t.kind == .freeze && b.unit(id).frozen == 0 { tints[id] = nil }
        }
        updateSlides(now)
        if fidgeting == nil, now >= nextFidget {
            let waiting = b.units.filter { $0.alive && unitState[$0.id] == nil && unitPos[$0.id] == nil && !$0.disabled && !hidden.contains($0.id) }
            if waiting.isEmpty { nextFidget = now.addingTimeInterval(0.5) }
            else { let id = waiting[idleRandom.next() % waiting.count].id; fidget(id, now: now); fidgeting = id }
        }
        floaters.removeAll { now.timeIntervalSince($0.since) > floaterLife }
        if let m = actionMessage, now >= m.until { actionMessage = nil }
    }

    func begin(_ e: Battle.Event, now: Date) {
        guard let b = battle else { return }
        if CombatScreen.trace { print(String(format: "  [%.3f] begin ", now.timeIntervalSince(traceStart)) + "\(e)".prefix(90)) }
        switch e {
        case .move(let id, let path, let start, let flying):
            beginMove(id, path: path, start: start, flying: flying, now: now)
        case .melee, .shoot:
            beginSwings(e, now: now)
        case .together, .newRound, .castAt:
            break
        case .die(let id):
            pendingDeaths.remove(id); dying.insert(id)
            play(id, "die", at: now)
        case .defend(let id):
            postAction(id, "combat_action.defend", "Defend", now: now)
            play(id, "block", at: now)
        case .morale(let id, let good):
            // bad morale plays sorrow, good morale spiritual fervor (0x5f37a8 / 0x5f3850); the panel says it
            postAction(id, good ? "combat_action.good_morale" : "combat_action.bad_morale", good ? "Good Morale" : "Bad Morale", now: now)
            showEffect(good ? "spiritual fervor" : "sorrow", on: id, at: now, sound: good ? 148 : 145)
        case .effect(let id, let name, let dmg, let killed, let left):
            // an ability or a start-of-turn effect, with the fall it causes
            var dies = false
            if case .die(let d)? = queue.first, d == id { queue.removeFirst(); dies = true }
            abilityEffect(Strike(attacker: nil, target: id, damage: dmg, killed: killed, left: left, dies: dies), name: name, at: now)
        case .spellHit(let id, let spell, let dmg, let killed, let left):
            // on its own: Regeneration at the start of a turn
            var dies = false
            if case .die(let d)? = queue.first, d == id { queue.removeFirst(); dies = true }
            spellTarget(spell, Strike(attacker: nil, target: id, damage: dmg, killed: killed, left: left, dies: dies), at: now)
        case .cast(let id, let spell, let targets):
            beginCast(id, spell, targets: targets, now: now)
        case .resisted(let id, _):
            resist(id, at: now)
        case .gateHit(let id, let dmg, _):
            let u = b.unit(id)
            if let c = b.field.gateCells.first { face(u, toward: ((c / Battlefield.size + 1) * 16, (c % Battlefield.size + 5) * 16)) }
            let ranged = u.stats.shooter && !b.nextToGate(u)
            play(id, ranged ? "ranged" : "melee", at: now, hit: { [weak self] t in
                guard let self = self, self.showOtherNumbers, let c = b.field.gateCells.first else { return }
                // wall / gate damage: white, no icon (t_castle_gate 0x5bff70)
                let gx = Float(c / Battlefield.size) + 1, gy = Float(c % Battlefield.size) + 5
                self.floaters.append(Floater(lines: [("-\(dmg)", nil)], world: (gx, gy), height: 80, since: t, colour: (255, 255, 255)))
            })
        case .summon(let id):
            appear(id, spell: nil, at: now)
        case .teleported, .displaced, .revived, .phantom:
            special(e, spell: nil, caster: nil, at: now)
        case .wait(let id):
            postAction(id, "combat_action.wait", "Wait", now: now)
        case .finished(let won):
            result = (won, b.round)
            sound?.playMusic(won ? "combat.win" : "combat.lose", loop: false)
            after(now.addingTimeInterval(0.6)) { [weak self] _ in self?.showResults = true }
        }
    }

    // MARK: moves

    func beginMove(_ id: Int, path: [(Int, Int)], start: (Int, Int), flying: Bool, now: Date) {
        guard let b = battle, !path.isEmpty else { return }
        let u = b.unit(id)
        if u.stats.has("teleport") {
            // a teleporter (the devil, t_teleport_ability 0x87e0c0) faces where it goes, plays prewalk,
            // jumps there and plays postwalk, each with its state sound; no fade
            let end = path[path.count - 1]
            face(u, toward: (end.0 * 16 + u.size * 8, end.1 * 16 + u.size * 8))
            unitPos[id] = (Float(start.0), Float(start.1))
            play(id, "prewalk", at: now, then: { [weak self] t in
                guard let self = self else { return }
                self.unitPos[id] = nil; self.shownPos[id] = (Float(end.0), Float(end.1))
                self.play(id, "postwalk", at: t)
            })
            return
        }
        // flyers take off first (0x7dd400: prewalk, walk, postwalk); walkers walk and stop (0x7de960: walk, postwalk)
        let pts = flying ? [start] + (path.last.map { [$0] } ?? []) : [start] + path
        let face0 = pts.count > 1 ? Battle.facing(dx: Float(pts[1].0 - pts[0].0), dy: Float(pts[1].1 - pts[0].1)) : u.facing
        // the path's length in world units: 16 a straight step, 24 a diagonal one (0x7dec80); a flight is a straight line
        var length: Float = 0
        for k in 1..<max(1, pts.count) {
            let dx = abs(pts[k].0 - pts[k - 1].0), dy = abs(pts[k].1 - pts[k - 1].1)
            length += flying ? 16 * Float(dx * dx + dy * dy).squareRoot() : Float(dx != 0 && dy != 0 ? 24 : 16)
        }
        let a = actor(u.actor)
        let preTime = flying ? stateDuration(u.actor, "prewalk", face0) : 0
        let postTime = stateDuration(u.actor, "postwalk", face0)
        var preDist = preTime > 0 ? Float(a?.prewalkDistance ?? 16) : 0
        var postDist = postTime > 0 ? Float(a?.postwalkDistance ?? 16) : 0
        if preDist + postDist > length { let k = length / max(1, preDist + postDist); preDist *= k; postDist *= k }
        let loop = Float(a?.walkDistance ?? 64)
        let loops = max(length - preDist - postDist > 0 ? 1 : 0, Int((length - preDist - postDist + loop / 2) / loop))
        let loopTime = stateDuration(u.actor, "walk", face0)
        let walkTime = Double(loops) * (loopTime > 0 ? loopTime : Double(loop / 16) / CombatScreen.cellsPerSecond)
        sound?.startLoop("\(u.actor).walk", key: "walk|\(id)")
        let m = Move(length: length / 16, preDist: preDist / 16, postDist: postDist / 16, preTime: preTime, walkTime: walkTime, postTime: postTime)
        moving[id] = MoveAnim(path: path, start: start, flying: flying, since: now, move: m)
        unitPos[id] = (Float(start.0), Float(start.1))   // from this frame on, not only from the next update
        u.facing = face0
        after(now.addingTimeInterval(preTime + walkTime + postTime)) { [weak self] t in
            guard let self = self else { return }
            // it stays where this move ended until the queue has played out (the battle may already have moved it on)
            if let last = path.last { self.shownPos[id] = (Float(last.0), Float(last.1)) }
            self.unitPos[id] = nil; self.unitState[id] = nil; self.moving[id] = nil
            self.sound?.stopLoop("walk|\(id)")
            self.unitIdle(id, at: t)
        }
    }
    /// Positions and walk states of the moves in progress.
    func updateMoves(_ now: Date) {
        guard let b = battle else { return }
        for (id, mv) in moving {
            let m = mv.move
            // prewalk (a flyer's take-off), whole loops of walk, postwalk, each covering its
            // share of the path's length (0x7dec80)
            let elapsed = now.timeIntervalSince(mv.since)
            let state: String, d: Float
            if elapsed < m.preTime {
                state = "prewalk"; d = m.preDist * Float(elapsed / max(0.001, m.preTime))
            } else if elapsed < m.preTime + m.walkTime {
                state = "walk"; d = m.preDist + (m.length - m.preDist - m.postDist) * Float((elapsed - m.preTime) / max(0.001, m.walkTime))
            } else {
                state = "postwalk"; d = (m.length - m.postDist) + m.postDist * Float(min(1, (elapsed - m.preTime - m.walkTime) / max(0.001, m.postTime)))
            }
            // a flight is one straight line from where it took off to where it lands
            let pts = mv.flying ? [mv.start, mv.path[mv.path.count - 1]] : [mv.start] + mv.path
            var geo: Float = 0
            for k in 1..<pts.count { let dx = Float(pts[k].0 - pts[k - 1].0), dy = Float(pts[k].1 - pts[k - 1].1); geo += (dx * dx + dy * dy).squareRoot() }
            let (pos, dir) = CombatScreen.along(pts, m.length > 0 ? d / m.length * geo : geo)
            unitPos[id] = pos
            if unitState[id]?.state != state { unitState[id] = UnitAnim(state: state, since: now, once: state != "walk") }
            if dir.0 != 0 || dir.1 != 0 { b.unit(id).facing = Battle.facing(dx: dir.0, dy: dir.1) }
        }
    }
    func updateSlides(_ now: Date) {
        for (id, s) in slides {
            let f = Float(min(15, max(0, Int(now.timeIntervalSince(s.since) / 0.1)))) / 15
            unitPos[id] = (s.from.0 + (s.to.0 - s.from.0) * f, s.from.1 + (s.to.1 - s.from.1) * f)
        }
    }

    // MARK: blows

    /// One swing: the attacker's blow on its target and the others the same blow strikes (area,
    /// 3-headed, breath), what its abilities do then, and who falls of it.
    struct Swing {
        var attacker: Int, ranged: Bool
        var strikes: [Strike] = []
        var effects: [(strike: Strike, name: String)] = []
    }
    /// Start a blow and what is played with it: the answering blow of a simultaneous exchange (after
    /// `.together`) starts in the same frame; the target's fall and the attack's aftermath come at the
    /// hit (melee) or the impact (missiles).
    func beginSwings(_ first: Battle.Event, now: Date) {
        func swing(_ e: Battle.Event) -> Swing? {
            switch e {
            case .melee(let a, let t, let d, let k, let l): var s = Swing(attacker: a, ranged: false); s.strikes = [Strike(attacker: a, target: t, damage: d, killed: k, left: l)]; return s
            case .shoot(let a, let t, let d, let k, let l): var s = Swing(attacker: a, ranged: true); s.strikes = [Strike(attacker: a, target: t, damage: d, killed: k, left: l)]; return s
            default: return nil
            }
        }
        guard var current = swing(first) else { return }
        var swings: [Swing] = []
        parse: while let e = queue.first {
            switch e {
            case .together:
                queue.removeFirst()
                guard let n = queue.first, let s = swing(n) else { break parse }
                queue.removeFirst()
                swings.append(current); current = s
            case .melee(let a, let t, _, _, _), .shoot(let a, let t, _, _, _):
                // the same swing striking another stack too (area, 3-headed, breath)
                let ranged: Bool = { if case .shoot = e { return true }; return false }()
                guard a == current.attacker, ranged == current.ranged, !current.strikes.contains(where: { $0.target == t }) else { break parse }
                queue.removeFirst()
                if let s = swing(e) { current.strikes += s.strikes }
            case .effect(let id, let name, let d, let k, let l):
                // the aftermath (0x553440) on the stacks of this exchange
                let involved = Set(swings.flatMap { $0.strikes.map { $0.target } + [$0.attacker] } + current.strikes.map { $0.target } + [current.attacker])
                guard involved.contains(id) else { break parse }
                queue.removeFirst()
                current.effects.append((Strike(attacker: current.attacker, target: id, damage: d, killed: k, left: l), name))
            case .die(let id):
                // the fall goes with what caused it: an effect's damage, else the blow that struck it last
                var all = swings + [current]
                var placed = false
                for si in stride(from: all.count - 1, through: 0, by: -1) where !placed {
                    if let ei = all[si].effects.lastIndex(where: { $0.strike.target == id && $0.strike.damage > 0 }) { all[si].effects[ei].strike.dies = true; placed = true }
                    else if let k = all[si].strikes.lastIndex(where: { $0.target == id }) { all[si].strikes[k].dies = true; placed = true }
                }
                guard placed else { break parse }
                queue.removeFirst()
                current = all.removeLast(); swings = all
            default:
                break parse
            }
        }
        swings.append(current)
        for s in swings { startSwing(s, now: now) }
    }

    /// The attacker turns to its target and plays melee or ranged (sound with it); on the hit frame a
    /// melee blow lands, a shot leaves.
    func startSwing(_ s: Swing, now: Date) {
        guard let b = battle, let first = s.strikes.first else { return }
        let a = b.unit(s.attacker), t = b.unit(first.target)
        // the facing from the shooter's centre to the aim point (0x568900 / 0x51ee00)
        let aim = aimPoint(t)
        face(a, toward: (aim.0, aim.1))
        // the panel: "Melee Attack" / "Ranged Attack", or "Retaliate" for a blow back at the striker
        let back = lastBlow.map { $0.target == s.attacker && $0.attacker == first.target } ?? false
        if back { postAction(s.attacker, s.ranged ? "combat_action.ranged_retaliation" : "combat_action.melee_retaliation", "Retaliate", now: now) }
        else { postAction(s.attacker, s.ranged ? "combat_action.ranged_attack" : "combat_action.melee_attack", s.ranged ? "Ranged Attack" : "Melee Attack", now: now) }
        lastBlow = (s.attacker, first.target)
        play(s.attacker, s.ranged ? "ranged" : "melee", at: now, hit: { [weak self] th in
            guard let self = self else { return }
            if s.ranged {
                let from = self.launchPoint(a)
                let land: (Date) -> Void = { [weak self] ti in self?.impact(s, at: ti) }
                if let type = self.missileType(a) { self.launch(type, from: from, to: aim, at: th, impact: land) } else { land(th) }
            } else {
                self.land(s, at: th, deferBusy: false)
            }
        })
    }
    /// A shot lands (0x56ad10): the shooter's impact effect, then the reactions of what it struck.
    func impact(_ s: Swing, at t: Date) {
        guard let b = battle, let first = s.strikes.first else { return }
        let a = b.unit(s.attacker), tg = b.unit(first.target)
        let p = aimPoint(tg)
        switch a.keyword.lowercased() {
        case "cyclops", "gargantuan":
            // the boulder's puff (0x5d4230): missile.Boulder_Puff in cast_spell, 100000 / (8 x speed) ms a frame
            fieldActor("missile.Boulder_Puff", states: ["cast_spell"], at: (Float(p.0), Float(p.1), 0), t: t)
        case "catapult":
            fieldActor("spells.Fireball", states: ["prewalk", "walk", "postwalk"], at: (Float(p.0), Float(p.1), 0), t: t)
        default:
            if a.stats.isHero, a.stats.has("area_effect") { fieldActor("spells.Fireball", states: ["prewalk", "walk", "postwalk"], at: (Float(p.0), Float(p.1), 0), t: t) }
        }
        land(s, at: t, deferBusy: true)
    }
    /// The swing's strikes and aftermath take effect.
    func land(_ s: Swing, at t: Date, deferBusy: Bool) {
        for k in s.strikes {
            if !deferBusy, busy(k.target) {
                // a stack swinging its own blow (a simultaneous exchange) is not cut short by a flinch;
                // its fall waits for the swing
                shownCount[k.target] = k.left
                if let b = battle, k.damage > 0 || k.killed > 0 { blowMessages(damage: k.damage, killed: k.killed, unit: b.unit(k.target), since: t) }
                if k.dies { var d = k; d.damage = 0; d.killed = 0; react(d, at: t, rule: .blow, deferBusy: true) }
                continue
            }
            react(k, at: t, rule: .blow, deferBusy: deferBusy)
        }
        for e in s.effects { abilityEffect(e.strike, name: e.name, at: t) }
    }

    /// An ability's or a turn start's effect on a stack (the fixed ids of spell_visuals_spec 3.2): its
    /// window and sound; damage shows when the window ends (Lightning: when it starts).
    func abilityEffect(_ s: Strike, name: String, at t: Date) {
        guard let b = battle else { return }
        let key = name.lowercased()
        switch key {
        case "frozen":
            // Freezing Attack: no window, the icy ramp and sound.spell.frozen
            freeze(s.target, at: t)
            return
        case "stone_gaze":
            stone(s.target, at: t, survivors: s.left > 0)
        default: break
        }
        let sid = CombatScreen.spellId(key)
        if s.damage <= 0 && s.killed <= 0 {
            // a heal or a status: the count changes as it starts (vampirism raises the dead)
            showEffect(name, on: s.target, at: t, sound: sid, start: { [weak self] _ in self?.shownCount[s.target] = s.left })
            if s.dies { react(s, at: t, rule: .spell, deferBusy: true) }
            return
        }
        if key == "lightning" {
            showEffect(name, on: s.target, at: t, sound: sid, start: { [weak self] ts in self?.react(s, at: ts, rule: .spell, deferBusy: false) })
        } else {
            showEffect(name, on: s.target, at: t, sound: sid, then: { [weak self] te in self?.react(s, at: te, rule: .spell, deferBusy: true) })
        }
        _ = b
    }

    // MARK: spells

    /// The caster turns to its target and plays cast_spell; the spell is released on its hit frame
    /// (0x574c60 -> 0x583580 -> slot 9) while the caster finishes the rest of its frames.
    func beginCast(_ caster: Int, _ spell: Int, targets: [Int], now: Date) {
        guard let b = battle else { return }
        let effectSpell = Battle.massOf[spell] ?? spell
        // what the cast did, as the battle resolved it
        var strikes: [Strike] = [], resisted: [Int] = [], summons: [Int] = [], specials: [Battle.Event] = []
        var cell: (Int, Int)? = nil
        var spellOf: [Int: Int] = [:]
        parse: while let e = queue.first {
            switch e {
            case .castAt(_, _, let c): cell = c
            case .spellHit(let id, let sp, let d, let k, let l) where sp == spell || sp == effectSpell || sp == 5:
                if let i = strikes.firstIndex(where: { $0.target == id }) {
                    // Banish reports its damage and then the spell itself: one strike
                    if d != 0 { strikes[i].damage = d; strikes[i].killed = k }
                    strikes[i].left = l
                } else { strikes.append(Strike(attacker: caster, target: id, damage: d, killed: k, left: l)); spellOf[id] = sp }
            case .resisted(let id, _): resisted.append(id)
            case .summon(let id): summons.append(id)
            case .die(let id):
                if let i = strikes.lastIndex(where: { $0.target == id }) { strikes[i].dies = true }
                else { strikes.append(Strike(attacker: caster, target: id, damage: 0, killed: shownCount[id] ?? 0, left: 0, dies: true)) }
            case .teleported, .displaced, .revived, .phantom: specials.append(e)
            default: break parse
            }
            queue.removeFirst()
        }
        let u = b.unit(caster)
        let def = RuleTables.spells[spell]
        // the facing toward the target (0x5748c0); a self-target or no target keeps it
        if let c = cell { face(u, toward: (c.0 * 16 + 8, c.1 * 16 + 8)) }
        else if let t = targets.first(where: { $0 != caster }) ?? strikes.first(where: { $0.target != caster })?.target {
            let p = aimPoint(b.unit(t)); face(u, toward: (p.0, p.1))
        }
        postAction(caster, "combat_action.cast_spell", "Cast %Spell", now: now, replacing: ["%Spell": def.name, "%spell": def.name])
        let release: (Date) -> Void = { [weak self] t in
            self?.release(spell, by: caster, strikes: strikes, spellOf: spellOf, resisted: resisted, summons: summons, specials: specials, cell: cell, at: t)
        }
        play(caster, "cast_spell", at: now, hit: release)
    }

    /// The spell released: what each kind of spell shows (spell_visuals_spec 1.3, area_spells_spec).
    func release(_ spell: Int, by caster: Int, strikes: [Strike], spellOf: [Int: Int], resisted: [Int], summons: [Int],
                 specials: [Battle.Event], cell: (Int, Int)?, at t: Date) {
        guard let b = battle else { return }
        let u = b.unit(caster)
        for id in resisted { resist(id, at: t) }
        for id in summons { appear(id, spell: spell, at: t) }
        for e in specials { special(e, spell: spell, caster: caster, at: t) }
        switch spell {
        case 43, 66, 67, 19, 25, 50:
            // the fireball family (t_fireball): missile #6 (none for Cloud of Confusion) to the cell's
            // centre at ground level; on impact the sound, every member struck at once, the burst(s)
            let c = cell ?? strikes.first.map { s in let v = b.unit(s.target); return (v.x + v.size / 2, v.y + v.size / 2) } ?? (u.x, u.y)
            let target = (c.0 * 16 + 8, c.1 * 16 + 8, 0)
            let boom: (Date) -> Void = { [weak self] ti in
                guard let self = self else { return }
                self.playSpellSound(spell)
                for s in strikes { self.react(s, at: ti, rule: .spell, deferBusy: true) }
                self.areaBurst(spell, at: target, t: ti)
            }
            if spell == 19 { boom(t) } else {
                let from = launchPoint(u)
                launch(6, from: (from.0 + 8, from.1 + 8, from.2), to: target, at: t, impact: boom)
            }
        case 4:
            armageddon(strikes, at: t)
        case 17:
            chainLightning(strikes, at: t)
        case 41:
            fireRing(strikes, cell: cell, at: t)
        case 14:
            sparks(strikes, by: caster, at: t)
        case 68:
            lifeDrain(strikes, to: caster, at: t)
        case 39, 63, 71, 72:
            // t_missile_spell (0x61a750): the sound at launch, the missile (fire bolt 7, ice bolt 9,
            // magic arrow 13, magic fist 14), the struck stack's reaction at impact
            let type = [39: 7, 63: 9, 71: 13, 72: 14][spell]!
            playSpellSound(spell)
            for s in strikes {
                let tg = b.unit(s.target)
                launch(type, from: launchPoint(u), to: aimPoint(tg), at: t, impact: { [weak self] ti in self?.react(s, at: ti, rule: .blow, deferBusy: true) })
            }
        default:
            for s in strikes { spellTarget(spellOf[s.target] ?? spell, s, at: t) }
        }
    }

    /// One target of an ordinary spell: its effect window and sound (0x575960); damage spells show the
    /// loss when the window ends (0x56b540; Lightning when it starts), heals "+N" at once, a stack the
    /// spell kills outright (Hand of Death) falls with the window.
    func spellTarget(_ spell: Int, _ s: Strike, at t: Date) {
        guard let b = battle else { return }
        let name = CombatScreen.effectKeyword(spell)
        if s.damage > 0 {
            if spell == 69 {
                showEffect(name, on: s.target, at: t, sound: spell, start: { [weak self] ts in self?.react(s, at: ts, rule: .spell, deferBusy: false) })
            } else {
                showEffect(name, on: s.target, at: t, sound: spell, then: { [weak self] te in self?.react(s, at: te, rule: .spell, deferBusy: true) })
            }
            return
        }
        showEffect(name, on: s.target, at: t, sound: spell)
        if s.damage < 0 {
            shownCount[s.target] = s.left
            if showOtherNumbers { floatOver(b.unit(s.target), [("+\(-s.damage)", "heal")], since: t) }
        } else if s.dies {
            // Hand of Death: the "-N" and the fall with the window
            react(Strike(attacker: s.attacker, target: s.target, damage: 0, killed: s.killed, left: s.left, dies: true), at: t, rule: .spell, deferBusy: true)
        } else {
            shownCount[s.target] = s.left
        }
    }

    /// A resisted spell (0x575dc0): the message and animation.spell.magic resistance with its sound.
    func resist(_ id: Int, at t: Date) {
        postAction(id, "combat_action.magic_resistance", "Magic Resistance", now: t)
        showEffect("magic resistance", on: id, at: t, sound: 75)
    }

    /// A summoned stack fades in, 15 steps of 75 ms in its idle state, with the spell's sound (0x87c1c0).
    func appear(_ id: Int, spell: Int?, at t: Date) {
        hidden.remove(id)
        alphaLevel[id] = 0
        if let s = spell { playSpellSound(s) }
        fade(id, from: 0, to: 15, at: t)
    }

    /// Fire Ball bursts (combat_actor.spells.Fireball, pre -> loop -> post at 100000 / (fps x speed)):
    /// one at the impact; Inferno four more 48 units along the grid diagonals (0x718880); the clouds
    /// for Cloud of Confusion / Despair (spells.cloud of confusion) and Choking Gas (spells.choking gas).
    func areaBurst(_ spell: Int, at p: (Int, Int, Int), t: Date) {
        switch spell {
        case 19, 25:
            fieldActor("spells.cloud of confusion", states: ["prewalk", "walk", "postwalk"], at: (Float(p.0), Float(p.1), 0), t: t)
        case 50:
            fieldActor("spells.choking gas", states: ["prewalk", "walk", "postwalk"], at: (Float(p.0), Float(p.1), 0), t: t)
        default:
            fieldActor("spells.Fireball", states: ["prewalk", "walk", "postwalk"], at: (Float(p.0), Float(p.1), 0), t: t)
            if spell == 66 {
                for d in [(-1, -1), (-1, 1), (1, 1), (1, -1)] {
                    fieldActor("spells.Fireball", states: ["prewalk", "walk", "postwalk"], at: (Float(p.0 + 48 * d.0), Float(p.1 + 48 * d.1), 0), t: t)
                }
            }
        }
    }

    /// Armageddon (0x718d60 / 0x719380): one sound; then every 50 ms one meteor (missile #0) for a
    /// random remaining target (the game's LCG), falling from 640 units "north" and 452 up, walked
    /// back into the field; each impact strikes that stack and bursts.
    func armageddon(_ strikes: [Strike], at t: Date) {
        guard let b = battle else { return }
        playSpellSound(4)
        var list = strikes
        var rng = GameRandom(seed: (b.units.count * 7919) ^ Int(b.round))
        var k = 0
        while !list.isEmpty {
            let s = list.remove(at: rng.next() % list.count)
            let tg = b.unit(s.target)
            let w = worldPos(tg)
            let target = ((w.0 / 16 + tg.size / 2) * 16 + 8, (w.1 / 16 + tg.size / 2) * 16 + 8, 0)
            // start = target + (0, -640, +452), walked back toward the target in 16-unit steps until inside
            var start = (Double(target.0), Double(target.1) - 640, 452.0)
            let len = (640.0 * 640 + 452 * 452).squareRoot()
            let field = Double(Battlefield.size * 16)
            while start.1 < 0 || start.1 >= field || start.0 < 0 || start.0 >= field {
                start.1 += 640 / len * 16; start.2 -= 452 / len * 16
            }
            let st = (Int(start.0), Int(start.1), Int(start.2))
            after(t.addingTimeInterval(0.05 * Double(k))) { [weak self] tl in
                self?.launch(0, from: st, to: target, at: tl, impact: { [weak self] ti in
                    guard let self = self else { return }
                    self.react(s, at: ti, rule: .spell, deferBusy: true)
                    self.fieldActor("spells.Fireball", states: ["prewalk", "walk", "postwalk"], at: (Float(target.0), Float(target.1), 0), t: ti)
                })
            }
            k += 1
        }
    }

    /// Chain Lightning (0x5c8660 / 0x5c7bf0): the Lightning window on the first target (its reaction
    /// at the start), then, when it ends, a bolt (missile #5) from each stack hit to the next, each
    /// striking on arrival and jumping on at once.
    func chainLightning(_ strikes: [Strike], at t: Date) {
        guard let b = battle, let first = strikes.first else { return }
        func jump(_ k: Int, _ tk: Date) {
            guard k < strikes.count else { return }
            let from = aimPoint(b.unit(strikes[k - 1].target)), to = aimPoint(b.unit(strikes[k].target))
            launch(5, from: from, to: to, at: tk, impact: { [weak self] ti in
                self?.react(strikes[k], at: ti, rule: .spell, deferBusy: true)
                jump(k + 1, ti)
            })
        }
        showEffect("lightning", on: first.target, at: t, sound: 69,
                   start: { [weak self] ts in self?.react(first, at: ts, rule: .spell, deferBusy: false) },
                   then: { tj in jump(1, tj) })
    }

    /// Fire Ring (t_fire_ring 0x714dc0): every target struck first, then the sound; a ring of
    /// spells.Fire Ring flames (cast_spell, 1000 / fps) around the aimed stack's footprint centre at
    /// R = size x 8 (24 with no stack) + 16, n = (round(2 pi R) / 2) >> 4 flames at pi/4 + 2 pi j / n.
    func fireRing(_ strikes: [Strike], cell: (Int, Int)?, at t: Date) {
        guard let b = battle else { return }
        for s in strikes { react(s, at: t, rule: .spell, deferBusy: true) }
        playSpellSound(41)
        guard let c = cell else { return }
        var centre = (Double(c.0 * 16 + 8), Double(c.1 * 16 + 8)), r = 24.0 + 16
        if let v = b.units.first(where: { shownAlive($0) && c.0 >= $0.x && c.0 < $0.x + $0.size && c.1 >= $0.y && c.1 < $0.y + $0.size }) {
            let w = worldPos(v)
            centre = (Double(w.0 + v.size * 8), Double(w.1 + v.size * 8)); r = Double(v.size * 8 + 16)
        }
        let n = max(1, (Int((2 * Double.pi * r).rounded()) / 2) >> 4)
        for j in 0..<n {
            let th = Double.pi / 4 + 2 * Double.pi * Double(j) / Double(n)
            let p = (Float(centre.0 + r * sin(th)), Float(centre.1 + r * cos(th)), Float(0))
            fieldActor("spells.Fire Ring", states: ["cast_spell"], at: p, t: t, unscaled: true)
        }
    }
    /// Sparks (t_spell_sparks 0x866c60): the sound, a spells.sparks actor in melee facing the caster's
    /// way at its front edge (13 frames x 100 ms); the targets struck at its hit frame (5).
    func sparks(_ strikes: [Strike], by caster: Int, at t: Date) {
        guard let b = battle else { return }
        let u = b.unit(caster)
        playSpellSound(14)
        let w = worldPos(u)
        let d = CombatScreen.directions[u.facing] ?? (0, 0)
        let p = (Float(w.0 + u.size * 8 + d.0 * u.size * 8), Float(w.1 + u.size * 8 + d.1 * u.size * 8), Float(0))
        fieldActor("spells.sparks", states: ["melee"], at: p, facing: u.facing, t: t, unscaled: true,
                   hit: { [weak self] th in for s in strikes { self?.react(s, at: th, rule: .spell, deferBusy: true) } })
    }
    /// Life Drain: each target struck at once, then a life_force missile from it back to the caster
    /// carrying half the damage; the caster's "+N" on arrival.
    func lifeDrain(_ strikes: [Strike], to caster: Int, at t: Date) {
        guard let b = battle else { return }
        let u = b.unit(caster)
        for s in strikes {
            react(s, at: t, rule: .blow, deferBusy: true)
            let gain = s.damage / 2
            launch(10, from: aimPoint(b.unit(s.target)), to: aimPoint(u), at: t, impact: { [weak self] ti in
                guard let self = self, gain > 0, self.showOtherNumbers else { return }
                self.floatOver(u, [("+\(gain)", "heal")], since: ti)
            })
        }
    }
    /// The grid direction of a facing (table 0x705b60): ne (-1, 0), e (-1, 1), ... n (-1, -1).
    static let directions: [String: (Int, Int)] = ["ne": (-1, 0), "e": (-1, 1), "se": (0, 1), "s": (1, 1), "sw": (1, 0), "w": (1, -1), "nw": (0, -1), "n": (-1, -1)]

    /// Teleport, Displacement, raising, phantoms (area_spells_spec 5.2, 6.1, 6.2).
    func special(_ e: Battle.Event, spell: Int?, caster: Int?, at t: Date) {
        guard let b = battle else { return }
        switch e {
        case .teleported(let id, _, let to):
            // fade out 15 x 75 ms, the instant move, fade in (t_teleport_spell 0x87e840)
            if let s = spell { playSpellSound(s) }
            fade(id, from: 15, to: 0, at: t, then: { [weak self] t2 in
                guard let self = self else { return }
                self.shownPos[id] = (Float(to.0), Float(to.1))
                self.fade(id, from: 0, to: 15, at: t2)
            })
        case .displaced(let id, let from, let to):
            // the displacement sprite on the side the push comes from (cast_spell, 1000 / fps), the
            // slide from its hit frame (t_spell_displacement 0x8604e0)
            playSpellSound(spell ?? 28)
            let v = b.unit(id)
            let dir = Battle.facing(dx: Float(to.0 - from.0), dy: Float(to.1 - from.1))
            let back = AdvActor.facings[((AdvActor.facings.firstIndex(of: dir) ?? 0) + 4) & 7]
            let dv = CombatScreen.directions[back] ?? (0, 0)
            let c = (from.0 * 16 + v.size * 8 + dv.0 * v.size * 8, from.1 * 16 + v.size * 8 + dv.1 * v.size * 8)
            fieldActor("spells.displacement", states: ["cast_spell"], at: (Float(c.0), Float(c.1), 0), facing: dir, t: t, unscaled: true,
                       hit: { [weak self] th in self?.slide(id, from: (Float(from.0), Float(from.1)), to: (Float(to.0), Float(to.1)), at: th) })
        case .revived(let id, let sp, let count, let rose):
            // the effect, the rise (the die animation backwards) at the same time, "+N"
            showEffect(CombatScreen.effectKeyword(sp), on: id, at: t, sound: sp)
            if rose { dead.insert(id); play(id, "die", at: t, reverse: true) }
            if let s = shownCount[id] { shownCount[id] = s + count }
            if showOtherNumbers { floatOver(b.unit(id), [("+\(count)", nil)], since: t) }
        case .phantom(let id, let of):
            // the copy at alpha 10 / 15, sliding from the original to its own place (0x87d050)
            hidden.remove(id)
            alphaLevel[id] = 10
            if let s = spell { playSpellSound(s) }
            let o = b.unit(of), c = b.unit(id)
            c.facing = o.facing
            let op = unitPos[of] ?? shownPos[of] ?? (Float(o.x), Float(o.y))
            slide(id, from: op, to: (Float(c.x), Float(c.y)), at: t)
        default: break
        }
    }
}

extension CombatScreen {
    struct MoveAnim { let path: [(Int, Int)]; let start: (Int, Int); let flying: Bool; let since: Date; let move: Move }
}
