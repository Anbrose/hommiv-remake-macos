import AppKit
import H4Engine

/// The main menu and the screens before a game (campaign_spec §3): layers.menu.main.1024 over the
/// bitmap_raw background (New Game, Load Game, Quit); New Game's scroll menu (Scenarios, the three
/// campaign sets, Tutorial); the scenario list (layers.dialog.new_game); a set's campaign selection
/// (dialog.campaign_selection / storm_ / wow_); the campaign screen (layers.dialog.Campaign: the
/// scenario's 426x340 splash, its prologue as the voice-over text, Begin / Back) and the epilogue
/// (Campaign_Epilogue). A choice starts the game process again with the map or campaign scenario.
func runMainMenu(_ args: [String]) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = MenuAppDelegate(args: args)
    app.delegate = delegate
    app.run()
    exit(0)
}

final class MenuAppDelegate: NSObject, NSApplicationDelegate {
    let args: [String]
    var window: NSWindow?
    init(args: [String]) { self.args = args }
    func applicationDidFinishLaunching(_ n: Notification) {
        guard let view = try? MenuView(args: args) else { print("menu: cannot open the game data"); NSApp.terminate(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Heroes of Might and Magic IV"
        w.contentView = view
        w.contentAspectRatio = NSSize(width: 4, height: 3)
        w.center(); w.makeKeyAndOrderFront(nil)
        window = w
        if let out = ProcessInfo.processInfo.environment["H4MENUSNAP"] {   // snapshot: a menu screen ("scenarios", "campaigns:k", "briefing:id:i", "epilogue:id:i", "popup")
            let p = (ProcessInfo.processInfo.environment["H4MENUSCREEN"] ?? "").split(separator: ":").map(String.init)
            switch p.first {
            case "scenarios": view.openScenarios()
            case "campaigns": view.screen = .campaigns(set: Int(p[1]) ?? 0)
            case "briefing": view.screen = .briefing(id: Int(p[1]) ?? 1, index: Int(p[2]) ?? 0, carry: nil); view.briefingTab = Int(p.count > 3 ? p[3] : "2") ?? 2
            case "epilogue": view.screen = .epilogue(id: Int(p[1]) ?? 1, index: Int(p[2]) ?? 0, carry: nil)
            case "popup": view.clickMain(900, 130)
            default: break
            }
            view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            }
            exit(0)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

final class MenuView: NSView {
    enum Screen {
        case main
        case scenarios
        case campaigns(set: Int)
        case briefing(id: Int, index: Int, carry: String?)
        case epilogue(id: Int, index: Int, carry: String?)
        case load
    }
    let archivePath: String
    let archive: H4Archive
    let strings: [String: String]
    let font14: H4Font, font12: H4Font, font22: H4Font
    let sound: GameSound
    var screen: Screen = .main
    var popup: [(String, () -> Void)]? = nil
    var hover: (Float, Float) = (0, 0)
    var images: [String: CGImage] = [:]
    var layerFiles: [String: LayerFile] = [:]
    // the scenario list
    var maps: [(path: String, summary: MapSummary)] = []
    var scroll = 0, selected = 0
    var saves: [(name: String, date: Date)] = []
    var campaignCache: [Int: CampaignFile] = [:]

    init(args: [String]) throws {
        archivePath = args[1]
        let dir = URL(fileURLWithPath: args[1]).deletingLastPathComponent()
        archive = try H4Archive(url: URL(fileURLWithPath: args[1]))
        for f in ["x2.h4r", "storm.h4r", "updates.h4r"] { if let a = try? H4Archive(url: dir.appendingPathComponent(f)) { archive.supplement(with: a) } }
        // (the updates copies of the dialogs and campaigns come first)
        if let u = try? H4Archive(url: dir.appendingPathComponent("updates.h4r")) { overrides = u }
        strings = (try? H4Archive(url: dir.appendingPathComponent("text.h4r"))).flatMap { try? RuleTables(archive: $0) }?.strings ?? [:]
        font14 = try H4Font(data: archive.payload("font.Prose_Antique.14.h4d"))
        font12 = try H4Font(data: archive.payload("font.Prose_Antique.12.h4d"))
        font22 = (try? H4Font(data: archive.payload("font.Prose_Antique.22.h4d"))) ?? font14
        sound = GameSound(dataDirectory: dir)
        super.init(frame: NSRect(x: 0, y: 0, width: 1024, height: 768))
        // an epilogue / the next scenario after a won campaign scenario: "--menu --next <id> <index> [--carry file]"
        if let k = args.firstIndex(of: "--next"), k + 2 < args.count, let id = Int(args[k + 1]), let index = Int(args[k + 2]) {
            let carry = args.firstIndex(of: "--carry").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            screen = .epilogue(id: id, index: index, carry: carry)
        }
        sound.playMusic("main_menu")
    }
    required init?(coder: NSCoder) { fatalError() }
    var overrides: H4Archive?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: resources

    func payload(_ name: String) -> Data? {
        if let o = overrides, let d = try? o.payload(name) { return d }
        if let d = try? archive.payload(name) { return d }
        let low = name.lowercased()
        if let e = archive.entries.first(where: { $0.name.lowercased() == low }) { return try? archive.payload(e.name) }
        return nil
    }
    func layers(_ name: String) -> LayerFile? {
        if let l = layerFiles[name] { return l }
        let l = payload("layers.\(name).h4d").flatMap { try? LayerFile(data: $0) }
        layerFiles[name] = l
        return l
    }
    func image(_ key: String, _ bm: @autoclosure () -> Bitmap) -> CGImage? {
        if let i = images[key] { return i }
        let b = bm()
        guard b.width > 0, b.height > 0, let p = CGDataProvider(data: Data(b.pixels) as CFData),
              let i = CGImage(width: b.width, height: b.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: b.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: p, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        images[key] = i
        return i
    }
    /// bitmap_raw.menu.main.1024: u32 1, u32 height, u32 width, u32 size, then 24-bit pixels.
    lazy var background: CGImage? = {
        guard let d = payload("bitmap_raw.menu.main.1024.h4d"), d.count > 16 else { return nil }
        var r = ByteReader(d); _ = r.u32()
        let h = Int(r.u32()), w = Int(r.u32()); _ = r.u32()
        guard d.count >= 16 + w * h * 3 else { return nil }
        var b = Bitmap(width: w, height: h)
        d.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            for k in 0..<(w * h) {
                b.pixels[k * 4] = src[16 + k * 3]; b.pixels[k * 4 + 1] = src[16 + k * 3 + 1]; b.pixels[k * 4 + 2] = src[16 + k * 3 + 2]; b.pixels[k * 4 + 3] = 255
            }
        }
        return image("bg", b)
    }()
    func text(_ key: String, _ fallback: String) -> String { strings[key] ?? fallback }

    // MARK: drawing

    var ctx: CGContext?
    var origin = (0, 0)   // the current dialog's top-left on the 1024 x 768 canvas
    func draw(_ l: UILayer?, key: String) {
        guard let l = l, let c = ctx, let i = image(key, l.bitmap) else { return }
        c.saveGState(); c.translateBy(x: CGFloat(origin.0 + l.x), y: CGFloat(origin.1 + l.y + l.height)); c.scaleBy(x: 1, y: -1)
        c.draw(i, in: CGRect(x: 0, y: 0, width: l.width, height: l.height)); c.restoreGState()
    }
    func drawAll(_ f: LayerFile, key: String, skip: (String) -> Bool = { _ in false }) {
        for l in f.layers where l.isImage && !l.name.lowercased().hasSuffix("_pressed") && !l.name.lowercased().hasSuffix("_highlighted") && !l.name.lowercased().hasSuffix("_disabled") && !skip(l.name) {
            draw(l, key: "\(key)|\(l.name)")
        }
    }
    func label(_ s: String, in l: UILayer?, font: H4Font? = nil, colour: (UInt8, UInt8, UInt8) = (40, 24, 8), centre: Bool = true) {
        guard let l = l, !s.isEmpty else { return }
        let f = font ?? font14
        let w = f.measure(s)
        let bm = f.render(s, colour: colour)
        let x = centre ? l.x + (l.width - w) / 2 : l.x, y = l.y + (l.height - f.size) / 2
        draw(UILayer(name: "", kind: 1, x: x, y: y, width: bm.width, height: bm.height, bitmap: bm), key: "text|\(f.size)|\(colour.0)|\(s)")
    }
    func paragraph(_ s: String, in l: UILayer?, font: H4Font? = nil) {
        guard let l = l else { return }
        let f = font ?? font12
        for (k, line) in AdventureUI.wrap(s, font: f, width: l.width).enumerated() where k * f.lineHeight + f.size <= l.height {
            let bm = f.render(line, colour: (40, 24, 8))
            draw(UILayer(name: "", kind: 1, x: l.x, y: l.y + k * f.lineHeight, width: bm.width, height: bm.height, bitmap: bm), key: "text|\(f.size)|40|\(line)")
        }
    }
    func inside(_ l: UILayer?, _ x: Float, _ y: Float) -> Bool {
        guard let l = l else { return false }
        return x >= Float(origin.0 + l.x) && x < Float(origin.0 + l.x + l.width) && y >= Float(origin.1 + l.y) && y < Float(origin.1 + l.y + l.height)
    }
    func fill(_ r: CGRect, _ c: (CGFloat, CGFloat, CGFloat, CGFloat)) { ctx?.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: c.3); ctx?.fill(r) }

    override func draw(_ dirty: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.setFillColor(.black); c.fill(bounds)
        let s = min(bounds.width / 1024, bounds.height / 768)
        c.translateBy(x: (bounds.width - 1024 * s) / 2, y: (bounds.height - 768 * s) / 2); c.scaleBy(x: s, y: s)
        ctx = c
        origin = (0, 0)
        if let bg = background { c.saveGState(); c.translateBy(x: 0, y: 768); c.scaleBy(x: 1, y: -1); c.draw(bg, in: CGRect(x: 0, y: 0, width: 1024, height: 768)); c.restoreGState() }
        switch screen {
        case .main: drawMain()
        case .scenarios: drawScenarios()
        case .campaigns(let set): drawCampaigns(set)
        case .briefing(let id, let index, _): drawBriefing(id, index, epilogue: false)
        case .epilogue(let id, let index, _): drawBriefing(id, index, epilogue: true)
        case .load: drawLoad()
        }
        if let p = popup { drawPopup(p) }
        ctx = nil
    }
    var canvasScale: (s: CGFloat, dx: CGFloat, dy: CGFloat) {
        let s = min(bounds.width / 1024, bounds.height / 768)
        return (s, (bounds.width - 1024 * s) / 2, (bounds.height - 768 * s) / 2)
    }
    func canvasPoint(_ e: NSEvent) -> (Float, Float) {
        let p = convert(e.locationInWindow, from: nil), t = canvasScale
        return (Float((p.x - t.dx) / t.s), Float((p.y - t.dy) / t.s))
    }

    // MARK: the main menu

    let mainButtons = ["New_Game", "Load_Game", "Options", "Network", "Quit"]
    func drawMain() {
        guard let f = layers("menu.main.1024") else { return }
        origin = (0, 0)
        draw(f["Background"], key: "mm|bg")
        draw(f["Copywright_Text"], key: "mm|copy")
        for b in mainButtons {
            let hot = inside(f["\(b)_Released"], hover.0, hover.1) && popup == nil && (b == "New_Game" || b == "Load_Game" || b == "Quit")
            draw(f["\(b)_\(hot ? "Highlighted" : "Released")"], key: "mm|\(b)|\(hot)")
            // the label in the button's scroll (new_game.main_menu, ...)
            let key = ["New_Game": "new_game", "Load_Game": "load_game", "Options": "options", "Network": "multiplayer", "Quit": "quit"][b] ?? b
            let enabled = b == "New_Game" || b == "Load_Game" || b == "Quit"
            label(text("\(key).main_menu", b.replacingOccurrences(of: "_", with: " ")), in: f["\(b)_Text"], font: font22, colour: enabled ? (40, 24, 8) : (120, 100, 80))
        }
    }
    func clickMain(_ x: Float, _ y: Float) {
        guard let f = layers("menu.main.1024") else { return }
        if inside(f["New_Game_Released"], x, y) {
            var items: [(String, () -> Void)] = [(text("main_menu_scenario.misc", "Scenarios"), { [weak self] in self?.openScenarios() })]
            for (k, key, fb) in [(0, "storm_new_campaign_original", "Heroes IV Campaigns"), (1, "storm_new_campaign_storm", "Gathering Storm Campaigns"), (2, "new_campaign_x2", "Winds of War Campaigns")] {
                items.append((strings["\(key).misc"] ?? strings[key] ?? fb, { [weak self] in self?.screen = .campaigns(set: k) }))
            }
            items.append((text("main_menu_tutorial.misc", "Tutorial"), { [weak self] in self?.start(["campaign:0:0"]) }))
            popup = items
        } else if inside(f["Load_Game_Released"], x, y) {
            saves = Renderer.savedGames(); scroll = 0; selected = 0; screen = .load
        } else if inside(f["Quit_Released"], x, y) { NSApp.terminate(nil) }
    }
    /// The scroll menu (layers.dialog.scroll_menu): the top bar, a parchment row per entry, the bottom.
    func drawPopup(_ items: [(String, () -> Void)]) {
        guard let f = layers("dialog.scroll_menu"), let top = f["top_bar"], let parch = f["parchment"], let bottom = f["bottom_border"] else { return }
        let rowH = 30
        origin = (560, 60)
        draw(top, key: "sm|top")
        for (k, item) in items.enumerated() {
            let y = top.height + k * rowH
            draw(UILayer(name: "", kind: 4, x: parch.x, y: y, width: parch.width, height: rowH, bitmap: crop(parch.bitmap, height: rowH)), key: "sm|row")
            let r = UILayer(name: "", kind: 1, x: parch.x, y: y, width: parch.width, height: rowH, bitmap: Bitmap(width: 1, height: 1))
            let hot = inside(r, hover.0, hover.1)
            label(item.0, in: r, colour: hot ? (150, 30, 10) : (40, 24, 8))
        }
        draw(UILayer(name: "", kind: 4, x: bottom.x, y: top.height + items.count * rowH, width: bottom.width, height: bottom.height, bitmap: bottom.bitmap), key: "sm|bottom")
    }
    func crop(_ b: Bitmap, height h: Int) -> Bitmap {
        var o = Bitmap(width: b.width, height: min(h, b.height))
        for k in 0..<(o.width * o.height * 4) { o.pixels[k] = b.pixels[k] }
        return o
    }
    func clickPopup(_ items: [(String, () -> Void)], _ x: Float, _ y: Float) {
        guard let f = layers("dialog.scroll_menu"), let top = f["top_bar"], let parch = f["parchment"] else { popup = nil; return }
        origin = (560, 60)
        for (k, item) in items.enumerated() {
            let r = UILayer(name: "", kind: 1, x: parch.x, y: top.height + k * 30, width: parch.width, height: 30, bitmap: Bitmap(width: 1, height: 1))
            if inside(r, x, y) { popup = nil; item.1(); return }
        }
        popup = nil
    }

    // MARK: the scenario list

    var mapsDir: URL { URL(fileURLWithPath: archivePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("maps") }
    func openScenarios() {
        if maps.isEmpty {
            let files = (try? FileManager.default.contentsOfDirectory(at: mapsDir, includingPropertiesForKeys: nil)) ?? []
            maps = files.filter { $0.pathExtension.lowercased() == "h4c" }.compactMap { u in
                (try? Data(contentsOf: u)).flatMap { MapSummary(data: $0) }.map { (u.path, $0) }
            }.sorted { $0.summary.name.lowercased() < $1.summary.name.lowercased() }
        }
        scroll = 0; selected = 0
        screen = .scenarios
    }
    var dialogOrigin: (Int, Int) { ((1024 - 800) / 2, (768 - 600) / 2) }
    func drawScenarios() {
        guard let f = layers("dialog.new_game") else { return }
        origin = dialogOrigin
        drawAll(f, key: "ng", skip: { ["Choose_File_Grid", "line_width", "column_width", "Description", "Description_Box"].contains($0) || $0.hasPrefix("Map_") && !$0.hasPrefix("Map_Type") })
        label(text("scenario_name.new_game", "Scenario Name"), in: f["Map_Title"], centre: false)
        // (a map's size in the file is 38 cells a step: small 38 ... gigantic 266)
        let sizes = ["S", "M", "L", "XL", "H", "XH", "G"]
        for row in 0..<10 {
            let k = scroll + row
            guard k < maps.count, let slot = f["Map_\(row + 1)"] else { continue }
            let m = maps[k].summary
            if k == selected { fill(CGRect(x: origin.0 + 27, y: origin.1 + slot.y, width: 716, height: slot.height), (0.95, 0.8, 0.4, 0.5)) }
            label(m.name, in: slot, font: font12, centre: false)
            func col(_ s: String, _ x0: Int, _ x1: Int) { label(s, in: UILayer(name: "", kind: 1, x: x0, y: slot.y, width: x1 - x0, height: slot.height, bitmap: Bitmap(width: 1, height: 1)), font: font12) }
            col(sizes[max(0, min(6, (m.size + 19) / 38 - 1))], 355, 420)
            col(["Easy", "Normal", "Hard", "Expert", "Impossible"][min(4, max(0, m.difficulty))], 425, 485)
            col("\(m.players)", 494, 542); col("\(m.humans)", 558, 605); col("\(m.scenarios)", 687, 740)
        }
        if selected < maps.count { paragraph(maps[selected].summary.description, in: f["Description"]) }
        label(text("back.new_game", "Back"), in: f["Back_Button"], font: font14)
        label(text("begin.new_game", "Begin"), in: f["Begin_Button"], font: font14)
    }
    func clickScenarios(_ x: Float, _ y: Float) {
        guard let f = layers("dialog.new_game") else { return }
        origin = dialogOrigin
        for row in 0..<10 where inside(f["Map_\(row + 1)"], x, y) || (inside(f["line_width"].map { UILayer(name: "", kind: 1, x: $0.x, y: f["Map_\(row + 1)"]?.y ?? 0, width: $0.width, height: $0.height, bitmap: $0.bitmap) }, x, y)) {
            if scroll + row < maps.count { selected = scroll + row }
            return
        }
        if inside(f["Scrollbar"], x, y) { scroll = max(0, min(max(0, maps.count - 10), scroll + (y < Float(origin.1 + 209) ? -10 : 10))); return }
        if inside(f["Back_Button"], x, y) { screen = .main; return }
        if inside(f["Begin_Button"], x, y), selected < maps.count { start([maps[selected].path]) }
    }

    // MARK: campaigns

    /// A set's six campaigns in button order, their 192x154 buttons and the layout.
    func campaignSet(_ set: Int) -> (layout: String, buttons: [String], faces: [String]) {
        switch set {
        case 1: return ("dialog.storm_campaign_Selection", (0..<6).map { "Campaign_\($0)" }, ["Campaign1A", "Campaign2A", "Campaign3A", "Campaign4A", "Campaign5A", "Campaign6A"])
        case 2: return ("dialog.wow_campaign_Selection", (0..<6).map { "Campaign_\($0)" }, ["SpazzA", "MongoA", "MysterioA", "ErutanA", "TarkinA", "WoWPro"])
        default: return ("dialog.campaign_Selection", ["Life_Campaign", "Might_Campaign", "Order_Campaign", "Nature_Campaign", "Death_Campaign", "Chaos_Campaign"],
                         ["Life_Intro", "Might_Intro", "Order_Intro", "Nature_Intro", "Death_Intro", "Chaos_Intro"])
        }
    }
    func drawCampaigns(_ set: Int) {
        let s = campaignSet(set)
        guard let f = layers(s.layout) else { return }
        origin = dialogOrigin
        drawAll(f, key: "cs\(set)", skip: { $0 == "Completed" })
        label(text("title.campaign_selection", "Campaign Selection"), in: f["Title"], font: font22)
        for (k, b) in s.buttons.enumerated() {
            guard let slot = f[b] ?? f["Campaign_\(k)"], let face = layers("Campaign_Splashscreens.192x154.\(s.faces[k])")?.layers.first(where: { $0.isImage }) else { continue }
            draw(UILayer(name: "", kind: 4, x: slot.x, y: slot.y, width: face.width, height: face.height, bitmap: face.bitmap), key: "face|\(s.faces[k])")
            if inside(slot, hover.0, hover.1), let c = campaign(CampaignFile.sets[set][k]) {
                label(c.name, in: UILayer(name: "", kind: 1, x: slot.x - 20, y: slot.y + slot.height + 2, width: slot.width + 40, height: 18, bitmap: Bitmap(width: 1, height: 1)), font: font14)
            }
        }
        label(text("cancel", "Cancel"), in: f["Cancel_Button"], font: font12)
    }
    func campaign(_ id: Int) -> CampaignFile? {
        if let c = campaignCache[id] { return c }
        let c = try? CampaignFile.load(id, from: archive)
        campaignCache[id] = c
        return c
    }
    func clickCampaigns(_ set: Int, _ x: Float, _ y: Float) {
        let s = campaignSet(set)
        guard let f = layers(s.layout) else { return }
        origin = dialogOrigin
        for (k, b) in s.buttons.enumerated() where inside(f[b] ?? f["Campaign_\(k)"], x, y) {
            screen = .briefing(id: CampaignFile.sets[set][k], index: 0, carry: nil); return
        }
        if inside(f["Cancel_Button"], x, y) { screen = .main }
    }
    func scenarioMap(_ id: Int, _ index: Int) -> MapFile? {
        guard let c = campaign(id), index < c.count, let d = try? c.scenario(index) else { return nil }
        return try? MapFile(data: d, objectNames: [])
    }
    var voicePlaying: String?
    /// The campaign screen: the scenario's splash and prologue (or, after a win, the last one's
    /// epilogue), its title; the tabs' text (campaign, scenario, details); Begin / Back (Next).
    func drawBriefing(_ id: Int, _ index: Int, epilogue: Bool) {
        guard let f = layers(epilogue ? "dialog.Campaign_Epilogue" : "dialog.Campaign"), let m = scenarioMap(id, index) else { return }
        origin = epilogue ? ((1024 - 800) / 2, (768 - 456) / 2) : dialogOrigin
        drawAll(f, key: epilogue ? "ce" : "cb", skip: { n in
            let l = n.lowercased()
            return l.hasPrefix("tab_") || l.hasPrefix("creature_guard") || l.hasPrefix("pause") || l.hasPrefix("play") || l == "all" || l == "map_size" || l == "title_background"
        })
        let cut = epilogue ? m.epilogue : m.prologue
        if let name = cut?.image, !name.isEmpty, let pic = layers("Campaign_Splashscreens.426x340.\(name)")?.layers.first(where: { $0.isImage }), let slot = f["Picture"] {
            draw(UILayer(name: "", kind: 4, x: slot.x, y: slot.y, width: pic.width, height: pic.height, bitmap: pic.bitmap), key: "splash|\(name)")
        }
        draw(f["Title_Background"], key: "\(epilogue ? "ce" : "cb")|titlebg")   // (over the picture's top)
        label(epilogue ? m.name : "\(campaign(id)?.name ?? ""): \(m.name)", in: f["Title"], font: font14)
        paragraph(cut?.text ?? "", in: f["Voice_Text"])
        if epilogue {
            label(text("next", "Next"), in: f["Next"], font: font14)
        } else {
            for (k, t) in [(1, text("campaign_info.campaign", "Campaign")), (2, text("scenario_info.campaign", "Scenario")), (3, text("scenario_details.campaign", "Details"))] {
                draw(f["Tab_\(k)_\(briefingTab == k ? "Pressed" : "Released")"], key: "cb|tab\(k)|\(briefingTab == k)")
                label(t, in: f[["Campaign", "Map", "Details"][k - 1]], font: font12)
            }
            let body: String
            switch briefingTab {
            case 1: body = campaign(id)?.description ?? ""
            case 2: body = m.description
            default:
                body = [("\(text("win_condition.campaign", "Victory Condition")):   ", m.victoryText ?? text("default_victory_condition", "Defeat all enemies.")),
                        ("\(text("loss_condition.campaign", "Loss Condition")):   ", m.lossText ?? text("default_loss_condition", "Lose all towns and armies.")),
                        ("\(text("carryover.campaign", "Carryover")):   ", m.carryoverText)].filter { !$0.1.isEmpty }.map { $0.0 + $0.1 }.joined(separator: "\n\n")
            }
            for (k, part) in body.components(separatedBy: "\n\n").enumerated() where k < 3 {
                let slot = f["Campaign_Description"].map { UILayer(name: "", kind: 1, x: $0.x, y: $0.y + k * 44, width: $0.width, height: k == 0 && !body.contains("\n\n") ? $0.height : 44, bitmap: $0.bitmap) }
                paragraph(part, in: slot)
            }
            label(["Easy", "Normal", "Hard", "Expert", "Impossible"][difficulty], in: f["Player_difficulty_Text"], font: font14)
            label(text("begin_campaign", "Begin"), in: f["Begin"], font: font14)
            label(text("back", "Back"), in: f["Back"], font: font14)
        }
        let voice = cut?.voice ?? ""
        if !voice.isEmpty, voicePlaying != "\(id)|\(index)|\(epilogue)" {
            voicePlaying = "\(id)|\(index)|\(epilogue)"
            _ = sound.play("Voice_Over.\(voice)")
        }
    }
    var briefingTab = 2
    var difficulty = 1
    func clickBriefing(_ id: Int, _ index: Int, carry: String?, epilogue: Bool, _ x: Float, _ y: Float) {
        guard let f = layers(epilogue ? "dialog.Campaign_Epilogue" : "dialog.Campaign") else { return }
        origin = epilogue ? ((1024 - 800) / 2, (768 - 456) / 2) : dialogOrigin
        if epilogue {
            guard inside(f["Next"], x, y) else { return }
            if let c = campaign(id), index + 1 < c.count { screen = .briefing(id: id, index: index + 1, carry: carry) }
            else { screen = .main }   // the campaign is won
            return
        }
        for k in 1...3 where inside(f["Tab_\(k)_Released"], x, y) { briefingTab = k; return }
        if inside(f["Left_Released"], x, y) { difficulty = max(0, difficulty - 1); return }
        if inside(f["Right_Released"], x, y) { difficulty = min(4, difficulty + 1); return }
        if inside(f["Back"], x, y) { screen = .main; return }
        if inside(f["Begin"], x, y) { start(["campaign:\(id):\(index)"] + (carry.map { ["--carry", $0] } ?? [])) }
    }

    // MARK: load

    func drawLoad() {
        guard let f = layers("dialog.load_game") else { return }
        origin = ((1024 - 799) / 2, (768 - 598) / 2)
        drawAll(f, key: "lg")
        label(text("load_game.dialog", "Load Game"), in: f["title"], font: font22)
        for row in 0..<11 {
            let k = scroll + row
            guard k < saves.count, let slot = f[String(format: "line %02d", row + 1)] else { continue }
            if k == selected { fill(CGRect(x: origin.0 + slot.x, y: origin.1 + slot.y, width: slot.width, height: slot.height), (0.95, 0.8, 0.4, 0.5)) }
            label(saves[k].name, in: slot, font: font12, centre: false)
        }
        label(text("load", "Load"), in: f["load_location"], font: font14)
        label(text("cancel", "Cancel"), in: f["cancel_location"], font: font14)
    }
    func clickLoad(_ x: Float, _ y: Float) {
        guard let f = layers("dialog.load_game") else { return }
        origin = ((1024 - 799) / 2, (768 - 598) / 2)
        for row in 0..<11 where inside(f[String(format: "line %02d", row + 1)], x, y) { if scroll + row < saves.count { selected = scroll + row }; return }
        if inside(f["cancel_location"], x, y) { screen = .main; return }
        if inside(f["load_location"], x, y), selected < saves.count {
            let file = Renderer.savesDirectory.appendingPathComponent("\(saves[selected].name).h4s")
            if let s = try? SaveGame.read(file) { start([s.mapPath, "--load", file.path]) }
        }
    }

    // MARK: input and starting the game

    override func mouseMoved(with e: NSEvent) { hover = canvasPoint(e); needsDisplay = true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseUp(with e: NSEvent) {
        let (x, y) = canvasPoint(e)
        defer { needsDisplay = true }
        if let p = popup { clickPopup(p, x, y); return }
        switch screen {
        case .main: clickMain(x, y)
        case .scenarios: clickScenarios(x, y)
        case .campaigns(let set): clickCampaigns(set, x, y)
        case .briefing(let id, let index, let carry): clickBriefing(id, index, carry: carry, epilogue: false, x, y)
        case .epilogue(let id, let index, let carry): clickBriefing(id, index, carry: carry, epilogue: true, x, y)
        case .load: clickLoad(x, y)
        }
    }
    override func scrollWheel(with e: NSEvent) {
        guard abs(e.scrollingDeltaY) > 1 else { return }
        let n = { () -> Int in if case .load = self.screen { return self.saves.count }; return self.maps.count }()
        scroll = max(0, min(max(0, n - 10), scroll + (e.scrollingDeltaY < 0 ? 1 : -1)))
        needsDisplay = true
    }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { popup = nil; screen = .main; needsDisplay = true }   // Esc
    }
    /// Start the game process on a map (or a campaign scenario "campaign:<id>:<index>").
    func start(_ gameArgs: [String]) {
        let app = Bundle.main.bundleURL
        let all = [archivePath] + gameArgs
        if app.pathExtension == "app" {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.arguments = all; cfg.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: app, configuration: cfg) { _, _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
        } else {
            let p = Process(); p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); p.arguments = all
            try? p.run(); NSApp.terminate(nil)
        }
    }
}
