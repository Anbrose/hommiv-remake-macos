import Foundation

/// Map event scripts, as heroes4.exe reads them (all verified by parsing every script of the
/// shipped maps). A script is `u16 version` then an action; every node is its keyword (string16)
/// followed by its own fields:
///
///  * actions (54, keyword table built at 0x81bb00, factories at 0xa8d8c8, versioned reader
///    = vtable slot 4) -- `seq` u16 count + actions, `if` bool + then + else, `win`/`lose` u8
///    player, `text` string + (v >= 1) a seq of choices, `give_material` u8 player + 7 x i32, ...
///  * booleans (24, reader 0x411800 -> slot 9): `and`/`or`, `not`, `==` ... (two numerics),
///    `is_color` u8 player + u8 colour, `is_dead` hero name, `var` name, `true`/`false`, ...
///  * numerics (21, reader 0x4114e0 -> slot 9): `lit` i32, `rand` i32 min/max, `+ - * / %`,
///    `day`, `dow`, `week`, `month`, `wom`, `materials` u8 player + u8 material, `var`, ...
///
/// Targets: players 0 owner, 1 current, 2 opposing, 3... a colour; armies 0 this, 1 garrison,
/// 2 opposing; heroes 0 this, 1 first in this army, 2 any in opposing army, 3 first in
/// garrison, 4-6 most powerful (this / opposing / garrison), 7-9 least powerful.
public indirect enum ScriptArg {
    case int(Int)
    case text(String)
    case node(ScriptNode)
    case nodes([ScriptNode])
    case ints([Int])
    case army([(creature: Int, count: Int)?])
}

public struct ScriptNode {
    public let keyword: String
    public let args: [ScriptArg]
    public func int(_ i: Int) -> Int { if i < args.count, case .int(let v) = args[i] { return v }; return 0 }
    public func text(_ i: Int) -> String { if i < args.count, case .text(let v) = args[i] { return v }; return "" }
    public func node(_ i: Int) -> ScriptNode? { if i < args.count, case .node(let v) = args[i] { return v }; return nil }
    public func nodes(_ i: Int) -> [ScriptNode] { if i < args.count, case .nodes(let v) = args[i] { return v }; return [] }
    public func ints(_ i: Int) -> [Int] { if i < args.count, case .ints(let v) = args[i] { return v }; return [] }
    public func army(_ i: Int) -> [(creature: Int, count: Int)?] { if i < args.count, case .army(let v) = args[i] { return v }; return [] }
}

/// A map event: where it came from and when it fires.
public struct MapEvent {
    public enum Kind { case builtin(slot: Int), timed(firstDay: Int, repeatDays: Int), triggerable, continuous }
    public let kind: Kind
    public let name: String
    /// The text shown when the event fires (the script's string, 0x705e20 +0x28).
    public var message = ""
    public let action: ScriptNode
    /// Players (colour bits) the event applies to.
    public let players: Int
    public let flags: Int
    public var enabled = true
}

public struct ScriptError: Error { public let message: String }

public struct ScriptReader {
    var rd: ByteReader
    var version = 2
    public var position: Int { rd.pos }
    public init(_ d: Data, at p: Int) { rd = ByteReader(d, at: p) }

    mutating func need(_ n: Int) throws { if rd.remaining < n { throw ScriptError(message: "end of data") } }
    mutating func u8() throws -> Int { try need(1); return Int(rd.u8()) }
    mutating func i8() throws -> Int { try need(1); return Int(Int8(bitPattern: rd.u8())) }
    mutating func u16() throws -> Int { try need(2); return Int(rd.u16()) }
    mutating func i16() throws -> Int { try need(2); return Int(Int16(bitPattern: rd.u16())) }
    mutating func i32() throws -> Int { try need(4); return Int(rd.i32()) }
    mutating func str() throws -> String {
        let n = try u16()
        guard n <= 8000 else { throw ScriptError(message: "string of \(n)") }
        try need(n)
        let d = rd.bytes(n)
        return String(bytes: d, encoding: .isoLatin1) ?? ""
    }

