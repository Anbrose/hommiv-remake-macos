import Foundation
import H4Engine

/// How the combat screen plays what the battle resolved (spell_visuals_spec, missiles_spec,
/// area_spells_spec). Several animations run at once; each one that the original counts in the
/// battlefield's pending-animation counter (+0x48c: t_play_combat_animation, the spell effect
/// windows, missiles, faders, explosions) holds the next action, which starts only when every one
/// of them has ended (0x56b310).
extension CombatScreen {
    // MARK: the clock

    /// Run `fn` at time `t`. A holding timer keeps the next action waiting until it has run.
    func after(_ t: Date, hold: Bool = true, _ fn: @escaping (Date) -> Void) {
        timerSeq += 1
        timers.append(Timer(at: t, seq: timerSeq, hold: hold, fn: fn))
    }
    /// What holds the next action: timers that hold, missiles in flight, reactions and effect
    /// windows waiting for their unit.
    var holds: Int {
        timers.reduce(0) { $0 + ($1.hold ? 1 : 0) } + missiles.count
            + waitingOnUnit.values.reduce(0) { $0 + $1.count } + windowWaiting.values.reduce(0) { $0 + $1.count }
    }
    /// Run every timer and missile step that is due, in time order (each at its own time, so a chain
    /// of animations keeps the exe's timing whatever the frame rate).
    func advance(to now: Date) {
        while true {
            var best: (at: Date, timer: Int?, missile: Int?)? = nil
            for (k, t) in timers.enumerated() where t.at <= now {
                if best == nil || t.at < best!.at || (t.at == best!.at && best!.timer.map { t.seq < timers[$0].seq } ?? false) { best = (t.at, k, nil) }
            }
            for (k, m) in missiles.enumerated() where m.nextTick <= now {
                if best == nil || m.nextTick < best!.at { best = (m.nextTick, nil, k) }
            }
            guard let b = best else { return }
            if let k = b.timer {
                let t = timers.remove(at: k)
                t.fn(t.at)
            } else if let k = b.missile {
                stepMissile(k)
            }
        }
    }

    // MARK: unit animations

    /// A stack that is playing something other than its idle loops (wait, fidget) or moving.
    func busy(_ id: Int) -> Bool {
        if moving[id] != nil { return true }
        guard let s = unitState[id] else { return false }
        return s.state != "wait" && s.state != "fidget"
    }
    /// Frames of an actor's state for a facing (0 when it has none).
    func frameCount(_ actorName: String, _ state: String, _ facing: String) -> Int {
        let key = "\(actorName)|\(state)|\(facing)"
        if let n = frameCounts[key] { return n }
        var n = 0
        if let a = actor(actorName), let entry = a.sequenceEntry(state: state, facing: facing), let data = payload(entry), let s = try? Sprite(data: data) {
            n = s.timeline.isEmpty ? (s.frames.isEmpty ? 0 : 1) : s.timeline.count
        }
        frameCounts[key] = n
        return n
    }
    /// When a state reaches its hit frame (0x7dd10d): on the tick showing frame f >= hitFrame, or the
    /// last frame if that comes first; frame 0 shows at the start, so a hit frame of 0 fires on frame 1.
    func hitTime(_ actorName: String, _ state: String, _ facing: String) -> Double {
        let n = frameCount(actorName, state, facing)
        let hit = actor(actorName)?.state(state)?.hitFrame ?? 0
        return Double(max(1, min(hit, n - 1))) * framePeriod(actorName, state)
    }

