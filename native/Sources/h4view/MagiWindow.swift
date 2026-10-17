import Foundation
import H4Engine

/// The Window of the Magi's playback (heroes4.exe 0x842ef0 / 0x842e70, re/window_of_the_magi_spec.md):
/// once its message is closed the view jumps to each Eye of the Magi of its colour (centred on the
/// eye, on the eye's level), 3 s each with the eye's surroundings in full sight, then returns to
/// where it was. Any click or key press ends it at once (the rest explored).
extension Renderer {
    func playMagiView(now: Date) {
        guard let g = game, g.magiView != nil else { return }
        if magiPlayback == nil {
            // it starts when the visit's message has been read (the modal dialog 0x720c80 returns)
            guard g.scripts.messages.isEmpty, prompt == nil else { return }
            magiPlayback = (pan, g.level, now)
        }
        guard let m = magiPlayback, now >= m.due else { return }
        if let e = g.magiViewStep() {
            g.level = e.level
            centre(onCell: (e.x, e.y))
            magiPlayback?.due = now.addingTimeInterval(MagiView.period)
        } else { endMagiView() }
    }
    /// Input while it plays (the interceptor 0x7d24e0 -> 0x842e70): finish at once. True when used.
    @discardableResult
    func skipMagiView() -> Bool {
        guard let g = game, magiPlayback != nil else { return false }
        g.magiViewFinish()
        endMagiView()
        return true
    }
    private func endMagiView() {
        guard let m = magiPlayback else { return }
        game?.magiView = nil
        game?.level = m.level
        pan = m.pan
        magiPlayback = nil
    }
}
