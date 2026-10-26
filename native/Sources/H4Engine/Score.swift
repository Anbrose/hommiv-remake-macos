import Foundation
import Compression

/// A won scenario's score (heroes4.exe 0x81ad30, re/end_sequence_spec.md §8): nine categories, each
/// capped, summed; the rank a creature from the score. A cheated game scores 0 everywhere (the
/// counts stay, and the rank is the honest one).
public struct ScenarioScore: Codable, Equatable {
    public var towns = 0, townScore = 0
    public var armyValue = 0, armyScore = 0
    public var quests = 0, questScore = 0
    public var artifacts = 0, artifactScore = 0
    public var heroName = "", heroLevel = 0, heroScore = 0
    /// The best hero's portrait (heroes table keyword, alignment).
    public var heroKeyword = "", heroAlignment = ""
    public var battlesWon = 0, battleScore = 0
    public var wealth = 0, wealthScore = 0
    public var explored: Double = 0, exploreScore = 0
    public var days = 0, timeScore = 0
    public var mapDifficulty = 0, mapPercent = 100
    public var playerDifficulty = 0, difficultyBase = 0
    public var total = 0
    /// The rank: a creature id (RuleTables.creatureIds).
    public var rank = 0
    public init() {}

    /// What it adds to a campaign (0x4e6020: {score, days}).
    public var campaignEntry: CampaignScore { CampaignScore(score: total, days: days) }
}

/// One finished campaign scenario (t_carryover_data +0xffc).
public struct CampaignScore: Codable, Equatable {
    public var score: Int, days: Int
    public init(score: Int, days: Int) { self.score = score; self.days = days }
}

/// What the score is made of, as 0x81ad30 gathers it.
public struct ScoreInputs {
    /// Map size class S (0x405e60: width <= 76, 152, 228, else 3) and levels L.
    public var sizeClass = 0, levels = 1
    public var playerDifficulty = 1, mapDifficulty = 2
    public var days = 0
    public var towns = 0, quests = 0, battlePoints = 0, battlesWon = 0
    /// Resources now, gold first (GameState.materialNames order), and the difficulty's starting ones.
    public var resources: [Int] = Array(repeating: 0, count: 7), startResources: [Int] = Array(repeating: 0, count: 7)
    /// Gold cost x count of every creature stack (heroes not counted).
    public var armyValue = 0
    /// Each artifact's level (0 item, 1 treasure, 2 minor, 3 major, 4 fragment, 5 relic, 6 divine).
    public var artifactLevels: [Int] = []
    public var bestHero: (name: String, level: Int)? = nil
    public var bestHeroPortrait: (keyword: String, alignment: String) = ("", "")
    public var explored: Double = 0
    public var cheated = false
    public init() {}
}

extension ScenarioScore {
    // the exe's tables (0x991110..0x991200, 0x9910c0, 0xa7a2a8, 0x99113c)
    static let townPoints = [30, 15, 10, 10], townCap = 120
    static let armyFactor = [0.001, 0.0005, 0.00025, 0.000125], armyCap = 24
    static let questPoints = [48, 24, 12, 8], questCap = 96
    static let artifactPoints = [[10, 20, 40, 76, 76], [5, 10, 20, 45, 45], [1, 5, 10, 45, 45], [0, 3, 8, 30, 30]], artifactCap = 76
    static let heroThreshold = [3, 4, 5, 6, 7], heroPoints = [10, 6, 5, 3, 2], heroCap = 76
    static let battleCap = 72
    static let wealthFactor = [0.002, 0.001, 0.0005, 0.00025], wealthCap = 48
    static let difficultyBase = [[50, 100, 200, 400, 750], [75, 125, 225, 420, 700], [90, 150, 250, 440, 650], [100, 200, 300, 450, 600]]
    static let mapPercent = [50, 75, 100, 125, 150]
    static let weekDivisor = [1, 2, 4, 6], earlyBonus = [250, 100, 50]
    /// The score column of an artifact level (jump tables 0x81b530 / 0x81b548): items and fragments none.
    static func artifactColumn(_ level: Int) -> Int? { [1: 0, 2: 1, 3: 2, 5: 3, 6: 4][level] }

