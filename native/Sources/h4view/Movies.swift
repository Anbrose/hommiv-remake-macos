import Foundation
import H4Engine

/// The game's Bink movies (movies.h4r: bink.win_battle_intro, bink.lose_battle_loop, ...), shown
/// in dialogs such as the combat results' Cut_Scene. There is no Bink decoder in the engine yet:
/// a movie is decoded once with ffmpeg (if one is installed) into raw RGBA frames kept in
/// ~/Library/Caches/h4view, then played from memory. Without ffmpeg the slot stays empty.
final class Movie {
    let width: Int, height: Int, fps: Double
    let frames: [Bitmap]
    init(width: Int, height: Int, fps: Double, frames: [Bitmap]) { self.width = width; self.height = height; self.fps = fps; self.frames = frames }
}

final class Movies {
    let archive: H4Archive?
    private var loaded: [String: Movie] = [:]
    private var pending: Set<String> = []
    private let queue = DispatchQueue(label: "movies")

    init(dataDirectory: URL) { archive = try? H4Archive(url: dataDirectory.appendingPathComponent("movies.h4r")) }

    static let ffmpeg: String? = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    static var cacheDirectory: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("h4view/movies")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// The movie if it is ready; otherwise starts decoding it in the background and returns nil.
    func movie(_ name: String) -> Movie? {
        if let m = queue.sync(execute: { loaded[name] }) { return m }
        // already decoded once: read the cached frames right away
        if !queue.sync(execute: { pending.contains(name) }),
           let files = try? FileManager.default.contentsOfDirectory(atPath: Movies.cacheDirectory.path),
           files.contains(where: { $0.hasPrefix("\(name).") && $0.hasSuffix(".rgba") }) {
            decode(name)
            if let m = queue.sync(execute: { loaded[name] }) { return m }
        }
        let start: Bool = queue.sync { if pending.contains(name) { return false }; pending.insert(name); return true }
        if start { DispatchQueue.global(qos: .userInitiated).async { self.decode(name) } }
        return nil
    }

    private func decode(_ name: String) {
        guard let archive = archive, let ffmpeg = Movies.ffmpeg, let data = try? archive.payload("bink.\(name).h4d"), data.count > 20 else { return }
        // the Bink header: width and height at 20 and 24, the frame rate as a fraction at 28 / 32
        func u32(_ o: Int) -> Int { Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8 | Int(data[data.startIndex + o + 2]) << 16 | Int(data[data.startIndex + o + 3]) << 24 }
        let w = u32(20), h = u32(24), num = u32(28), den = max(1, u32(32))
        guard w > 0, h > 0, w <= 1280, h <= 1024 else { return }
        let dir = Movies.cacheDirectory
        let raw = dir.appendingPathComponent("\(name).\(w)x\(h).rgba")
        if !FileManager.default.fileExists(atPath: raw.path) {
            let bik = dir.appendingPathComponent("\(name).bik")
            try? data.write(to: bik)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-v", "error", "-y", "-i", bik.path, "-f", "rawvideo", "-pix_fmt", "rgba", raw.path]
            try? p.run(); p.waitUntilExit()
            try? FileManager.default.removeItem(at: bik)
        }
        guard let pixels = try? Data(contentsOf: raw) else { return }
        let size = w * h * 4
        var frames: [Bitmap] = []
        var o = 0
        while o + size <= pixels.count {
            var bm = Bitmap(width: w, height: h)
            bm.pixels = [UInt8](pixels[o..<(o + size)])
            frames.append(bm); o += size
        }
        guard !frames.isEmpty else { return }
        let m = Movie(width: w, height: h, fps: num > 0 ? Double(num) / Double(den) : 15, frames: frames)
        queue.sync { loaded[name] = m }
    }
}
