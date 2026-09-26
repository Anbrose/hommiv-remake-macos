import Foundation

/// What the adventure map's objects do when visited, as heroes4.exe does it (each object class's
/// activate, vtable slot 3; the random contents rolled at game start, slot 14 / 28; the daily
/// tick, slot 31). Amounts, chances and texts follow the exe; texts are table.Adventure Object's
/// rows (type, subtype, keyword).
public struct ObjectState: Codable {
    public var gold = 0, material = 0, amount = 0
    public var artifacts: [Int] = []
    /// Owned objects (generators, windmills): the owner and the days until the next payout.
    public var owner: Int? = nil
    public var countdown = 0
    /// Tree of Knowledge: 0 = 2500 gold, 1 = 5 gems per hero.
    public var price = 0
    public var used = false
    /// A weekly generator's own material (its payouts may be gold instead).
    public var baseMaterial = 0
    /// Skills a teacher or school teaches, a shrine's spell, a tunnel's partner ("level|x|y").
    public var skills: [Int] = []
    public var spell: Int? = nil
    public var partner: String? = nil
    /// A creature bank: its guards (creature, count, growth in 1/256 creatures), its worth in gold
    /// (V0 the initial part), and the days before it grows again after being cleared.
    public var guardCreatures: [String] = [], guardCounts: [Int] = [], guardFractions: [Int] = []
    public var worth = 0, initialWorth = 0
}

extension GameState {
    static let materialNames = ["Gold", "Wood", "Ore", "Crystal", "Sulfur", "Mercury", "Gems"]
    /// The value of a unit of each material in gold (0x98c3a0), for the marketplace and banks.
    public static let materialValue = [1, 125, 125, 250, 250, 250, 250]

    func objectKey(_ p: MapScene.Placed) -> String { "\(level)|\(p.cellX)|\(p.cellY)" }
    func rng(_ n: Int) -> Int { n <= 0 ? 0 : random.next() % n }

    /// A table.Adventure Object text with its placeholders filled.
    func objectText(_ p: MapScene.Placed, _ key: String, _ subs: [String: String] = [:]) -> String? {
        // a random_* object speaks with its resolved kind's texts
        let base = p.type.hasPrefix("random_") ? String(p.type.dropFirst(7)) : p.type
        guard var t = tables?.objectText(p.type, p.subtype, key) ?? tables?.objectText(base, p.subtype, key) ?? tables?.objectText(base, "", key) else { return nil }
        var all = subs
        if all["%object_name"] == nil { all["%object_name"] = tables?.objectText(p.type, p.subtype, "name") ?? p.type }
        for (k, v) in all.sorted(by: { $0.key.count > $1.key.count }) { t = t.replacingOccurrences(of: k, with: v) }
        return t
    }
    func say(_ p: MapScene.Placed, _ key: String, _ subs: [String: String] = [:]) {
        if let t = objectText(p, key, subs) { scripts.messages.append(t) }
    }
    /// "5 wood", "1000 gold and 5 wood"
    func materialList(_ items: [(Int, Int)]) -> String {
        let parts = items.filter { $0.1 > 0 }.map { "\($0.1) \(GameState.materialNames[$0.0].lowercased())" }
        return parts.count <= 1 ? parts.first ?? "" : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }
    func gain(_ material: Int, _ n: Int, at hero: Hero) {
        guard n > 0 else { return }
        resources[GameState.materialNames[material], default: 0] += n
        floaters.append(("+\(n) \(GameState.materialNames[material].lowercased())", hero.x, hero.y))
    }
    /// The dialogue sounds by the exe's id (0x5022a0; the ids objects pass, quirks kept).
    static let dialogueSounds = ["abandoned_mine", "artifact", "creature_bank", "experience", "kingdom_overview", "level_up", "luck", "magi", "mana",
                                 "marketplace", "military", "morale", "new_class", "new_month", "portal", "power_up", "puzzle", "quest", "recruit",
                                 "sanctuary", "shipyard", "shrine", "sign", "stables", "tavern", "thieves_guild", "tower", "treasure", "treasure_chest",
                                 "university", "view_world", "button"]
    func dialogueSound(_ id: Int) { if id < GameState.dialogueSounds.count { sounds.append("dialogue.\(GameState.dialogueSounds[id])") } }

