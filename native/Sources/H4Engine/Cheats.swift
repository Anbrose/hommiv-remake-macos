import Foundation

/// The cheat codes (re/cheats_spec.md). heroes4.exe keeps only their string keys
/// (`free_materials.cheats` ...) and reads the codes from strings.Text ("nwcAmbrosia" ...); the
/// Tab box (t_dialog_cheat, 0x5cede0) compares the text typed with each in turn (0x5cf240:
/// `_strnicmp` over the shorter length and equal lengths -- an exact match, ASCII case ignored),
/// marks the game as cheated (game +0xe0) and sends the code's menu command to the screen it was
/// opened on (adventure frame 0x4bd620, combat window 0x6326d0, town window 0x8b60c3); a command
/// the screen does not handle does nothing.
public enum Cheats {
    /// The screens the box opens on (Tab in their key handlers: 0x4bf54c, 0x63372f, 0x8bcb5d).
    public enum Screen { case adventure, combat, town }

    /// The menu command ids (RT_MENU 109's "Cheat" popup and menu 133's New Game).
    public enum Command: Int {
        case freeMaterials = 0x8004, unlimitedMovement = 0x8005, greaterRingOfVulnerability = 0x8017
        case increaseLevel = 0x8019, learnAllSpells = 0x801a, gainSkill = 0x8062
        case shroud = 0x8077, winCombat = 0x8078, loseCombat = 0x8079, winScenario = 0x807e, loseScenario = 0x807f
        case autoPlay = 0x8080, newGame = 0x8081, daggerOfDespair = 0x8082, dumpMapImage = 0x8083
        case maxMorale = 0x8085, revealPuzzle = 0x8086, tattooedWhiteTrash = 0x8087, buildAll = 0x8088
        case cheatMenu = 0x8089, maxLuck = 0x808a, oldManJack = 0x808b
        // the creature commands (0x9793fc) the codes use
        case crusaders = 0x8020, archangels = 0x8022, champions = 0x8023, dwarves = 0x8024, magi = 0x8027
        case titans = 0x802b, vampires = 0x8034, devils = 0x8036, minotaurs = 0x803f, trolls = 0x8040
        case nightmares = 0x8042, blackDragons = 0x8043, sprites = 0x8047, wolves = 0x8048, elves = 0x804b
        case unicorns = 0x8051, phoenixes = 0x8054, ogreMagi = 0x805b, behemoths = 0x805c, seaMonsters = 0x805d
    }

