import Foundation
import H4Engine

/// t_basic_dialog (heroes4.exe 0x558050; dialogs_spec.md parts A and B): the message box, the
/// yes/no question and the right-click popup are one class. The layers.dialog.generic frame
/// (margins 15/15/14/16) holds the text in a scroll band (text_background.small up to two lines,
/// .large from three), Prose_Antique 18 black with the (200,200,200) halo, centred; an optional
/// title banner (dialog.Title) straddling the top edge; rows of pictures with captions; a row of
/// buttons. Sizes come from the two-pass layout 0x5595d0 / 0x558b90.
struct BasicDialog {
    struct Item { var picture: UILayer?; var caption: [String]; var captionW: Int }
    var W = 0, H = 0
    var title: String?
    var lines: [String] = []
    var tw = 0, th = 0, fit = 0            // text size; lines shown (the rest scrolls)
    var band = "small", bandW = 0, bandH = 0, bandT = 0
    var bandX = 0, bandY = 0, textX = 0, textY = 0
    var items: [Item] = []
    var itemPlaces: [(x: Int, y: Int, capX: Int, capY: Int)] = []
    var buttons: [String] = []
    var buttonPlaces: [(x: Int, y: Int, w: Int, h: Int)] = []
}

extension Renderer {
    /// A t_window_background: the file's eight border pieces and background around a W x H window
    /// (0x8cd470/0x8cd890): corners at their boxes (the right/bottom ones moved by the growth), edges
    /// tiled from their own boxes with the last tile clipped, the background tiled from background_rect.
    func nineSlice(_ f: LayerFile, w W: Int, h H: Int) -> Bitmap {
        func l(_ n: String) -> UILayer? { f.layers.first { $0.name.lowercased() == n } }
        let names = ["top_left", "top", "top_right", "left", "right", "bottom_left", "bottom", "bottom_right"]
        let pieces = names.compactMap(l)
        guard pieces.count == 8 else { return Bitmap(width: max(1, W), height: max(1, H)) }
        let bx0 = pieces.map(\.x).min()!, by0 = pieces.map(\.y).min()!
        let bx1 = pieces.map { $0.x + $0.width }.max()!, by1 = pieces.map { $0.y + $0.height }.max()!
        let dW = W - (bx1 - bx0), dH = H - (by1 - by0)
        var bm = Bitmap(width: max(1, W), height: max(1, H))
        func put(_ src: Bitmap, _ x: Int, _ y: Int, clip: (Int, Int, Int, Int)) {
            var c = src
            let cw = min(src.width, clip.2 - x), ch = min(src.height, clip.3 - y)
            guard cw > 0, ch > 0, x + cw > clip.0, y + ch > clip.1 else { return }
            if cw < src.width || ch < src.height { c = Renderer.crop(src, x: 0, y: 0, w: cw, h: ch) }
            AdventureUI.blend(c, onto: &bm, x: x, y: y)
        }
        let all = (0, 0, W, H)
        if let bg = l("background"), let r = l("background_rect") {
            let x0 = r.x - bx0, y0 = r.y - by0, x1 = r.x + r.width - bx0 + dW, y1 = r.y + r.height - by0 + dH
            var y = y0
            while y < y1 { var x = x0; while x < x1 { put(bg.bitmap, x, y, clip: (x0, y0, x1, y1)); x += bg.width }; y += bg.height }
        }
        let tl = l("top_left")!, tr = l("top_right")!, bl = l("bottom_left")!, br = l("bottom_right")!
        for (e, dx, dy) in [(l("top")!, 0, 0), (l("bottom")!, 0, dH)] {
            var x = e.x - bx0
            let end = min(tr.x, br.x) - bx0 + dW
            while x < end { put(e.bitmap, x, e.y - by0 + dy, clip: (0, 0, end, H)); x += e.width }
            _ = dx
        }
        for (e, dx) in [(l("left")!, 0), (l("right")!, dW)] {
            var y = e.y - by0
            let end = min(bl.y, br.y) - by0 + dH
            while y < end { put(e.bitmap, e.x - bx0 + dx, y, clip: (0, 0, W, end)); y += e.height }
        }
        for (c, dx, dy) in [(tl, 0, 0), (tr, dW, 0), (bl, 0, dH), (br, dW, dH)] { put(c.bitmap, c.x - bx0 + dx, c.y - by0 + dy, clip: all) }
        return bm
    }
    /// A t_window_background's margins: client_area minus the border pieces' bounding box (L, T, R, B).
    func sliceMargins(_ f: LayerFile) -> (l: Int, t: Int, r: Int, b: Int) {
        let pieces = ["top_left", "top", "top_right", "left", "right", "bottom_left", "bottom", "bottom_right"].compactMap { n in f.layers.first { $0.name.lowercased() == n } }
        guard let c = f.layers.first(where: { $0.name.lowercased() == "client_area" }), !pieces.isEmpty else { return (15, 15, 14, 16) }
        let bx0 = pieces.map(\.x).min()!, by0 = pieces.map(\.y).min()!
        let bx1 = pieces.map { $0.x + $0.width }.max()!, by1 = pieces.map { $0.y + $0.height }.max()!
        return (c.x - bx0, c.y - by0, bx1 - c.x - c.width, by1 - c.y - c.height)
    }

