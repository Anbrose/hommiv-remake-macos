#if os(iOS)
import UIKit
import AVFoundation
import UniformTypeIdentifiers
import MetalKit
import H4Engine

/// Where the iPhone app keeps the game data: the app's Documents folder, which the Files app shows
/// (UIFileSharingEnabled). The user copies the game's Data folder there (and, if wanted, its maps
/// folder beside it: the scenario list reads Documents/maps), or imports it with the picker below.
enum IOSData {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    /// Documents/Data when the user put one there, else the copy a personal device build carries
    /// in the app bundle (GameData/Data, H4_BUNDLE_DATA=1 in make_ios.sh device), else Documents/Data.
    static var dataDirectory: URL {
        let own = documents.appendingPathComponent("Data")
        if FileManager.default.fileExists(atPath: own.appendingPathComponent("heroes4.h4r").path) { return own }
        if let b = Bundle.main.resourceURL?.appendingPathComponent("GameData/Data"),
           FileManager.default.fileExists(atPath: b.appendingPathComponent("heroes4.h4r").path) { return b }
        return own
    }
    static var archivePath: String { dataDirectory.appendingPathComponent("heroes4.h4r").path }
    static var isPresent: Bool { FileManager.default.fileExists(atPath: archivePath) }
}

final class IOSAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        try? AVAudioSession.sharedInstance().setActive(true)
        return true
    }
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        c.delegateClass = IOSSceneDelegate.self
        return c
    }
}

/// The one window, in the scene lifecycle (iOS 27 SDK apps must adopt it: the app-delegate
/// window alone traps at launch).
final class IOSSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        w.rootViewController = AppController.shared.controller
        w.makeKeyAndVisible()
        window = w
    }
}

/// The iPhone's counterpart of the mac's window controller (AppController.swift): the main menu
/// and a scenario take turns as the content of the one view controller.
final class AppController {
    static let shared = AppController()
    var initialArgs: [String] = []
    var initialCentre: (Int, Int)?
    let controller = GameViewController()
    private var pendingOpen: [String]?
    private var started = false

    static func isMenu(_ all: [String]) -> Bool { all.count == 2 || (all.count >= 3 && all[2] == "--menu") }

    /// The view controller is on screen: the first screen, or the data import screen.
    func start() {
        guard !started else { return }
        if !IOSData.isPresent { controller.showImport(); return }
        started = true
        show(initialArgs, first: true)
        if let script = ProcessInfo.processInfo.environment["H4TOUCHES"] { controller.runTouchScript(script) }
    }

    /// As on the mac: the screen changes on the next turn of the run loop.
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

    /// Quit: an iOS app does not end itself; from a game it goes back to the main menu.
    func quitRequested() {
        if controller.content is MapView { open([initialArgs[1], "--menu"]) }
    }

    private func show(_ all: [String], first: Bool = false) {
        leaveCurrent()
        if AppController.isMenu(all) {
            guard let v = try? MenuView(args: all, sound: gameSound) else { print("menu: cannot open the game data"); controller.showImport(); return }
            controller.install(v, aspect: CGSize(width: 1024, height: 768))
        } else {
            do {
                let aspect = CGSize(width: AdventureUI.width, height: AdventureUI.height)
                let g = try makeGameView(all, size: controller.fitRect(aspect).size, centre: first ? initialCentre : nil)
                controller.install(g.view, aspect: g.aspect)
            } catch {
                print("cannot start \(all.dropFirst()): \(error)")
                show([all[0], all[1], "--menu"]); return
            }
        }
        lap("screen up")
    }

    private func leaveCurrent() {
        if let m = controller.content as? MapView { m.teardown() }
        else if let m = controller.content as? MenuView { m.teardown() }
        controller.install(nil, aspect: .zero)
    }
}

/// One touch read as the mouse (the game's handlers stay the mac's):
/// - a tap is a left click at the point (move, press, release; two quick taps a double click);
/// - a press held still for 0.4 s is the right button, held until the finger lifts (the
///   right-click information boxes show while it is held);
/// - a drag is a left drag: what the press picked up is carried, else (on the map) the view pans.
/// The pointer (hover: highlights, status line) follows the finger.
protocol TouchTarget: UIView {
    func touchMoved(_ p: CGPoint)
    func touchPressed(_ p: CGPoint)
    func touchDragged(_ p: CGPoint, by d: CGPoint)
    func touchReleased(_ p: CGPoint, clicks: Int)
    func touchHeld(_ p: CGPoint)
    func touchHoldEnded(_ p: CGPoint)
}

extension MapView: TouchTarget {
    private func event(_ p: CGPoint, _ d: CGPoint = .zero, clicks: Int = 1) -> PointerEvent {
        // the handlers take AppKit's bottom-left origin; a drag's distance in pixels, so the
        // map follows the finger (the mac's is in points: the trackpad's gearing)
        PointerEvent(location: CGPoint(x: p.x, y: bounds.height - p.y), deltaX: d.x * contentScaleFactor, deltaY: d.y * contentScaleFactor, clickCount: clicks)
    }
    func touchMoved(_ p: CGPoint) { pointerMoved(event(p)) }
    func touchPressed(_ p: CGPoint) { pointerDown(event(p)) }
    func touchDragged(_ p: CGPoint, by d: CGPoint) { pointerMoved(event(p)); pointerDragged(event(p, d)) }
    func touchReleased(_ p: CGPoint, clicks: Int) { pointerUp(event(p, clicks: clicks)) }
    func touchHeld(_ p: CGPoint) { rightPointerDown(event(p)) }
    func touchHoldEnded(_ p: CGPoint) { rightPointerUp(event(p)) }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startTicking() }
    }
}

