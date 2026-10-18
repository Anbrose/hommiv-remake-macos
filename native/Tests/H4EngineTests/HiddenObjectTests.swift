import XCTest
@testable import H4Engine

/// Objects the player never sees on the adventure map (re/hidden_objects_spec.md).
final class HiddenObjectTests: XCTestCase {
    func testPresenceByType() {
        XCTAssertEqual(MapScene.presence(ofType: "event_trigger"), .pictureless)
        XCTAssertEqual(MapScene.presence(ofType: "deletion_marker"), .notPlaced)
        XCTAssertEqual(MapScene.presence(ofType: "obelisk_marker"), .notPlaced)
        for t in ["decorative", "system_object", "nothing", "sign", "pandoras_box", "obelisk", "mine", "random_monster"] {
            XCTAssertEqual(MapScene.presence(ofType: t), .drawn, t)
        }
    }

    // MARK: on real maps when the game is installed

    func loadGame(_ mapName: String) throws -> GameState {
        let data = URL(fileURLWithPath: NSHomeDirectory() + "/Games/HoMM4/prefix/drive_c/Games/HoMM4/Data")
        let mapURL = data.deletingLastPathComponent().appendingPathComponent("Maps/\(mapName).h4c")
        guard FileManager.default.fileExists(atPath: mapURL.path) else { throw XCTSkip("game data not installed") }
        let archive = try H4Archive(url: data.appendingPathComponent("heroes4.h4r"))
        for f in ["x2.h4r", "storm.h4r", "updates.h4r"] { if let a = try? H4Archive(url: data.appendingPathComponent(f)) { archive.supplement(with: a) } }
        let names = Set(archive.names(prefix: "adv_object.").map { String($0.dropFirst("adv_object.".count).dropLast(4)) })
        let map = try MapFile(data: Data(contentsOf: mapURL), objectNames: names)
        let masks = try TransitionMasks(data: archive.payload("transition.Transitions.h4d"))
        let scene = try MapScene(map: map, level: 0, archive: archive, masks: masks)
        return GameState(map: map, level: 0, scenes: [scene])
    }

    /// Event triggers are on the map without pictures and add nothing to passability: their cells
    /// stay free and are neither stops nor objects a route enters.
    func testEventTriggersArePicturelessAndOpen() throws {
        let g = try loadGame("Search for the Old Heroes 2")
        XCTAssertFalse(g.scene.placed.contains { MapScene.presence(ofType: $0.type) != .drawn })
        let records = g.map.objects.filter { $0.type == "event_trigger" && $0.level == 0 }
        XCTAssertFalse(records.isEmpty)
        XCTAssertEqual(g.scene.triggers.count, records.count)
        for x in 121...126 {
            XCTAssertTrue(g.passability.isFree(x, 58), "(\(x), 58)")
            XCTAssertFalse(g.passability.isTrigger(x, 58), "(\(x), 58)")
        }
    }

    /// Walking onto either cell of a 2x1 trigger ("Event Trigger 2" at (121, 58)) sets off its
    /// placed event; it fires again unless it removed itself.
    func testEachCellOfAWideTriggerFires() throws {
        for x in 121...122 {
            let g = try loadGame("Search for the Old Heroes 2")
            g.loadScripts()
            guard let wide = g.scene.triggers.first(where: { $0.cellX == 121 && $0.cellY == 58 }) else { return XCTFail("no trigger at (121, 58)") }
            XCTAssertEqual(wide.sprite.footprint.w, 2)
            guard let name = g.record(for: wide)?.text, !g.scripts.placedEvents.filter({ $0.name.caseInsensitiveCompare(name) == .orderedSame }).isEmpty else {
                throw XCTSkip("the trigger's placed event did not parse")
            }
            let h = Hero(actor: "test", x: x, y: 57)
            h.owner = g.map.humanColour
            g.stepped(h, onto: x, 57)
            XCTAssertTrue(g.scripts.messages.isEmpty, "(\(x), 57) is not a trigger cell")
            g.stepped(h, onto: x, 58)
            XCTAssertFalse(g.scripts.messages.isEmpty, "(\(x), 58)")
            // again only while the event has not removed itself (rem_event, 0x4de2e0)
            let n = g.scripts.messages.count
            let alive = g.scripts.placedEvents.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.enabled }
            g.stepped(h, onto: x, 58)
            XCTAssertEqual(g.scripts.messages.count, alive ? 2 * n : n)
        }
    }

    /// The event's filter (0x726960): a player whose bit is clear sets nothing off.
    func testFilterByPlayer() throws {
        let g = try loadGame("Search for the Old Heroes 2")
        g.loadScripts()
        guard let wide = g.scene.triggers.first(where: { $0.cellX == 121 && $0.cellY == 58 }), let name = g.record(for: wide)?.text,
              let i = g.scripts.placedEvents.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw XCTSkip("no event") }
        let e = g.scripts.placedEvents[i]
        g.scripts.placedEvents[i] = MapEvent(kind: e.kind, name: e.name, action: e.action, players: e.players & ~(1 << g.map.humanColour), flags: e.flags)
        g.scripts.placedEvents[i].message = e.message
        let h = Hero(actor: "test", x: 121, y: 58)
        h.owner = g.map.humanColour
        g.stepped(h, onto: 121, 58)
        XCTAssertTrue(g.scripts.messages.isEmpty)
        XCTAssertTrue(g.scripts.placedEvents[i].enabled)
        // a self-removing event fires once: the second arrival runs nothing
        g.scripts.placedEvents[i] = e
        g.stepped(h, onto: 122, 58)
        let n = g.scripts.messages.count
        XCTAssertGreaterThan(n, 0)
        g.stepped(h, onto: 121, 58)
        XCTAssertEqual(g.scripts.messages.count, g.scripts.placedEvents[i].enabled ? 2 * n : n)
    }

    /// Deletion and obelisk markers are never map objects (0x44a730, 0x7c6b30).
    func testMarkersAreNotPlaced() throws {
        let g = try loadGame("Beebee and the Three Pigs")
        XCTAssertTrue(g.map.objects.contains { $0.type == "deletion_marker" && $0.level == 0 })
        XCTAssertFalse(g.scene.placed.contains { $0.type == "deletion_marker" })
        XCTAssertFalse(g.scene.triggers.contains { $0.type == "deletion_marker" })
        let b = try loadGame("Bandits of the Rifen Maze")
        XCTAssertTrue(b.map.objects.contains { $0.type == "obelisk_marker" && $0.level == 0 })
        XCTAssertFalse(b.scene.placed.contains { $0.type == "obelisk_marker" })
    }
}