    /// The map size class (0x405e60 via 0x81ad3c).
    public static func sizeClass(mapSize: Int) -> Int { mapSize <= 76 ? 0 : mapSize <= 152 ? 1 : mapSize <= 228 ? 2 : 3 }

    /// The time score (0x81b1a0..): the base by size and player difficulty, a bonus for under three
    /// (scaled) weeks, a decline after eight, times the map's difficulty percent.
    public static func timeScore(days: Int, sizeClass s: Int, playerDifficulty pd: Int, mapDifficulty md: Int) -> Int {
        let base = difficultyBase[s][min(4, max(0, pd))]
        let w = days / 7 / weekDivisor[s]
        var t: Int
        if w < 3 { t = base + earlyBonus[w] }
        else if w <= 7 { t = base }
        else { t = base * max(30, 5 * (27 - w)) / 100 }
        t = t * mapPercent[min(4, max(0, md))] / 100
        return t
    }

    /// The whole computation (0x81ad30 after the gathering); `rank` maps the honest total to a creature.
    public static func compute(_ i: ScoreInputs, rank: (Int) -> Int) -> ScenarioScore {
        let s = min(3, max(0, i.sizeClass))
        var r = ScenarioScore()
        r.days = i.days
        r.towns = i.towns; r.townScore = min(townCap, i.towns * townPoints[s])
        r.armyValue = i.armyValue; r.armyScore = min(armyCap, Int(Double(i.armyValue) * armyFactor[s]))
        r.quests = i.quests; r.questScore = min(questCap, i.quests * questPoints[s])
        var pts = 0, count = 0
        for l in i.artifactLevels {
            guard let c = artifactColumn(l) else { continue }
            let p = artifactPoints[s][c]
            pts += p
            if p > 0 { count += 1 }
        }
        r.artifacts = count; r.artifactScore = min(artifactCap, pts)
        if let h = i.bestHero {
            let k = s == 3 && i.levels > 1 ? 4 : s
            r.heroName = h.name; r.heroLevel = h.level
            r.heroKeyword = i.bestHeroPortrait.keyword; r.heroAlignment = i.bestHeroPortrait.alignment
            let d = h.level - heroThreshold[k]
            r.heroScore = d > 0 ? min(heroCap, heroPoints[k] * d) : 0
        }
        r.battlesWon = i.battlesWon; r.battleScore = min(battleCap, i.battlePoints)
        var w = i.resources[0] - i.startResources[0]
        for k in 1..<7 { w += (i.resources[k] - i.startResources[k]) * GameState.materialValue[k] / 2 }
        r.wealth = max(0, w); r.wealthScore = min(wealthCap, Int(Double(r.wealth) * wealthFactor[s]))
        r.explored = i.explored; r.exploreScore = Int(i.explored * 12)
        r.playerDifficulty = i.playerDifficulty; r.difficultyBase = difficultyBase[s][min(4, max(0, i.playerDifficulty))]
        r.mapDifficulty = i.mapDifficulty; r.mapPercent = mapPercent[min(4, max(0, i.mapDifficulty))]
        r.timeScore = timeScore(days: i.days, sizeClass: s, playerDifficulty: i.playerDifficulty, mapDifficulty: i.mapDifficulty)
        r.total = max(0, r.timeScore + r.battleScore + r.questScore + r.wealthScore + r.exploreScore + r.armyScore + r.artifactScore + r.heroScore + r.townScore)
        r.rank = rank(r.total)
        if i.cheated {   // 0x81b2b6: the scores go, the counts and the rank stay
            r.armyScore = 0; r.artifactScore = 0; r.battleScore = 0; r.exploreScore = 0; r.total = 0
            r.heroScore = 0; r.questScore = 0; r.timeScore = 0; r.townScore = 0; r.wealthScore = 0
        }
        return r
    }

