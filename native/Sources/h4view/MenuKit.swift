import Foundation
import H4Engine

/// The generic window machinery of heroes4.exe that the menus and system dialogs are built from
/// (menus_spec.md, army_screen_spec.md §0), producing positioned bitmaps that both the main menu
/// (CoreGraphics) and the adventure screen (Metal quads) draw:
/// * bitmap windows: a layout layer at its own box (kind-1 layers with a palette are images too);
/// * t_text_window: the font 0x875bc0(size) = the largest cached slot <= size, black text with the
///   (200,200,200) halo, left / centred / right, optionally centred vertically, word-wrapped;
/// * t_button at a hotspot's top-left, the large text button (layers.button.large with its
///   released_text / pressed_text / disabled_text captions in Prose_Antique 18);
/// * the translucent selection fill 0x59ebc0 (RGB 0,0,200 at 8/16);
/// * t_scrollbar (control.vertical_scroll / horizontal_scroll) and the t_scroll_menu pop-up.
struct UIItem {
    let key: String
    let make: () -> Bitmap
    let x: Int, y: Int, w: Int, h: Int
}

/// A rectangle on the canvas.
struct UIRect {
    var x: Int, y: Int, w: Int, h: Int
    init(_ x: Int, _ y: Int, _ w: Int, _ h: Int) { self.x = x; self.y = y; self.w = w; self.h = h }
    init(_ l: UILayer, _ ox: Int = 0, _ oy: Int = 0) { x = l.x + ox; y = l.y + oy; w = l.width; h = l.height }
    func contains(_ px: Float, _ py: Float) -> Bool { px >= Float(x) && px < Float(x + w) && py >= Float(y) && py < Float(y + h) }
    func offset(_ dx: Int, _ dy: Int) -> UIRect { UIRect(x + dx, y + dy, w, h) }
}

enum ButtonLook { case released, pressed, highlighted, disabled }

final class MenuKit {
    typealias RGB = (UInt8, UInt8, UInt8)
    static let halo: RGB = (200, 200, 200)
    /// Archives searched in order (the first that has a resource wins: updates, x2, storm, heroes4).
    let archives: [H4Archive]
    let strings: () -> [String: String]
    init(archives: [H4Archive], strings: @escaping () -> [String: String]) {
        self.archives = archives; self.strings = strings
    }
    func t(_ key: String, _ fallback: String) -> String { strings()[key] ?? fallback }

    // MARK: resources

    func payload(_ name: String) -> Data? {
        for a in archives { if let d = try? a.payload(name) { return d } }
        let low = name.lowercased()
        for a in archives {
            if let e = a.entries.first(where: { $0.name.lowercased() == low }), let d = try? a.payload(e.name) { return d }
        }
        return nil
    }
    private var files: [String: LayerFile?] = [:]
    /// A layer file by its name without "layers." and ".h4d" ("dialog.options", "button.large").
    func file(_ name: String) -> LayerFile? {
        if let f = files[name] { return f }
        let f = payload("layers.\(name).h4d").flatMap { try? LayerFile(data: $0) }
        files[name] = f
        return f
    }
    /// A layer of a file, the name compared without case (0x58e950 is case-insensitive).
    static func find(_ f: LayerFile?, _ n: String) -> UILayer? {
        guard let f = f else { return nil }
        if let l = f[n] { return l }
        let low = n.lowercased()
        return f.layers.first { $0.name.lowercased() == low }
    }
    func layer(_ file: String, _ n: String) -> UILayer? { MenuKit.find(self.file(file), n) }

    /// The font slots of 0x875bc0 (table 0xa84798; menus_spec A.0).
    static let fontSlots: [(Int, String)] = [(9, "Small Fonts5"), (11, "Small Fonts6"), (12, "Prose_Antique.12"), (14, "Prose_Antique.14"),
                                              (16, "Prose_Antique.16"), (18, "Prose_Antique.18"), (20, "Prose_Antique.20"), (23, "Prose_Antique.22"),
                                              (25, "Prose_Antique.24"), (27, "Prose_Antique.26"), (29, "Prose_Antique.28"), (30, "Prose_Antique.30"),
                                              (33, "Prose_Antique.32"), (34, "Prose_Antique.34")]
    private var fonts: [String: H4Font] = [:]
    func fontNamed(_ n: String) -> H4Font? {
        if let f = fonts[n] { return f }
        guard let d = payload("font.\(n).h4d"), let f = try? H4Font(data: d) else { return nil }
        fonts[n] = f
        return f
    }
    /// The largest cached font no bigger than `size`.
    func font(_ size: Int) -> H4Font {
        let name = MenuKit.fontSlots.last { $0.0 <= size }?.1 ?? "Small Fonts5"
        return fontNamed(name) ?? fontNamed("Prose_Antique.14")!
    }

