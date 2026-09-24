import Foundation

/// An adventure-map actor definition (adv_actor.<creature>.h4d, adv_actor.hero.<class>.h4d):
/// a table of states ("wait", "fidget", "prewalk", "walk", "postwalk", "attack"), each naming
/// the actor_sequence to play for the eight facings ne, e, se, s, sw, w, nw, n.
///
/// Layout: u16 3, u8 1, u16, u16 32, u16, u16 nstates; per state: string16 name, u8 speed,
/// 8 x string16 sequence names; then a trailer of i32s.
public struct AdvActor {
    public static let facings = ["ne", "e", "se", "s", "sw", "w", "nw", "n"]
    public struct State {
        public let name: String
        public let speed: Int
        public let sequences: [String]   // one per facing, in `facings` order
    }
    public let states: [State]

    public init(data d: Data) throws {
        var r = ByteReader(d)
        guard d.count > 11, r.u16() == 3 else { throw H4Error.corrupt("adv_actor: bad header") }
        _ = r.u8(); _ = r.u16(); _ = r.u16(); _ = r.u16()
        let n = Int(r.u16())
        var list: [State] = []
        for _ in 0..<n {
            guard r.remaining > 3 else { throw H4Error.corrupt("adv_actor: truncated") }
            let name = r.string16()
            let speed = Int(r.u8())
            var seqs: [String] = []
            for _ in 0..<8 { seqs.append(r.string16()) }
            list.append(State(name: name, speed: speed, sequences: seqs))
        }
        states = list
    }

    public func state(_ name: String) -> State? { states.first { $0.name == name } }

    /// Archive entry of the sequence for a state and facing, e.g. "actor_sequence.Squire.wait.s.h4d".
    public func sequenceEntry(state: String, facing: String) -> String? {
        guard let s = self.state(state), let i = AdvActor.facings.firstIndex(of: facing) else { return nil }
        return "actor_sequence.\(s.sequences[i]).h4d"
    }
}
