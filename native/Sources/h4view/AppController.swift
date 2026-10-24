import AppKit
import MetalKit
import H4Engine

/// The game's one window (heroes4.exe keeps a single main window for the menus and the
/// adventure screen): the main menu and a scenario take turns as its content. A new scenario,
/// a campaign scenario, a load, a restart, the next campaign scenario and the return to the
/// menu change the content in place -- the window keeps its size, place and full-screen state.
/// The screen left is torn down (its timers, loops and music stop) and released with its game.
final class AppController: NSObject, NSApplicationDelegate {
    static let shared = AppController()
    /// The command line the program started with, and its --center (the first scenario only).
    var initialArgs: [String] = []
    var initialCentre: (Int, Int)?
    private(set) var window: NSWindow?
    private var pendingOpen: [String]?
    /// The screens left so far (weakly): a check that each was released (H4CYCLE).
    private var left: [(name: String, ref: () -> AnyObject?)] = []

    /// (`all` as CommandLine.arguments: the program first)
    static func isMenu(_ all: [String]) -> Bool { all.count == 2 || (all.count >= 3 && all[2] == "--menu") }

    func applicationDidFinishLaunching(_ n: Notification) {
        show(initialArgs, first: true)
        NSApp.activate(ignoringOtherApps: true)
        if let seq = ProcessInfo.processInfo.environment["H4CYCLE"] { runCycle(seq.split(separator: ";").map(String.init), step: 0) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    /// Show another screen: the arguments of a command line ([h4r, map or campaign:<id>:<index>,
    /// options] or [h4r, "--menu", options]; the program's own path goes before them). It happens on the next turn of the run loop, once the press or
    /// key that asked for it is handled by the screen being left.
    func open(_ all: [String]) {
        let first = pendingOpen == nil
        pendingOpen = [CommandLine.arguments[0]] + all
        guard first else { return }
        DispatchQueue.main.async { [self] in
            guard let a = pendingOpen else { return }
            pendingOpen = nil
            show(a)
        }
    }

    private func show(_ all: [String], first: Bool = false) {
        leaveCurrent()
        let size = window?.contentView?.bounds.size
        let view: NSView, aspect: NSSize, title: String
        if AppController.isMenu(all) {
            guard let v = try? MenuView(args: all, sound: gameSound) else {
                print("menu: cannot open the game data"); NSApp.terminate(nil); return
            }
            view = v; aspect = NSSize(width: 1024, height: 768); title = "Heroes of Might and Magic IV"
        } else {
            do {
                let g = try makeGameView(all, size: size, centre: first ? initialCentre : nil)
                view = g.view; aspect = g.aspect; title = g.title
            } catch {
                print("cannot start \(all.dropFirst()): \(error)")
                if first { exit(1) }
                show([all[0], all[1], "--menu"]); return
            }
        }
        if let w = window {
            if w.contentAspectRatio != aspect { w.contentAspectRatio = aspect }
            w.title = title
            w.contentView = view
            w.makeFirstResponder(view)
        } else {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: aspect), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentAspectRatio = aspect
            w.title = title
            w.contentView = view
            w.center()
            w.makeFirstResponder(view)
            w.makeKeyAndOrderFront(nil)
            window = w
        }
        if first, let m = view as? MenuView, let out = ProcessInfo.processInfo.environment["H4MENUSNAP"] { snapshotMenu(m, to: out) }
        lap("screen up")
    }

    /// Stop the screen on show: the adventure screen's drawing, timers, sound loops, music, end
    /// movie and the state its dialogs keep; the menu's redraw timer and music. Its objects go
    /// once the window lets go of the view.
    private func leaveCurrent() {
        guard let v = window?.contentView else { return }
        if let m = v as? MapView {
            m.teardown()
            if let r = m.renderer {
                let game = r.game
                left.append(("renderer", { [weak r] in r }))
                left.append(("game", { [weak game] in game }))
            }
            left.append(("map view", { [weak m] in m }))
        } else if let m = v as? MenuView {
            m.teardown()
            left.append(("menu", { [weak m] in m }))
        }
        NSCursor.arrow.set()
        window?.contentView = NSView()   // (released here, not at the next screen's install)
    }

    /// The adventure screen of a scenario (the old process's window content).
    private func makeGameView(_ all: [String], size: NSSize?, centre: (Int, Int)?) throws -> (view: MapView, aspect: NSSize, title: String) {
        let session = try autoreleasepool { try makeSession(all) }
        let game = session.game, ui = session.ui
        let aspect = ui == nil ? NSSize(width: 1280, height: 800) : NSSize(width: AdventureUI.width, height: AdventureUI.height)
        let view = MapView(frame: NSRect(origin: .zero, size: size ?? aspect), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 60
        let renderer = try Renderer(device: device, scenes: session.scenes, pixelFormat: .bgra8Unorm)
        renderer.archivePath = all[1]; renderer.mapPath = all.count > 2 ? all[2] : nil
        renderer.launchArgs = Array(all.dropFirst())
        if session.loadFile != nil { renderer.lastAutosaveDay = game.day }   // a loaded game: its day is saved already (no new autosave until the next day)
        renderer.game = game
        renderer.resolver = session.resolver
        game.gaitProvider = { [unowned renderer] in renderer.gait($0) }
        renderer.showBlocked = showBlocked
        renderer.ui = ui
        renderer.town = session.townScreen
        renderer.combat = session.combatScreen
        renderer.movies = movies
        renderer.sound = gameSound
        session.combatScreen?.sound = gameSound
        renderer.applySettings()
        renderer.onTitle = { [weak view] t in if let w = view?.window, w.title != t { w.title = t } }
        view.renderer = renderer
        view.cursors = GameCursors(archive: archive)
        view.delegate = renderer
        renderer.viewSize = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        aim(renderer, at: centre ?? game.heroes.first.map { ($0.x, $0.y) } ?? (session.map.size / 2, session.map.size / 2))
        return (view, aspect, "Heroes IV — \(session.map.name)")
    }

    private func snapshotMenu(_ view: MenuView, to out: String) {
        // a menu screen ("popup", "options", "settings", "load", "scenarios", "setup[:map]",
        // "campaigns:k", "briefing:id:i[:tab]", "epilogue:id:i", "hover:<button>")
        view.snapshotting = true
        view.open(ProcessInfo.processInfo.environment["H4MENUSCREEN"] ?? "")
        view.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
        exit(0)
    }

    // MARK: H4CYCLE: a headless check of the transitions

    /// H4CYCLE="--menu;maps/A.h4c;campaign:0:0;--menu,--screen,scenarios": each step (its
    /// arguments after the h4r, comma-separated) opens in the window after H4CYCLEDELAY seconds
    /// (default 4); each reports the windows, the memory footprint and the screens left still
    /// alive. H4CYCLEQUIT ends the program after the last.
    private func runCycle(_ steps: [String], step k: Int) {
        let delay = ProcessInfo.processInfo.environment["H4CYCLEDELAY"].flatMap { Double($0) } ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            report(k == 0 ? "start" : steps[k - 1])
            guard k < steps.count else {
                if ProcessInfo.processInfo.environment["H4CYCLEQUIT"] != nil { NSApp.terminate(nil) }
                return
            }
            open([initialArgs[1]] + steps[k].split(separator: ",").map(String.init))
            runCycle(steps, step: k + 1)
        }
    }
    private func report(_ what: String) {
        let alive = left.filter { $0.ref() != nil }.map { $0.name }
        left.removeAll { $0.ref() == nil }
        let windows = NSApp.windows.filter { $0.isVisible }.count
        print("cycle \(what): windows \(windows) content \(window?.contentView.map { String(describing: type(of: $0)) } ?? "-") footprint \(AppController.footprintMB()) MB, left screens alive: \(alive.isEmpty ? "none" : alive.joined(separator: ", "))")
    }
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return r == KERN_SUCCESS ? Int(info.phys_footprint >> 20) : -1
    }
}

extension MapView {
    /// The window shows another screen: no more frames, pointer ticks or sounds of this game.
    func teardown() {
        isPaused = true
        cursorTimer?.invalidate(); cursorTimer = nil
        hoverPending = nil
        delegate = nil
        renderer?.teardown()
    }
}

extension Renderer {
    /// Leaving the scenario: its loops, music and end movie stop; the state that would outlive
    /// it (the scenario information flag, closures over this renderer) goes.
    func teardown() {
        endGame?.audio?.stop(); endGame = nil
        sound?.leaveScreen()
        combat?.sound = nil
        Renderer.scenarioInfoOpen = false
        game?.gaitProvider = nil
        onTitle = nil
        prompt = nil; menu = nil
    }
}
