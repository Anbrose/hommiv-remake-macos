import Foundation

/// How an army model walks (heroes4.exe adv_actor header, reader 0x42cfc0): the distances its
/// prewalk, one walk loop and its postwalk cover, in the walk's units (a straight step 32, a
/// diagonal 48), the frames of those sequences and the states' speed bytes (frame time
/// 1000 / speed ms at 100 %, 0x41aac0). re/adventure_walk_spec.md §2.
public struct ArmyGait {
    public var pre = 8, loop = 32, post = 8
    /// Frames of the state's sequence (actor +0x60), by state name.
    public var frames: [String: Int] = ["prewalk": 2, "walk": 6, "postwalk": 2]
    /// The state's speed byte (actor +0x5c = 1000 / speed), by state name.
    public var speed: [String: Int] = [:]
    public init() {}
    public init(pre: Int, loop: Int, post: Int, frames: [String: Int], speed: [String: Int]) {
        self.pre = pre; self.loop = max(1, loop); self.post = post; self.frames = frames; self.speed = speed
    }
    func frameCount(_ state: String) -> Int { max(1, frames[state] ?? 1) }
    /// One frame's time in ms at `percent` (0x544b18: 100 x (1000 / speed) / percent).
    func frameMs(_ state: String, percent: Int) -> Double {
        Double(100 * (1000 / max(1, speed[state] ?? 10))) / Double(max(1, percent))
    }
}

/// The animation of an army walking its walk list (heroes4.exe t_army_mover, 0x544630 /
/// 0x544720 / 0x545560; re/adventure_walk_spec.md §3-4): a prewalk, walk loops stretched to fit
/// the route, a postwalk; the picture moves on the animation's frame ticks only, at a constant
/// speed within each segment, so a diagonal step (48) takes 1.5 times a straight one (32).
public struct ArmyWalk {
    /// The walk's steps: 32 straight, 48 diagonal.
    public private(set) var steps: [Int]
    /// The step being walked (0-based) and its distance not yet walked.
    public private(set) var step = 0
    private(set) var rest: Double
    public private(set) var state = "prewalk"
    /// The frame counter (the actor's frame; prewalk and postwalk hold their last frame).
    private(set) var counter = 0
    private var partFrames = 0, partDone = 0
    private var perFrame = 0.0
    private var clock = 0.0
    public private(set) var done = false

    public init(steps: [Int], gait: ArmyGait) {
        self.steps = steps
        rest = Double(steps.first ?? 0)
        if steps.isEmpty { done = true } else { fit(gait) }
    }
    /// A step from (x0, y0) to (x1, y1): 48 across a corner, else 32 (0x544630, node +4 bit 1).
    public static func distance(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int { x0 != x1 && y0 != y1 ? 48 : 32 }

    /// The frame shown: the counter, the last one once a prewalk or postwalk has played out.
    public func frame(_ gait: ArmyGait) -> Int { min(counter, gait.frameCount(state) - 1) }
    /// How far the current step is walked, 0...1.
    public var stepProgress: Float {
        guard step < steps.count, steps[step] > 0 else { return 1 }
        return Float(1 - rest / Double(steps[step]))
    }

    /// 0x544720: fit the animation to the distance left, from the actor's current frame.
    private mutating func fit(_ g: ArmyGait) {
        let n = g.frameCount(state), a = counter
        let restInt = Int(rest.rounded())
        let d = restInt + steps[(step + 1)...].reduce(0, +)
        var segFrames: Int, segPath: Int
        if state == "postwalk" {   // 0x5448ef
            segFrames = n - a; segPath = restInt
        } else {
            let preRem = state == "prewalk" && a < n ? (n - a) * g.pre / n : 0
            var e = d - g.post - preRem
            if state == "walk" { e += g.loop * a / n }
            var l = max(0, e / g.loop)
            if 2 * (preRem + g.post) < e - l * g.loop { l += 1 }
            if state == "walk", a != 0, l == 0 { l = 1 }
            var whole = l * g.loop + g.post + preRem
            if state == "walk", a != 0 { whole -= g.loop * a / n }
            whole = max(1, whole)
            if state == "prewalk", a < n {
                segFrames = n - a; segPath = preRem * d / whole
            } else if l > 0 {
                var walked = l * g.loop
                if state == "walk" { walked -= g.loop * a / n; segFrames = l * n - a }
                else { state = "walk"; counter = 0; segFrames = l * g.frameCount("walk") }
                segPath = walked * d / whole
            } else {
                state = "postwalk"; counter = 0
                segFrames = g.frameCount("postwalk"); segPath = restInt
            }
        }
        segFrames = max(1, segFrames); segPath = max(0, segPath)
        // 0x544a7b: this step's share of the segment
        var dist = restInt, frames = segFrames
        if segPath < restInt { if segPath > 0 { dist = segPath } }
        else if segPath > restInt, restInt > 0 { frames = (restInt * segFrames + segPath - 1) / segPath }
        partFrames = max(1, frames); partDone = 0
        perFrame = Double(dist) / Double(partFrames)
    }

    /// Advance by dt seconds at the army's speed percent. Returns the steps finished meanwhile
    /// (their count); `done` once the postwalk has played out at the end of the walk.
    public mutating func advance(_ dt: Float, gait g: ArmyGait, percent: Int) -> Int {
        guard !done else { return 0 }
        clock += Double(dt) * 1000
        var finished = 0
        while !done {
            let ms = g.frameMs(state, percent: percent)
            guard clock >= ms else { break }
            clock -= ms
            finished += tick(g)
        }
        return finished
    }

    /// One frame (0x545560's loop body).
    private mutating func tick(_ g: ArmyGait) -> Int {
        rest = max(0, rest - perFrame)
        partDone += 1
        counter += 1
        if state == "walk", counter == g.frameCount("walk") { counter = 0 }
        guard partDone >= partFrames else { return 0 }
        rest = rest.rounded()
        var finished = 0
        if rest <= 0 {
            finished = 1
            if step + 1 < steps.count { step += 1; rest = Double(steps[step]) }
            else { done = true; return finished }   // nothing left (the postwalk ends every fitted walk)
        }
        fit(g)
        return finished
    }

    /// Stop at the end of the current step (a click while walking): the rest of the walk list
    /// is dropped and the animation fitted to what is left of this step.
    public mutating func stopAfterCurrentStep(_ g: ArmyGait) {
        guard !done else { return }
        steps = Array(steps[...step])
        fit(g)
    }
}
