import Foundation
import Metal
import H4Engine

/// The town screen on the 1024x768 canvas: the town view (layers.town.<alignment>.<terrain>,
/// a 1280x825 picture squashed into the frame's 800x568 window) with the built buildings from
/// layers.town.<alignment>.layout, the bottom bar from layers.town.1024 with the town name,
/// the dwellings to recruit from, the treasury, and a build list opened from the hall.
final class TownScreen {
    let archive: H4Archive
    let frame: LayerFile
    var views: [String: LayerFile] = [:]     // "life.grass"
    var layouts: [String: LayerFile] = [:]   // "life"
    var showBuildList = false
    var buildRows: [(rect: (Int, Int, Int, Int), building: RuleTables.BuildingDef)] = []

    /// The 1280x825 view is scaled to the canvas width (0.8); the bottom bar covers its lower part.
    static let viewW = 1024, viewH = 660, sourceW = 1280, sourceH = 825
    static let terrainNames: [UInt8: String] = [0: "grass", 1: "grass", 2: "rough", 3: "swamp", 4: "volcanic", 5: "snow", 6: "sand", 7: "dirt", 8: "subterranean"]

    init(archive: H4Archive) throws {
        self.archive = archive
        frame = try LayerFile(data: archive.payload("layers.town.1024.h4d"))
    }

    func view(_ alignment: String, _ terrain: UInt8) -> LayerFile? {
        let key = "\(alignment).\(TownScreen.terrainNames[terrain] ?? "grass")"
        if views[key] == nil, let d = try? archive.payload("layers.town.\(key).h4d") ?? archive.payload("layers.town.\(alignment).grass.h4d") { views[key] = try? LayerFile(data: d) }
        return views[key]
    }
    /// A building's animation (animation.town.<alignment>.<building>.h4d): a "base" image the
    /// size of the building's layer and frames placed on it; nil when the building has none.
    var animations: [String: Sprite?] = [:]
    func animation(_ alignment: String, _ building: String) -> Sprite? {
        let key = "\(alignment).\(building.lowercased())"
        if animations[key] == nil {
            animations[key] = .some((try? archive.payload("animation.town.\(key).h4d")).flatMap { try? Sprite(data: $0) })
        }
        return animations[key] ?? nil
    }
    func layout(_ alignment: String) -> LayerFile? {
        if layouts[alignment] == nil, let d = try? archive.payload("layers.town.\(alignment).layout.h4d") { layouts[alignment] = try? LayerFile(data: d) }
        return layouts[alignment]
    }

    /// Source (1280x825) rectangle -> canvas rectangle inside the frame's town window.
    static func place(_ l: UILayer) -> (x: Int, y: Int, w: Int, h: Int) {
        let sx = Float(viewW) / Float(sourceW), sy = Float(viewH) / Float(sourceH)
        return (Int(Float(l.x) * sx), Int(Float(l.y) * sy), max(1, Int(Float(l.width) * sx)), max(1, Int(Float(l.height) * sy)))
    }

    func hotspot(_ name: String) -> UILayer? { frame[name] }
    func hit(_ l: UILayer?, _ x: Float, _ y: Float) -> Bool {
        guard let l = l else { return false }
        return x >= Float(l.x) && x < Float(l.x + l.width) && y >= Float(l.y) && y < Float(l.y + l.height)
    }
}