    // MARK: bitmap windows

    /// A layer at its own box plus (dx, dy) (0x597e50 with flag 1).
    func image(_ l: UILayer?, _ tag: String, _ dx: Int = 0, _ dy: Int = 0) -> [UIItem] {
        guard let l = l, l.width > 0, l.height > 0 else { return [] }
        return [UIItem(key: "mk|\(tag)|\(l.name)|\(l.x),\(l.y),\(l.width)x\(l.height)", make: { l.bitmap }, x: l.x + dx, y: l.y + dy, w: l.width, h: l.height)]
    }
    /// A layer of a file at its own box plus (dx, dy).
    func image(_ file: String, _ n: String, _ dx: Int = 0, _ dy: Int = 0) -> [UIItem] { image(layer(file, n), file, dx, dy) }
    /// A layer with its top-left at (x, y), its box origin ignored (0x597e50 with flag 0).
    func imageAt(_ l: UILayer?, _ tag: String, _ x: Int, _ y: Int) -> [UIItem] {
        guard let l = l else { return [] }
        return image(l, tag, x - l.x, y - l.y)
    }
    /// A button file's state image at a window top-left (the file's boxes start at 0,0), falling back
    /// to Released when the state has no image (0x5a1200).
    func button(_ file: String, _ look: ButtonLook, _ x: Int, _ y: Int) -> [UIItem] {
        let f = self.file("button.\(file)")
        let names: [String]
        switch look {
        case .released: names = ["Released"]
        case .pressed: names = ["Pressed", "Released"]
        case .highlighted: names = ["Highlighted", "Released"]
        case .disabled: names = ["Disabled", "Released"]
        }
        guard let l = names.lazy.compactMap({ MenuKit.find(f, $0) }).first else { return [] }
        return image(l, "button.\(file)", x, y)
    }
    /// A layout-image button (0x5a2250 / 0x52d990): `<prefix>_Released/_Pressed/_Highlighted/_Disabled` at their own boxes.
    func layoutButton(_ file: String, _ prefix: String, _ look: ButtonLook, _ dx: Int, _ dy: Int) -> [UIItem] {
        let f = self.file(file)
        let names: [String]
        switch look {
        case .released: names = ["Released"]
        case .pressed: names = ["Pressed", "Released"]
        case .highlighted: names = ["Highlighted", "Released"]
        case .disabled: names = ["Disabled", "Released"]
        }
        guard let l = names.lazy.compactMap({ MenuKit.find(f, "\(prefix)_\($0)") }).first else { return [] }
        return image(l, file, dx, dy)
    }

    // MARK: text windows

