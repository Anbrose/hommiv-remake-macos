import Foundation

/// The spoils of war (heroes4.exe's battle-end routine 0x7fcdb0, re/booty_spec.md): every
/// artifact of the beaten army -- each slot in turn (0x7fde50), a hero's worn items, then its
/// backpack, a creature stack's backpack (0x7fc1f0) -- is taken from it. A computer winner takes
/// them all at once (0x7fb560); a human winner gets the "Spoils of War" dialog (t_dialog_booty
/// 0x674e90), drags them onto the portraits of the army, and whatever is left when it closes goes
/// to the army's first hero as booty (0x6760d0 -> 0x7fb560). Only then does the adventure map's
/// post-battle step (0x4d7800: the end check, the continuous events, the end check) run.
public final class Booty {
    /// The winning army the artifacts are for (the dialog's ring row).
    public let army: Hero
    /// What is still to hand out, in the order taken.
    public internal(set) var artifacts: [Int]
    /// The post-battle step that waits for the dialog (a hero battle's 0x4d7800, a stack's).
    let heroBattle: Bool
    init(army: Hero, artifacts: [Int], heroBattle: Bool) { self.army = army; self.artifacts = artifacts; self.heroBattle = heroBattle }
}

extension GameState {
    /// Takes every artifact a beaten army carries (0x7fde50 -> 0x7fc1f0): each hero's worn items
    /// (slot order [inferred: the exe pops them through vfunc +0x70]) and backpack, then the
    /// creatures' (a heroless army's backpack stands in for its stacks' backpacks).
    func takeSpoils(from army: Hero) -> [Int] {
        var out: [Int] = []
        for h in army.members {
            out += h.equipped.compactMap { $0 } + h.backpack
            h.equipped = Array(repeating: nil, count: h.equipped.count); h.backpack = []
        }
        if army.heroless { out += army.backpack; army.backpack = [] }
        return out
    }

    /// The spoils for a winner (0x7fd9d6..0x7fdb96): nothing to give -> nothing; a human winner
    /// opens the dialog (the post-battle step waits for it, true), a computer one takes them as
    /// booty at once.
    func awardSpoils(_ ids: [Int], to army: Hero, human: Bool, heroBattle: Bool) -> Bool {
        guard !ids.isEmpty else { return false }
        guard human else { giveLoot(ids, to: army); return false }
        booty = Booty(army: army, artifacts: ids, heroBattle: heroBattle)
        return true
    }

    /// Debugging aid (h4view H4BOOTY): the dialog with these artifacts for an army.
    public func debugSpoils(_ ids: [Int], for army: Hero) { _ = awardSpoils(ids, to: army, human: true, heroBattle: false) }

    /// An artifact dragged from the dialog onto a portrait of the army: the hero takes it
    /// (vfunc +4(artifact, 1): worn when its slot is free, else the backpack) and it leaves the
    /// list (0x676540); an emptied list closes the dialog (0x676190). A creature's portrait or an
    /// empty place keeps it in the dialog (the remake's stacks carry nothing). True when taken.
    @discardableResult
    public func bootyGive(_ index: Int, to member: Hero) -> Bool {
        guard let b = booty, b.artifacts.indices.contains(index), b.army.members.contains(where: { $0 === member }) else { return false }
        member.receive(b.artifacts.remove(at: index), tables: tables)
        artifactsChanged(b.army)
        if b.artifacts.isEmpty { closeBooty() }
        return true
    }

    /// Okay (0x6760d0, also the emptied list): what is left goes to the army as booty (0x7fb560),
    /// then the battle's post-battle step runs.
    public func closeBooty() {
        guard let b = booty else { return }
        booty = nil
        giveLoot(b.artifacts, to: b.army)
        if b.heroBattle { afterHeroBattle() } else { afterStackBattle() }
    }
}