    /// The rank (0x81b560): creatures 0...73 sorted by Experience (ties by id), the one at
    /// ((n - 1) x score + scale / 2) / scale, the last for anything higher.
    public static func rank(score: Int, scale: Int, experience: (Int) -> Int) -> Int {
        let ids = (0..<RuleTables.creatureIds.count).sorted { (experience($0), $0) < (experience($1), $1) }
        let n = ids.count
        guard n > 0 else { return 0 }
        let idx = (UInt32(truncatingIfNeeded: (n - 1) * max(0, score)) &+ UInt32(scale / 2)) / UInt32(scale)
        return ids[min(Int(idx), n - 1)]
    }

    /// The battle points for a win (0x7e4940): by the ratio of the winner's strength to the
    /// loser's (0x6411d0 values before the battle), per size class.
    public static func battlePoints(winner: Int, loser: Int, sizeClass s: Int) -> Int {
        guard loser > 0 else { return 0 }
        let r = Float(winner) / Float(loser)
        let table = [[60, 40, 30, 20, 10], [45, 30, 25, 15, 8], [30, 20, 15, 10, 5], [30, 20, 10, 8, 3]][min(3, max(0, s))]
        let limits: [Float] = [0.333, 0.5, 0.666, 1.0, 1.5]
        guard let k = limits.firstIndex(where: { r <= $0 }) else { return 0 }
        return table[k]
    }

    /// The campaign's score (t_dialog_campaign_score 0x67e3c0): the scenarios' average (truncated) x 5.
    public static func campaign(_ scores: [CampaignScore]) -> (average: Int, score: Int, days: Int) {
        guard !scores.isEmpty else { return (0, 0, 0) }
        let avg = scores.reduce(0) { $0 + $1.score } / scores.count
        return (avg, avg * 5, scores.reduce(0) { $0 + $1.days })
    }
}

extension GameState {
    /// An artifact's level id (the keyword table at 0x97c4f0).
    static func artifactLevelId(_ level: String) -> Int {
        ["item": 0, "treasure": 1, "minor": 2, "major": 3, "fragment": 4, "relic": 5, "divine": 6][level.lowercased()] ?? 0
    }

    /// Gather a team's score (0x81ad30): every player of the team adds its towns, battles,
    /// quests, resources and armies (map armies, town garrisons, adventure garrisons, the
    /// sanctuary's guests); the starting resources of the player difficulty are taken off once.
    public func scenarioScore(team winner: Int) -> ScenarioScore {
        var i = ScoreInputs()
        i.sizeClass = ScenarioScore.sizeClass(mapSize: map.size)
        i.levels = map.levels
        i.playerDifficulty = difficulty
        i.mapDifficulty = map.difficulty
        i.days = day - 1   // game +0xec counts from 0
        i.cheated = cheated
        let start = GameState.startingResources(difficulty: difficulty, computer: false)
        i.startResources = GameState.materialNames.map { start[$0] ?? 0 }
        var res = Array(repeating: 0, count: 7)
        var heroes: [Hero] = []
        var stacks: [(String, Int)] = []
        for c in playerColours where team(of: c) == winner {
            i.towns += towns.filter { townOwner($0) == c }.count
            i.battlePoints += battlePoints[c] ?? 0
            i.battlesWon += battlesWon[c] ?? 0
            i.quests += questsCompleted[c] ?? 0
            let r = c == map.humanColour ? resources : aiTreasury(c)
            for (k, m) in GameState.materialNames.enumerated() { res[k] += r[m] ?? 0 }
            for a in armies(of: c) { heroes += a.members; stacks += a.army.map { ($0.creature, $0.count) } }
            for t in towns where townOwner(t) == c {
                heroes += t.garrisonHeroes; stacks += t.garrison.map { ($0.creature, $0.count) }
            }
            for st in objectStates.values where st.isGarrison && st.garrisonOwner == c {
                stacks += zip(st.troopCreatures, st.troopCounts).map { ($0.0, $0.1) }
            }
            if c == map.humanColour { heroes += sanctuaryGuests.values.flatMap { $0.members } }
        }
        i.resources = res
        i.armyValue = stacks.reduce(0) { $0 + (tables?.creature($1.0)?.gold ?? 0) * $1.1 }
        for h in heroes {
            for a in h.equipped.compactMap({ $0 }) + h.backpack {
                let b = RuleTables.artifactBase(a)
                let def = b < RuleTables.artifactIds.count ? tables?.artifacts[RuleTables.artifactIds[b]] : nil
                i.artifactLevels.append(GameState.artifactLevelId(def?.level ?? ""))
            }
        }
        // the best hero: the highest level, the first of equals (hero +0x6a0)
        if let best = heroes.reduce(nil as Hero?, { b, h in b == nil || h.level > b!.level ? h : b }) {
            i.bestHero = (best.name, best.level); i.bestHeroPortrait = (best.keyword, best.alignment)
        }
        if team(of: map.humanColour) == winner { i.explored = exploredFraction() }
        return ScenarioScore.compute(i) { [tables] total in
            ScenarioScore.rank(score: total, scale: 1000) { id in tables?.creature(RuleTables.creatureIds[id])?.experience ?? 0 }
        }
    }