    // MARK: artifacts

    /// Artifact ids of a level ("item", "treasure", "minor", "major", "relic"), allowed by default.
    func artifactPool(level: String, slot: String? = nil) -> [Int] {
        guard let t = tables else { return [] }
        return RuleTables.artifactIds.indices.filter { i in
            // never the spell parchment and scroll (0x7c, 0xa6: they carry a spell)
            guard i != 0x7c, i != 0xa6, let a = t.artifacts[RuleTables.artifactIds[i]] else { return false }
            return a.level.lowercased() == level && a.allowedByDefault && (slot == nil || a.slot.lowercased() == slot)
        }
    }
    /// A random artifact of a level, avoiding repeats until the level's pool runs out (0x4d9630).
    func randomArtifact(level: String) -> Int? {
        let pool = artifactPool(level: level)
        guard !pool.isEmpty else { return nil }
        var free = pool.filter { !usedArtifacts.contains($0) }
        if free.isEmpty { usedArtifacts.subtract(pool); free = pool }
        let a = free[rng(free.count)]
        usedArtifacts.insert(a)
        return a
    }
    /// A potion (0x4d9c30: artifacts of the potion slot).
    func randomPotion() -> Int? {
        let pool = artifactPool(level: "item", slot: "potion")
        return pool.isEmpty ? nil : pool[rng(pool.count)]
    }
    public func artifactName(_ id: Int, article: Bool = false) -> String {
        guard id < RuleTables.artifactIds.count, let a = tables?.artifacts[RuleTables.artifactIds[id]] else { return "an artifact" }
        return article ? a.article : a.name
    }
    /// An artifact joins the army: the hero's backpack (the leader's).
    func give(artifact id: Int, to hero: Hero) {
        hero.backpack.append(id)
        floaters.append((artifactName(id), hero.x, hero.y))
    }

    // MARK: game start