    /// The codes in the order 0x5cf240 tries them: (strings.Text key, the GOG English text, command).
    public static let codes: [(key: String, code: String, command: Command)] = [
        ("free_materials.cheats", "nwcAmbrosia", .freeMaterials),
        ("auto_play.cheats", "nwcGoSolo", .autoPlay),
        ("win_combat.cheats", "nwcAres", .winCombat),
        ("lose_combat.cheats", "nwcAchilles", .loseCombat),
        ("elven_chainmail.cheats", "nwcHephaestus", .newGame),   // 0x8081: the frame's New Game, not the chainmail
        ("dagger_of_despair.cheats", "nwcEtTuBrute", .daggerOfDespair),
        ("sword_of_the_gods.cheats", "nwcExcalibur", .dumpMapImage),   // 0x8083: Dump Entire Map Image on the map
        ("ring_of_greater_negation.cheats", "nwcNibelungenlied", .greaterRingOfVulnerability),
        ("crusaders.cheats", "nwcTristram", .crusaders),
        ("champions.cheats", "nwcLancelot", .champions),
        ("angels.cheats", "nwcStMichael", .archangels),
        ("dwarves.cheats", "nwcSevenLittleGuys", .dwarves),
        ("minotaur.cheats", "nwcKingMinos", .minotaurs),
        ("magi.cheats", "nwcMerlin", .magi),
        ("titans.cheats", "nwcCronus", .titans),
        ("vampires.cheats", "nwcBlahBlah", .vampires),
        ("devils.cheats", "nwcHades", .devils),
        ("trolls.cheats", "nwcUnderTheBridge", .trolls),
        ("nightmares.cheats", "nwcXanthus", .nightmares),
        ("black_dragons.cheats", "nwcFafnir", .blackDragons),
        ("sprites.cheats", "nwcDoYouSmellBrownies", .sprites),
        ("wolves.cheats", "nwcFenrir", .wolves),
        ("elves.cheats", "nwcFixMyShoes", .elves),
        ("unicorn.cheats", "nwcTheLast", .unicorns),
        ("phoenix.cheats", "nwcRa", .phoenixes),
        ("ogre_magi.cheats", "nwcValkyries", .ogreMagi),
        ("behemoth.cheats", "nwcGrendel", .behemoths),
        ("sea_monster.cheats", "nwcPoseidon", .seaMonsters),
        ("shroud_fow.cheats", "nwcPrometheus", .shroud),
        ("gain_skill.cheats", "nwcAthena", .gainSkill),
        ("increase_level.cheats", "nwcThoth", .increaseLevel),
        ("learn_spells.cheats", "nwcIsis", .learnAllSpells),
        ("lose_scenario.cheats", "nwcRagnarok", .loseScenario),
        ("unlimited_movement.cheats", "nwcHermes", .unlimitedMovement),
        ("win_scenario.cheats", "nwcValhalla", .winScenario),
        ("max_luck.cheats", "nwcSacrificeToTheGods", .maxLuck),
        ("max_morale.cheats", "nwcPan", .maxMorale),
        ("reveal_puzzle_map.cheats", "nwcSphinx", .revealPuzzle),
        ("tatooed_white_trash.cheats", "nwcAphrodite", .tattooedWhiteTrash),
        ("build_all_buildings.cheats", "nwcCityOfTroy", .buildAll),
        ("access_cheat_menu.cheats", "nwcImAGod", .cheatMenu),
        ("old_man_jack.cheats", "nwcOldMan", .oldManJack),
    ]

    /// The creature each creature command adds (table 0x9793fc), 20 at a time (0x6410d0(c, 20, -1)).
    public static let creatures: [Command: String] = [
        .crusaders: "crusader", .champions: "champion", .archangels: "archangel", .dwarves: "dwarf", .minotaurs: "minotaur",
        .magi: "mage", .titans: "titan", .vampires: "vampire", .devils: "archdevil", .trolls: "troll", .nightmares: "nightmare",
        .blackDragons: "black dragon", .sprites: "sprite", .wolves: "wolf", .elves: "elf", .unicorns: "unicorn",
        .phoenixes: "phoenix", .ogreMagi: "ogre mage", .behemoths: "behemoth", .seaMonsters: "sea monster",
    ]
    /// The artifact commands the frame reaches (artifact switch 0x4bbc50): artifact ids.
    public static let artifacts: [Command: Int] = [.greaterRingOfVulnerability: 0x4e, .daggerOfDespair: 0xcc]
    public static let creaturesPerCode = 20

    /// 0x879620 over _strnicmp (0x8e3150, the "C" locale): equal ignoring the case of A-Z only.
    public static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        func low(_ c: UInt8) -> UInt8 { c >= 0x41 && c <= 0x5a ? c + 0x20 : c }
        return zip(x, y).allSatisfy { low($0) == low($1) }
    }
    /// The command a text sends, if it is one of the codes (`strings`: the game's strings.Text).
    public static func command(for text: String, strings: [String: String]) -> Command? {
        codes.first { same(text, strings[$0.key] ?? $0.code) }?.command
    }

    /// What the screen has to do after a code (the engine did the rest).
    public enum Result: Equatable {
        case nothing                 // the screen does not handle it (or the command has no effect)
        case done                    // applied
        case gainSkillMenu(Hero)     // 0x4b7440: open the skill menus for this hero
        case newGame                 // 0x8081: the new-game screen
        case dumpMapImage            // 0x8083: entire_map.bmp
        case message(String)         // a message box
        case combat(Command)         // win / lose combat, the two hero models: the battle does it
        public static func == (a: Result, b: Result) -> Bool {
            switch (a, b) {
            case (.nothing, .nothing), (.done, .done), (.newGame, .newGame), (.dumpMapImage, .dumpMapImage): return true
            case let (.gainSkillMenu(x), .gainSkillMenu(y)): return x === y
            case let (.message(x), .message(y)): return x == y
            case let (.combat(x), .combat(y)): return x == y
            default: return false
            }
        }
    }

    /// The 9 skill families the Gain Skill menu offers, by primary id (hard-coded English 0xa52228...).
    public static let familyLabels = ["Tactics", "Combat", "Scouting", "Nobility", "Life", "Order", "Death", "Chaos", "Nature"]
    /// The internal movement Unlimited Movement gives (0x4bd721: 1,000,000 points, 100 a cell).
    public static let unlimitedMovement: Float = 10_000
}

