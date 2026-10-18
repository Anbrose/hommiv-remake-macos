import AppKit
import AVFoundation
import Metal
import H4Engine

/// The win / lose window (heroes4.exe t_win_lose_window, ctor 0x4a3450, init 0x4a37c0;
/// re/end_sequence_spec.md): once the scenario is over (0x4c5df0: the sound loops stop) and every
/// message is read, the adventure screen closes and this full-screen window plays the outcome's
/// movie once (bink.win_game / bink.lose_game, 800x600 at (112,84) in the 1024 layout) inside
/// the frame of layers.dialog.win_lose.Epilogue_1024 (Top, Left, Bottom, Right, drawn over it).
/// The music stops (0x7a4620); the movie's own sound plays. The movie's end or any key or press
/// (the input interceptor 0x7d24e0) closes it, then 0x4c5850 carries on (EndStep).
final class EndGameWindow {
    let won: Bool
    var started: Date?
    var audio: AVAudioPlayer?
    var texture: MTLTexture?
    var shownFrame = -1
    var closed = false
    init(won: Bool) { self.won = won }
    /// The movie's place in the 1024 layout (+0xcc / +0xd0).
    static let movieOrigin = (x: 112, y: 84)
    static let frameFile = "win_lose.Epilogue_1024"
}

extension Renderer {
    /// The scenario is over: open the win / lose window once nothing else is up.
    func startEndSequenceIfDue() {
        guard let g = game, let won = g.outcome, endGame == nil, !outcomeShown, prompt == nil, !inCombat,
              g.scripts.messages.isEmpty else { return }
        outcomeShown = true
        sound?.stopAllLoops()   // 0x503bd0
        sound?.stopMusic()      // 0x7a4620
        townOpen = nil
        endGame = EndGameWindow(won: won)
    }

    /// The window's pictures: the movie's current frame under the four frame pieces.
    func endGameQuads(now: Date) -> [Quad] {
        guard let w = endGame, let ui = ui else { return [] }
        var out: [Quad] = []
        if let m = movies?.movie(EndStep.movie(won: w.won)) {
            if w.started == nil {   // it starts once decoded, with its sound
                w.started = now
                if let a = m.audio, let p = try? AVAudioPlayer(contentsOf: a) {
                    p.volume = sound?.effectVolume ?? 0.8
                    p.play(); w.audio = p
                }
            }
            let i = min(m.count - 1, Int(now.timeIntervalSince(w.started!) * m.fps))
            if w.texture == nil || w.texture!.width != m.width || w.texture!.height != m.height {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: m.width, height: m.height, mipmapped: false)
                d.usage = .shaderRead
                w.texture = device.makeTexture(descriptor: d)
                w.shownFrame = -1
            }
            if let t = w.texture, i != w.shownFrame {
                let bm = m.frame(i)
                bm.pixels.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, m.width, m.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: m.width * 4) }
                w.shownFrame = i
            }
            if let t = w.texture { out.append(Quad(texture: t, x: EndGameWindow.movieOrigin.x, y: EndGameWindow.movieOrigin.y, w: m.width, h: m.height)) }
        } else if Movies.ffmpeg == nil, w.started == nil {
            w.started = now   // no movie can be decoded: the frame alone, closed by a press
        }
        if let f = ui.dialog(EndGameWindow.frameFile) {
            for n in ["Top", "Left", "Bottom", "Right"] {
                if let l = layer(f, n) { out.append(image(l, key: "dlg|win_lose|\(n)", l.x, l.y)) }
            }
        }
        return out
    }

    /// Each frame: the movie ending closes the window (the movie's done handler 0x4a3760).
    func updateEndGame(now: Date) {
        guard let w = endGame, !w.closed, let s = w.started, let m = movies?.movie(EndStep.movie(won: w.won)) else { return }
        if now.timeIntervalSince(s) >= m.duration { closeEndGame() }
    }

    /// Any key or press while it plays (0x4a3710). True when the window took it.
    @discardableResult
    func skipEndGame() -> Bool {
        guard endGame != nil else { return false }
        closeEndGame()
        return true
    }

    /// The window is done (0x4c5850): the movie stops, then the outcome's next steps.
    func closeEndGame() {
        guard let w = endGame, !w.closed, let g = game else { return }
        w.closed = true
        w.audio?.stop(); w.audio = nil
        // a won campaign scenario: the epilogue / next briefing / results are the menu's (EndStep's
        // campaign steps, decided there once the campaign file is read)
        if w.won, g.campaign != nil { campaignScenarioWon(g); return }
        switch EndStep.after(won: w.won, campaign: false, hasNextScenario: false, campaignFinished: false).first {
        case .finalScore: openFinalScore(g)
        default: leaveToMainMenu()
        }
    }

    /// A won campaign scenario (0x81ad30, 0x4e6020, 0x771070): its score joins the campaign's,
    /// the heroes carry over, and the menu shows the epilogue (if the scenario has one), then the
    /// next scenario's briefing -- or, after the last, the campaign's results.
    func campaignScenarioWon(_ g: GameState) {
        guard let archive = archivePath, let c = g.campaign else { leaveToMainMenu(); return }
        var carry = g.carryOut()
        carry.scores = (g.carriedIn?.scores ?? []) + [g.scenarioScore(team: g.winningTeam ?? g.team(of: g.map.humanColour)).campaignEntry]
        let file = Renderer.savesDirectory.deletingLastPathComponent().appendingPathComponent("carryover.json")
        if let d = try? JSONEncoder().encode(carry) { try? d.write(to: file) }
        relaunch([archive, "--menu", "--next", "\(c.id)", "\(c.index)", "--carry", file.path])
    }

    /// 0x4b6bf0: back to the main menu (the game is over, so no question).
    func leaveToMainMenu() {
        guard let archive = archivePath else { NSApp.terminate(nil); return }
        relaunch([archive, "--menu"])
    }
}