    /// Roll every object's contents (heroes4.exe rolls them when the game starts).
    public func setupObjects() {
        let playing = level
        for l in scenes.indices {
            level = l
            for p in scene.placed { setupObject(p) }
        }
        level = playing
        linkTunnels()
    }
    static let pileMaterial = ["gold_pile": 0, "wood_pile": 1, "ore_pile": 2, "crystal_pile": 3, "sulfur_pile": 4, "pot_of_mecury": 5, "gem_pile": 6]
    static func pileMaterial(ofModel name: String) -> Int? {
        let n = name.lowercased()
        for (k, m) in [("gold", 0), ("wood", 1), ("ore", 2), ("crystal", 3), ("sulfur", 4), ("mercury", 5), ("gem", 6)] where n.contains("resources.\(k)") { return m }
        return nil
    }
    func setupObject(_ p: MapScene.Placed) {
        var st = ObjectState()
        switch p.type {
        case "material_pile", "random_material_pile":
            // gold 100 x (4..8), wood and ore 4..8, the rest 2..4 (0x7912b0)
            guard let m = GameState.pileMaterial[p.subtype] ?? GameState.pileMaterial(ofModel: p.name) else { return }
            st.material = m
            st.amount = m == 0 ? 100 * (4 + rng(5)) : m <= 2 ? 4 + rng(5) : 2 + rng(3)
        case "campfire":   // 300..500 gold and 3..5 of another material, doubled for wood and ore (0x5aeb50)
            st.gold = 100 * (3 + rng(3)); st.material = 1 + rng(6); st.amount = st.gold / 100
            if st.material <= 2 { st.amount *= 2 }
        case "treasure" where p.subtype == "treasure_chest" || p.subtype == "sea_chest":
            // 1000 / 1500 / 2000 gold at 30% each, else a treasure-level artifact (0x475740)
            let r = rng(10)
            if r < 9 { st.gold = [1000, 1500, 2000][r / 3] } else if let a = randomArtifact(level: "treasure") { st.artifacts = [a] }
        case "flotsam":   // 5..10 wood, and 100 gold for each short of 10 (0x71afe0)
            st.amount = 5 + rng(6); st.gold = 100 * (10 - st.amount)
        case "treasure", "corpse", "shipwreck_survivor":
            let level = ["mages_chest": "minor", "travelers_backpack": "item"][p.subtype] ?? "treasure"
            if let a = randomArtifact(level: level) { st.artifacts = [a] }
        case "random_artifact":
            if let a = randomArtifact(level: p.subtype.isEmpty ? "treasure" : p.subtype) { st.artifacts = [a] }
        case "random_potion":
            if let a = randomPotion() { st.artifacts = [a] }
        case "artifact":
            if let i = RuleTables.artifactIds.firstIndex(of: p.subtype.lowercased()) { st.artifacts = [i] }
        case "medicine_wagon":   // 2 or 3 potions (0x4474e0)
            let n = 2 + (random.next() & 1)
            st.artifacts = (0..<n).compactMap { _ in randomPotion() }
        case "windmill":   // 4..6 crystal, sulfur, mercury or gems a week (0x478720)
            st.material = 3 + rng(4); st.amount = 4 + rng(3)
            st.owner = record(for: p)?.owner
        case "weekly_material_generator", "random_weekly_material_generator":
            let subs = ["water_wheel", "woodcutters_cottage", "miners_guild", "crystal_garden", "imp_pit", "apprentices_lab", "leprechaun"]
            let m = subs.firstIndex(of: p.subtype) ?? (1 + rng(6))
            rollStock(&st, material: m)
            st.owner = record(for: p)?.owner
        case "tree_of_knowledge":
            st.price = random.next() & 1
        case "teacher", "random_teacher", "school", "shrine", "random_shrine":
            setupTeaching(p, &st)
        case "creature_bank":
            setupBank(p, &st)
        case "tavern":
            st.baseMaterial = -1   // (marks a tavern for the daily count)
        default:
            return
        }
        objectStates["\(level)|\(p.cellX)|\(p.cellY)"] = st
    }
    /// A weekly generator's next payout: 1000 gold, 10 wood or ore, 5 of the others; a non-gold one
    /// pays 500 gold instead half the time (0x8cbd10).
    func rollStock(_ st: inout ObjectState, material m: Int) {
        st.baseMaterial = m
        st.material = m; st.amount = [1000, 10, 10, 5, 5, 5, 5][m]
        if m != 0, random.next() % 2 == 0 { st.material = 0; st.amount = 500 }
    }

    // MARK: new day

