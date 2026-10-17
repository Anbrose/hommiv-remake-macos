import Foundation

/// Artifacts carried by hand on the army screen (re/hero_artifacts_spec.md): picked up from a
/// worn slot or a backpack place (t_drag_artifact_source), dropped on a worn slot, a backpack
/// place or an army ring, and sent back where they came from when the drop goes nowhere.

/// Something with a backpack: a hero, or a creature stack (t_stack_with_backpack).
public protocol ArtifactCarrier: AnyObject {
    var backpack: [Int] { get set }
    /// The hero whose worn slots these are (nil for creatures).
    var wearer: Hero? { get }
}

extension Hero: ArtifactCarrier {
    public var wearer: Hero? { self }
}

/// A worn slot of a hero (0..13) or a backpack place (slot -1) of a carrier.
public struct ArtifactPlace {
    public let carrier: ArtifactCarrier
    public let slot: Int
    public let index: Int
    public static func worn(_ h: Hero, _ slot: Int) -> ArtifactPlace { ArtifactPlace(carrier: h, slot: slot, index: -1) }
    public static func backpack(_ c: ArtifactCarrier, _ index: Int) -> ArtifactPlace { ArtifactPlace(carrier: c, slot: -1, index: index) }
    public var isBackpack: Bool { slot < 0 }
}

/// The artifact in hand (t_drag_artifact): what it is and where it came from.
public final class ArtifactDrag {
    public let artifact: Int
    public let origin: ArtifactPlace
    /// Set once a drop took it; until then ending the drag sends it home.
    public private(set) var consumed = false
    init(artifact: Int, origin: ArtifactPlace) { self.artifact = artifact; self.origin = origin }
    fileprivate func consume() { consumed = true }
}

/// What reading a parchment put on a hero said (0x7260a0).
public enum ParchmentNote: Equatable {
    case alreadyKnown(spell: Int)
    case needsSkill(spell: Int, skill: Int)
    case learned(spell: Int)
}

public enum ArtifactRules {
    /// The slot types (record +0x24; names 0x97c524): 0..13 the worn slots, then these.
    public static let invalid = 14, bothHands = 15, backpackOnly = 16, potion = 17, miscellaneous = 18, ring = 19
    static let slotNames = ["bow", "feet", "head", "left ring", "misc_1", "misc_2", "misc_3", "misc_4", "neck", "right ring",
                            "left hand", "shoulders", "torso", "right hand", "invalid", "both hands", "backpack", "potion", "miscellaneous", "ring"]
    public static let leftHand = 10, rightHand = 13

    /// The slot type of an artifact (table.Artifacts "Slot"); an unknown name is "invalid".
    public static func slotType(_ id: Int, tables: RuleTables?) -> Int {
        let b = RuleTables.artifactBase(id)
        guard b < RuleTables.artifactIds.count, let a = tables?.artifacts[RuleTables.artifactIds[b]] else { return invalid }
        return slotNames.firstIndex(of: a.slot.lowercased()) ?? invalid
    }

    /// Can worn slot `slot` of `h` take artifact `id` (0x537b00)? `strict` is the not-the-player's
    /// army case: only an empty slot, a two-handed one only with both hands empty, no left hand
    /// beside a two-handed one.
    public static func accepts(_ id: Int, slot: Int, of h: Hero, tables: RuleTables?, strict: Bool = false) -> Bool {
        let t = slotType(id, tables: tables)
        if strict {
            if h.equipped[slot] != nil { return false }
            if t == bothHands {
                if h.equipped[rightHand] != nil || h.equipped[leftHand] != nil { return false }
            } else if slot == leftHand, let r = h.equipped[rightHand], slotType(r, tables: tables) == bothHands {
                return false
            }
        }
        if t < invalid { return t == slot }
        switch t {
        case bothHands: return slot == rightHand
        case backpackOnly, potion: return false
        case miscellaneous: return (4...7).contains(slot)
        case ring: return slot == 3 || slot == 9
        default: return true   // "invalid" falls out of the exe's jump table as yes
        }
    }

    /// Pick up what is at a place (0x537650); nil when it is empty (or the army is not the player's).
    public static func pickUp(_ p: ArtifactPlace, strict: Bool = false) -> ArtifactDrag? {
        guard !strict else { return nil }
        if p.isBackpack {
            guard p.carrier.backpack.indices.contains(p.index) else { return nil }
            return ArtifactDrag(artifact: p.carrier.backpack.remove(at: p.index), origin: p)
        }
        guard let h = p.carrier.wearer, let a = h.takeOff(p.slot) else { return nil }
        return ArtifactDrag(artifact: a, origin: p)
    }

