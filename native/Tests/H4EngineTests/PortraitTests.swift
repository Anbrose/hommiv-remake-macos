import XCTest
@testable import H4Engine

/// Hero portraits (RuleTables.heroPortraits, HeroPortraits): every hero the game can put on a map
/// has an image, looked up as heroes4.exe does (portrait id table 0x989ad8, archive order 0x73bec0).
final class PortraitTests: XCTestCase {
    static let dataDir = URL(fileURLWithPath: NSHomeDirectory() + "/Games/HoMM4/prefix/drive_c/Games/HoMM4/Data")

    struct Game { let resources: H4Archive; let tables: RuleTables; let portraits: HeroPortraits }
    static let game: Game? = {
        guard let r = H4Archive.gameResources(dataDirectory: dataDir), r.byName["layers.icons.hero.life.52.h4d"] != nil,
              let text = try? H4Archive(url: dataDir.appendingPathComponent("text.h4r")), let t = try? RuleTables(archive: text) else { return nil }
        return Game(resources: r, tables: t, portraits: HeroPortraits(resources: r))
    }()
    func game() throws -> Game {
        guard let g = Self.game else { throw XCTSkip("game data not installed") }
        return g
    }

    func testArchiveOrderPutsTheExpansionsFirst() throws {
        let g = try game()
        // x2.h4r's sheet (Winds of War's heroes added) wins over heroes4.h4r's
        let x2 = try H4Archive(url: Self.dataDir.appendingPathComponent("x2.h4r"))
        XCTAssertEqual(try g.resources.payload("layers.icons.hero.chaos.52.h4d"), try x2.payload("layers.icons.hero.chaos.52.h4d"))
    }

    func testEveryPortraitIdHasBothSizes() throws {
        let g = try game()
        XCTAssertEqual(RuleTables.heroPortraits.count, 0x138)
        XCTAssertEqual(RuleTables.portraitId("aidan"), 0)
        XCTAssertEqual(RuleTables.portraitId("dead"), 97)
        XCTAssertEqual(RuleTables.portraitId("mysterio_the_magnificent"), 311)
        for (id, p) in RuleTables.heroPortraits.enumerated() {
            XCTAssertEqual(g.portraits.image(id: id, size: 52)?.width, 52, "\(id) \(p.keyword) 52")
            XCTAssertEqual(g.portraits.image(id: id, size: 82)?.width, 82, "\(id) \(p.keyword) 82")
        }
    }

    func testEveryClassedHeroRowHasAPortrait() throws {
        let g = try game()
        for h in g.tables.heroes where h.heroClass != "generic" {
            XCTAssertNotNil(h.portrait, "\(h.keyword) has no portrait id")
        }
    }

    /// Every hero of every map (the maps folder and the campaigns' scenarios): placed armies'
    /// heroes, prisoners and town garrisons, made as the game makes them, has a portrait.
    func testEveryMapHeroResolvesToAPortrait() throws {
        let g = try game()
        let objectNames = Set(g.resources.names(prefix: "adv_object.").map { String($0.dropFirst("adv_object.".count).dropLast(4)) })
        var maps: [(String, Data)] = []
        let mapsDir = Self.dataDir.deletingLastPathComponent().appendingPathComponent("maps")
        if let e = FileManager.default.enumerator(at: mapsDir, includingPropertiesForKeys: nil) {
            for case let u as URL in e where u.pathExtension.lowercased() == "h4c" { maps.append((u.lastPathComponent, try Data(contentsOf: u))) }
        }
        for id in CampaignFile.resources.keys.sorted() {
            guard let c = try? CampaignFile.load(id, from: g.resources) else { XCTAssertEqual(id, 0, "campaign \(id) missing"); continue }   // (the tutorial is no campaign file)
            for k in 0..<c.count { maps.append(("campaign \(id):\(k)", try c.scenario(k))) }
        }
        XCTAssertGreaterThan(maps.count, 80)
        // the maps' heroes, read in parallel (the reader is slow in debug builds)
        var found = [[MapHero]?](repeating: nil, count: maps.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: maps.count) { i in
            let m = try? MapFile(data: maps[i].1, objectNames: objectNames)
            let hs = m.map { $0.objects.flatMap { o in o.heroes + (o.prisoner.map { [$0] } ?? []) + (o.town?.garrisonHeroes ?? []) } }
            lock.lock(); found[i] = hs; lock.unlock()
        }
        var heroes = 0, withPortrait = 0, unread: [String] = []
        for ((name, _), list) in zip(maps, found) {
            // (a few maps the remake's reader does not take yet; they are listed, not portrait failures)
            guard let all = list else { unread.append(name); continue }
            for mh in all {
                heroes += 1
                if mh.portrait >= 0 { withPortrait += 1 }
                // the reader rejects ids outside the table (0x72f5b5)
                XCTAssertTrue((-1..<RuleTables.heroPortraits.count).contains(mh.portrait), "\(name): portrait \(mh.portrait)")
                for seed: UInt32 in [1, 2] {
                    var rng = H4Random(seed: seed)
                    let alignment = ["life", "order", "death", "chaos", "nature", "might"][Int(seed) % 6]
                    let h = Hero.fromMap(mh, alignment: alignment, x: 0, y: 0, tables: g.tables, random: &rng)
                    XCTAssertNotNil(g.portraits.image(keyword: h.keyword, alignment: h.alignment, size: 52), "\(name): '\(h.name)' (portrait \(mh.portrait), keyword '\(h.keyword)') 52")
                    XCTAssertNotNil(g.portraits.image(keyword: h.keyword, alignment: h.alignment, size: 82), "\(name): '\(h.name)' (portrait \(mh.portrait), keyword '\(h.keyword)') 82")
                    if mh.portrait >= 0 { XCTAssertEqual(RuleTables.portraitId(h.keyword), mh.portrait, "\(name): \(h.name)") }
                }
            }
        }
        XCTAssertLessThanOrEqual(unread.count, 10, "unread maps: \(unread)")
        XCTAssertGreaterThan(heroes, 100)
        XCTAssertGreaterThan(withPortrait, 10)
    }

    func testRandomHeroesOfEveryClassAndGenderHaveAPortrait() throws {
        let g = try game()
        for c in 0..<RuleTables.heroClasses.count { for gender in [0, 1] { for seed: UInt32 in 1...8 {
            var mh = MapHero(); mh.heroClass = c; mh.gender = gender
            var rng = H4Random(seed: seed)
            let h = Hero.fromMap(mh, alignment: RuleTables.heroClasses[c].alignment, x: 0, y: 0, tables: g.tables, random: &rng)
            XCTAssertNotNil(g.portraits.image(keyword: h.keyword, alignment: h.alignment), "class \(c) gender \(gender): '\(h.keyword)'")
        } } }
    }
}