    /// The daily tick of owned objects (slot 31): generators pay every 7 days from their claim.
    func objectsNewDay() {
        // an adventure tavern (0x470df0): reopens when used and its day count has reached 7, else counts on
        for (k, st) in objectStates where st.baseMaterial == -1 {
            var t = st
            if t.used && t.countdown >= 7 { t.used = false; t.countdown = 0 } else { t.countdown += 1 }
            objectStates[k] = t
        }
        for (k, st) in objectStates where !st.guardCreatures.isEmpty || st.initialWorth > 0 {   // banks grow every day, or count down
            var b = st
            if b.countdown > 0 { b.countdown -= 1 } else { growBank(&b, days: 1) }
            objectStates[k] = b
        }
        for (k, var st) in objectStates where st.owner != nil {
            if st.countdown > 0 { st.countdown -= 1 }
            if st.countdown == 0 {
                if st.owner == map.humanColour || st.owner == nil { resources[GameState.materialNames[st.material], default: 0] += st.amount }
                else if let o = st.owner { aiResources[o, default: GameState.startingResources][GameState.materialNames[st.material], default: 0] += st.amount }
                objectStates[k] = st
                reroll(key: k)
                objectStates[k]?.countdown = 7
            } else { objectStates[k] = st }
        }
        for h in heroes.flatMap({ [$0] + $0.companions }) {
            h.manaRestoredToday = 0
            for (k, d) in h.timedEffects { h.timedEffects[k] = d > 1 ? d - 1 : nil }
            // spell points come back: 2, and 2 per level of the five magic secondaries (0x72da20)
            let regen = 2 + 2 * ["healing", "enchantment", "black", "conjuration", "herbalism"].reduce(0) { $0 + h.skill($1) } + h.artifactSum(0x1a)
            if let sp = h.spellPoints { h.spellPoints = min(maxSpellPoints(h), sp + regen) }
        }
    }
    func reroll(key: String) {
        guard var st = objectStates[key] else { return }
        let parts = key.split(separator: "|").compactMap { Int($0) }
        guard parts.count == 3, parts[0] < scenes.count, let p = scenes[parts[0]].placed.first(where: { $0.cellX == parts[1] && $0.cellY == parts[2] }) else { return }
        if p.type == "windmill" { st.material = 3 + rng(4); st.amount = 4 + rng(3) } else { rollStock(&st, material: st.baseMaterial) }
        objectStates[key] = st
    }
    public func maxSpellPoints(_ h: Hero) -> Int {
        10 + 10 * ["healing", "enchantment", "black", "conjuration", "herbalism"].reduce(0) { $0 + h.skill($1) } + h.spellPointBonus + h.artifactSum(0x19)
    }
    public func spellPoints(_ h: Hero) -> Int { h.spellPoints ?? maxSpellPoints(h) }

    // MARK: visits

    /// The object kinds with a visit of their own.
    static let visitTypes: Set<String> = ["material_pile", "random_material_pile", "campfire", "treasure", "flotsam", "corpse", "shipwreck_survivor",
                                          "artifact", "random_artifact", "random_potion", "medicine_wagon", "windmill", "weekly_material_generator",
                                          "random_weekly_material_generator", "vein", "academy", "arena", "training_grounds", "mercenary_camp",
                                          "sacred_grove", "sphinx", "magic_gem", "mana_recharger", "fountain", "clover_field", "faerie_ring",
                                          "oyster", "dolphin_school", "rainbow", "buoy", "blattner_stone", "idol_of_fortune", "movement_booster",
                                          "pathfinder", "tree_of_knowledge", "temple", "random_temple", "trading_post",
                                          "teacher", "random_teacher", "school", "shrine", "random_shrine", "subterranean_gate", "gateway",
                                          "teleporter_entrance", "teleporter_exit", "whirlpool", "keymaster_tent", "border_gate", "border_guard",
                                          "tower", "cartographer", "obelisk", "lighthouse", "creature_bank",
                                          "sign", "ocean_bottle", "prison", "pandoras_box", "seers_hut", "quest_gate", "quest_guard", "tavern"]
    public func hasVisit(_ p: MapScene.Placed) -> Bool { GameState.visitTypes.contains(p.type) }

    func remove(_ p: MapScene.Placed) {
        scene.remove(p)
        for i in 0..<p.sprite.footprint.w { for j in 0..<p.sprite.footprint.h { passability.free(p.cellX + i, p.cellY + j) } }
    }
    func armyHeroes(_ hero: Hero) -> [Hero] { [hero] + hero.companions }

    /// Debugging: visit an object as `hero` would (no walking).
    public func debugVisit(hero: Hero, _ p: MapScene.Placed) -> Bool { visitObject(hero: hero, p) }

