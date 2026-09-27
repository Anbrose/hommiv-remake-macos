import Foundation
import H4Engine

/// The generic window machinery of heroes4.exe's dialogs (army_screen_spec §0, object_dialogs_spec
/// §0-D), shared by the spell book, the level-up, shop, sanctuary, puzzle and split dialogs:
/// layout layers drawn at their own boxes (kind-1 256-colour layers are images too), buttons whose
/// state images sit at a hotspot's top-left, and text windows in the font 0x875bc0 picks, black,
/// left or centred, optionally centred vertically, with or without the (200,200,200) halo.
struct DRect {
    var x: Int, y: Int, w: Int, h: Int
    init(_ x: Int, _ y: Int, _ w: Int, _ h: Int) { self.x = x; self.y = y; self.w = w; self.h = h }
    init(_ l: UILayer) { self.init(l.x, l.y, l.width, l.height) }
    func offset(_ dx: Int, _ dy: Int) -> DRect { DRect(x + dx, y + dy, w, h) }
    func contains(_ px: Float, _ py: Float) -> Bool { px >= Float(x) && px < Float(x + w) && py >= Float(y) && py < Float(y + h) }
}

extension Renderer {
    static let halo200: (UInt8, UInt8, UInt8) = (200, 200, 200)

    /// 0x875bc0: the largest cached size no larger than `n` (9 ... 34), as the even Prose Antique file at or under it.
    func dFont(_ n: Int) -> H4Font? {
        guard let ui = ui else { return nil }
        return ui.font(n)   // the slot table 0xa84798 and its resources (AdventureUI.fontSlots)
    }
    /// font.Script.<n> (14, 16, 18, 20).
    func scriptFont(_ n: Int) -> H4Font? {
        guard let ui = ui else { return nil }
        let key = 1000 + n
        if let f = ui.fonts[key] { return f }
        let f = (try? ui.archive.payload("font.Script.\(n).h4d")).flatMap { try? H4Font(data: $0) }
        if let f = f { ui.fonts[key] = f }
        return f
    }
    /// A layout layer by name, whatever the case.
    func dLayer(_ d: LayerFile?, _ name: String) -> UILayer? {
        guard let d = d else { return nil }
        return d[name] ?? d.layers.first { $0.name.lowercased() == name.lowercased() }
    }
    func dRect(_ d: LayerFile?, _ name: String) -> DRect? { dLayer(d, name).map(DRect.init) }
    /// A bitmap window: the layer at its own box, moved by (dx, dy) and the dialog origin.
    func dImage(_ d: LayerFile?, _ tag: String, _ name: String, _ ox: Int, _ oy: Int, dx: Int = 0, dy: Int = 0) -> [Quad] {
        guard let l = dLayer(d, name), l.width > 0, l.height > 0 else { return [] }
        return [Quad(texture: uiTexture("dk|\(tag)|\(l.name)", { l.bitmap }), x: ox + l.x + dx, y: oy + l.y + dy, w: l.width, h: l.height)]
    }
    /// A layer drawn with its box's top-left at (x, y) (0x597f50(layer, false)).
    func dImageAt(_ l: UILayer?, _ tag: String, x: Int, y: Int) -> [Quad] {
        guard let l = l, l.width > 0, l.height > 0 else { return [] }
        return [Quad(texture: uiTexture("dk|\(tag)|\(l.name)", { l.bitmap }), x: x, y: y, w: l.width, h: l.height)]
    }
    /// An alpha bitmap window (0x59ee20): the layer at (x, y) at alpha/15 opacity.
    func dImageAlpha(_ l: UILayer?, _ tag: String, x: Int, y: Int, alpha: Int) -> [Quad] {
        guard let l = l, l.width > 0, l.height > 0 else { return [] }
        return [Quad(texture: uiTexture("dka|\(alpha)|\(tag)|\(l.name)", {
            var b = l.bitmap
            for i in stride(from: 3, to: b.pixels.count, by: 4) { b.pixels[i] = UInt8(Int(b.pixels[i]) * alpha / 15) }
            return b
        }), x: x, y: y, w: l.width, h: l.height)]
    }
    /// A layer at its box offset from a window origin (x, y) (a button's state image, a ring piece).
    func dImageOffset(_ l: UILayer?, _ tag: String, x: Int, y: Int) -> [Quad] {
        guard let l = l else { return [] }
        return dImageAt(l, tag, x: x + l.x, y: y + l.y)
    }
    /// A layers file anywhere in the archives (updates first).
    func dFile(_ name: String) -> LayerFile? {
        guard let ui = ui else { return nil }
        let key = "file:" + name
        if let d = ui.dialogs[key] { return d }
        let d = ui.payload("layers.\(name).h4d").flatMap { try? LayerFile(data: $0) }
        ui.dialogs[key] = d
        return d
    }
    /// A t_button (0x5a0010): the state image of layers.button.<file> (or any layers.<file>) with the
    /// window at (x, y); the images' boxes start at the window's top-left.
    func dButton(_ file: String, _ state: String, x: Int, y: Int) -> [Quad] {
        let f = dFile("button.\(file)") ?? dFile(file)
        let l = dLayer(f, state) ?? (state.lowercased() == "disabled" ? nil : dLayer(f, "Released"))
        return dImageOffset(l, "btn.\(file)", x: x, y: y)
    }
    /// The size of a button file's Released image.
    func dButtonSize(_ file: String) -> (Int, Int) {
        guard let l = dLayer(dFile("button.\(file)") ?? dFile(file), "Released") else { return (0, 0) }
        return (l.x + l.width, l.y + l.height)
    }