    /// 0x71c5e0: wrap starting at the widest word, widening by half until the text is at least four
    /// times as wide as tall, fits one line, or reaches maxW.
    static func fitWrap(_ text: String, font: H4Font, minW: Int, maxW: Int) -> (lines: [String], w: Int) {
        let widest = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map { font.measure(String($0)) }.max() ?? 0
        var w = max(minW, min(widest, maxW))
        var lines = AdventureUI.wrap(text, font: font, width: w)
        while lines.count > 1 && w < maxW && 4 * font.lineHeight * lines.count > w {
            w = min(w * 3 / 2, maxW)
            lines = AdventureUI.wrap(text, font: font, width: w)
        }
        return (lines, max(minW, lines.map { font.measure($0) }.max() ?? 0))
    }

    /// The two-pass layout of a basic dialog.
    func basicDialog(text: String, title: String? = nil, items: [(picture: UILayer?, caption: String)] = [], buttons: [String] = []) -> BasicDialog? {
        guard let ui = ui else { return nil }
        var d = BasicDialog()
        let f = ui.font(18), lh = f.lineHeight
        d.title = title
        let fit = Renderer.fitWrap(text, font: f, minW: 0, maxW: AdventureUI.width - 150)
        d.lines = fit.lines; d.tw = fit.w
        d.th = min(d.lines.count * lh, AdventureUI.height - 200)
        d.fit = max(1, d.th / lh)
        d.band = d.th < 60 ? "small" : "large"
        let m = ui.popupFrame(d.band).map(sliceMargins) ?? (l: 12, t: 8, r: 13, b: 9)
        d.bandW = d.tw + m.l + m.r; d.bandH = d.th + m.t + m.b; d.bandT = m.t
        // pass 1: sizes
        let start = title != nil ? 60 : 15
        var cursor = start + d.bandH + 10
        d.items = items.map { it in
            if it.caption.isEmpty { return BasicDialog.Item(picture: it.picture, caption: [], captionW: 0) }
            let c = Renderer.fitWrap(it.caption, font: f, minW: 40, maxW: 160)
            return BasicDialog.Item(picture: it.picture, caption: c.lines, captionW: c.w)
        }
        let cellW = d.items.map { max($0.picture?.width ?? 0, $0.captionW) }.max() ?? 0
        let picH = d.items.map { $0.picture?.height ?? 0 }.max() ?? 0
        let capH = d.items.map { $0.caption.count * lh }.max() ?? 0
        let rowW = d.items.isEmpty ? 0 : d.items.count * cellW + (d.items.count - 1) * 10
        var picY = 0, capY = 0
        if !d.items.isEmpty {
            picY = cursor; cursor += picH + 10
            if capH > 0 { capY = cursor; cursor += capH + 10 }
        }
        let sizes = buttons.map { (ui.button($0) ?? ui.button($0, state: "released")).map { ($0.x + $0.width, $0.y + $0.height) } ?? (76, 44) }
        let bw = sizes.map(\.0).max() ?? 0, bh = sizes.map(\.1).max() ?? 0
        let btnRowW = buttons.isEmpty ? 0 : buttons.count * bw + (buttons.count - 1) * 10
        let btnY = cursor
        if !buttons.isEmpty { cursor += bh }
        let unionW = max(d.bandW, title != nil ? 318 : 0, rowW > 0 ? 15 + rowW : 0, btnRowW > 0 ? 15 + btnRowW : 0)
        let unionH = max(title != nil ? 60 : 0, d.bandH, (d.items.isEmpty && buttons.isEmpty) ? 0 : cursor)
        d.W = unionW + 29; d.H = unionH + 31
        // pass 2: places, each row centred between the margins
        let inner = d.W - 29
        d.bandX = 15 + (inner - d.bandW) / 2; d.bandY = start
        d.textX = 15 + (inner - d.tw) / 2; d.textY = d.bandY + d.bandT
        let rx = 15 + (inner - rowW) / 2
        d.itemPlaces = d.items.enumerated().map { k, it in
            let cx = rx + k * (cellW + 10)
            let pw = it.picture?.width ?? 0, ph = it.picture?.height ?? 0
            return (cx + (cellW - pw) / 2, picY + picH - ph, cx + (cellW - it.captionW) / 2, capY)
        }
        let bx = 15 + (inner - btnRowW) / 2
        d.buttons = buttons
        d.buttonPlaces = sizes.enumerated().map { k, s in (bx + k * (bw + 10) + (bw - s.0) / 2, btnY + bh - s.1, s.0, s.1) }
        return d
    }