    /// Play a one-off state on a stack (t_play_combat_animation 0x7dcc40, counted): its sound with
    /// it, `hit` on its hit frame, `then` when the last frame has shown; the stack goes back to its
    /// idle loop afterwards (or lies dead after `die`). Returns how long it runs.
    @discardableResult
    func play(_ id: Int, _ state: String, at t: Date, reverse: Bool = false, sound playSound: Bool = true,
              hit: ((Date) -> Void)? = nil, then: ((Date) -> Void)? = nil) -> Double {
        guard let b = battle else { return 0 }
        let u = b.unit(id)
        // a fidget cut short by this: the idle timer goes on (0x563870)
        if fidgeting == id { fidgeting = nil; nextFidget = t.addingTimeInterval(1 + Double(idleRandom.next() % 2001) / 1000) }
        stateToken += 1
        let token = stateToken
        unitState[id] = UnitAnim(state: state, since: t, once: true, reverse: reverse, token: token)
        if playSound { sound?.actor(u.actor, state) }
        let n = frameCount(u.actor, state, u.facing)
        let d = Double(n) * framePeriod(u.actor, state)
        if let h = hit {
            let period = framePeriod(u.actor, state)
            after(t.addingTimeInterval(n == 0 ? 0 : hitTime(u.actor, state, u.facing))) { [weak self] th in
                guard let self = self, let p = self.pendingHits[id], p.token == token else { return }
                self.pendingHits[id] = nil
                h(th)
            }
            pendingHits[id] = (token, timerSeq, t, period, h)
        }
        after(t.addingTimeInterval(d)) { [weak self] t2 in
            guard let self = self else { return }
            if self.swingEnds[id]?.token == token { self.swingEnds[id] = nil }
            if self.unitState[id]?.token == token {
                self.unitState[id] = nil
                if state == "die", !reverse { self.dying.remove(id); self.dead.insert(id); self.fallen(id, at: t2) }
                if state == "die", reverse { self.dead.remove(id); self.dying.remove(id) }
            }
            then?(t2)
            self.unitIdle(id, at: t2)
        }
        if hit != nil { swingEnds[id] = (token, timerSeq) }
        return d
    }
    /// A stack starts dying in the middle of its own swing (0x7dcd16 effect 0xba -> 0x7dcf60): the swing
    /// stops at once, without its hit if that has not come, and no longer holds.
    func cutSwing(_ id: Int, at t: Date) {
        if let e = swingEnds.removeValue(forKey: id), unitState[id]?.token == e.token {
            timers.removeAll { $0.seq == e.seq }
            unitState[id] = nil
        }
        // the cut swing's blow does not land (0x7dd1b5 calls only the end handler); the battle has
        // already made it a blow of nothing (Battle.together)
        if let p = pendingHits.removeValue(forKey: id) { timers.removeAll { $0.seq == p.seq } }
    }
    /// A stack's animation ended: what waited for it runs now (t_delayed_missile_impact,
    /// t_delayed_spell_animation).
    func unitIdle(_ id: Int, at t: Date) {
        guard !busy(id), let list = waitingOnUnit[id], !list.isEmpty else { return }
        waitingOnUnit[id] = nil
        for fn in list { fn(t) }
    }
    /// Run `fn` once the stack lies dead on screen: now, or when the fall pending or playing has ended.
    func afterFall(_ id: Int, at t: Date, _ fn: @escaping (Date) -> Void) {
        if dying.contains(id) || pendingDeaths.contains(id) { waitingDeath[id, default: []].append(fn) } else { fn(t) }
    }
    func fallen(_ id: Int, at t: Date) {
        guard let list = waitingDeath.removeValue(forKey: id) else { return }
        for fn in list { fn(t) }
    }
    /// Run `fn` now, or when the stack's running animation has ended.
    func whenIdle(_ id: Int, at t: Date, _ fn: @escaping (Date) -> Void) {
        if busy(id) { waitingOnUnit[id, default: []].append(fn) } else { fn(t) }
    }

    // MARK: reactions