    /// Visit an object; false when it has no visit of its own.
    @discardableResult
    func visitObject(hero: Hero, _ p: MapScene.Placed) -> Bool {
        guard hasVisit(p) else { return false }
        let key = objectKey(p)
        var st = objectStates[key] ?? ObjectState()
        defer { if objectStates[key] != nil { objectStates[key] = st } }
        let heroes = armyHeroes(hero)
        switch p.type {
        case "material_pile", "random_material_pile":
            // floating text only, and one of the six pick-up sounds (an RNG draw on each pickup)
            gain(st.material, st.amount, at: hero)
            sounds.append("miscellaneous.pick_up.0\(1 + rng(6))")
            remove(p)
        case "campfire":
            gain(0, st.gold, at: hero); gain(st.material, st.amount, at: hero)
            say(p, "initial", ["%material_list": materialList([(0, st.gold), (st.material, st.amount)])])
            dialogueSound(27); remove(p)
        case "flotsam":
            gain(0, st.gold, at: hero); gain(1, st.amount, at: hero)
            say(p, "initial", ["%material_list": materialList([(0, st.gold), (1, st.amount)])])
            dialogueSound(27); remove(p)
        case "treasure" where p.subtype == "treasure_chest":
            if let a = st.artifacts.first {
                give(artifact: a, to: hero)
                say(p, "artifact", ["%an_artifact": artifactName(a, article: true), "%artifact_name": artifactName(a)])
                dialogueSound(27)
            } else {
                // keep the gold, or give it away for gold - 500 experience shared by the heroes
                chestOffer = (hero, st.gold, st.gold - 500)
                dialogueSound(28)
            }
            remove(p)
        case "treasure" where p.subtype == "sea_chest":
            if let a = st.artifacts.first { give(artifact: a, to: hero); say(p, "artifact", ["%an_artifact": artifactName(a, article: true)]) }
            else { gain(0, st.gold, at: hero); say(p, "gold", ["%material": materialList([(0, st.gold)])]) }
            dialogueSound(27); remove(p)
        case "treasure", "corpse", "shipwreck_survivor":
            if let a = st.artifacts.first {
                give(artifact: a, to: hero)
                say(p, "Initial", ["%an_artifact": artifactName(a, article: true), "%artifact_name": artifactName(a)])
            } else { say(p, "empty") }
            dialogueSound(27); remove(p)
        case "artifact", "random_artifact", "random_potion":
            if let a = st.artifacts.first {
                give(artifact: a, to: hero)
                if let t = tables?.artifacts[RuleTables.artifactIds[a]]?.pickUp, !t.isEmpty { scripts.messages.append(t) }
            }
            dialogueSound(27); remove(p)
        case "medicine_wagon":
            if st.artifacts.isEmpty { say(p, "empty") }
            else {
                let list = st.artifacts.map { artifactName($0, article: true) }.joined(separator: ", ")
                for a in st.artifacts { give(artifact: a, to: hero) }
                st.artifacts = []
                say(p, "Initial", ["%artifact_list": list])
            }
        case "windmill", "weekly_material_generator", "random_weekly_material_generator":
            st.owner = actingColour
            if st.countdown == 0 {
                gain(st.material, st.amount, at: hero)
                say(p, "initial", ["%material": materialList([(st.material, st.amount)]), "%material_name": GameState.materialNames[st.material].lowercased()])
                st.countdown = 7
            } else { say(p, "empty", ["%material": materialList([(st.material, st.amount)]), "%material_name": GameState.materialNames[st.material].lowercased()]) }
            if p.type == "windmill" { dialogueSound(27) }
        case "vein":
            visitVein(hero, p)
        case "academy", "arena", "training_grounds", "mercenary_camp", "sacred_grove", "sphinx":
            onceEachHero(hero, p)
        case "magic_gem":
            // one hero takes it for good: opal +6 spell points, sapphire +6 defense, ruby +6 attack, emerald +2 speed
            guard let h = heroes.first else { say(p, "no heroes"); break }
            switch p.subtype {
            case "opal_of_magic": h.spellPointBonus += 6; h.spellPoints = min(maxSpellPoints(h), spellPoints(h) + 6)
            case "sapphire_of_health": h.defenseBonus += 6
            case "ruby_of_offense": h.attackBonus += 6
            default: h.speedBonus += 2
            }
            say(p, "Initial"); dialogueSound(15); remove(p)
        case "mana_recharger":
            visitMana(hero, p)
        case "fountain" where ["fountain_of_strength", "spring_of_speed", "fountain_of_vigor", "pool_of_power"].contains(p.subtype):
            let effects: [String] = ["fountain_of_strength": ["strength"], "spring_of_speed": ["speed"], "fountain_of_vigor": ["vigor"]][p.subtype] ?? ["strength", "vigor"]
            let takers = heroes.filter { !effects.allSatisfy($0.fountainEffects.contains) }
            if takers.isEmpty { say(p, "empty") } else { for h in takers { h.fountainEffects.formUnion(effects) }; say(p, "initial") }
            dialogueSound(8)
        case "fountain", "clover_field", "faerie_ring", "oyster", "dolphin_school", "rainbow", "buoy", "blattner_stone", "idol_of_fortune":
            // luck / morale until the next battle, once per object type (0x75dbe0)
            let kind = p.type == "fountain" ? p.subtype : p.type
            var luck = ["fountain_of_fortune": 1, "clover_field": 1, "faerie_ring": 1, "oyster": 1, "dolphin_school": 2, "rainbow": 2, "blattner_stone": 1][kind] ?? 0
            var morale = ["fountain_of_youth": 1, "buoy": 1, "blattner_stone": 1][kind] ?? 0
            if kind == "idol_of_fortune" { if random.next() & 1 == 1 { luck = 1 } else { morale = 1 } }
            if hero.armyLuck[kind] != nil || hero.armyMorale[kind] != nil { say(p, "Empty") }
            else {
                if luck > 0 { hero.armyLuck[kind] = luck }
                if morale > 0 { hero.armyMorale[kind] = morale }
                say(p, "Initial")
            }
            dialogueSound(6)
        case "movement_booster", "pathfinder":
            // stables +5 cells for 7 days, oasis +10 for a day, watering hole +7.5, rally flag +1 for 28;
            // the lodges +2 for 7 days (0x448be0, 0x448610)
            let (amount, days): (Float, Int) = p.type == "pathfinder" ? (2, 7) :
                (["stables": (5, 7), "oasis": (10, 1), "watering_hole": (7.5, 1), "rally_flag": (1, 28)][p.subtype] ?? (5, 7))
            let kind = "\(p.type).\(p.subtype)"
            if hero.timedEffects[kind] != nil { say(p, "empty") }
            else { hero.movement = max(0, hero.movement + amount); hero.timedEffects[kind] = days; say(p, "initial") }
            dialogueSound(15)
        case "tree_of_knowledge":
            visitTree(hero, p, st)
        case "temple", "random_temple":
            let aligns = ["life", "order", "death", "chaos", "nature"]
            let align = aligns.first { p.subtype.contains($0) } ?? aligns[(p.cellX + p.cellY) % 5]
            if hero.templeAlignment == align { say(p, "pray.empty") } else { hero.templeAlignment = align; say(p, "pray.positive") }
            dialogueSound(11)
        case "trading_post":
            marketOpen = 2; dialogueSound(9)
        case "teacher", "random_teacher", "school", "shrine", "random_shrine", "subterranean_gate", "gateway", "teleporter_entrance",
             "teleporter_exit", "whirlpool", "keymaster_tent", "border_gate", "border_guard", "tower", "cartographer", "obelisk", "lighthouse",
             "creature_bank", "sign", "ocean_bottle", "prison", "pandoras_box", "seers_hut", "quest_gate", "quest_guard", "tavern":
            return visitMore(hero, p, &st)
        default:
            return false
        }
        hero.target = nil
        return true
    }