    /// The share of the map's tiles (every level, inside the diamond) the human has seen (0x4cdf40).
    public func exploredFraction() -> Double {
        var seen = 0, all = 0
        for l in 0..<map.levels {
            for x in 0..<map.size { for y in 0..<map.size where map.cells[l][x * map.size + y] != nil {
                all += 1
                if fogState(x, y, level: l) != GameState.fogUnexplored { seen += 1 }
            } }
        }
        return all == 0 ? 0 : Double(seen) / Double(all)
    }

    /// A battle won by `colour` (0x809d0c): one more win and its points (0x7e4940).
    public func recordBattleWin(colour: Int, winnerValue: Int, loserValue: Int) {
        battlesWon[colour, default: 0] += 1
        battlePoints[colour, default: 0] += ScenarioScore.battlePoints(winner: winnerValue, loser: loserValue, sizeClass: ScenarioScore.sizeClass(mapSize: map.size))
    }

    /// An army's value for the battle points (0x6411d0): Experience x count, 100 x (level + 1) a hero.
    public func armyValue(_ h: Hero) -> Int {
        ThievesGuild.armyValue(stacks: h.army.map { (experience: tables?.creature($0.creature)?.experience ?? 0, count: $0.count) },
                               heroLevels: h.members.map { $0.level })
    }
    func armyValue(_ stacks: [Hero.Stack]) -> Int {
        ThievesGuild.armyValue(stacks: stacks.map { (experience: tables?.creature($0.creature)?.experience ?? 0, count: $0.count) }, heroLevels: [])
    }
}

/// The high-score lists (t_high_scores, 0x7430a0 / 0x7413e0): ten standard and ten campaign
/// entries, best first; the file is `high_scores.dat`, gzip of u16 version 0 then the 20 entries
/// (i32 rank, then days, score, name, map as u16-length strings).
public struct HighScores: Equatable {
    public struct Entry: Equatable {
        public var rank: Int, days: String, score: String, name: String, map: String
        /// Just entered (+0x4c, not saved).
        public var isNew = false
        public init(rank: Int, days: String, score: String, name: String, map: String) {
            self.rank = rank; self.days = days; self.score = score; self.name = name; self.map = map
        }
    }
    public var standard: [Entry], campaign: [Entry]

    static let standardDays = [15, 22, 21, 37, 41, 29, 51, 44, 38, 55], standardScores = [294, 278, 249, 228, 215, 186, 177, 156, 130, 118]
    static let campaignDays = [23, 27, 29, 31, 51, 28, 31, 52, 12, 57], campaignScores = [1455, 1380, 1265, 1185, 1070, 975, 845, 765, 685, 555]