    /// One stack struck: what it has left, the damage numbers, and its flinch or its fall
    /// (0x56a710 / 0x5f3c50).
    struct Strike {
        var attacker: Int?, target: Int, damage: Int, killed: Int, left: Int
        var dies = false
        /// The blow was blocked (0x5f62e0 -> state 0); `blockMessage`: the panel says Block (only the missile
        /// reaction posts combat_action.block, 0x56a92a).
        var blocked = false, blockMessage = false
    }
    enum ReactionRule {
        /// A blow or a missile (0x56a710): survivors flinch.
        case blow
        /// A spell's damage (0x5f3c50): survivors flinch when some died.
        case spell
    }
    /// The struck stack reacts at `t`; a busy one (swinging, flinching) waits for its animation to end
    /// when `deferBusy` (missile impacts), otherwise only its flinch is skipped.
    func react(_ s: Strike, at t: Date, rule: ReactionRule, deferBusy: Bool) {
        guard let b = battle else { return }
        if deferBusy, busy(s.target) {
            waitingOnUnit[s.target, default: []].append { [weak self] t2 in self?.react(s, at: t2, rule: rule, deferBusy: true) }
            return
        }
        let u = b.unit(s.target)
        shownCount[s.target] = s.left
        if s.damage > 0 || s.killed > 0 { blowMessages(damage: s.damage, killed: s.killed, unit: u, since: t) }
        if s.blocked {
            // block (0x5f6480): turned toward the striker, the Block window (0xbd, animation.spell.block with
            // sound.spell.block) and the block state with its sound; a stack with no block sequence flinches
            if s.blockMessage { postAction(s.target, "combat_action.block", "Block", now: t) }
            if let a = s.attacker, let bb = battle { let ac = shownCentre(bb.unit(a)), tc = shownCentre(u); if ac != tc { u.facing = Battle.facing(dx: ac.0 - tc.0, dy: ac.1 - tc.1) } }
            if actor(u.actor)?.sequenceEntry(state: "block", facing: u.facing) != nil {
                showEffect("block", on: s.target, at: t, sound: 189)
                play(s.target, "block", at: t)
            } else if !busy(s.target) { play(s.target, "flinch", at: t) }
            return
        }
        if s.dies {
            let fall: (Date) -> Void = { [weak self] t2 in
                guard let self = self else { return }
                self.pendingDeaths.remove(s.target); self.dying.insert(s.target)
                if let a = s.attacker, let bb = self.battle { let ac = self.shownCentre(bb.unit(a)), tc = self.shownCentre(u); if ac != tc { u.facing = Battle.facing(dx: ac.0 - tc.0, dy: ac.1 - tc.1) } }
                self.play(s.target, "die", at: t2)
            }
            whenIdle(s.target, at: t, fall)
        } else if s.left > 0, rule == .blow || s.killed > 0, !busy(s.target) {
            play(s.target, "flinch", at: t)
        }
    }

    // MARK: effect windows (animation.spell.<keyword>)

    /// Show an animation.spell effect on a stack (0x5754b0): one window at a time per stack (+0xbfc),
    /// a later one waits for it (t_delayed_spell_animation); `sound` (a spell id) plays as it starts.
    /// A missing file shows nothing, plays no sound and completes at once.
    func showEffect(_ name: String, on id: Int, at t: Date, sound spellId: Int? = nil,
                    start: ((Date) -> Void)? = nil, then: ((Date) -> Void)? = nil) {
        guard let info = effectInfo(name), let dur = Optional(effectDuration(info)) else { start?(t); then?(t); return }
        if windowBusy.contains(id) {
            windowWaiting[id, default: []].append { [weak self] t2 in self?.showEffect(name, on: id, at: t2, sound: spellId, start: start, then: then) }
            return
        }
        windowBusy.insert(id)
        windowSeq += 1
        let seq = windowSeq
        windows.append(EffectWindow(name: name, unit: id, since: t, seq: seq))
        if let s = spellId { playSpellSound(s) }
        start?(t)
        after(t.addingTimeInterval(dur)) { [weak self] t2 in
            guard let self = self else { return }
            self.windows.removeAll { $0.seq == seq }
            self.windowBusy.remove(id)
            then?(t2)
            if var w = self.windowWaiting[id], !w.isEmpty {
                let next = w.removeFirst()
                self.windowWaiting[id] = w.isEmpty ? nil : w
                next(t2)
            }
        }
    }
    /// The spell id whose keyword an effect name is (for its sound).
    static func spellId(_ keyword: String) -> Int? {
        let k = keyword.lowercased()
        return RuleTables.spells.firstIndex { $0.keyword == k }
    }
    /// The effect a spell shows (0x865580 remaps three ids): its keyword.
    static func effectKeyword(_ spell: Int) -> String {
        let id = [116: 53, 70: 48, 103: 148][spell] ?? spell
        return id < RuleTables.spells.count ? RuleTables.spells[id].keyword : ""
    }
    /// sound.spell.<keyword(id)>, or sound.spell.curse when the spell has none (cache 0x611400, entry 23).
    func playSpellSound(_ spell: Int) {
        let id = [116: 53, 70: 48, 103: 148][spell] ?? spell
        guard id < RuleTables.spells.count, let s = sound else { return }
        let name = "spell.\(RuleTables.spells[id].keyword)"
        _ = s.play(s.has(name) ? name : "spell.curse")
    }

    // MARK: faders, tints, slides