extension GameState {
    /// Typed into the box and Enter pressed (0x5cf240): the command, after marking the game cheated.
    /// `town`: the town screen's town; nil text matches nothing.
    @discardableResult
    public func enterCheat(_ text: String, on screen: Cheats.Screen, town: Int? = nil) -> Cheats.Result {
        guard let c = Cheats.command(for: text, strings: tables?.strings ?? [:]) else { return .nothing }
        cheated = true
        return cheat(c, on: screen, town: town)
    }

    /// A cheat command on a screen (the screens' on_command handlers).
    public func cheat(_ c: Cheats.Command, on screen: Cheats.Screen, town: Int? = nil) -> Cheats.Result {
        switch screen {
        case .adventure: return adventureCheat(c)
        case .combat:
            switch c {
            case .winCombat, .loseCombat, .tattooedWhiteTrash, .oldManJack: return .combat(c)
            case .winScenario, .loseScenario: endScenario(won: c == .winScenario); return .done
            case .newGame: return .newGame
            default: return .nothing
            }
        case .town:
            switch c {
            case .freeMaterials: freeMaterials(); return .done
            case .buildAll:
                guard let i = town else { return .nothing }
                if let m = buildAllBuildings(i) { return .message(m) }
                return .done
            default: return .nothing
            }
        }
    }

    func adventureCheat(_ c: Cheats.Command) -> Cheats.Result {
        let army = heroes.first
        // the selected slot of the army panel: its hero (the leader)
        let hero = army.flatMap { $0.heroless ? nil : $0 }
        switch c {
        case .freeMaterials: freeMaterials(); return .done
        case .unlimitedMovement:
            guard let a = army else { return .nothing }
            a.movement = Cheats.unlimitedMovement
            return .done
        case .increaseLevel:
            guard let h = hero else { return .nothing }
            cheatIncreaseLevel(h); return .done
        case .gainSkill:
            guard let h = hero else { return .nothing }
            if gainSkillFamilies(h).isEmpty { return .message("\(h.name) can learn no skills") }
            return .gainSkillMenu(h)
        case .learnAllSpells:
            guard let h = hero else { return .nothing }
            learnAllSpells(h); return .done
        case .shroud:
            fogEnabled.toggle(); visionChanged = true; return .done
        case .autoPlay:
            autoPlay.toggle()
            autoPlayPending = autoPlay   // on: the turn ends (0x4b2930(0)) and the computer plays on
            return .done
        case .winScenario, .loseScenario: endScenario(won: c == .winScenario); return .done
        case .newGame: return .newGame
        case .dumpMapImage: return .dumpMapImage
        default:
            if let id = Cheats.artifacts[c] {
                guard let h = hero else { return .nothing }   // 0x6402b0 refuses an army without a hero
                give(artifact: id, to: h); return .done
            }
            if let k = Cheats.creatures[c] {
                guard let a = army, let d = tables?.creature(k) else { return .nothing }
                // the creature's expansion must be installed (record +0xdc <= 0x435c80, which is 2)
                guard d.expansion <= 2 else { return .done }
                _ = add(d.keyword, Cheats.creaturesPerCode, to: a)
                return .done
            }
            return .nothing   // 0x8085, 0x8086, 0x808a: handled, nothing done; the rest: no handler
        }
    }