    /// The Learning Stone, Arena, Training Grounds, Mercenary Camp, Sacred Fountain and Dream
    /// Teacher: every hero of the army who has not been here gains, once (0x849520).
    func onceEachHero(_ hero: Hero, _ p: MapScene.Placed) {
        let key = objectKey(p)
        let heroes = armyHeroes(hero)
        guard !heroes.isEmpty else { say(p, "no_heroes"); return }
        let fresh = heroes.filter { !$0.visitedObjects.contains(key) }
        guard !fresh.isEmpty else { say(p, "visited"); return }
        for h in fresh {
            h.visitedObjects.insert(key)
            switch p.type {
            case "academy": giveExperience(1000, toOnly: h)
            case "arena": h.defenseBonus += 3
            case "training_grounds": h.attackBonus += 3
            case "mercenary_camp": h.speedBonus += 1
            case "sacred_grove": h.spellPointBonus += 3; h.spellPoints = min(maxSpellPoints(h), spellPoints(h) + 3)
            default: h.dreamTeachers += 1; giveExperience(500 * h.dreamTeachers, toOnly: h)   // sphinx
            }
        }
        say(p, fresh.count == 1 ? "one_hero" : "several_heroes", ["%hero_name": fresh[0].name, "%hero_names": fresh.map { $0.name }.joined(separator: ", ")])
        dialogueSound(p.type == "academy" || p.type == "sphinx" ? 3 : 15)
    }
    /// Experience for one hero (not shared with the army).
    func giveExperience(_ n: Int, toOnly h: Hero) {
        h.experience += n
        if Hero.level(for: h.experience) > h.level, !levelUpQueue.contains(where: { $0 === h }) { levelUpQueue.append(h) }
        floaters.append(("+\(n) experience", h.x, h.y))
        nextLevelUp()
    }

