import Foundation

/// Saving during combat (re/combat_save_spec.md): heroes4.exe's t_saved_combat keeps the battle and
/// its combat context (the adventure object or army fought), so loading puts the same stack back in
/// front of the human with the result going to the map as for any battle.
extension SaveGame {
    public struct SavedCombat: Codable {
        public enum Kind: String, Codable { case monster, hero, siege }
        public var kind: Kind
        /// The human's army (GameState.heroes index).
        public var hero: Int
        /// The enemy hero's army (enemyHeroes index), the monster fought (monsters index) and its
        /// map object, the town besieged (towns index).
        public var enemy: Int? = nil
        public var monster: Int? = nil
        public var placed: PlacedRef? = nil
        public var town: Int? = nil
        /// A computer's army attacked (the ship decks are the other way round).
        public var aiAttacking: Bool? = nil
        public var battle: Battle.Snapshot
        /// What the screen shows that the battle does not keep: spell-made obstacles as drawn,
        /// stacks whose bodies are gone, alpha levels (phantoms).
        public var screen: Screen? = nil

        public struct PlacedRef: Codable { public var x, y, z: Int; public var name: String }
        public struct Decor: Codable {
            public var name: String; public var x, y, w, h: Int
            public init(name: String, x: Int, y: Int, w: Int, h: Int) { self.name = name; self.x = x; self.y = y; self.w = w; self.h = h }
        }
        public struct Screen: Codable {
            public var hidden: [Int]; public var alpha: [Int: Int]; public var decor: [Decor]
            public init(hidden: [Int], alpha: [Int: Int], decor: [Decor]) { self.hidden = hidden; self.alpha = alpha; self.decor = decor }
        }
    }
}

extension GameState {
    /// The battle's context for a save, or nil where the exe's context cannot save (a map script's
    /// battle, t_combat_context_script: "save_not_supported.misc").
    public func savedCombat(hero: Hero, enemy: Hero?, monster: Int?, placed: MapScene.Placed?, town: Int?, battle: Battle) -> SaveGame.SavedCombat? {
        guard battle.canSnapshot, battle.finished == nil, let h = heroes.firstIndex(where: { $0 === hero }) else { return nil }
        let snap = battle.snapshot()
        if let t = town { return SaveGame.SavedCombat(kind: .siege, hero: h, town: t, battle: snap) }
        if let e = enemy {
            guard let k = enemyHeroes.firstIndex(where: { $0 === e }) else { return nil }
            return SaveGame.SavedCombat(kind: .hero, hero: h, enemy: k, aiAttacking: aiAttacking ? true : nil, battle: snap)
        }
        guard let m = monster, m < monsters.count, let p = placed, monsters[m].bank != "script" else { return nil }
        return SaveGame.SavedCombat(kind: .monster, hero: h, monster: m, placed: .init(x: p.cellX, y: p.cellY, z: monsters[m].z, name: p.name), battle: snap)
    }

    /// A loaded combat save: the battle waits for the combat screen as when it was first fought
    /// (pendingBattle / pendingSiege / pendingHeroBattle), with the snapshot to lay over it.
    func resumeBattle(_ c: SaveGame.SavedCombat) {
        guard c.hero < heroes.count else { return }
        let h = heroes[c.hero]
        switch c.kind {
        case .siege:
            guard let t = c.town, t < towns.count else { return }
            pendingSiege = (h, t)
        case .hero:
            guard let e = c.enemy, e < enemyHeroes.count else { return }
            aiAttacking = c.aiAttacking ?? false
            pendingHeroBattle = (h, enemyHeroes[e])
        case .monster:
            guard let m = c.monster, m < monsters.count, let r = c.placed, r.z < scenes.count else { return }
            let sc = scenes[r.z]
            guard let p = (sc.placed + sc.triggers).first(where: { $0.cellX == r.x && $0.cellY == r.y && $0.name == r.name }) else { return }
            pendingBattle = (h, m, p)
        }
        resumeCombat = c
    }
}