    /// Fade a stack's alpha level 0...15 one step every 75 ms, fixed (t_combat_object_fader 0x606740), counted.
    func fade(_ id: Int, from a: Int, to b: Int, at t: Date, then: ((Date) -> Void)? = nil) {
        fades[id] = Fade(from: a, to: b, since: t)
        let steps = abs(b - a)
        after(t.addingTimeInterval(Double(steps) * 0.075)) { [weak self] t2 in
            guard let self = self else { return }
            if let f = self.fades[id], f.since == t { self.fades[id] = nil; self.alphaLevel[id] = b == 15 ? nil : b }
            then?(t2)
        }
    }
    /// A stack's alpha level now (15 opaque).
    func alpha(_ id: Int, now: Date) -> Int {
        if let f = fades[id] {
            let k = min(abs(f.to - f.from), max(0, Int(now.timeIntervalSince(f.since) / 0.075)))
            return f.from + (f.to > f.from ? k : -k)
        }
        return alphaLevel[id] ?? 15
    }
    /// The icy ramp of a frozen stack (t_freeze_animation 0x8790a0): sound.spell.frozen, then every
    /// 10000 / speed ms the colour adjust (430, 256, 25k, min(500, 256 + 15k)) for k = 0...16, a hold
    /// of 40000 / speed ms; the tint stays while it is frozen.
    func freeze(_ id: Int, at t: Date) {
        _ = sound?.play("spell.frozen")
        tints[id] = Tint(kind: .freeze, since: t, survivors: true)
        let tick = Double(10000 / max(1, animationSpeed)) / 1000, hold = Double(40000 / max(1, animationSpeed)) / 1000
        after(t.addingTimeInterval(tick * 16 + hold)) { _ in }
    }
    /// Stone Gaze (t_stoning_animation 0x878d90): saturation 256 -> 0 in 16 steps of 10000 / speed ms,
    /// a hold of 40000 / speed ms, then back to colour for survivors (the dead stay grey until removed).
    func stone(_ id: Int, at t: Date, survivors: Bool) {
        tints[id] = Tint(kind: .stone, since: t, survivors: survivors)
        let tick = Double(10000 / max(1, animationSpeed)) / 1000, hold = Double(40000 / max(1, animationSpeed)) / 1000
        after(t.addingTimeInterval(tick * 16 + hold)) { [weak self] _ in
            guard let self = self else { return }
            if survivors { self.tints[id] = nil } else { self.tints[id] = nil }
        }
    }
    /// The colour adjust of a stack now (hue target, hue amount, saturation, value; neutral (0, 0, 256, 256)).
    func colourAdjust(_ id: Int, now: Date) -> SIMD4<Float>? {
        guard let tn = tints[id] else { return nil }
        let tick = Double(10000 / max(1, animationSpeed)) / 1000
        let k = min(16, max(0, Int(now.timeIntervalSince(tn.since) / tick)))
        switch tn.kind {
        case .freeze: return SIMD4(430, 256, Float(25 * k), Float(min(500, 256 + 15 * k)))
        case .stone: return SIMD4(0, 0, Float(256 - 16 * k), 256)
        }
    }
    /// Slide a stack in a straight line, in its current pose, 15 steps of 100 ms (t_translation_animation 0x8c6cb0).
    func slide(_ id: Int, from a: (Float, Float), to b: (Float, Float), at t: Date, then: ((Date) -> Void)? = nil) {
        slides[id] = Slide(from: a, to: b, since: t)
        unitPos[id] = a
        after(t.addingTimeInterval(1.5)) { [weak self] t2 in
            guard let self = self else { return }
            self.slides[id] = nil; self.unitPos[id] = nil; self.shownPos[id] = b
            then?(t2)
        }
    }

    // MARK: battlefield actors (explosions, clouds, puffs, flames)

    /// A combat actor placed on the field for a spell or an impact: its states played in turn, each
    /// frame for `period(state)` s, then removed (or kept on its last frame).
    @discardableResult
    func fieldActor(_ model: String, states: [String], at p: (x: Float, y: Float, z: Float), facing: String = "ne",
                    t: Date, unscaled: Bool = false, holdLast: Bool = false, ground: Bool = false, hit: ((Date) -> Void)? = nil, then: ((Date) -> Void)? = nil) -> Double {
        guard let a = actor(model) else { hit?(t); then?(t); return 0 }
        var parts: [(state: String, frames: Int, period: Double)] = []
        for s in states {
            let n = frameCount(model, s, facing)
            guard n > 0 else { continue }
            let fps = max(1, a.state(s)?.speed ?? 10)
            // t_spell_actor_animation runs at 1000 / fps, unscaled; t_cloud_animation and the boulder
            // puff at 100000 / (fps x animation speed)
            parts.append((s, n, unscaled ? 1.0 / Double(fps) : framePeriod(model, s)))
        }
        let total = parts.reduce(0) { $0 + Double($1.frames) * $1.period }
        fieldSeq += 1
        let seq = fieldSeq
        fieldActors.append(FieldActor(model: model, parts: parts, world: p, facing: facing, since: t, holdLast: holdLast, seq: seq, ground: ground))
        if let h = hit, let first = parts.first {
            let hf = a.state(first.state)?.hitFrame ?? 0
            after(t.addingTimeInterval(Double(min(hf, first.frames - 1)) * first.period), h)
        }
        after(t.addingTimeInterval(total)) { [weak self] t2 in
            guard let self = self else { return }
            if !holdLast { self.fieldActors.removeAll { $0.seq == seq } }
            then?(t2)
        }
        return total
    }