    struct Style {
        var size: Int
        var colour: RGB = (0, 0, 0)
        var halo: RGB? = MenuKit.halo
        var just = 0          // +0xc4: 0 left, 1 centre, 2 right
        var vcentre = false   // +0xd4
        init(_ size: Int, colour: RGB = (0, 0, 0), halo: RGB? = MenuKit.halo, just: Int = 0, vcentre: Bool = false) {
            self.size = size; self.colour = colour; self.halo = halo; self.just = just; self.vcentre = vcentre
        }
    }
    /// The lines a text takes in a width.
    func lines(_ s: String, _ st: Style, width: Int) -> [String] {
        let f = font(st.size)
        return s.components(separatedBy: "\n").flatMap { $0.isEmpty ? [""] : AdventureUI.wrap($0, font: f, width: width) }
    }
    /// A t_text_window: the text wrapped to the rect, justified, optionally centred vertically,
    /// clipped to the rect; `scroll` moves the text up by that many pixels.
    func text(_ s: String, _ r: UIRect, _ st: Style, scroll: Int = 0, clip: Bool = true) -> [UIItem] {
        guard !s.isEmpty, r.w > 0 else { return [] }
        let f = font(st.size)
        let ls = lines(s, st, width: r.w)
        var y = r.y - scroll
        if st.vcentre, ls.count * f.lineHeight < r.h { y = r.y + (r.h - ls.count * f.lineHeight) / 2 }
        var out: [UIItem] = []
        let c = st.colour, h = st.halo
        let hk = h.map { "\($0.0),\($0.1),\($0.2)" } ?? "-"
        for (k, line) in ls.enumerated() where !line.isEmpty {
            let w = f.measure(line)
            let x = st.just == 1 ? r.x + max(0, (r.w - w) / 2) : st.just == 2 ? r.x + max(0, r.w - w) : r.x
            let item = UIItem(key: "mkt|\(f.size)|\(f.lineHeight)|\(c.0),\(c.1),\(c.2)|\(hk)|\(line)", make: { f.render(line, colour: c, halo: h) }, x: x, y: y + k * f.lineHeight, w: w, h: f.size)
            out += clip ? MenuKit.clip([item], to: r) : [item]
        }
        return out
    }
    /// The text's height in lines of its font.
    func textHeight(_ s: String, _ st: Style, width: Int) -> Int { lines(s, st, width: width).count * font(st.size).lineHeight }

    /// Items cut to a rectangle (the parts outside dropped).
    static func clip(_ items: [UIItem], to r: UIRect) -> [UIItem] {
        items.compactMap { it in
            let x0 = max(it.x, r.x), y0 = max(it.y, r.y), x1 = min(it.x + it.w, r.x + r.w), y1 = min(it.y + it.h, r.y + r.h)
            guard x1 > x0, y1 > y0 else { return nil }
            if x0 == it.x, y0 == it.y, x1 == it.x + it.w, y1 == it.y + it.h { return it }
            let sx = x0 - it.x, sy = y0 - it.y, w = x1 - x0, h = y1 - y0
            let make = it.make
            return UIItem(key: it.key + "|clip\(sx),\(sy),\(w)x\(h)", make: { MenuKit.crop(make(), sx, sy, w, h) }, x: x0, y: y0, w: w, h: h)
        }
    }
    static func crop(_ b: Bitmap, _ sx: Int, _ sy: Int, _ w: Int, _ h: Int) -> Bitmap {
        var o = Bitmap(width: max(1, w), height: max(1, h))
        for y in 0..<h where sy + y < b.height {
            for x in 0..<w where sx + x < b.width {
                let s = ((sy + y) * b.width + sx + x) * 4, d = (y * o.width + x) * 4
                o.pixels[d] = b.pixels[s]; o.pixels[d + 1] = b.pixels[s + 1]; o.pixels[d + 2] = b.pixels[s + 2]; o.pixels[d + 3] = b.pixels[s + 3]
            }
        }
        return o
    }

    /// The translucent fill window 0x59ebc0: RGB (0,0,200) at `level` of 15 (8 = the selection bar).
    func fill(_ r: UIRect, _ rgb: RGB = (0, 0, 200), level: Int = 8) -> [UIItem] {
        guard r.w > 0, r.h > 0 else { return [] }
        let a = UInt8(min(15, max(0, level)) * 17)
        return [UIItem(key: "mkfill|\(rgb.0),\(rgb.1),\(rgb.2),\(a)|\(r.w)x\(r.h)", make: {
            var b = Bitmap(width: r.w, height: r.h)
            for k in 0..<(r.w * r.h) { b.pixels[k * 4] = rgb.0; b.pixels[k * 4 + 1] = rgb.1; b.pixels[k * 4 + 2] = rgb.2; b.pixels[k * 4 + 3] = a }
            return b
        }, x: r.x, y: r.y, w: r.w, h: r.h)]
    }

    // MARK: buttons