    /// Free Materials (0x4d88c0): 200000 gold and 300 of each other resource (0x7e3dd0 adds, at
    /// least 0) for the player whose turn it is.
    public func freeMaterials() {
        for (k, name) in GameState.materialNames.enumerated() {
            resources[name] = max(0, resources[name, default: 0] + (k == 0 ? 200_000 : 300))
        }
    }

    /// Increase Level (0x4b72b0): the hero's experience becomes the next level's threshold
    /// (0x72b4e0), then the level-up as experience brings it (0x72bc80).
    public func cheatIncreaseLevel(_ h: Hero) {
        let next = min(Hero.experienceTable.count - 1, h.level + 1)
        h.experience += Hero.experienceTable[next] - h.experience
        if Hero.level(for: h.experience) > h.level, !levelUpQueue.contains(where: { $0 === h }) { levelUpQueue.append(h) }
        nextLevelUp()
    }

    /// Learn All Spells (0x4b8df0 -> 0x72ddd0): every spell 0...187 with the Teach flag, and 1000
    /// spell points (hero +0x798).
    public func learnAllSpells(_ h: Hero) {
        for s in 0..<min(188, RuleTables.spells.count) where RuleTables.spells[s].has("Teach") { h.spells.insert(s) }
        h.spellPoints = 1000
    }

    /// Win / Lose Scenario (0x4c5df0, the routine a real victory or defeat runs).
    public func endScenario(won: Bool) {
        guard outcome == nil else { return }
        outcome = won
        log.append(won ? (scripts.victoryText ?? map.victoryText ?? text("default_victory_condition", "Be the only player to own towns."))
                       : (scripts.lossText ?? map.lossText ?? text("default_loss_condition", "Lose all towns and armies.")))
    }

    /// The name a victory's high score is entered under (dialog.win 0x6f526b): "Cheater"
    /// (cheater.misc) once a code was used.
    public func highScoreName(typed: String) -> String { cheated ? text("cheater.misc", "Cheater") : typed }

    // MARK: Gain Skill (0x4b7440)

    /// The families the first menu lists: those with a skill below grandmaster, unless the hero
    /// lacks the family's primary and already knows five.
    public func gainSkillFamilies(_ h: Hero) -> [Int] {
        let primaries = (0..<9).filter { h.skill(id: $0) > 0 }.count
        return (0..<9).filter { p in
            if h.skill(id: p) == 0 && primaries >= 5 { return false }
            return !gainSkillChoices(h, family: p).isEmpty
        }
    }
    /// The skills of a family the second menu lists (0x4b8430): below grandmaster.
    public func gainSkillChoices(_ h: Hero, family p: Int) -> [Int] {
        (0..<36).filter { RuleTables.primary(of: $0) == p && h.skill(id: $0) < 5 }
    }
    /// The levels the third menu lists (0x4b87a0): above the current one, up to grandmaster (0...4).
    public func gainSkillLevels(_ h: Hero, skill s: Int) -> [Int] { Array(h.skill(id: s)..<5) }
    /// A skill's name for the menus (table.skills' basic name less the level) and at a level.
    public func skillName(_ s: Int, level l: Int? = nil) -> String {
        let k = RuleTables.skillIds[s]
        if let l = l { return tables?.skillTexts["\(k)_\(RuleTables.skillLevelNames[l])"]?.name ?? "\(RuleTables.skillLevelNames[l].capitalized) \(k.capitalized)" }
        let n = tables?.skillTexts["\(k)_basic"]?.name ?? k.capitalized
        return n.hasPrefix("Basic ") ? String(n.dropFirst(6)) : n
    }
    /// The pick (0x4b8a20): the skill at that level, then each unmet prerequisite in turn; the
    /// message "<hero> learned <a>, <b>" and the class reconsidered (0x72b820).
    @discardableResult
    public func gainSkill(_ h: Hero, skill s: Int, level l: Int) -> String {
        var work = [(s, l)], learned: [String] = []
        var k = 0
        while k < work.count {
            let (sk, lv) = work[k]; k += 1
            guard h.lv(sk) < lv else { continue }
            h.learn(sk, level: lv)
            guard h.lv(sk) >= lv else { continue }
            learned.append(skillName(sk, level: lv))
            for r in Hero.requirements[sk][lv] where h.lv(r.0) < r.1 && !work.contains(where: { $0 == r }) { work.append(r) }
        }
        h.grantSchoolSpells(random: &random)
        h.reconsiderClass()
        return "\(h.name) learned " + learned.joined(separator: ", ")
    }