    // MARK: world geometry (world units, 16 a cell)

    /// A stack's top corner as shown, in world units.
    func worldPos(_ u: Battle.Unit) -> (Int, Int) {
        let p = unitPos[u.id] ?? shownPos[u.id] ?? (Float(u.x), Float(u.y))
        return (Int((p.0 * 16).rounded()), Int((p.1 * 16).rounded()))
    }
    /// The footprint centre raised by half the actor's height: where missiles aim (0x568cc0).
    func aimPoint(_ u: Battle.Unit) -> (Int, Int, Int) {
        let p = worldPos(u)
        return (p.0 + u.size * 8, p.1 + u.size * 8, (actor(u.actor)?.height ?? 0) / 2)
    }
    /// Where a stack's missile leaves (0x5d5b50): its position plus the launch offset of its facing.
    func launchPoint(_ u: Battle.Unit) -> (Int, Int, Int) {
        let p = worldPos(u)
        let o: (x: Int, y: Int, z: Int) = actor(u.actor)?.launchOffset(u.facing) ?? (u.size * 8, u.size * 8, 40)
        return (p.0 + o.x, p.1 + o.y, o.z)
    }
    /// Face a stack toward a world point (0x5748c0 / 0x51ee00); no change for its own centre.
    func face(_ u: Battle.Unit, toward p: (Int, Int)) {
        let c = worldPos(u)
        let dx = Float(p.0 - (c.0 + u.size * 8)), dy = Float(p.1 - (c.1 + u.size * 8))
        if dx != 0 || dy != 0 { u.facing = Battle.facing(dx: dx, dy: dy) }
    }

    // MARK: missiles (t_move_missile 0x7a37f0)

    /// The missile of a shooter (0x5efa50 / 0x656fc0; heroes 0x72e220: the mage model shoots
    /// "magic", the others arrows); nil when it has none (a medusa's gaze lands at once).
    static let creatureMissiles: [String: Int] = [
        "ballista": 8, "beholder": 3, "centaur": 18, "crossbowman": 1, "elf": 1, "cyclops": 4, "gargantuan": 4,
        "venom spawn": 19, "fire elemental": 7, "halfling": 16, "mage": 12, "monk": 12, "evil sorceress": 12,
        "orc": 2, "titan": 11, "waspwort": 20, "catapult": 21]
    /// Missile type ids (table 0xa73cb8): combat_actor.missile.<keyword>; 21 is the catapult's arced fireball.
    static let missileKeywords = ["armageddon", "arrow", "axe", "beam", "boulder", "chain_lightning", "fireball", "fire_bolt",
                                  "heavy_bolt", "ice_bolt", "life_force", "lightning", "magic", "magic_arrow", "magic_fist",
                                  "mana", "pebble", "potion", "spear", "spittle", "thorn", "fireball"]
    /// Arced missiles (0x7a2760).
    static let arcedMissiles: Set<Int> = [1, 2, 4, 8, 16, 17, 18, 19, 20, 21]
    func missileType(_ u: Battle.Unit) -> Int? {
        if u.stats.isHero { return u.actor.contains("_mage_") ? 12 : 1 }
        return CombatScreen.creatureMissiles[u.keyword.lowercased()]
    }