    // node families
    mutating func action() throws -> ScriptNode {
        let k = try str()
        let a: [ScriptArg]
        switch k {
        case "clear_lc_text", "clear_l_msg", "clear_vc_text", "clear_v_msg", "disable_vc", "enable_vc", "lose", "win", "build", "change_owner":
            a = [.int(try u8())]
        case "combat": a = [.int(try u8()), .army(try creatureArray()), .node(try action()), .node(try action())]
        case "if": a = [.node(try boolean()), .node(try action()), .node(try action())]
        case "dec_mana", "inc_mana", "dec_pop", "inc_pop", "give_spell": a = [.int(try u8()), .int(try u16())]
        case "dec_damage", "dec_max_hp", "dec_max_mana", "dec_speed", "inc_damage", "inc_max_hp", "inc_max_mana", "inc_speed":
            a = [.int(try u8()), .int(try u16()), .int(try i8())]
        case "dec_luck", "dec_morale", "inc_luck", "inc_morale", "inc_move", "inc_level": a = [.int(try u8()), .int(try i8())]
        case "detonate", "gosub": a = [.text(try str())]
        case "text":
            let t = try str()
            a = version >= 1 ? [.text(t), .nodes(try seqBody())] : [.text(t), .nodes(try seqBody()), .text(try str())]
        case "give_artifact", "rem_artifact":
            let target = try u8(), n = try u16()
            var arts: [Int] = []
            for _ in 0..<n { arts.append(try artifact()) }
            a = [.int(target), .ints(arts)]
        case "give_creature", "take_creature": a = [.int(try u8()), .int(try u16()), .int(try u16())]
        case "give_material", "take_material":
            let p = try u8()
            var amounts: [Int] = []
            for _ in 0..<7 { amounts.append(try i32()) }
            a = [.int(p), .ints(amounts)]
        case "give_skill", "inc_skill": a = [.int(try u8()), .int(try u8()), .int(try u8())]
        case "inc_exp": a = [.int(try u8()), .int(try i32())]
        case "no_op", "rem_event", "rem_this": a = []
        case "ask": a = [.text(try str()), .node(try action()), .node(try action())]
        case "seq": a = [.nodes(try seqBody())]
        case "set_bool": a = [.text(try str()), .node(try boolean())]
        case "set_num": a = [.text(try str()), .node(try numeric())]
        case "set_lc_text", "set_l_msg", "set_vc_text", "set_v_msg": a = [.int(try u8()), .text(try str())]
        default: throw ScriptError(message: "action '\(k)'")
        }
        return ScriptNode(keyword: k, args: a)
    }
    mutating func seqBody() throws -> [ScriptNode] {
        let n = try u16()
        guard n <= 2000 else { throw ScriptError(message: "seq of \(n)") }
        var out: [ScriptNode] = []
        for _ in 0..<n { out.append(try action()) }
        return out
    }
    /// An artifact (0x664640): u16 id; the parchment (124) and the scroll (166) add their spell.
    mutating func artifact() throws -> Int {
        let a = try u16()
        guard a <= 248 else { throw ScriptError(message: "artifact \(a)") }
        if a == 166 || a == 124 { return RuleTables.artifact(a, spell: try u16()) }
        return a
    }
    mutating func creatureArray() throws -> [(creature: Int, count: Int)?] {
        guard try u16() == 0 else { throw ScriptError(message: "creature array") }
        var out: [(creature: Int, count: Int)?] = []
        for _ in 0..<7 {
            let kind = try u8()
            if kind == 0xff { out.append(nil); continue }
            guard kind == 0 else { throw ScriptError(message: "hero in a script army") }
            let v = try u16(), id = try i16(), n = try i16()
            if v >= 1 {   // a stack may carry artifacts (0x653760: u16 n + n artifacts)
                let k = try u16()
                guard k <= 100 else { throw ScriptError(message: "stack artifacts \(k)") }
                for _ in 0..<k { _ = try artifact() }
            }
            out.append(id >= 0 ? (id, n) : nil)
        }
        return out
    }
    mutating func boolean() throws -> ScriptNode {
        let k = try str()
        let a: [ScriptArg]
        switch k {
        case "true", "false": a = []
        case "and", "or": a = [.node(try boolean()), .node(try boolean())]
        case "not": a = [.node(try boolean())]
        case "has_alignment", "is_alignment", "is_color": a = [.int(try u8()), .int(try u8())]
        case "has_hero", "owns_hero", "owns_town": a = [.int(try u8()), .text(try str())]
        case "can_give_skill": a = [.int(try u8()), .int(try u8()), .int(try u8())]
        case "has_artifact": a = [.int(try u8()), .int(try u8()), .int(try artifact())]
        case "is_computer", "is_human", "is_eliminated": a = [.int(try u8())]
        case "==", "<", ">", "<=", ">=": a = [.node(try numeric()), .node(try numeric())]
        case "is_dead", "is_imprisoned", "var": a = [.text(try str())]
        default: throw ScriptError(message: "boolean '\(k)'")
        }
        return ScriptNode(keyword: k, args: a)
    }
    mutating func numeric() throws -> ScriptNode {
        let k = try str()
        let a: [ScriptArg]
        switch k {
        case "day", "dow", "week", "wom", "month": a = []
        case "player", "total_creatures", "total_heroes", "exp_level": a = [.int(try u8())]
        case "materials", "mastery": a = [.int(try u8()), .int(try u8())]
        case "neg": a = [.node(try numeric())]
        case "+", "-", "*", "/", "%": a = [.node(try numeric()), .node(try numeric())]
        case "creatures": a = [.int(try u8()), .int(try u16())]
        case "lit": a = [.int(try i32())]
        case "rand": a = [.int(try i32()), .int(try i32())]
        case "var": a = [.text(try str())]
        default: throw ScriptError(message: "numeric '\(k)'")
        }
        return ScriptNode(keyword: k, args: a)
    }

