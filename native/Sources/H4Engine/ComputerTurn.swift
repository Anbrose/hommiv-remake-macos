import Foundation

/// The computer players' turns between the human's End Turn and the new day (heroes4.exe
/// t_adventure_ai::do_turn 0x47b720 per player; re/ai_turn_display_spec.md). The work is a queue of
/// steps run in order: the players one after another, each player's armies one after another, each
/// army's walk to its target and the use of it. On the screen (`animated`) an army's walk plays on
/// the map with the walk animation while the player sees it (t_ai_army_mover over t_army_mover:
/// 0x5444b3 / 0x544c93 / 0x545090) and the turn waits for it, and for a battle it opened with one of
/// the player's armies; otherwise (tests, Auto Play) everything runs at once.
public final class ComputerTurn {
    public let animated: Bool
    /// What is left to do, the next first. Each step is run bare; what plays a computer player's
    /// part runs inside GameState.playing.
    var tasks: [() -> Void] = []
    /// The army walk under way (animated turns only).
    public internal(set) var walk: AIWalk?
    /// The player whose turn it is, and its progress bar (t_ai_progress_bar 0x479c10: its armies
    /// moved of their count + 1, 0x47be32 / 0x47baeb).
    public internal(set) var colour: Int?
    public internal(set) var moved = 0, armies = 1
    init(animated: Bool) { self.animated = animated }
    /// Run these next, in this order, before what is already queued.
    func next(_ t: [() -> Void]) { tasks.insert(contentsOf: t, at: 0) }
}

/// A computer army's walk along its walk list (t_ai_army_mover). The steps are applied one by one
/// as the original loop does them (`step` returns false to stop the walk there); shown, they are
/// applied as the animation finishes them.
public final class AIWalk {
    public let hero: Hero
    let colour: Int?
    let z: Int
    /// The cells still to walk, the next first.
    var cells: [(x: Int, y: Int)]
    let step: ((x: Int, y: Int)) -> Bool
    let finish: () -> Void
    /// The player sees the walk (mover +0x5f); hidden steps are taken at once (0x545090).
    public internal(set) var shown = false
    var anim: ArmyWalk?
    init(hero: Hero, colour: Int?, z: Int, cells: [(x: Int, y: Int)], step: @escaping ((x: Int, y: Int)) -> Bool, finish: @escaping () -> Void) {
        self.hero = hero; self.colour = colour; self.z = z; self.cells = cells; self.step = step; self.finish = finish
    }
}

extension GameState {
    /// End the human's turn at once: the computer players' turns, then the new day.
    public func endTurn() {
        guard computerTurn == nil else { return }
        beginEndTurn(animated: false)
    }

    /// End the human's turn on the screen: the computer players' turns play out (GameState.update
    /// advances them), then the new day starts. Nothing happens while a turn is already under way.
    public func beginEndTurn(animated: Bool = true) {
        guard computerTurn == nil else { return }
        let t = ComputerTurn(animated: animated)
        computerTurn = t
        // the computer players move before the new day
        t.tasks = aiPlayers.map { c in { [unowned self] in self.aiTurn(c) } }
            + [{ [unowned self] in self.computerTurn = nil; self.newDay() }]
        runComputerTurn()
    }

    /// The new day after the computer players' turns.
    func newDay() {
        defer { runDayEvents(); checkScenario(newDay: true) }
        day += 1
        for h in heroes { h.maxMovement = armyMovement(h); h.movement = h.maxMovement; h.path = []; h.plan = [] }
        for (res, amount) in income { resources[res, default: 0] += amount }
        aiNewDay()       // the computer players' income and its difficulty handicap (0x4d8910)
        monthsNewDay()   // 0x4d8910: the month changes before the objects' day
        objectsNewDay()
        sanctuariesNewDay()
        dwellingsNewDay()
        townsNewDay()    // town dwellings grow a seventh of their week every day (0x899960)
        for i in towns.indices { towns[i].builtToday = false; if towns[i].tavernDays > 0 { towns[i].tavernDays -= 1 } }
        caravanArrivals(for: map.humanColour)   // the human's turn starts (0x4b3710 -> 0x4b1010)
    }

    /// Run the queued steps until a walk is shown, something waits for the player (a battle the
    /// computer started, its results, a level up) or the game is over, or nothing is left.
    func runComputerTurn() {
        guard let t = computerTurn else { return }
        while t.walk == nil, !t.tasks.isEmpty {
            if t.animated && (adventureBusy || outcome != nil) { return }
            t.tasks.removeFirst()()
        }
    }

    /// A frame of the computer players' turns (GameState.update while one is under way).
    func advanceComputerTurn(_ t: ComputerTurn, dt: Float) {
        if !adventureBusy { for h in enemyHeroes + heroes where !h.isWalking && h.animState == "attack" { h.animState = nil } }   // the attack pose ends with the battle
        if let w = t.walk { advance(w, dt: dt) }
        if t.walk == nil { runComputerTurn() }
    }