    /// Mana sources restore up to 35 / 50 / 65 / 80 / 100% of the maximum, sharing one budget per
    /// hero and day (0x778dc0); the Mana Vortex doubles one hero's points, once a week.
    func visitMana(_ hero: Hero, _ p: MapScene.Placed) {
        let heroes = armyHeroes(hero)
        guard !heroes.isEmpty else { say(p, "no_heroes"); return }
        if p.subtype == "mana_vortex" {
            let key = objectKey(p)
            if (objectStates[key]?.countdown ?? 0) > 0 { say(p, "empty"); return }
            guard let h = heroes.first(where: { spellPoints($0) < 2 * maxSpellPoints($0) }) else { say(p, "empty"); return }
            h.spellPoints = 2 * maxSpellPoints(h)
            var st = objectStates[key] ?? ObjectState(); st.countdown = 7; st.owner = nil; objectStates[key] = st
            say(p, "Initial"); dialogueSound(8); return
        }
        let percent = ["magic_well": 35, "fountain_of_magic": 50, "magicians_pool": 65, "scarlet_swan_lake": 80, "magic_spring": 100][p.subtype] ?? 35
        var any = false
        for h in heroes where h.manaRestoredToday < percent {
            let mx = maxSpellPoints(h), cur = spellPoints(h)
            var g = (percent - h.manaRestoredToday) * mx / 100
            if cur + g > mx { g = mx - cur }
            if g > 0 { h.spellPoints = cur + g; h.manaRestoredToday += g * 100 / max(1, mx); any = true }
        }
        say(p, any ? "Initial" : "full"); dialogueSound(8)
    }