    /// The large text button (layers.button.large, 166x40) with its top-left at (x, y): the state
    /// image and the caption in that state's *_text rect, Prose_Antique 18 centred both ways, black
    /// with the halo, (100,100,100) when disabled (0x5a0010 with a label, 0x5a1380).
    func largeButton(_ label: String, _ x: Int, _ y: Int, _ look: ButtonLook) -> [UIItem] {
        let f = file("button.large")
        let state = look == .pressed ? "Pressed" : look == .disabled ? "Disabled" : "Released"
        var out = button("large", look == .highlighted ? .released : look, x, y)
        if let tr = MenuKit.find(f, "\(state.lowercased())_text") {
            out += text(label, UIRect(tr, x, y), Style(tr.height, colour: look == .disabled ? (100, 100, 100) : (0, 0, 0), just: 1, vcentre: true), clip: false)
        }
        return out
    }

    // MARK: scroll bars

    /// A vertical t_scrollbar (control.vertical_scroll): the up arrow at the top, the down arrow at
    /// the bottom, the track tiled between, the thumb at `first` of `total - visible`.
    func vScrollbar(_ x: Int, _ y: Int, _ h: Int, first: Int, visible: Int, total: Int) -> [UIItem] {
        let f = file("control.vertical_scroll")
        guard let up = MenuKit.find(f, "Up_Released"), let down = MenuKit.find(f, "Down_Released"), let bg = MenuKit.find(f, "Background"), let th = MenuKit.find(f, "Thumb") else { return [] }
        var out: [UIItem] = []
        let top = y + up.height, bottom = y + h - down.height
        var ty = top
        while ty < bottom {
            let n = min(bg.height, bottom - ty)
            out += MenuKit.clip(image(bg, "vscroll", x - bg.x, ty - bg.y), to: UIRect(x, ty, bg.width, n))
            ty += n
        }
        out += image(up, "vscroll", x - up.x, y - up.y)
        out += image(down, "vscroll", x - down.x, bottom - down.y)
        let range = max(0, total - visible)
        let span = max(0, bottom - top - th.height)
        let pos = range > 0 ? span * min(first, range) / range : 0
        out += image(th, "vscroll", x, top + pos - th.y)
        return out
    }
    /// Which part of a vertical scrollbar a point is on: -1 up arrow / above the thumb, +1 below / down arrow.
    func vScrollbarHit(_ x: Int, _ y: Int, _ h: Int, _ px: Float, _ py: Float) -> Int? {
        guard px >= Float(x), px < Float(x + 39), py >= Float(y), py < Float(y + h) else { return nil }
        return py < Float(y + h / 2) ? -1 : 1
    }
    /// A horizontal t_scrollbar (control.horizontal_scroll) over a rect: the left arrow at its left, the
    /// right arrow at its right, the track between, the thumb at `value` (0...1).
    func hScrollbar(_ r: UIRect, value: Float) -> [UIItem] {
        let f = file("control.horizontal_scroll")
        guard let up = MenuKit.find(f, "Up_Released"), let down = MenuKit.find(f, "Down_Released"), let bg = MenuKit.find(f, "Background"), let th = MenuKit.find(f, "Thumb") else { return [] }
        var out: [UIItem] = []
        let left = r.x + up.width, right = r.x + r.w - down.width
        var tx = left
        while tx < right {
            let n = min(bg.width, right - tx)
            out += MenuKit.clip(image(bg, "hscroll", tx - bg.x, r.y - bg.y), to: UIRect(tx, r.y, n, bg.height))
            tx += n
        }
        out += image(up, "hscroll", r.x - up.x, r.y - up.y)
        out += image(down, "hscroll", right - down.x, r.y - down.y)
        let span = max(0, right - left - th.width)
        out += image(th, "hscroll", left + Int(Float(span) * max(0, min(1, value))) - th.x, r.y)
        return out
    }
    /// The value (0...1) a click on a horizontal scrollbar's track sets.
    func hScrollbarValue(_ r: UIRect, _ px: Float) -> Float {
        let f = file("control.horizontal_scroll")
        let uw = MenuKit.find(f, "Up_Released")?.width ?? 52, dw = MenuKit.find(f, "Down_Released")?.width ?? 56, tw = MenuKit.find(f, "Thumb")?.width ?? 28
        let left = Float(r.x + uw) + Float(tw) / 2, right = Float(r.x + r.w - dw) - Float(tw) / 2
        return max(0, min(1, (px - left) / max(1, right - left)))
    }