    /// A backpack insert (0x652a50): at the index while it is inside the backpack, else at the front.
    public static func insert(_ id: Int, into backpack: inout [Int], at index: Int) {
        if index >= 0 && index < backpack.count { backpack.insert(id, at: index) } else { backpack.insert(id, at: 0) }
    }

    /// An artifact arrives at a place (holder +0x10, 0x537c70): worn there when the slot is free,
    /// else into that hero's backpack; a backpack place inserts it at its index.
    public static func place(_ id: Int, at p: ArtifactPlace, tables: RuleTables?) {
        if p.isBackpack { insert(id, into: &p.carrier.backpack, at: p.index); return }
        guard let h = p.carrier.wearer else { p.carrier.backpack.append(id); return }
        if !h.wear(id, slot: p.slot, tables: tables) { h.backpack.append(id) }
    }

    /// The drag ends without a taker (a refused drop, a drop on nothing, Escape): home it goes (0x706960).
    public static func cancel(_ d: ArtifactDrag, tables: RuleTables?) {
        guard !d.consumed else { return }
        d.consume()
        place(d.artifact, at: d.origin, tables: tables)
    }

    /// A drop on a worn slot or backpack place (0x5370f0). False when refused (the caller then
    /// cancels). A parchment put on says what happened.
    @discardableResult
    public static func drop(_ d: ArtifactDrag, on p: ArtifactPlace, tables: RuleTables?, strict: Bool = false) -> (accepted: Bool, note: ParchmentNote?) {
        guard !d.consumed else { return (false, nil) }
        if p.isBackpack {
            insert(d.artifact, into: &p.carrier.backpack, at: p.index)
            d.consume()
            return (true, nil)
        }
        guard let h = p.carrier.wearer, accepts(d.artifact, slot: p.slot, of: h, tables: tables, strict: strict) else { return (false, nil) }
        var displaced = h.takeOff(p.slot)
        if displaced == nil, p.slot == leftHand, let r = h.equipped[rightHand], slotType(r, tables: tables) == bothHands {
            displaced = h.takeOff(rightHand)
        }
        if slotType(d.artifact, tables: tables) == bothHands {
            if let x = displaced { place(x, at: d.origin, tables: tables) }
            displaced = h.takeOff(leftHand)
        }
        var note: ParchmentNote? = nil
        if h.wear(d.artifact, slot: p.slot, tables: tables) {
            if RuleTables.artifactBase(d.artifact) == 0x7c, let sp = RuleTables.artifactSpell(d.artifact) {
                note = h.readParchment(sp)
                if case .learned? = note { h.equipped[p.slot] = nil }
            }
        } else {
            h.backpack.append(d.artifact)
        }
        if let x = displaced { place(x, at: d.origin, tables: tables) }
        d.consume()
        return (true, note)
    }

    /// A drop on an army ring holding a stack (0x6430bb): into that stack's backpack.
    public static func drop(_ d: ArtifactDrag, onto c: ArtifactCarrier) {
        guard !d.consumed else { return }
        c.backpack.append(d.artifact)
        d.consume()
    }

    /// Every worn slot that would take the artifact (the highlights while it is carried, 0x537a30).
    public static func takingSlots(_ id: Int, of h: Hero, tables: RuleTables?, strict: Bool = false) -> [Int] {
        (0..<14).filter { accepts(id, slot: $0, of: h, tables: tables, strict: strict) }
    }
}

extension Hero {
    /// Take off what is worn in a slot (0x479180).
    public func takeOff(_ slot: Int) -> Int? {
        guard equipped.indices.contains(slot), let a = equipped[slot] else { return nil }
        equipped[slot] = nil
        return a
    }
    /// Wear an artifact in a slot (0x72a330): only an empty slot, and not the left hand beside a
    /// two-handed weapon. (No slot-type check here; the drop checked it.)
    @discardableResult
    public func wear(_ id: Int, slot: Int, tables: RuleTables?) -> Bool {
        guard equipped.indices.contains(slot), equipped[slot] == nil else { return false }
        if slot == ArtifactRules.leftHand, let r = equipped[ArtifactRules.rightHand], ArtifactRules.slotType(r, tables: tables) == ArtifactRules.bothHands { return false }
        equipped[slot] = id
        return true
    }
    /// Reading a parchment (0x7260a0): known already, the school skill too low, or learned.
    public func readParchment(_ spell: Int) -> ParchmentNote {
        if spells.contains(spell) { return .alreadyKnown(spell: spell) }
        guard canLearn(spell) else {
            return .needsSkill(spell: spell, skill: spell < RuleTables.spells.count ? RuleTables.spells[spell].schoolSkill : -1)
        }
        spells.insert(spell)
        return .learned(spell: spell)
    }
}