    /// The built-in lists (0x741b80): names and maps from the strings, ranks from the standard
    /// scores for both lists.
    public static func defaults(strings: [String: String], rank: (Int) -> Int) -> HighScores {
        var lower: [String: String] = [:]   // the table's keys mix cases ("Map_name_1.High_Score")
        for (k, v) in strings where k.lowercased().contains("high_score") { lower[k.lowercased()] = v }
        func s(_ k: String) -> String { lower[k.lowercased()] ?? "" }
        let ranks = standardScores.map(rank)
        let std = (0..<10).map { k in Entry(rank: ranks[k], days: "\(standardDays[k])", score: "\(standardScores[k])",
                                            name: s("player_name_\(k + 1).high_score"), map: s("map_name_\(k + 1).high_score")) }
        let camp = (0..<10).map { k in Entry(rank: ranks[k], days: "\(campaignDays[k])", score: "\(campaignScores[k])",
                                             name: s("player_name_campaign_\(k + 1).high_score"), map: s("campaign_name_\(k + 1).high_score")) }
        return HighScores(standard: std, campaign: camp)
    }

    /// Enter a result (0x7430a0): before the first entry it beats (a tie goes below), the last
    /// one drops off. The entry's index, or nil when it does not make the list.
    @discardableResult
    public mutating func insert(map: String, days: Int, score: Int, name: String, standard isStandard: Bool, rank: Int) -> Int? {
        var list = isStandard ? standard : campaign
        for k in list.indices { list[k].isNew = false }
        guard let i = list.firstIndex(where: { score > (Int($0.score) ?? 0) }) else { return nil }
        var e = Entry(rank: min(73, max(-1, rank)), days: "\(days)", score: "\(score)", name: name, map: map)
        e.isNew = true
        list.insert(e, at: i)
        list.removeLast(list.count - 10)
        if isStandard { standard = list } else { campaign = list }
        return i
    }

    // MARK: the file

    /// The lists in a file, else the built-in ones (a missing or unreadable file: the defaults).
    public static func load(_ url: URL, defaults: () -> HighScores) -> HighScores {
        (try? Data(contentsOf: url)).flatMap { decode($0) } ?? defaults()
    }
    /// Write the lists; false when that failed ("high_score_save_problem.misc").
    @discardableResult
    public func save(_ url: URL) -> Bool { (try? encoded().write(to: url)) != nil }

    public func encoded() -> Data {
        var d = Data([0, 0])
        func u16(_ v: Int) { d.append(UInt8(v & 255)); d.append(UInt8(v >> 8 & 255)) }
        func str(_ s: String) { let b = Array(s.data(using: .isoLatin1, allowLossyConversion: true) ?? Data()); u16(b.count); d.append(contentsOf: b) }
        for e in standard + campaign {
            let r = UInt32(bitPattern: Int32(e.rank))
            d.append(contentsOf: [UInt8(r & 255), UInt8(r >> 8 & 255), UInt8(r >> 16 & 255), UInt8(r >> 24 & 255)])
            str(e.days); str(e.score); str(e.name); str(e.map)
        }
        return HighScores.gzip(d)
    }

    public static func decode(_ file: Data) -> HighScores? {
        guard let raw = try? gunzip(file, expected: 4096) else { return nil }
        var r = ByteReader(raw)
        guard r.remaining >= 2, r.u16() == 0 else { return nil }
        var all: [Entry] = []
        for _ in 0..<20 {
            guard r.remaining >= 12 else { return nil }
            let rank = Int(Int32(bitPattern: r.u32()))
            let days = r.string16(), score = r.string16(), name = r.string16(), map = r.string16()
            all.append(Entry(rank: rank, days: days, score: score, name: name, map: map))
        }
        return HighScores(standard: Array(all[0..<10]), campaign: Array(all[10..<20]))
    }

    /// gzip (deflate + CRC-32 trailer), as the game's gzip'd filebuf writes it.
    static func gzip(_ data: Data) -> Data {
        var out = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff])
        let cap = data.count + 1024
        var buf = [UInt8](repeating: 0, count: cap)
        let n = data.withUnsafeBytes { src in
            compression_encode_buffer(&buf, cap, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        out.append(contentsOf: buf[0..<n])
        var crc: UInt32 = 0xffff_ffff
        for b in data {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
        }
        crc ^= 0xffff_ffff
        for v in [crc, UInt32(truncatingIfNeeded: data.count)] { out.append(contentsOf: [UInt8(v & 255), UInt8(v >> 8 & 255), UInt8(v >> 16 & 255), UInt8(v >> 24 & 255)]) }
        return out
    }
}