    // MARK: the scroll menu (t_scroll_menu, menus_spec A.2)

    struct ScrollMenuRow { let rect: UIRect; let lines: [String] }
    /// The rows of a scroll menu opened at (x, y) = the clicked button's top-left: the menu's right
    /// edge is x; items from y + 102, each 125 wide (text_size) at x 42, its wrapped text + 12 high.
    func scrollMenuRows(_ titles: [String], x: Int, y: Int) -> [ScrollMenuRow] {
        let f = file("dialog.scroll_menu")
        let top = MenuKit.find(f, "top_bar"), ts = MenuKit.find(f, "text_size")
        let x0 = x - (top?.width ?? 212), cy = y + (ts?.y ?? 102)
        let tx = ts?.x ?? 42, tw = ts?.width ?? 125
        let st = Style(20)
        var yy = 0
        var out: [ScrollMenuRow] = []
        for s in titles {
            let ls = lines(s, st, width: tw)
            let h = ls.count * font(20).lineHeight + 12
            out.append(ScrollMenuRow(rect: UIRect(x0 + tx, cy + yy, tw, h), lines: ls))
            yy += h
        }
        return out
    }
    /// The scroll menu's picture: the top bar, the container (tiles every 187 px, the parchment and
    /// the bottom border after the items), the items black on the parchment, the one under the
    /// pointer as white text on the translucent blue bar; `elapsed` seconds since it opened unroll it
    /// 40 px per 20 ms tick with the rolling edge (frame 001..010).
    func scrollMenu(_ titles: [String], x: Int, y: Int, hover: (Float, Float)?, elapsed: Double) -> [UIItem] {
        let f = file("dialog.scroll_menu")
        guard let top = MenuKit.find(f, "top_bar") else { return [] }
        let x0 = x - top.width, y0 = y
        let rows = scrollMenuRows(titles, x: x, y: y)
        let cTop = MenuKit.find(f, "text_size")?.y ?? 102
        let itemsH = rows.reduce(0) { $0 + $1.rect.h }
        let H = itemsH + (MenuKit.find(f, "bottom_border_size")?.height ?? 43)
        let ticks = Int(elapsed / 0.02)
        let visible = min(H, 40 * (ticks + 1))
        let frames = (1...10).compactMap { MenuKit.find(f, String(format: "frame %03d", $0)) }
        let start = frames.count - (H + 39) / 40 - 1
        var out = image(top, "scroll_menu", x0, y0)
        var inner: [UIItem] = []
        // the tiles: left, right and background every 187 px from the container top
        let tileH = MenuKit.find(f, "background")?.height ?? 187
        var k = 0
        while tileH * k < H {
            for n in ["left", "right", "background"] {
                if let l = MenuKit.find(f, n) { inner += image(l, "scroll_menu", x0, y0 + tileH * k + cTop - l.y) }
            }
            k += 1
        }
        for n in ["parchment", "bottom_border"] {
            if let l = MenuKit.find(f, n) { inner += image(l, "scroll_menu", x0, y0 + cTop + itemsH - l.y) }
        }
        for r in rows {
            let hot = hover.map { r.rect.contains($0.0, $0.1) } ?? false
            if hot { inner += fill(r.rect) }
            let st = Style(20, colour: hot ? (255, 255, 255) : (0, 0, 0), halo: nil, vcentre: true)
            inner += text(r.lines.joined(separator: "\n"), r.rect, st, clip: false)
        }
        out += MenuKit.clip(inner, to: UIRect(x0, y0 + cTop, 204, visible))
        // the rolling bottom edge while it unrolls
        let idx = start + ticks
        if visible < H, !frames.isEmpty {
            let fr = frames[max(0, min(frames.count - 1, idx))]
            out += image(fr, "scroll_menu", x0, y0 + cTop + visible - (fr.y + fr.height))
        }
        return out
    }
    /// The scroll menu's row under a point, if any.
    func scrollMenuHit(_ titles: [String], x: Int, y: Int, _ px: Float, _ py: Float) -> Int? {
        scrollMenuRows(titles, x: x, y: y).firstIndex { $0.rect.contains(px, py) }
    }
}
