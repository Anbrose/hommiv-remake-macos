import AppKit
import H4Engine

/// The main menu and the screens before a game (campaign_spec §3, menus_spec parts A-C): the
/// bitmap_raw background (the Winds of War copy) under layers.menu.main.1024's five layout-image
/// buttons with their labels in the `_Text` rects; New Game's and Options' scroll menus; the
/// scenario list (dialog.new_game), New_Game_Options, the campaign selection (campaign_selection /
/// storm_ / wow_), the campaign briefing (dialog.Campaign) and epilogue (Campaign_Epilogue), Load
/// Game and Game Settings. A choice starts the game process again with the map or campaign scenario.
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
        // snapshot: a menu screen ("popup", "options", "settings", "load", "scenarios", "setup[:map]",
        // "campaigns:k", "briefing:id:i[:tab]", "epilogue:id:i", "hover:<button>")
        if let out = ProcessInfo.processInfo.environment["H4MENUSNAP"] {
            view.snapshotting = true
            view.open(ProcessInfo.processInfo.environment["H4MENUSCREEN"] ?? "")
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
        case setup(path: String)
    }
    /// The new-game options (layers.dialog.New_Game_Options): the players, who is human, their
    /// alignments, the difficulty, whether wandering stacks move.
    struct Setup { var map: MapFile; var human: Int; var align: [Int: Int] = [:]; var difficulty = 1; var guardsMove = true }
    /// An open scroll menu: its entries, the clicked button's top-left, when it opened.
    struct Popup { var items: [(String, () -> Void)]; var x: Int, y: Int; var opened = Date() }
    var setup: Setup?
    let archivePath: String
    let archive: H4Archive
    let strings: [String: String]
    let kit: MenuKit
    let sound: GameSound
    var screen: Screen = .main { didSet { screenOpened = Date() } }
    var screenOpened = Date()
    var popup: Popup? = nil
    var options: GameSettings? = nil
    var hover: (Float, Float) = (-1, -1)
    var pressedAt: (Float, Float)? = nil
    var snapshotting = false
    var images: [String: CGImage] = [:]
    var timer: Timer?
    // the scenario list
    var maps: [(path: String, summary: MapSummary)] = []
    var scroll = 0, selected = 0
    var saves: [(name: String, date: Date)] = []
    var campaignCache: [Int: CampaignFile] = [:]

    init(args: [String]) throws {
        archivePath = args[1]
        let dir = URL(fileURLWithPath: args[1]).deletingLastPathComponent()
        archive = try H4Archive(url: URL(fileURLWithPath: args[1]))
        var extra: [H4Archive] = []
        for f in ["updates.h4r", "x2.h4r", "storm.h4r"] { if let a = try? H4Archive(url: dir.appendingPathComponent(f)) { extra.append(a) } }
        for a in extra.reversed() { archive.supplement(with: a) }
        let texts = (try? H4Archive(url: dir.appendingPathComponent("text.h4r"))).flatMap { try? RuleTables(archive: $0) }?.strings ?? [:]
        strings = texts
        kit = MenuKit(archives: extra + [archive], strings: { texts })
        sound = GameSound(dataDirectory: dir)
        super.init(frame: NSRect(x: 0, y: 0, width: 1024, height: 768))
        // an epilogue / the next scenario after a won campaign scenario: "--menu --next <id> <index> [--carry file]"
        if let k = args.firstIndex(of: "--next"), k + 2 < args.count, let id = Int(args[k + 1]), let index = Int(args[k + 2]) {
            let carry = args.firstIndex(of: "--carry").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            screen = .epilogue(id: id, index: index, carry: carry)
        }
        // the adventure System Menu's New Scenario / New Campaign: "--menu --screen <scenarios|campaigns:k>"
        if let k = args.firstIndex(of: "--screen"), k + 1 < args.count { open(args[k + 1]) }
        sound.playMusic("main_menu")
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Open a screen by name (the snapshot names and --screen).
    func open(_ name: String) {
        let p = name.split(separator: ":").map(String.init)
        switch p.first {
        case "scenarios": openScenarios()
        case "campaigns": screen = .campaigns(set: Int(p.count > 1 ? p[1] : "0") ?? 0)
        case "briefing": screen = .briefing(id: Int(p[1]) ?? 1, index: Int(p[2]) ?? 0, carry: nil); if p.count > 3 { briefingTab = Int(p[3]) ?? 3 }
        case "epilogue": screen = .epilogue(id: Int(p[1]) ?? 1, index: Int(p[2]) ?? 0, carry: nil)
        case "popup": openNewGameMenu()
        case "options": openOptionsMenu()
        case "settings": options = GameSettings.load()
        case "load": saves = Renderer.savedGames(); scroll = 0; selected = 0; screen = .load
        case "hover": if let l = MenuKit.find(kit.file("menu.main.1024"), "\(p.count > 1 ? p[1] : "New_Game")_Released") { hover = (Float(l.x + l.width / 2), Float(l.y + l.height / 2)) }
        case "setup":
            let H = URL(fileURLWithPath: archivePath).deletingLastPathComponent().deletingLastPathComponent().path
            let path = "\(H)/maps/\(p.count > 1 ? p[1] : "Barbarians from Below").h4c"
            if let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let m = try? MapFile(data: d, objectNames: []) { setup = Setup(map: m, human: m.humanColour); screen = .setup(path: path) }
        default: break
        }
    }
    /// Redraw while something moves (the scroll menu unrolling, the voice text scrolling, the caret).
    func tick() {
        if popup != nil { needsDisplay = true; return }
        switch screen {
        case .briefing, .epilogue: needsDisplay = true
        default: break
        }
    }

    // MARK: resources and drawing

    func text(_ key: String, _ fallback: String) -> String { strings[key] ?? fallback }
    func layers(_ name: String) -> LayerFile? { kit.file(name) }
    func image(_ key: String, _ bm: () -> Bitmap) -> CGImage? {
        if let i = images[key] { return i }
        let b = bm()
        guard b.width > 0, b.height > 0, let p = CGDataProvider(data: Data(b.pixels) as CFData),
              let i = CGImage(width: b.width, height: b.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: b.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: p, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        images[key] = i
        return i
    }
    /// bitmap_raw.menu.main.1024 (the x2 copy wins): u32 1, u32 height, u32 width, u32 size, then 24-bit BGR pixels.
    lazy var background: CGImage? = {
        guard let d = kit.payload("bitmap_raw.menu.main.1024.h4d"), d.count > 16 else { return nil }
        var r = ByteReader(d); _ = r.u32()
        let h = Int(r.u32()), w = Int(r.u32()); _ = r.u32()
        guard d.count >= 16 + w * h * 3 else { return nil }
        var b = Bitmap(width: w, height: h)
        d.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            for k in 0..<(w * h) {
                b.pixels[k * 4] = src[16 + k * 3]; b.pixels[k * 4 + 1] = src[16 + k * 3 + 1]; b.pixels[k * 4 + 2] = src[16 + k * 3 + 2]; b.pixels[k * 4 + 3] = 255
            }
        }
        return image("bg") { b }
    }()

    var ctx: CGContext?
    func draw(_ items: [UIItem]) {
        guard let c = ctx else { return }
        for it in items {
            guard let i = image(it.key, it.make) else { continue }
            c.saveGState(); c.translateBy(x: CGFloat(it.x), y: CGFloat(it.y + it.h)); c.scaleBy(x: 1, y: -1)
            c.draw(i, in: CGRect(x: 0, y: 0, width: it.w, height: it.h)); c.restoreGState()
        }
    }
    func dialogOrigin(_ w: Int, _ h: Int) -> (Int, Int) { ((1024 - w) / 2, (768 - h) / 2) }
    func look(_ r: UIRect, enabled: Bool = true) -> ButtonLook {
        guard enabled else { return .disabled }
        if let p = pressedAt, r.contains(p.0, p.1), r.contains(hover.0, hover.1) { return .pressed }
        return r.contains(hover.0, hover.1) ? .highlighted : .released
    }
    func largeButton(_ label: String, _ l: UILayer?, _ ox: Int, _ oy: Int, enabled: Bool = true) {
        guard let l = l else { return }
        draw(kit.largeButton(label, ox + l.x, oy + l.y, look(UIRect(ox + l.x, oy + l.y, 166, 40), enabled: enabled)))
    }
    func hit(_ l: UILayer?, _ ox: Int, _ oy: Int, _ x: Float, _ y: Float, w: Int? = nil, h: Int? = nil) -> Bool {
        guard let l = l else { return false }
        return UIRect(ox + l.x, oy + l.y, w ?? l.width, h ?? l.height).contains(x, y)
    }

    override func draw(_ dirty: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.setFillColor(.black); c.fill(bounds)
        let s = min(bounds.width / 1024, bounds.height / 768)
        c.translateBy(x: (bounds.width - 1024 * s) / 2, y: (bounds.height - 768 * s) / 2); c.scaleBy(x: s, y: s)
        ctx = c
        if let bg = background { c.saveGState(); c.translateBy(x: 0, y: 768); c.scaleBy(x: 1, y: -1); c.draw(bg, in: CGRect(x: 0, y: 0, width: 1024, height: 768)); c.restoreGState() }
        switch screen {
        case .main: drawMain()
        case .scenarios: drawScenarios()
        case .campaigns(let set): drawCampaigns(set)
        case .briefing(let id, let index, _): drawBriefing(id, index, epilogue: false)
        case .epilogue(let id, let index, _): drawBriefing(id, index, epilogue: true)
        case .load: drawLoad()
        case .setup: drawSetup()
        }
        if let p = popup {
            draw(kit.scrollMenu(p.items.map { $0.0 }, x: p.x, y: p.y, hover: hover, elapsed: snapshotting ? 10 : Date().timeIntervalSince(p.opened)))
        }
        if let o = options {
            let (ox, oy) = OptionsView.origin(1024, 768)
            draw(OptionsView.items(kit, o, ox: ox, oy: oy, hover: hover))
        }
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

    // MARK: the main menu (menus_spec A.1)

    let mainButtons = ["New_Game", "Load_Game", "Options", "Network", "Quit"]
    static let mainLabels = ["New_Game": "new_game", "Load_Game": "load_game", "Options": "options", "Network": "multiplayer", "Quit": "quit"]
    func drawMain() {
        guard let f = layers("menu.main.1024") else { return }
        // the copyright: white with a black halo, PA.12, left and top in Copywright_Text
        if let r = MenuKit.find(f, "Copywright_Text") {
            draw(kit.text(text("x2_copyright.main_menu", ""), UIRect(r), MenuKit.Style(12, colour: (255, 255, 255), halo: (0, 0, 0))))
        }
        for b in mainButtons {
            guard let rel = MenuKit.find(f, "\(b)_Released") else { continue }
            let l = popup == nil && options == nil ? look(UIRect(rel)) : .released
            let name = l == .pressed ? "Pressed" : l == .highlighted ? "Highlighted" : "Released"
            draw(kit.image(MenuKit.find(f, "\(b)_\(name)") ?? rel, "menu.main.1024"))
            // the label: a text window of the menu (it does not move with the press), font = rect height
            if let t = MenuKit.find(f, "\(b)_Text") {
                draw(kit.text(text("\(MenuView.mainLabels[b] ?? b).main_menu", b), UIRect(t), MenuKit.Style(t.height, just: 1, vcentre: true), clip: false))
            }
        }
    }
    func openNewGameMenu() {
        guard let rel = kit.layer("menu.main.1024", "New_Game_Released") else { return }
        var items: [(String, () -> Void)] = [(text("main_menu_scenario.misc", "Scenarios"), { [weak self] in self?.openScenarios() })]
        for (k, key, fb) in [(0, "storm_new_campaign_original", "Heroes IV Campaigns"), (1, "storm_new_campaign_storm", "Gathering Storm Campaigns"), (2, "new_campaign_x2", "Winds of War Campaigns")] {
            items.append((text(key, fb), { [weak self] in self?.screen = .campaigns(set: k) }))
        }
        items.append((text("main_menu_tutorial.misc", "Tutorial"), { [weak self] in self?.start(["campaign:0:0"]) }))
        popup = Popup(items: items, x: rel.x, y: rel.y)
    }
    func openOptionsMenu() {
        guard let rel = kit.layer("menu.main.1024", "Options_Released") else { return }
        let none: () -> Void = {}
        popup = Popup(items: [(text("main_menu_settings.misc", "Game Settings"), { [weak self] in self?.options = GameSettings.load() }),
                              (text("main_menu_high_score.misc", "High Scores"), none),
                              (text("main_menu_replay_intro.misc", "Replay Cinematic"), none),
                              (text("main_menu_replay_intro.storm_misc", "Replay Storm Cinematic"), none),
                              (text("main_menu_replay_intro.x2_misc", "Replay Winds of War Cinematic"), none),
                              (text("main_menu_credits.misc", "Credits"), none)], x: rel.x, y: rel.y)
    }
    func clickMain(_ x: Float, _ y: Float) {
        guard let f = layers("menu.main.1024") else { return }
        func on(_ b: String) -> Bool { MenuKit.find(f, "\(b)_Released").map { UIRect($0).contains(x, y) } ?? false }
        if on("New_Game") { openNewGameMenu() }
        else if on("Load_Game") { saves = Renderer.savedGames(); scroll = 0; selected = 0; screen = .load }
        else if on("Options") { openOptionsMenu() }
        else if on("Quit") { NSApp.terminate(nil) }
    }
    func clickPopup(_ p: Popup, _ x: Float, _ y: Float) {
        popup = nil
        if let k = kit.scrollMenuHit(p.items.map { $0.0 }, x: p.x, y: p.y, x, y) { p.items[k].1() }
    }
    func clickOptions(_ x: Float, _ y: Float) {
        guard var o = options else { return }
        let (ox, oy) = OptionsView.origin(1024, 768)
        let h = OptionsView.hit(kit, ox: ox, oy: oy, x, y)
        switch h {
        case .ok: o.save(); options = nil; sound.setMusicVolume(o.music)
        case .cancel: options = nil
        case .none: break
        default: OptionsView.apply(h, to: &o); options = o
        }
    }

    // MARK: the scenario list (menus_spec B.1)

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
    /// The visible columns packed from line_width's right edge (0x7b60b0): each takes column_width 57
    /// plus a 9 px line; default Map type, Players, Difficulty, Size (Allies and Humans off).
    static let scenarioColumns = ["Map_Type", "Players", "Difficulty", "Size"]
    func columnX(_ f: LayerFile) -> (cols: [String: Int], lines: [Int], nameEnd: Int) {
        var edge = (MenuKit.find(f, "line_width").map { $0.x + $0.width }) ?? 743
        let cw = MenuKit.find(f, "column_width")?.width ?? 57
        var cols: [String: Int] = [:], lines: [Int] = []
        for c in MenuView.scenarioColumns { edge -= cw + 9; cols[c] = edge + 9; lines.append(edge) }
        return (cols, lines, edge)
    }
    func drawScenarios() {
        guard let f = layers("dialog.new_game") else { return }
        let (ox, oy) = dialogOrigin(800, 599)
        func l(_ n: String) -> UILayer? { MenuKit.find(f, n) }
        draw(kit.image(l("Background"), "new_game", ox, oy))
        draw(kit.image(l("Choose_File_Grid"), "new_game", ox, oy))
        if let t = l("Map_Title") {   // the name header: a toggle with no images, its text 34 left, v-centred
            draw(kit.text(text("map_name", "Scenario Name"), UIRect(ox + t.x, oy + t.y, t.width - 8, 44), MenuKit.Style(40, vcentre: true), clip: false))
        }
        let (cols, lines, nameEnd) = columnX(f)
        let cw = l("column_width")?.width ?? 57
        let lw = l("line_width")
        let diffIcons = layers("icons.difficulty"), typeIcons = layers("icons.map_type")
        for row in 0..<10 {
            let k = scroll + row
            guard k < maps.count, let slot = l("Map_\(row + 1)") else { continue }
            let m = maps[k].summary
            let sel = k == selected
            let rowRect = UIRect(ox + (lw?.x ?? 27), oy + slot.y, (lw?.width ?? 716), slot.height)
            if sel { draw(kit.fill(rowRect)) }
            let st = MenuKit.Style(slot.height, colour: sel ? (255, 255, 255) : (0, 0, 0), halo: sel ? (0, 0, 0) : MenuKit.halo, vcentre: true)
            var cst = st; cst.just = 1
            draw(kit.text(m.name, UIRect(ox + slot.x, oy + slot.y, nameEnd - 8 - slot.x, slot.height), st))
            func cell(_ c: String) -> UIRect { UIRect(ox + (cols[c] ?? 0), oy + slot.y, cw, slot.height) }
            let size = m.size <= 76 ? "S" : m.size <= 152 ? "M" : m.size <= 228 ? "L" : "XL"
            draw(kit.text(size, cell("Size"), cst))
            draw(kit.text("\(m.players)", cell("Players"), cst))
            if let ic = MenuKit.find(diffIcons, Renderer.difficultyLayers[min(4, max(0, m.difficulty))]) {
                let c = cell("Difficulty"); draw(kit.image(ic, "icons.difficulty", c.x + (cw - ic.width) / 2 - ic.x, c.y))
            }
            let tname = m.version >= 29 ? "expansion_2" : m.version >= 28 ? "expansion" : "original"
            if let ic = MenuKit.find(typeIcons, tname) {
                let c = cell("Map_Type"); draw(kit.image(ic, "icons.map_type", c.x + (cw - ic.width) / 2 - ic.x, c.y))
            }
        }
        // the separators (only right of the name area) and the column headers re-centred on their columns
        if let v = l("Vertical_Line") { for x in lines { draw(kit.image(v, "new_game", ox + x - v.x, oy)) } }
        for c in MenuView.scenarioColumns {
            guard let rel = l("\(c)_Released"), let cx = cols[c] else { continue }
            let dx = cx + (cw - rel.width) / 2 - rel.x
            let hot = UIRect(ox + rel.x + dx, oy + rel.y, rel.width, rel.height).contains(hover.0, hover.1)
            draw(kit.image(hot ? (l("\(c)_Highlighted") ?? rel) : rel, "new_game", ox + dx + (hot ? (rel.x + rel.width / 2) - ((l("\(c)_Highlighted") ?? rel).x + (l("\(c)_Highlighted") ?? rel).width / 2) : 0), oy))
        }
        if let s = l("Scrollbar") { draw(kit.vScrollbar(ox + s.x, oy + s.y, s.height, first: scroll, visible: 10, total: maps.count)) }
        draw(kit.image(l("Description_Box"), "new_game", ox, oy))
        if selected < maps.count, let d = l("Description") {
            draw(kit.text(text("scene_info_description_title.misc", "Map Description") + ":\n" + maps[selected].summary.description, UIRect(d, ox, oy), MenuKit.Style(16)))
        }
        largeButton(text("details", "Details"), l("Details_Button"), ox, oy)
        largeButton(text("cancel", "Cancel"), l("Back_Button"), ox, oy)
        largeButton(text("new_map_next.misc", "Next"), l("Begin_Button"), ox, oy, enabled: selected < maps.count)
    }
    func clickScenarios(_ x: Float, _ y: Float, double: Bool) {
        guard let f = layers("dialog.new_game") else { return }
        let (ox, oy) = dialogOrigin(800, 599)
        func l(_ n: String) -> UILayer? { MenuKit.find(f, n) }
        let lw = l("line_width")
        for row in 0..<10 {
            guard let slot = l("Map_\(row + 1)") else { continue }
            if UIRect(ox + (lw?.x ?? 27), oy + slot.y, lw?.width ?? 716, slot.height).contains(x, y) {
                if scroll + row < maps.count { selected = scroll + row; if double { begin() } }
                return
            }
        }
        if let s = l("Scrollbar"), let d = kit.vScrollbarHit(ox + s.x, oy + s.y, s.height, x, y) { scroll = max(0, min(max(0, maps.count - 10), scroll + d)); return }
        if hit(l("Back_Button"), ox, oy, x, y) { screen = .main; return }
        if hit(l("Begin_Button"), ox, oy, x, y) { begin() }
    }
    func begin() {
        guard selected < maps.count else { return }
        let path = maps[selected].path
        // a single scenario: its options first; a campaign file straight in
        if maps[selected].summary.scenarios > 1 { start([path]); return }
        if let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let m = try? MapFile(data: d, objectNames: []) {
            setup = Setup(map: m, human: m.humanColour); screen = .setup(path: path)
        } else { start([path]) }
    }

    // MARK: campaigns (menus_spec C.1)

    /// A set's layout and its six faces in button order (table 0x6807a0).
    func campaignSet(_ set: Int) -> (layout: String, faces: [String]) {
        switch set {
        case 1: return ("dialog.storm_campaign_Selection", ["Campaign3A", "Campaign2A", "Campaign5A", "Campaign4A", "Campaign1A", "Campaign6A"])
        case 2: return ("dialog.wow_campaign_Selection", ["SpazzA", "MongoA", "MysterioA", "ErutanA", "TarkinA", "WoWPro"])
        default: return ("dialog.campaign_Selection", ["Life_Intro", "Might_Intro", "Order_Intro", "Nature_Intro", "Death_Intro", "Chaos_Intro"])
        }
    }
    func drawCampaigns(_ set: Int) {
        let s = campaignSet(set)
        guard let f = layers(s.layout) else { return }
        let (ox, oy) = dialogOrigin(800, 599)
        func l(_ n: String) -> UILayer? { MenuKit.find(f, n) }
        draw(kit.image(l("Background"), s.layout, ox, oy))
        if let t = l("Title") { draw(kit.text(text("title.campaign_selection", "Campaign Selection"), UIRect(t, ox, oy), MenuKit.Style(t.height, just: 1, vcentre: true), clip: false)) }
        if let c = l("Cancel_Button") { draw(kit.button("cancel", look(UIRect(ox + c.x, oy + c.y, 76, 44)), ox + c.x, oy + c.y)) }
        for k in 0..<6 {
            guard let slot = l("Campaign_\(k)"), let face = MenuKit.find(layers("Campaign_Splashscreens.192x154.\(s.faces[k])"), "frame 001") else { continue }
            draw(kit.image(face, "face.\(s.faces[k])", ox + slot.x, oy + slot.y))
        }
        draw(kit.image(l("Frame"), s.layout, ox, oy))   // created last: over the faces
    }
    func campaign(_ id: Int) -> CampaignFile? {
        if let c = campaignCache[id] { return c }
        let c = try? CampaignFile.load(id, from: archive)
        campaignCache[id] = c
        return c
    }
    func clickCampaigns(_ set: Int, _ x: Float, _ y: Float) {
        guard let f = layers(campaignSet(set).layout) else { return }
        let (ox, oy) = dialogOrigin(800, 599)
        for k in 0..<6 where hit(MenuKit.find(f, "Campaign_\(k)"), ox, oy, x, y) {
            briefingTab = 3
            screen = .briefing(id: CampaignFile.sets[set][k], index: 0, carry: nil); return
        }
        if hit(MenuKit.find(f, "Cancel_Button"), ox, oy, x, y, w: 76, h: 44) { screen = .main }
    }
    func scenarioMap(_ id: Int, _ index: Int) -> MapFile? {
        guard let c = campaign(id), index < c.count, let d = try? c.scenario(index) else { return nil }
        return try? MapFile(data: d, objectNames: [])
    }

    // MARK: the campaign briefing and epilogue (menus_spec C.2, C.3)

    var voicePlaying: String?
    var briefingTab = 3
    var difficulty = 1
    var guardsMove = true
    var paused = false
    static let difficultyKeys = ["easy", "normal", "hard", "expert", "impossible"]
    func difficultyName(_ d: Int) -> String {
        text("new_map_difficulty_balloon_help_\(MenuView.difficultyKeys[d]).misc", ["Novice Game", "Intermediate Game", "Advanced Game", "Expert Game", "Champion Game"][d])
    }
    func drawBriefing(_ id: Int, _ index: Int, epilogue: Bool) {
        let name = epilogue ? "dialog.Campaign_Epilogue" : "dialog.Campaign"
        guard let f = layers(name), let m = scenarioMap(id, index) else { return }
        let (ox, oy) = dialogOrigin(800, epilogue ? 456 : 599)
        func l(_ n: String) -> UILayer? { MenuKit.find(f, n) }
        draw(kit.image(l("Background"), name, ox, oy))
        let campaignFile = campaign(id)
        let multi = (campaignFile?.count ?? 1) > 1
        if !epilogue {   // the tabs: the pressed one's image, the label on each in (0,14)-(133,45) of the pressed box, font 20
            for k in (multi ? [1, 2, 3] : [2, 3]) {
                guard let pr = l("Tab_\(k)_Pressed"), let rel = l("Tab_\(k)_Released") else { continue }
                let on = briefingTab == k
                draw(kit.image(on ? pr : rel, name, ox, oy))
                let label = [text("campaign_info.campaign", "Campaign"), text("scenario_info.campaign", "Scenario"), text("scenario_details.campaign", "Details")][k - 1]
                draw(kit.text(label, UIRect(ox + pr.x, oy + pr.y + 14, pr.width, pr.height - 14 - (on ? 0 : 0)), MenuKit.Style(pr.height - 14 - 10, just: 1, vcentre: on), clip: false))
            }
        }
        let cut = epilogue ? m.epilogue : m.prologue
        if let pic = cut?.image, !pic.isEmpty, let p = l("Picture"), let fr = MenuKit.find(layers("Campaign_Splashscreens.426x340.\(pic)"), "frame 001") {
            draw(kit.image(fr, "splash.\(pic)", ox + p.x, oy + p.y))
        }
        draw(kit.image(l("Picture_Frame"), name, ox, oy))
        draw(kit.image(l("Title_Background"), name, ox, oy))
        if !epilogue {
            draw(kit.image(l("Player_Difficulty_Box"), name, ox, oy))
            if let s = l("Player_Difficulty") { draw(kit.image(kit.layer("icons.difficulty_60", Renderer.difficultyLayers[difficulty]), "icons.difficulty_60", ox + s.x, oy + s.y)) }
            if let g = l("Creature_Guard_Released") {
                let hot = UIRect(g, ox, oy).contains(hover.0, hover.1)
                let n = guardsMove ? (hot ? "Creature_Guard_Highlighted_Pressed" : "Creature_Guard_Pressed") : (hot ? "Creature_Guard_Highlighted" : "Creature_Guard_Released")
                draw(kit.image(l(n) ?? g, name, ox, oy))
            }
            if let s = l("Map_Size") {
                let w = m.size
                let n = w <= 76 ? "Small" : w <= 152 ? "Medium" : w <= 228 ? "Large" : "X_Large"
                draw(kit.image(kit.layer("icons.map_size", n), "icons.map_size", ox + s.x, oy + s.y))
            }
        }
        if let t = l("Title") { draw(kit.text(m.name, UIRect(t, ox, oy), MenuKit.Style(t.height, just: 1, vcentre: true), clip: false)) }
        // the voice-over text, font 27, black without a halo, scrolled up over the text's time (length x 100 ms)
        if let v = l("Voice_Text"), let s = cut?.text, !s.isEmpty {
            let st = MenuKit.Style(27, halo: nil)
            let over = max(0, kit.textHeight(s, st, width: v.width) - v.height)
            let t = snapshotting ? 0 : Date().timeIntervalSince(screenOpened)
            let dur = max(1, Double(s.count) * 0.1)
            draw(kit.text(s, UIRect(v, ox, oy), st, scroll: Int(Double(over) * min(1, t / dur))))
        }
        if epilogue {
            draw(kit.layoutButton(name, "Replay", .released, ox, oy))
            draw(kit.layoutButton(name, "Pause", paused ? .pressed : .released, ox, oy))
            largeButton(text("new_map_next.misc", "Next"), l("Next"), ox, oy)
        } else {
            if let g = l("creature_guard_text") {
                draw(kit.text(guardsMove ? text("guards_move.shared", "Mobile Guards") : text("guards_dont_move.shared", "Stationary Guards"), UIRect(g, ox, oy), MenuKit.Style(g.height / 2, just: 1), clip: false))
            }
            if let d = l("Player_difficulty_Text") { draw(kit.text(difficultyName(difficulty), UIRect(d, ox, oy), MenuKit.Style(d.height / 2, just: 1), clip: false)) }
            largeButton(text("cancel", "Cancel"), l("Back"), ox, oy)
            largeButton(text("begin", "Begin"), l("Begin"), ox, oy)
            draw(kit.layoutButton(name, "Replay", .released, ox, oy))
            draw(kit.layoutButton(name, "Pause", paused ? .pressed : .released, ox, oy))
            let body: String
            switch briefingTab {
            case 1: body = campaignFile?.description ?? ""
            case 2: body = m.description
            default:
                body = ["\(text("win_condition.campaign", "Victory Condition")):   \(m.victoryText ?? text("default_victory_condition", "Be the only player to own towns."))",
                        "\(text("loss_condition.campaign", "Loss Condition")):   \(m.lossText ?? text("default_loss_condition", "Lose all towns and armies."))",
                        "\(text("map_difficulty.campaign", "Map Difficulty")):   \(difficultyName(min(4, max(0, m.difficulty))))",
                        "\(text("carryover.campaign", "Carryover")):   \(m.carryoverText)"].joined(separator: "\n")
            }
            if let d = l("map_description") { draw(kit.text(body, UIRect(d, ox, oy), MenuKit.Style(16))) }
            if multi && index == 0 {   // the difficulty arrows only on the first scenario
                draw(kit.layoutButton(name, "Left", difficulty > 0 ? look(UIRect(l("Left_Released")!, ox, oy)) : .disabled, ox, oy))
                draw(kit.layoutButton(name, "Right", difficulty < 4 ? look(UIRect(l("Right_Released")!, ox, oy)) : .disabled, ox, oy))
            }
        }
        let voice = cut?.voice ?? ""
        if !snapshotting, !voice.isEmpty, voicePlaying != "\(id)|\(index)|\(epilogue)" {
            voicePlaying = "\(id)|\(index)|\(epilogue)"
            _ = sound.play("Voice_Over.\(voice)")
        }
    }
    func clickBriefing(_ id: Int, _ index: Int, carry: String?, epilogue: Bool, _ x: Float, _ y: Float) {
        guard let f = layers(epilogue ? "dialog.Campaign_Epilogue" : "dialog.Campaign") else { return }
        let (ox, oy) = dialogOrigin(800, epilogue ? 456 : 599)
        func l(_ n: String) -> UILayer? { MenuKit.find(f, n) }
        if hit(l("Pause_released"), ox, oy, x, y) { paused.toggle(); return }
        if hit(l("Replay_Released"), ox, oy, x, y) { voicePlaying = nil; screenOpened = Date(); return }
        if epilogue {
            guard hit(l("Next"), ox, oy, x, y, w: 166, h: 40) else { return }
            if let c = campaign(id), index + 1 < c.count { screen = .briefing(id: id, index: index + 1, carry: carry) }
            else { screen = .main }   // the campaign is won
            return
        }
        for k in 1...3 where hit(l("Tab_\(k)_Pressed"), ox, oy, x, y) && ((campaign(id)?.count ?? 1) > 1 || k > 1) { briefingTab = k; return }
        if index == 0 {
            if hit(l("Left_Released"), ox, oy, x, y) { difficulty = max(0, difficulty - 1); return }
            if hit(l("Right_Released"), ox, oy, x, y) { difficulty = min(4, difficulty + 1); return }
        }
        if hit(l("Creature_Guard_Released"), ox, oy, x, y) { guardsMove.toggle(); return }
        if hit(l("Back"), ox, oy, x, y, w: 166, h: 40) { screen = .main; return }
        if hit(l("Begin"), ox, oy, x, y, w: 166, h: 40) { start(["campaign:\(id):\(index)", "--difficulty", "\(difficulty)"] + (carry.map { ["--carry", $0] } ?? [])) }
    }

    // MARK: new game options (menus_spec B.2)

    static let colourNames = ["Red", "Blue", "Green", "Orange", "Purple", "Teal"]
    static let alignmentNames = ["Life", "Order", "Death", "Chaos", "Nature", "Might"]
    /// A row's alignment choice: the one picked, or the map's only one, else Random (-1).
    func alignment(_ s: Setup, _ spec: PlayerSpec) -> Int {
        if let a = s.align[spec.colour] { return a }
        let allowed = (0..<6).filter { spec.alignments & (1 << $0) != 0 }
        return allowed.count == 1 ? allowed[0] : -1
    }
    /// The rows as the original lists them: grouped by team (in order of first appearance), the
    /// teams numbered 1, 2, ... in that order.
    func setupRows(_ s: Setup) -> [(spec: PlayerSpec, team: Int)] {
        var order: [Int] = []
        for p in s.map.playerSpecs { let t = s.map.teams[p.colour] ?? 100 + p.colour; if !order.contains(t) { order.append(t) } }
        return s.map.playerSpecs.map { p in (p, (order.firstIndex(of: s.map.teams[p.colour] ?? 100 + p.colour) ?? 0) + 1) }
            .enumerated().sorted { ($0.element.team, $0.offset) < ($1.element.team, $1.offset) }.map { $0.element }
    }
    func drawSetup() {
        guard let s = setup, let f = layers("dialog.New_Game_Options"), let p1 = MenuKit.find(f, "Player_1") else { return }
        let (ox, oy) = dialogOrigin(800, 600)
        func l(_ n: String) -> UILayer? { MenuKit.find(f, n) }
        let name = "dialog.New_Game_Options"
        draw(kit.image(l("background"), name, ox, oy))
        largeButton(text("back.shared", "Back"), l("Back_Button"), ox, oy)
        largeButton(text("begin", "Begin"), l("Begin_Button"), ox, oy)
        for (n, t) in [("Name_Title", "Name"), ("Team_Title", text("new_map_team.misc", "Team")), ("Alignment_Title", "Alignment"), ("Color_Title", "Color")] {
            if let r = l(n) { draw(kit.text(t, UIRect(r, ox, oy), MenuKit.Style(r.height, just: 1), clip: false)) }
        }
        if let d = l("Difficulty_Text") { draw(kit.text(difficultyName(s.difficulty), UIRect(d, ox, oy), MenuKit.Style(d.height / 2, just: 1, vcentre: true), clip: false)) }
        if let d = l("Map_Description") { draw(kit.text(s.map.description, UIRect(d, ox, oy), MenuKit.Style(18))) }
        if let d = l("victory_loss_Condition") {
            let loss = text("new_map_loss_condition.misc", "Loss Condition: ") + (s.map.lossText ?? text("default_loss_condition", "Lose all towns and armies."))
            let win = text("new_map_win_condition.misc", "Victory Condition: ") + (s.map.victoryText ?? text("default_victory_condition", "Be the only player to own towns."))
            draw(kit.text(loss + "\n\n" + win, UIRect(d, ox, oy), MenuKit.Style(18)))
        }
        draw(kit.image(l("Player_Difficulty_Box"), name, ox, oy))
        if let slot = l("Player_Difficulty") { draw(kit.image(kit.layer("icons.difficulty_60", Renderer.difficultyLayers[s.difficulty]), "icons.difficulty_60", ox + slot.x, oy + slot.y)) }
        if let g = l("Creature_Guard_Released") {
            let hot = UIRect(g, ox, oy).contains(hover.0, hover.1)
            let n = s.guardsMove ? (hot ? "Creature_Guard_Highlighted_Pressed" : "Creature_Guard_Pressed") : (hot ? "Creature_Guard_Highlighted" : "Creature_Guard_Released")
            draw(kit.image(l(n) ?? g, name, ox, oy))
        }
        if let g = l("creature_guard_text") {
            draw(kit.text(s.guardsMove ? text("guards_move.shared", "Mobile Guards") : text("guards_dont_move.shared", "Stationary Guards"), UIRect(g, ox, oy), MenuKit.Style(g.height / 2, just: 1), clip: false))
        }
        for (n, ok) in [("Left", s.difficulty > 0), ("Right", s.difficulty < 4)] {
            guard let r = l("\(n)_Released") else { continue }
            draw(kit.layoutButton(name, n, ok ? look(UIRect(r, ox, oy)) : .disabled, ox, oy))
        }
        // the player rows, 74 px apart, sorted by team
        let arrows = layers("button.Arrows"), flags = layers("icons.flags.38")
        let humanColours = s.map.playerSpecs.filter { $0.canBeHuman }.count
        for (k, r) in setupRows(s).prefix(6).enumerated() {
            let spec = r.spec
            guard let row = l("Player_\(k + 1)") else { continue }
            let dy = row.y - p1.y
            let colour = MenuView.colourNames[min(5, spec.colour)]
            let human = spec.colour == s.human
            if let bg = l("Player_Background") {
                draw(MenuKit.clip(kit.image(bg, name, ox, oy + dy), to: UIRect(ox + row.x, oy + row.y, row.width, row.height)))
            }
            if let aa = l("Alignment_Arrows") {
                let ok = (0..<6).filter { spec.alignments & (1 << $0) != 0 }.count != 1
                for dir in ["Up", "Down"] {
                    if let a = MenuKit.find(arrows, "Alignment_\(dir)_\(ok ? "Released" : "Disabled")") { draw(kit.image(a, "button.Arrows", ox + aa.x, oy + aa.y + dy)) }
                }
            }
            if let pf = l("Player_Flag") {
                let a = alignment(s, spec)
                for n in [colour, a >= 0 ? MenuView.alignmentNames[a] : "Random"] { draw(kit.image(MenuKit.find(flags, n), "icons.flags.38", ox + pf.x, oy + pf.y + dy)) }
            }
            if let ca = l("Color_Arrows") {
                for dir in ["Up", "Down"] {
                    if let a = MenuKit.find(arrows, "\(colour)_\(dir)_Released") { draw(kit.image(a, "button.Arrows", ox + ca.x, oy + ca.y + dy)) }
                }
                _ = humanColours
            }
            if let tf = l("Team_Flag") {
                for n in [colour, "team_\(min(6, r.team))"] { draw(kit.image(MenuKit.find(flags, n), "icons.flags.38", ox + tf.x, oy + tf.y + dy)) }
            }
            if let pn = l("Player_Name") {
                let label = human ? "\(text("main_menu_player.misc", "Player")) 1" : text("computer.new_game", "Computer")
                draw(kit.text(label, UIRect(pn, ox, oy + dy), MenuKit.Style(pn.height)))
            }
            if spec.canBeHuman, let cb = l("human_checkbox") {
                let hot = UIRect(ox + cb.x, oy + cb.y + dy, 34, 29).contains(hover.0, hover.1)
                let n = human ? (hot ? "Highlighted_Pressed" : "Pressed") : (hot ? "Highlighted" : "Released")
                draw(kit.image(kit.layer("checkbox", n) ?? kit.layer("button.checkbox", n), "button.checkbox", ox + cb.x, oy + cb.y + dy))
            }
        }
    }
    func clickSetup(_ path: String, _ x: Float, _ y: Float) {
        guard var s = setup, let f = layers("dialog.New_Game_Options"), let p1 = MenuKit.find(f, "Player_1") else { return }
        let (ox, oy) = dialogOrigin(800, 600)
        func l(_ n: String) -> UILayer? { MenuKit.find(f, n) }
        let humans = s.map.playerSpecs.filter { $0.canBeHuman }.map { $0.colour }
        for (k, r) in setupRows(s).prefix(6).enumerated() {
            let spec = r.spec
            guard let row = l("Player_\(k + 1)") else { continue }
            let dy = row.y - p1.y
            if spec.canBeHuman, hit(l("human_checkbox"), ox, oy + dy, x, y, w: 34, h: 29) { s.human = spec.colour }
            if spec.colour == s.human, humans.count > 1, let ca = l("Color_Arrows"), hit(ca, ox, oy + dy, x, y), let i = humans.firstIndex(of: s.human) {
                let up = y < Float(oy + dy + ca.y + ca.height / 2)
                s.human = humans[(i + (up ? humans.count - 1 : 1)) % humans.count]
            }
            // the alignment arrows (any row): through the alignments the map allows, and Random
            if let aa = l("Alignment_Arrows"), hit(aa, ox, oy + dy, x, y) {
                let allowed = [-1] + (0..<6).filter { spec.alignments & (1 << $0) != 0 }
                if allowed.count > 2 {
                    let cur = allowed.firstIndex(of: alignment(s, spec)) ?? 0
                    let up = y < Float(oy + dy + aa.y + aa.height / 2)
                    s.align[spec.colour] = allowed[(cur + (up ? allowed.count - 1 : 1)) % allowed.count]
                }
            }
        }
        if hit(l("Left_Released"), ox, oy, x, y) { s.difficulty = max(0, s.difficulty - 1) }
        if hit(l("Right_Released"), ox, oy, x, y) { s.difficulty = min(4, s.difficulty + 1) }
        if hit(l("Creature_Guard_Released"), ox, oy, x, y) { s.guardsMove.toggle() }
        setup = s
        if hit(l("Back_Button"), ox, oy, x, y, w: 166, h: 40) { screen = .scenarios; return }
        if hit(l("Begin_Button"), ox, oy, x, y, w: 166, h: 40) {
            var a = [path, "--human", "\(s.human)", "--difficulty", "\(s.difficulty)"]
            if let al = s.align[s.human], al >= 0 { a += ["--align", "\(s.human):\(al)"] }
            start(a)
        }
    }

    // MARK: load (menus_spec D1)

    func drawLoad() {
        let (ox, oy) = dialogOrigin(799, 598)
        draw(FileDialogView.items(kit, save: false, files: saves, scroll: scroll, selected: selected < saves.count ? selected : nil, name: "", ox: ox, oy: oy))
    }
    func clickLoad(_ x: Float, _ y: Float, double: Bool) {
        let (ox, oy) = dialogOrigin(799, 598)
        switch FileDialogView.hit(kit, save: false, files: saves.count, scroll: scroll, ox: ox, oy: oy, x, y) {
        case .cancel: screen = .main
        case .ok: loadSelected()
        case .row(let k): selected = k; if double { loadSelected() }
        case .scroll(let d): scroll = max(0, min(max(0, saves.count - 11), scroll + d))
        case .none: break
        }
    }
    func loadSelected() {
        guard selected < saves.count else { return }
        let file = Renderer.savesDirectory.appendingPathComponent("\(saves[selected].name).h4s")
        if let s = try? SaveGame.read(file) { start([s.mapPath, "--load", file.path]) }
    }

    // MARK: input and starting the game

    override func mouseMoved(with e: NSEvent) { hover = canvasPoint(e); needsDisplay = true }
    override func mouseDragged(with e: NSEvent) { hover = canvasPoint(e); needsDisplay = true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseDown(with e: NSEvent) { pressedAt = canvasPoint(e); needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        let (x, y) = canvasPoint(e)
        pressedAt = nil
        defer { needsDisplay = true }
        if let p = popup { clickPopup(p, x, y); return }
        if options != nil { clickOptions(x, y); return }
        let double = e.clickCount >= 2
        switch screen {
        case .main: clickMain(x, y)
        case .scenarios: clickScenarios(x, y, double: double)
        case .campaigns(let set): clickCampaigns(set, x, y)
        case .briefing(let id, let index, let carry): clickBriefing(id, index, carry: carry, epilogue: false, x, y)
        case .epilogue(let id, let index, let carry): clickBriefing(id, index, carry: carry, epilogue: true, x, y)
        case .load: clickLoad(x, y, double: double)
        case .setup(let path): clickSetup(path, x, y)
        }
    }
    override func scrollWheel(with e: NSEvent) {
        guard abs(e.scrollingDeltaY) > 1 else { return }
        let (n, page) = { () -> (Int, Int) in if case .load = self.screen { return (self.saves.count, 11) }; return (self.maps.count, 10) }()
        scroll = max(0, min(max(0, n - page), scroll + (e.scrollingDeltaY < 0 ? 1 : -1)))
        needsDisplay = true
    }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 {   // Esc: close what is open, else back to the menu
            if popup != nil { popup = nil } else if options != nil { options = nil } else { screen = .main }
            needsDisplay = true
        } else if e.keyCode == 36 || e.keyCode == 76 {   // Enter: the screen's default button
            switch screen {
            case .scenarios: begin()
            case .load: loadSelected()
            default: break
            }
        }
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