    /// A text window (0x8859f0): wrapped to the rect's width, left or centred (+0xc4), the block
    /// centred vertically when it is shorter than the rect (+0xd4), black unless told otherwise,
    /// the (200,200,200) halo only when `halo`. `skipLines` scrolls the text by whole lines.
    func dText(_ s: String, _ r: DRect?, font: H4Font?, centre: Bool = true, vcentre: Bool = false, halo: (UInt8, UInt8, UInt8)? = nil,
               colour: (UInt8, UInt8, UInt8) = (0, 0, 0), _ ox: Int, _ oy: Int, skipLines: Int = 0, clip: Bool = false) -> [Quad] {
        guard let r = r, let f = font, !s.isEmpty else { return [] }
        let lines = Array(dLines(s, width: r.w, font: f).dropFirst(skipLines))
        var y = r.y
        if vcentre, lines.count * f.lineHeight < r.h { y = r.y + (r.h - lines.count * f.lineHeight) / 2 }
        var out: [Quad] = []
        let hk = halo.map { "\($0.0).\($0.1).\($0.2)" } ?? "-"
        for (k, line) in lines.enumerated() where !line.isEmpty {
            let ly = y + k * f.lineHeight
            if clip, ly + f.size > r.y + r.h { break }
            let w = f.measure(line)
            let x = centre ? r.x + max(0, (r.w - w) / 2) : r.x
            out.append(Quad(texture: uiTexture("dtx|\(ObjectIdentifier(f).hashValue)|\(colour.0).\(colour.1).\(colour.2)|\(hk)|\(line)", { f.render(line, colour: colour, halo: halo) }),
                            x: ox + x, y: oy + ly, w: w, h: f.size))
        }
        return out
    }
    /// The lines a text window breaks a text into.
    func dLines(_ s: String, width: Int, font f: H4Font) -> [String] {
        s.components(separatedBy: "\n").flatMap { $0.isEmpty ? [""] : AdventureUI.wrap($0, font: f, width: width) }
    }
    /// A balloon / interface text (table.Interface: window, item).
    func interfaceText(_ window: String, _ item: String) -> (balloon: String, rightClick: String)? {
        game?.tables?.interfaceTexts["\(window.lowercased()).\(item.lowercased())"]
    }
    /// The hot keys of the open dialog (Enter / Esc and the like); true when one took the key.
    func dialogKey(_ code: UInt16) -> Bool {
        if splitDialog != nil { return splitKey(code) }
        if spellBook != nil { return spellBookKey(code) }
        if game?.levelUp != nil, !inCombat, code == 36 || code == 76 { confirmLevelUp(); return true }
        return false
    }
    /// A ring row (t_creature_array_window 0x6439c0, layers.creature_rings): style 0 Left/Middle x5/Right,
    /// 1 Top_*, 2 Bottom_*; each piece's box top-left at the cursor, the cursor moving on by its width.
    /// Returns each slot's piece and frame origin (the piece file's (0,0)).
    func ringRow(x: Int, y: Int, style: Int = 0) -> [(piece: String, fx: Int, fy: Int)] {
        guard let ui = ui else { return [] }
        let names: [String] = style == 1 ? ["Top_Left", "Top", "Top_Right"] : style == 2 ? ["Bottom_Left", "Bottom", "Bottom_Right"] : ["Left", "Middle", "Right"]
        var cursor = x
        var out: [(String, Int, Int)] = []
        for k in 0..<7 {
            let name = k == 0 ? names[0] : k == 6 ? names[2] : names[1]
            guard let p = ui.creatureRing(name) else { continue }
            out.append((name, cursor - p.x, y - p.y))
            cursor += p.width
        }
        return out
    }
    /// A ring row's pictures: each slot's portrait (a hero's, or a creature's with its count), the piece
    /// (its _Highlight for the selected slot), the label.
    func ringRowQuads(_ slots: [(piece: String, fx: Int, fy: Int)], items: [(icon: UILayer?, count: String?, hero: Bool)], selected: Int?) -> [Quad] {
        guard let ui = ui else { return [] }
        var out: [Quad] = []
        for (k, s) in slots.enumerated() {
            let cx = s.fx + 41, cy = s.fy + 41
            if k < items.count, let icon = items[k].icon {
                out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: cx - icon.width / 2, y: cy - icon.height / 2, w: icon.width, h: icon.height))
            }
            if let p = ui.creatureRing(k == selected ? s.piece + "_Highlight" : s.piece) ?? ui.creatureRing(s.piece) {
                out.append(Quad(texture: uiTexture("cring|\(p.name)", { p.bitmap }), x: s.fx + p.x, y: s.fy + p.y, w: p.width, h: p.height))
            }
            if k < items.count { ringLabel(&out, ui: ui, cx: cx, cy: cy, count: items[k].count, hero: items[k].hero) }
        }
        return out
    }
    /// The ring items of an army: its heroes (the leader and companions), then its stacks.
    func ringItems(_ leader: Hero) -> [(icon: UILayer?, count: String?, hero: Bool)] {
        guard let ui = ui else { return [] }
        return ([leader] + leader.companions).map { (ui.portrait(keyword: $0.keyword, alignment: $0.alignment), nil, true) }
            + leader.army.map { (ui.creatureIcon($0.creature), String($0.count), false) }
    }
    /// The balloon of what is under the pointer in the open object dialog.
    func dialogTip(x: Float, y: Float) -> String? {
        if shop != nil { return shopTip(x: x, y: y) }
        if puzzle != nil { return puzzleTip(x: x, y: y) }
        return nil
    }
    var dialogOrigin800: (Int, Int) { ((AdventureUI.width - 800) / 2, (AdventureUI.height - 600) / 2) }
}