    // MARK: Auto Play (0x8080)

    /// The human's turn under Auto Play (0x4c6500 makes every player a computer, 0x4b2930 ends the
    /// turn): the computer-player routines move the human's armies and build in its towns, then
    /// the turn ends. A battle with a computer army stops the moves (it opens as usual).
    public func autoPlayTurn() {
        autoPlayPending = false
        guard autoPlay, outcome == nil else { return }
        let c = map.humanColour, savedQuick = quickCombatOnly
        quickCombatOnly = true
        aiComputeWeights(c)
        aiComputeBudget(c, withIncome: false)
        aiTownPlans(c)
        for h in heroes where pendingHeroBattle == nil { aiMove(h) }
        aiComputeBudget(c, withIncome: true)
        aiBuild(c)
        quickCombatOnly = savedQuick
        if pendingHeroBattle == nil { endTurn() }
        if autoPlay { autoPlayPending = true }
    }

    // MARK: Build All Buildings (0x8b1790)

    /// The grail first, then again and again the lowest building id the town can have whose
    /// requirements are met (0x894090: no cost, no day rule, no map restriction). nil when built,
    /// else the refusal (town.buy_building_not_owner).
    @discardableResult
    public func buildAllBuildings(_ i: Int) -> String? {
        guard towns.indices.contains(i) else { return nil }
        guard towns[i].owned || towns[i].owner == actingColour else {
            return text("town.buy_building_not_owner", "You can only build structures in your own towns.")
        }
        cheatBuild(i, 11)
        while let b = (0...42).first(where: { GameState.buildingExists(towns[i].alignment, $0) && !isBuilt(towns[i], $0)
                                              && met(towns[i], GameState.buildingReq(towns[i].alignment, $0)) }) {
            cheatBuild(i, b)
        }
        return nil
    }
    /// The build routine without the price (0x894270): the building, its dwelling's first recruits.
    func cheatBuild(_ i: Int, _ b: Int) {
        guard let k = buildingKeyword(towns[i].alignment, b), !towns[i].buildings.contains(k) else { return }
        towns[i].buildings.insert(k)
        if let d = buildingDef(towns[i], b), let c = d.creature, let def = tables?.creature(c) { dwellingBuilt(i, c, def) }
    }
}

extension Battle {
    /// Win / Lose Combat (0x633390): every creature of the losing side (code 0: side 0, code 4:
    /// side 1) is left with none, then the battle ends. The player is side 0 here, so a win is code 4.
    public func cheatEnd(playerWins: Bool) {
        guard finished == nil else { return }
        let losers = playerWins ? 1 : 0
        for u in units where u.side == losers { u.stats.count = 0 }
        checkEnd()
    }
    /// nwcAphrodite / nwcOldMan (0x632900): the acting hero's combat model becomes
    /// hero.tattooed_white_trash (1) / hero.jack (2) (+0xa2c), with at least 10 shots (+0xbc).
    /// False: the acting creature is not a hero ("This only works on heroes.").
    public func cheatHeroModel(_ mode: Int) -> Bool {
        guard let u = current, u.stats.isHero else { return false }
        u.modelOverride = mode
        u.actor = mode == 1 ? "hero.tattooed_white_trash" : "hero.jack"
        u.shots = max(u.shots, 10)
        return true
    }
}
