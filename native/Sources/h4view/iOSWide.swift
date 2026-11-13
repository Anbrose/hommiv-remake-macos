#if os(iOS)
import Foundation
import H4Engine

/// The wide phone screen (no stretching: one uniform scale, the canvas 768 high and as wide as the
/// screen's aspect). The game's screens are laid out on 1024x768; `Renderer.frameOffset` places that
/// frame on the wider canvas:
/// - the adventure screen keeps its right panel at the right (safe) edge and the map window grows
///   to the left edge of the screen;
/// - combat keeps the battlefield and its panel at the right (safe) edge; the touch sidebar
///   (iOSCombatTouch.swift) takes the room on the left;
/// - the town and the end screens stay 1024x768, centred, dark at the sides.
/// Large modal windows over the adventure map (the hero, army, kingdom screens...) are centred on
/// the screen rather than on the frame.
enum IOSWide {
    /// The screen's unsafe insets (notch / Dynamic Island, rounded corners) in canvas pixels,
    /// set by the view controller.
    static var safeLeft: Float = 0, safeRight: Float = 0
}

extension Renderer {
    /// The canvas's width (768 high).
    var canvasWidth: Float { viewSize.y > 0 ? viewSize.x / uiScale : Float(AdventureUI.width) }
    /// What a touch's canvas x is moved by to land on the frame's (and a centred window's) pixels.
    var pointerShift: Float { frameOffset + modalShift }
    /// The touch sidebar's room in frame canvas pixels: from the left safe edge to the frame (empty
    /// when there is none).
    var sidebarRect: (x: Int, y: Int, w: Int, h: Int) {
        let x0 = Int((IOSWide.safeLeft - frameOffset).rounded(.up)) + 6
        return (x0, 8, max(0, -6 - x0), AdventureUI.height - 16)
    }

    /// Place the frame for the screen showing now.
    func layoutWide() {
        let w = canvasWidth, extra = w - Float(AdventureUI.width)
        guard extra > 1 else { frameOffset = 0; wideMapLeft = nil; return }
        let rightAnchored = (w - IOSWide.safeRight - Float(AdventureUI.width)).rounded(.down)
        if endGame != nil || (townOpen != nil && town != nil) || ui == nil {
            frameOffset = (extra / 2).rounded(.down); wideMapLeft = nil
        } else if inCombat {
            frameOffset = max(0, rightAnchored); wideMapLeft = nil
        } else {
            // the map window from the screen's left edge, right of the frame's 8-pixel Left piece
            frameOffset = max(0, rightAnchored); wideMapLeft = 8 - frameOffset
        }
        if !inCombat { combatPick = nil; sidebarButtons = [] }
    }

    /// A modal window at least 600 canvas pixels wide over the adventure map is moved to the
    /// screen's centre (with what is drawn after it); the pointer follows (`modalShift`).
    func centreLargeModal(_ list: [Quad]) -> [Quad] {
        modalShift = 0
        guard !inCombat, endGame == nil, townOpen == nil, frameOffset > 0 else { return list }
        var start: Int? = nil
        var i = 0
        while i < list.count {
            guard case .modal? = list[i].press else { i += 1; continue }
            var j = i + 1, x0 = Int.max, x1 = Int.min
            while j < list.count { if case .modal? = list[j].press { break }; x0 = min(x0, list[j].x); x1 = max(x1, list[j].x + list[j].w); j += 1 }
            if x1 - x0 >= 600 { start = i; break }
            i = j
        }
        guard let s = start else { return list }
        let shift = Int(((canvasWidth - Float(AdventureUI.width)) / 2 - frameOffset).rounded())
        modalShift = Float(shift)
        var out = list
        for k in s..<out.count {
            out[k].x += shift
            if let c = out[k].clip { out[k].clip = (c.x + shift, c.y, c.w, c.h) }
        }
        return out
    }

    /// The adventure frame on a wide canvas: the map window runs to the screen's left edge. The
    /// frame's left end (the Left piece, the left dragons of the top and bottom borders) moves
    /// there, and the plain middle of the top and bottom strips repeats (never stretched) to join it.
    func wideFrameQuads(_ ui: AdventureUI) -> [Quad]? {
        guard let mapLeft = wideMapLeft, mapLeft < 8 else { return nil }
        let shift = Int(mapLeft) - 8   // where the frame's left end goes (frame pixels, < 0)
        var out: [Quad] = []
        for name in Renderer.framePieces {
            guard let l = frameLayer(ui, name) else { continue }
            let tex = uiTexture("frame|\(l.name)", { l.bitmap })
            switch name {
            case "Left", "Left_Border":
                out.append(Quad(texture: tex, x: l.x + shift, y: l.y, w: l.width, h: l.height))
            case "Top", "Top_Border", "Bottom", "Bottom_Border":
                // the piece's left end (the corner dragon) at the left edge, its plain middle
                // [cut, cut + tile) repeated over the gap, the rest where it was
                let cut = min(Renderer.wideFrameCut, l.width), tile = min(Renderer.wideFrameTile, l.width - cut)
                guard tile > 0 else { out.append(Quad(texture: tex, x: l.x, y: l.y, w: l.width, h: l.height)); continue }
                let head = uiTexture("framehead|\(l.name)", { Renderer.crop(l.bitmap, x: 0, y: 0, w: cut, h: l.height) })
                let mid = uiTexture("framemid|\(l.name)", { Renderer.crop(l.bitmap, x: cut, y: 0, w: tile, h: l.height) })
                let rest = uiTexture("framerest|\(l.name)", { Renderer.crop(l.bitmap, x: cut, y: 0, w: l.width - cut, h: l.height) })
                out.append(Quad(texture: head, x: l.x + shift, y: l.y, w: cut, h: l.height))
                var x = l.x + shift + cut
                let end = l.x + cut
                while x < end {
                    out.append(Quad(texture: mid, x: x, y: l.y, w: tile, h: l.height, clip: (x, l.y, min(tile, end - x), l.height)))
                    x += tile
                }
                out.append(Quad(texture: rest, x: end, y: l.y, w: l.width - cut, h: l.height))
            default:
                out.append(Quad(texture: tex, x: l.x, y: l.y, w: l.width, h: l.height))
            }
        }
        return out
    }
    /// The top and bottom pieces' corner part (their own pixels) and the plain stretch after it
    /// that repeats on a wide screen.
    static let wideFrameCut = 130, wideFrameTile = 60
}
#endif