    /// Launch a missile (0x56a190) from `from` to `to` (world units); the impact runs one tick after it
    /// arrives. A missing model lands at once.
    func launch(_ type: Int, from: (Int, Int, Int), to: (Int, Int, Int), at t: Date, impact: @escaping (Date) -> Void) {
        let model = "missile.\(CombatScreen.missileKeywords[type])"
        guard type >= 0, type < CombatScreen.missileKeywords.count, let a = actor(model) else { impact(t); return }
        let ms = a.footprint
        let pos = (from.0 - ms * 8, from.1 - ms * 8, from.2)
        let d = (to.0 - from.0, to.1 - from.1, to.2 - from.2)
        let dist = Int((Double(d.0 * d.0 + d.1 * d.1)).squareRoot())
        let step = max(1, a.walkDistance)
        let n = (dist + step - 1) / step
        let arc = CombatScreen.arcedMissiles.contains(type)
        let interval = Double(max(20, 5000 / max(1, animationSpeed))) / 1000
        let facing = (d.0 != 0 || d.1 != 0) ? Battle.facing(dx: Float(d.0), dy: Float(d.1)) : "ne"
        let fps = max(1, a.state("walk")?.speed ?? 10)
        missiles.append(Missile(model: model, size: ms, pos: pos, delta: d, dist: dist, remaining: dist, acc: (0, 0, 0),
                                arc: arc, vz: arc ? 2 * n : 0, step: step, facing: facing, frame: 0,
                                frames: max(1, frameCount(model, "walk", facing)), lastFrame: t, framePeriod: 1.0 / Double(fps),
                                interval: interval, nextTick: t.addingTimeInterval(interval), impact: impact))
    }
    /// One tick of a missile (0x7a3b00): its sprite frame on its own clock (1000 / fps ms, checked on
    /// ticks), then 64 world units along the line (Bresenham per axis), the arc's rise and fall; the
    /// impact on the tick after it arrives.
    func stepMissile(_ k: Int) {
        var m = missiles[k]
        let now = m.nextTick
        if now.timeIntervalSince(m.lastFrame) >= m.framePeriod - 1e-9 { m.frame = (m.frame + 1) % m.frames; m.lastFrame = now }
        if m.remaining <= 0 {
            missiles.remove(at: k)
            m.impact(now)
            return
        }
        let s = min(m.step, m.remaining)
        m.remaining -= s
        if m.dist > 0 {
            m.acc = (m.acc.0 + m.delta.0 * s, m.acc.1 + m.delta.1 * s, m.acc.2 + m.delta.2 * s)
            let q = (m.acc.0 / m.dist, m.acc.1 / m.dist, m.acc.2 / m.dist)
            m.pos = (m.pos.0 + q.0, m.pos.1 + q.1, m.pos.2 + q.2)
            m.acc = (m.acc.0 - q.0 * m.dist, m.acc.1 - q.1 * m.dist, m.acc.2 - q.2 * m.dist)
        }
        if m.arc { m.pos.2 += m.vz - 2; m.vz -= 4 }
        m.nextTick = now.addingTimeInterval(m.interval)
        missiles[k] = m
    }
}

extension CombatScreen {
    struct Timer { let at: Date; let seq: Int; let hold: Bool; let fn: (Date) -> Void }
    struct UnitAnim { var state: String; var since: Date; var once: Bool; var reverse = false; var token = 0 }
    struct EffectWindow { let name: String; let unit: Int; let since: Date; let seq: Int }
    struct Fade { let from: Int, to: Int; let since: Date }
    struct Tint { enum Kind { case freeze, stone }; let kind: Kind; let since: Date; let survivors: Bool }
    struct Slide { let from: (Float, Float), to: (Float, Float); let since: Date }
    struct FieldActor {
        let model: String
        let parts: [(state: String, frames: Int, period: Double)]
        let world: (x: Float, y: Float, z: Float)   // world units: the point its origin is drawn on
        let facing: String
        let since: Date
        let holdLast: Bool
        let seq: Int
        /// Drawn on the ground, under every stack (quicksand).
        var ground = false
        /// The state and frame shown at a time.
        func frame(at now: Date) -> (String, Int)? {
            var e = now.timeIntervalSince(since)
            for p in parts {
                let d = Double(p.frames) * p.period
                if e < d { return (p.state, min(p.frames - 1, Int(e / p.period))) }
                e -= d
            }
            return parts.last.map { ($0.state, $0.frames - 1) }
        }
    }
    struct Missile {
        let model: String
        let size: Int
        var pos: (Int, Int, Int)       // the missile actor's top corner, world units (z up)
        let delta: (Int, Int, Int)
        let dist: Int
        var remaining: Int
        var acc: (Int, Int, Int)
        let arc: Bool
        var vz: Int
        let step: Int
        let facing: String
        var frame: Int
        let frames: Int
        var lastFrame: Date
        let framePeriod: Double
        let interval: Double
        var nextTick: Date
        let impact: (Date) -> Void
    }
}