    /// The quads of a basic dialog with its top-left at (x, y); `scroll` = the first text line shown.
    func basicDialogQuads(_ d: BasicDialog, x: Int, y: Int, scroll: Int = 0, pressed: String? = nil) -> [Quad] {
        guard let ui = ui, let gen = ui.dialog("generic") else { return [] }
        var out: [Quad] = []
        out.append(Quad(texture: uiTexture("generic|\(d.W)x\(d.H)", { nineSlice(gen, w: d.W, h: d.H) }), x: x, y: y, w: d.W, h: d.H))
        if let bf = ui.popupFrame(d.band) {
            out.append(Quad(texture: uiTexture("band|\(d.band)|\(d.bandW)x\(d.bandH)", { nineSlice(bf, w: d.bandW, h: d.bandH) }), x: x + d.bandX, y: y + d.bandY, w: d.bandW, h: d.bandH))
        }
        let f = ui.font(18)
        let shown = Array(d.lines.dropFirst(scroll).prefix(d.fit))
        let top = y + d.textY + (d.th - shown.count * f.lineHeight) / 2
        for (i, line) in shown.enumerated() where !line.isEmpty {
            let w = f.measure(line)
            out.append(Quad(texture: uiTexture("atext|18|\(line)", { f.render(line, colour: (0, 0, 0), halo: Renderer.armyHalo) }), x: x + d.textX + (d.tw - w) / 2, y: top + i * f.lineHeight, w: w, h: f.size))
        }
        if let t = d.title, let tf = ui.dialog("Title"), let banner = tf["Banner"], let box = tf["Text"] {
            let bx = x + (d.W - banner.width) / 2
            out.append(Quad(texture: uiTexture("titlebanner", { banner.bitmap }), x: bx, y: y, w: banner.width, h: banner.height))
            let f20 = ui.font(20), w = f20.measure(t)
            let ty = y + box.y + (box.height - f20.lineHeight) / 2
            out.append(Quad(texture: uiTexture("dtext|20|\(t)", { f20.render(t, colour: (0, 0, 0)) }), x: bx + box.x + (box.width - w) / 2, y: ty, w: w, h: f20.size))
        }
        for (it, p) in zip(d.items, d.itemPlaces) {
            if let pic = it.picture { out.append(Quad(texture: uiTexture("dpic|\(pic.name)|\(pic.width)", { pic.bitmap }), x: x + p.x, y: y + p.y, w: pic.width, h: pic.height)) }
            for (k, line) in it.caption.enumerated() where !line.isEmpty {
                out.append(Quad(texture: uiTexture("atext|18|\(line)", { f.render(line, colour: (0, 0, 0), halo: Renderer.armyHalo) }), x: x + p.capX, y: y + p.capY + k * f.lineHeight, w: f.measure(line), h: f.size))
            }
        }
        for (name, r) in zip(d.buttons, d.buttonPlaces) {
            let over = pointerCanvas.0 >= Float(x + r.x) && pointerCanvas.0 < Float(x + r.x + r.w) && pointerCanvas.1 >= Float(y + r.y) && pointerCanvas.1 < Float(y + r.y + r.h)
            guard let b = ui.button(name, state: over ? "Highlighted" : "Released") ?? ui.button(name) else { continue }
            out.append(Quad(texture: uiTexture("button|\(name)|\(b.name)", { b.bitmap }), x: x + r.x + b.x, y: y + r.y + b.y, w: b.width, h: b.height))
        }
        return out
    }

    /// t_help_balloon (0x727490): black 1-px border, (255,255,216) inside, Prose_Antique 16 black,
    /// centred with 4 px around; its left edge at the pointer, above it when it fits, else 20 px below.
    func helpBalloonQuads(_ s: String, at p: (Float, Float)) -> [Quad] {
        guard let ui = ui, !s.isEmpty else { return [] }
        let f = ui.font(16)
        let lines = AdventureUI.wrap(s, font: f, width: AdventureUI.width - 8)
        let W = (lines.map { f.measure($0) }.max() ?? 0) + 8, H = lines.count * f.lineHeight + 8
        var x = Int(p.0)
        let y = H <= Int(p.1) ? Int(p.1) - H : Int(p.1) + 20
        if x + W > AdventureUI.width { x -= x + W - AdventureUI.width }
        var out = [Quad(texture: black, x: x, y: y, w: W, h: H), Quad(texture: solid(255, 255, 216), x: x + 1, y: y + 1, w: W - 2, h: H - 2)]
        for (i, line) in lines.enumerated() {
            let w = f.measure(line)
            out.append(Quad(texture: uiTexture("btext|16|\(line)", { f.render(line, colour: (0, 0, 0)) }), x: x + (W - w) / 2, y: y + 4 + i * f.lineHeight, w: w, h: f.size))
        }
        return out
    }
    /// The balloon waits a second of the pointer resting.
    var balloonDue: Bool { Date().timeIntervalSince(pointerSince) >= 1 }
}