    /// A script (0x410930 + 0x705e20): u16 version, the action, the message shown when it
    /// fires, and 7 i32.
    mutating func script() throws -> (action: ScriptNode, message: String) {
        version = try u16()
        guard version <= 3 else { throw ScriptError(message: "script version \(version)") }
        let a = try action()
        let message = try str()
        for _ in 0..<7 { _ = try i32() }
        return (a, message)
    }
    /// A versioned boolean (0x4112a0): u16 version, the expression.
    public mutating func versionedBoolean() throws -> ScriptNode {
        version = try u16()
        guard version <= 3 else { throw ScriptError(message: "bool version \(version)") }
        return try boolean()
    }
    /// A versioned action (0x410930): u16 version, the action.
    public mutating func versionedAction() throws -> ScriptNode {
        version = try u16()
        guard version <= 3 else { throw ScriptError(message: "script version \(version)") }
        return try action()
    }
    public mutating func string() throws -> String { try str() }
    public mutating func word() throws -> Int { try u16() }
    public mutating func long() throws -> Int { try i32() }
    public mutating func byte() throws -> Int { try u8() }
    public mutating func skip(_ n: Int) throws { try need(n); rd.pos += n }
    public mutating func seek(_ p: Int) { rd.pos = p }
    /// A placed event of the map's list (0x726f90): u16 version, the script, v1+ u8 players and
    /// u8 flags, string16 name -- what a Pandora's box or an event trigger runs.
    public mutating func placedEvent() throws -> MapEvent {
        let v = try u16()
        guard v <= 1 else { throw ScriptError(message: "placed event \(v)") }
        let s = try script()
        let players = v >= 1 ? try u8() : 0, flags = v >= 1 ? try u8() : 0
        let name = try str()
        var e = MapEvent(kind: .triggerable, name: name, action: s.action, players: players, flags: flags)
        e.message = s.message
        return e
    }

    /// A standard (built-in) event (0x7d2fd0): u16 version, script, u8 players, u8 flags.
    public mutating func builtinEvent(slot: Int) throws -> MapEvent {
        _ = try u16()
        let s = try script()
        var e = MapEvent(kind: .builtin(slot: slot), name: "", action: s.action, players: try u8(), flags: try u8())
        e.message = s.message
        return e
    }
    /// A timed event (0x7d3290, 0x88c700): the script, a name, u16 first day, u16 repeat.
    public mutating func timedEvent() throws -> MapEvent {
        _ = try u16()
        let s = try script()
        let name = try str(), first = try u16(), rep = try u16()
        var e = MapEvent(kind: .timed(firstDay: first, repeatDays: rep), name: name, action: s.action, players: try u8(), flags: try u8())
        e.message = s.message
        return e
    }
    /// A triggerable event (0x7d3530, 0x8c8db0): the script and a name; an object's adds the
    /// player mask and flags (the map's own list has none).
    public mutating func triggerableEvent(trailer: Bool = true) throws -> MapEvent {
        _ = try u16()
        let s = try script()
        let name = try str()
        var e = MapEvent(kind: .triggerable, name: name, action: s.action, players: trailer ? try u8() : 0, flags: trailer ? try u8() : 0)
        e.message = s.message
        return e
    }
    /// A continuous event (0x7d37f0, 0x63bda0): an action (no message), a name; an object's
    /// adds a byte, the player mask and flags (the map's own list has none).
    public mutating func continuousEvent(trailer: Bool = true) throws -> MapEvent {
        _ = try u16()
        version = try u16()
        let a = try action()
        let name = try str()
        guard trailer else { return MapEvent(kind: .continuous, name: name, action: a, players: 0, flags: 0) }
        _ = try u8()
        let players = try u8(), flags = try u8()
        return MapEvent(kind: .continuous, name: name, action: a, players: players, flags: flags)
    }
    public mutating func list(_ read: (inout ScriptReader) throws -> MapEvent) throws -> [MapEvent] {
        let n = try u16()
        guard n <= 500 else { throw ScriptError(message: "list of \(n)") }
        var out: [MapEvent] = []
        for _ in 0..<n { out.append(try read(&self)) }
        return out
    }

    /// The map's own events (timed, triggerable, continuous lists) right after the header: the
    /// first place from `start` where the three lists read cleanly.
    public static func mapEvents(_ d: Data, from start: Int) -> [MapEvent] {
        for p in start..<min(start + 16, d.count - 6) {
            var r = ScriptReader(d, at: p)
            if let timed = try? r.list({ try $0.timedEvent() }),
               let trig = try? r.list({ try $0.triggerableEvent(trailer: false) }),
               let cont = try? r.list({ try $0.continuousEvent(trailer: false) }) {
                return timed + trig + cont
            }
        }
        return []
    }
}