    /// A vein: pay to build the mine (15000 gold + 20 wood + 20 ore for gold; 2500 gold for wood or
    /// ore; 4000 gold + 10 wood for crystal, sulfur or gems; 5000 gold for mercury; 0x79da70).
    func visitVein(_ hero: Hero, _ p: MapScene.Placed) {
        let subs = ["gold_vein", "logging_camp", "ore_deposit", "crystal_vein", "sulfur_vein", "cinnabar_deposit", "gem_vein"]
        let m = subs.firstIndex(of: p.subtype) ?? 0
        let cost: [(Int, Int)] = m == 0 ? [(0, 15000), (1, 20), (2, 20)] : m <= 2 ? [(0, 2500)] : m == 5 ? [(0, 5000)] : [(0, 4000), (1, 10)]
        let text = objectText(p, "Initial") ?? "Build a mine here?"
        question = (text, { [weak self] in
            guard let self = self else { return }
            let short = cost.filter { self.resources[GameState.materialNames[$0.0], default: 0] < $0.1 }
                .map { ($0.0, $0.1 - self.resources[GameState.materialNames[$0.0], default: 0]) }
            if !short.isEmpty { self.say(p, "insufficient.materials", ["%material_list": self.materialList(short)]); return }
            for (mat, n) in cost { self.resources[GameState.materialNames[mat], default: 0] -= n }
            self.mines.append(Mine(x: p.cellX, y: p.cellY, name: p.name, resource: GameState.materialNames[m], amount: [1000, 2, 2, 1, 1, 1, 1][m], owned: self.isHumanActing, z: self.level, owner: self.actingColour))
            self.say(p, "paid")
            self.sounds.append("miscellaneous.flag_mine")
        })
    }

    /// The Tree of Knowledge: a level for each hero who has not been here, for 2500 gold or 5
    /// gems each (the price fixed at the start of the game).
    func visitTree(_ hero: Hero, _ p: MapScene.Placed, _ st: ObjectState) {
        let key = objectKey(p)
        let heroes = armyHeroes(hero)
        guard !heroes.isEmpty else { say(p, "no_heroes"); return }
        let fresh = heroes.filter { !$0.visitedObjects.contains(key) && $0.level < 70 }
        guard !fresh.isEmpty else { say(p, "Empty"); return }
        let (mat, each) = st.price == 0 ? (0, 2500) : (6, 5)
        let total = each * fresh.count
        dialogueSound(3)
        let text = objectText(p, "Initial", ["%material": materialList([(mat, total)]), "%hero_names": fresh.map { $0.name }.joined(separator: ", ")]) ?? "Pay for a level?"
        question = (text, { [weak self] in
            guard let self = self else { return }
            guard self.resources[GameState.materialNames[mat], default: 0] >= total else { self.say(p, "help.rejected"); return }
            self.resources[GameState.materialNames[mat], default: 0] -= total
            for h in fresh {
                h.visitedObjects.insert(key)
                let need = Hero.experienceTable[min(70, h.level + 1)] - h.experience
                if need > 0 { self.giveExperience(need, toOnly: h) }
            }
            self.say(p, "Paid")
        })
    }

    /// Morale objects give the army until its next battle: their sum, and a temple +2 to stacks
    /// of its alignment, +1 to the neighbours on the wheel life-order-death-chaos-nature (0x51ecf0);
    /// nothing to the undead and the mechanical.
    public func objectMorale(_ hero: Hero, alignment: String, undeadOrMechanical: Bool) -> Int {
        var m = hero.armyMorale.values.reduce(0, +)
        let wheel = ["life", "order", "death", "chaos", "nature"]
        if let t = hero.templeAlignment, !undeadOrMechanical, let a = wheel.firstIndex(of: alignment), let b = wheel.firstIndex(of: t) {
            let d = (a - b + 5) % 5
            m += d == 0 ? 2 : (d == 1 || d == 4) ? 1 : 0
        }
        return m
    }
    public func objectLuck(_ hero: Hero) -> Int { hero.armyLuck.values.reduce(0, +) }
    /// The next battle is over: what lasted until it wears off.
    func clearBattleEffects(_ hero: Hero) {
        for h in armyHeroes(hero) { h.fountainEffects = [] }
        hero.armyLuck = [:]; hero.armyMorale = [:]; hero.templeAlignment = nil
    }
}