    /// Play a computer player's part: its treasury and quick combat (acting), on the army's level.
    func playing(_ colour: Int?, on z: Int? = nil, _ body: () -> Void) {
        let back = level
        if let z = z, level != z { level = z }
        if let c = colour { acting(as: c) { body() } } else { body() }
        if level != back { level = back }
    }

    /// Is this army still on the map (not beaten in a battle meanwhile)?
    func onMap(_ h: Hero) -> Bool { enemyHeroes.contains { $0 === h } || heroes.contains { $0 === h } }

    /// The player sees a computer army walk: Show Enemy Moves and the army visible to him
    /// (0x544c93 / 0x5444b3 -> 0x4fae90 = its vtable +0x60, 0x526110).
    func seesComputerMove(_ h: Hero) -> Bool {
        heroes.contains { $0 === h } || (GameState.showEnemyMoves && isVisible(h))
    }

    /// Walk a computer army along `cells`: `step` takes one step (false: the walk stops there),
    /// `finish` runs after the last. At once unless the turn is shown and the player sees the army.
    func walkAI(_ h: Hero, colour: Int?, z: Int, cells: [(x: Int, y: Int)], step: @escaping ((x: Int, y: Int)) -> Bool, finish: @escaping () -> Void) {
        guard let t = computerTurn else { return }
        guard t.animated, !cells.isEmpty else {
            t.next([{ [unowned self] in self.playing(colour, on: z) { for c in cells where !step(c) { break } } }, finish])
            return
        }
        let w = AIWalk(hero: h, colour: colour, z: z, cells: cells, step: step, finish: finish)
        t.walk = w
        if seesComputerMove(h) { show(w, walking: false) } else { hiddenSteps(w) }
    }

    /// The hidden walk (0x545090): step after step at once, until the player sees the army (the
    /// rest is shown from its walk loop) or the walk is over.
    private func hiddenSteps(_ w: AIWalk) {
        while let c = w.cells.first {
            w.cells.removeFirst()
            if !take(w, c) { w.cells = []; break }
            if !w.cells.isEmpty, seesComputerMove(w.hero) { show(w, walking: true); return }
        }
        end(w)
    }

    /// Take one step of the walk as its player.
    private func take(_ w: AIWalk, _ c: (x: Int, y: Int)) -> Bool {
        var ok = false
        playing(w.colour, on: w.z) { ok = w.step(c) }
        return ok
    }

    /// The walk comes into the player's sight: the animation over the cells left, from its
    /// prewalk at the start, else from its walk loop (0x545475).
    private func show(_ w: AIWalk, walking: Bool) {
        let h = w.hero
        var steps: [Int] = [], px = h.x, py = h.y
        for c in w.cells { steps.append(ArmyWalk.distance(px, py, c.x, c.y)); px = c.x; py = c.y }
        w.anim = ArmyWalk(steps: steps, gait: gait(h.model), walking: walking)
        w.shown = true
        h.path = w.cells; h.progress = 0
        h.animState = w.anim?.state; h.animFrame = 0
        if let n = w.cells.first { h.facing = Hero.facing(dx: n.x - h.x, dy: n.y - h.y) }
    }

    /// One frame of a computer army's walk.
    private func advance(_ w: AIWalk, dt: Float) {
        let h = w.hero
        if !w.shown { hiddenSteps(w); return }
        guard var a = w.anim else { end(w); return }
        let g = gait(h.model)
        let percent = heroes.contains { $0 === h } ? GameState.armySpeedPercent : GameState.otherArmySpeedPercent
        var finished = a.advance(dt, gait: g, percent: percent)
        w.anim = a
        h.animState = a.state; h.animFrame = a.frame(g)
        h.progress = finished > 0 ? 0 : a.stepProgress
        while finished > 0, let c = w.cells.first {
            finished -= 1
            w.cells.removeFirst()
            if !take(w, c) { w.cells = []; break }
            // each new step: still in the player's sight? (0x5446ba) -- else the rest at once
            if !w.cells.isEmpty, !seesComputerMove(h) { w.shown = false; w.anim = nil; h.path = w.cells; h.progress = 0; h.animState = nil; return }
            if let n = w.cells.first { h.facing = Hero.facing(dx: n.x - h.x, dy: n.y - h.y) }
        }
        h.path = w.cells
        if w.cells.isEmpty || a.done { end(w); return }
        h.progress = a.stepProgress
    }

    /// The walk is over (0x5469d0): the army stands; what follows it runs next.
    private func end(_ w: AIWalk) {
        let h = w.hero
        h.path = []; h.walkAnim = nil; h.progress = 0
        if h.animState != "attack" { h.animState = nil }
        h.animFrame = 0
        computerTurn?.walk = nil
        computerTurn?.next([w.finish])
    }
}
