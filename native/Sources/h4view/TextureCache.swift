import Metal

/// GPU textures by key, least recently used dropped once the bytes pass a budget. A texture drawn
/// in the current frame is never dropped (a zoomed-out view may need more than the budget for a
/// while); `endFrame` trims back to the budget.
final class TextureCache<Key: Hashable> {
    private struct Entry { let texture: MTLTexture; let bytes: Int; var used: UInt64 }
    private var entries: [Key: Entry] = [:]
    private var frame: UInt64 = 0
    private(set) var bytes = 0
    let budget: Int
    /// Told about each texture dropped (the renderer forgets what it knew of it).
    var onEvict: ((Key, MTLTexture) -> Void)?

    init(budget: Int) { self.budget = budget }

    var count: Int { entries.count }

    subscript(key: Key) -> MTLTexture? {
        guard var e = entries[key] else { return nil }
        if e.used != frame { e.used = frame; entries[key] = e }
        return e.texture
    }

    func insert(_ t: MTLTexture, for key: Key) {
        if let old = entries.removeValue(forKey: key) { bytes -= old.bytes }
        let n = t.width * t.height * 4
        entries[key] = Entry(texture: t, bytes: n, used: frame)
        bytes += n
    }

    func removeAll() {
        if let f = onEvict { for (k, e) in entries { f(k, e.texture) } }
        entries.removeAll(); bytes = 0
    }

    /// The frame is drawn: drop the least recently used textures past the budget, down to 3/4 of
    /// it so the next few uploads do not each trim again.
    func endFrame() {
        defer { frame &+= 1 }
        guard bytes > budget else { return }
        let target = budget / 4 * 3
        for (k, e) in entries.filter({ $0.value.used != frame }).sorted(by: { $0.value.used < $1.value.used }) {
            guard bytes > target else { break }
            entries.removeValue(forKey: k)
            bytes -= e.bytes
            onEvict?(k, e.texture)
        }
    }
}