extension MenuView: TouchTarget {
    func touchMoved(_ p: CGPoint) { pointerMoved(canvasPoint(p)) }
    func touchPressed(_ p: CGPoint) { pointerDown(canvasPoint(p)) }
    func touchDragged(_ p: CGPoint, by d: CGPoint) { pointerMoved(canvasPoint(p)) }
    func touchReleased(_ p: CGPoint, clicks: Int) { pointerUp(canvasPoint(p), clickCount: clicks) }
    func touchHeld(_ p: CGPoint) { rightPointerDown(canvasPoint(p)) }
    func touchHoldEnded(_ p: CGPoint) { rightPointerUp() }
}

/// Full screen, landscape: the game's 4:3 screen scaled to fit (black bars at the sides).
final class GameViewController: UIViewController, UIDocumentPickerDelegate {
    private(set) var content: TouchTarget?
    private var aspect = CGSize.zero
    private var importView: UIView?
    private var statusLabel: UILabel?

    override func loadView() {
        view = UIView()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = false
    }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        AppController.shared.start()
    }

    func fitRect(_ aspect: CGSize) -> CGRect {
        let b = view.bounds
        guard aspect.width > 0, aspect.height > 0, b.width > 0, b.height > 0 else { return b }
        let s = min(b.width / aspect.width, b.height / aspect.height)
        let w = (aspect.width * s).rounded(.down), h = (aspect.height * s).rounded(.down)
        return CGRect(x: ((b.width - w) / 2).rounded(), y: ((b.height - h) / 2).rounded(), width: w, height: h)
    }
    func install(_ v: TouchTarget?, aspect: CGSize) {
        endTouch(cancelled: true)
        content?.removeFromSuperview()
        content = v
        self.aspect = aspect
        guard let v = v else { return }
        importView?.removeFromSuperview(); importView = nil
        v.frame = fitRect(aspect)
        v.isUserInteractionEnabled = false   // the touches come here (and go to the screen as the mouse)
        view.addSubview(v)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let v = content { v.frame = fitRect(aspect) }
        importView?.frame = view.bounds
    }

    // MARK: touches -> mouse

    private enum Phase { case pending, dragging, holding }
    private var touch: UITouch?
    private var phase = Phase.pending
    private var start = CGPoint.zero, last = CGPoint.zero
    private var holdTimer: Timer?
    private var lastTap: (time: Date, at: CGPoint)?
    /// How far a finger may wander before a press becomes a drag (points).
    private let slop: CGFloat = 10

    private func point(_ t: UITouch) -> CGPoint {
        guard let v = content else { return .zero }
        let p = t.location(in: v)
        return CGPoint(x: min(max(p.x, 0), v.bounds.width - 1), y: min(max(p.y, 0), v.bounds.height - 1))
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touch == nil, let t = touches.first, content != nil else { return }
        touch = t
        began(point(t))
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touch, touches.contains(t) else { return }
        moved(point(t))
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touch, touches.contains(t) else { return }
        last = point(t)
        endTouch(cancelled: false)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touch, touches.contains(t) else { return }
        endTouch(cancelled: true)
    }
    private var active: Bool { touch != nil || scripted }
    private func began(_ p: CGPoint) {
        guard let v = content else { return }
        phase = .pending
        start = p; last = p
        v.touchMoved(p)
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self = self, self.phase == .pending, let v = self.content else { return }
            self.phase = .holding
            v.touchHeld(self.start)
        }
    }
    private func moved(_ p: CGPoint) {
        guard let v = content else { return }
        switch phase {
        case .pending:
            guard hypot(p.x - start.x, p.y - start.y) > slop else { return }
            holdTimer?.invalidate(); holdTimer = nil
            phase = .dragging
            v.touchPressed(start)
            v.touchDragged(p, by: CGPoint(x: p.x - start.x, y: p.y - start.y))
        case .dragging:
            v.touchDragged(p, by: CGPoint(x: p.x - last.x, y: p.y - last.y))
        case .holding:
            break
        }
        last = p
    }

    /// H4TOUCHES (simctl launch with SIMCTL_CHILD_H4TOUCHES): scripted touches for checking the
    /// mapping without a finger, in canvas pixels (1024 x 768): "wait 2;tap 512,384;hold 100,200 1.5;
    /// drag 300,300 500,400" (steps 1 s apart unless a wait says otherwise).
    private var scripted = false
    func runTouchScript(_ script: String) {
        var steps = script.split(separator: ";").map { $0.split(separator: " ").map(String.init) }
        func pt(_ s: String) -> CGPoint {
            let c = s.split(separator: ",").compactMap { Double($0) }
            let k = (content?.bounds.width ?? 1024) / 1024
            return CGPoint(x: (c.first ?? 0) * k, y: (c.count > 1 ? c[1] : 0) * k)
        }
        func next() {
            guard !steps.isEmpty else { return }
            let s = steps.removeFirst()
            var after = 1.0
            switch s.first {
            case "wait": after = Double(s.count > 1 ? s[1] : "1") ?? 1
            case "tap" where s.count > 1:
                scripted = true; began(pt(s[1])); last = pt(s[1]); endTouch(cancelled: false); scripted = false
            case "hold" where s.count > 1:
                let held = Double(s.count > 2 ? s[2] : "1") ?? 1
                scripted = true; began(pt(s[1]))
                DispatchQueue.main.asyncAfter(deadline: .now() + held) { [self] in endTouch(cancelled: false); scripted = false }
                after = held + 1
            case "drag" where s.count > 2:
                let a = pt(s[1]), b = pt(s[2])
                scripted = true; began(a)
                for k in 1...10 {
                    let t = CGFloat(k) / 10
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(k)) { [self] in moved(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in endTouch(cancelled: false); scripted = false }
            default: break
            }
            print("touch script: \(s.joined(separator: " "))")
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { next() }
        }
        next()
    }
    private func endTouch(cancelled: Bool) {
        holdTimer?.invalidate(); holdTimer = nil
        defer { touch = nil; phase = .pending }
        guard active, let v = content else { return }
        switch phase {
        case .pending:
            guard !cancelled else { return }
            let now = Date()
            let double = lastTap.map { now.timeIntervalSince($0.time) < 0.35 && hypot($0.at.x - start.x, $0.at.y - start.y) < 24 } ?? false
            lastTap = double ? nil : (now, start)
            v.touchMoved(start)
            v.touchPressed(start)
            v.touchReleased(start, clicks: double ? 2 : 1)
        case .dragging:
            v.touchReleased(last, clicks: 1)
        case .holding:
            v.touchHoldEnded(last)
        }
    }

    // MARK: no data yet: the import screen

    func showImport() {
        importView?.removeFromSuperview()
        let box = UIView(frame: view.bounds)
        box.backgroundColor = .black
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .body)
        label.text = """
            H4 Remake needs the original game's data.

            Copy the game's "Data" folder (with heroes4.h4r) into this app's folder \
            ("On My iPhone > H4 Remake") with the Files app, or import it here. \
            The game's "maps" folder may go beside it for the single scenarios.
            """
        let status = UILabel()
        status.textAlignment = .center
        status.textColor = .lightGray
        status.font = .preferredFont(forTextStyle: .footnote)
        status.numberOfLines = 0
        statusLabel = status
        var pick = UIButton.Configuration.filled(); pick.title = "Import Data Folder…"
        let pickButton = UIButton(configuration: pick, primaryAction: UIAction { [weak self] _ in self?.pickFolder() })
        var again = UIButton.Configuration.gray(); again.title = "Check Again"
        let againButton = UIButton(configuration: again, primaryAction: UIAction { [weak self] _ in
            if IOSData.isPresent { AppController.shared.start() } else { self?.statusLabel?.text = "No Data/heroes4.h4r in the app's Documents folder yet." }
        })
        let buttons = UIStackView(arrangedSubviews: [pickButton, againButton])
        buttons.spacing = 16
        let stack = UIStackView(arrangedSubviews: [label, buttons, status])
        stack.axis = .vertical; stack.alignment = .center; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: box.centerXAnchor), stack.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: box.safeAreaLayoutGuide.widthAnchor, constant: -40),
        ])
        view.addSubview(box)
        importView = box
    }
    private func pickFolder() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let picked = urls.first else { return }
        statusLabel?.text = "Copying…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = GameViewController.importData(from: picked)
            DispatchQueue.main.async { [weak self] in
                if let error = result { self?.statusLabel?.text = error }
                else { self?.statusLabel?.text = "Imported."; AppController.shared.start() }
            }
        }
    }
    /// Copy the picked folder in: the Data folder itself, or the game folder holding Data (and maps).
    /// Nil when it worked, else what went wrong.
    static func importData(from picked: URL) -> String? {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        var copies: [(URL, URL)] = []
        if fm.fileExists(atPath: picked.appendingPathComponent("heroes4.h4r").path) {
            copies.append((picked, IOSData.dataDirectory))
        } else if fm.fileExists(atPath: picked.appendingPathComponent("Data/heroes4.h4r").path) {
            copies.append((picked.appendingPathComponent("Data"), IOSData.dataDirectory))
            let maps = picked.appendingPathComponent("maps")
            if fm.fileExists(atPath: maps.path) { copies.append((maps, IOSData.documents.appendingPathComponent("maps"))) }
        } else {
            return "That folder has no heroes4.h4r (pick the game's Data folder or the folder holding it)."
        }
        do {
            for (from, to) in copies {
                if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                try fm.copyItem(at: from, to: to)
            }
        } catch { return "Copying failed: \(error.localizedDescription)" }
        return nil
    }
}
#endif
