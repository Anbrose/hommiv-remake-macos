import Foundation
import AVFoundation
import H4Engine

/// The game's sound and music.
///
/// Sounds are archive entries "sound.<name>.h4d": effects in heroes4.h4r (and the expansions'
/// archives), music in music.h4r. A payload is u16 format (0 PCM, 1 MP3), u8 0, u8 bits,
/// u8 channels, u32 rate, u32 decoded length, u16 1, then the PCM samples (at 15), or for MP3
/// a u32 encoded length and the MP3 stream (at 19).
///
/// Names follow the game: a combat actor's state sounds are "<actor model>.<state>"
/// (Squire.Melee, hero.life_might_male.die, ...); the adventure music is terrain.<Terrain> under
/// the hero, a town's is town.<alignment>; a battle opens with combat.start and then plays the
/// combat.music.1...6 list (heroes4.exe 0x62a720 / 0x62a830), ending with combat.win or .lose.
final class GameSound: NSObject, AVAudioPlayerDelegate {
    private var index: [String: (H4Archive, String)] = [:]   // lower-cased "sound.x.h4d" -> archive, real name
    private var cache: [String: Data] = [:]
    private var effects: [AVAudioPlayer] = []
    private var music: AVAudioPlayer?
    private(set) var musicName: String?
    private var playlist: [String] = []
    private var loops: [String: AVAudioPlayer] = [:]
    var effectVolume: Float = 0.8
    var musicVolume: Float = 0.5

    init(dataDirectory: URL) {
        super.init()
        // later archives override earlier ones (the expansions and updates)
        for file in ["heroes4.h4r", "music.h4r", "x2.h4r", "storm.h4r", "updates.h4r", "x2_override.h4r", "storm_override.h4r"] {
            guard let a = try? H4Archive(url: dataDirectory.appendingPathComponent(file)) else { continue }
            for name in a.byName.keys where name.lowercased().hasPrefix("sound.") { index[name.lowercased()] = (a, name) }
        }
    }

    func has(_ name: String) -> Bool { index["sound.\(name.lowercased()).h4d"] != nil }

    /// The playable file (WAV or MP3) of a sound, or nil.
    func data(_ name: String) -> Data? {
        let key = "sound.\(name.lowercased()).h4d"
        if let d = cache[key] { return d }
        guard let (archive, real) = index[key], let raw = try? archive.payload(real), raw.count > 15 else { return nil }
        let b = [UInt8](raw)
        let fmt = Int(b[0]) | Int(b[1]) << 8, bits = Int(b[3]), ch = Int(b[4])
        let rate = Int(b[5]) | Int(b[6]) << 8 | Int(b[7]) << 16 | Int(b[8]) << 24
        let n = Int(b[9]) | Int(b[10]) << 8 | Int(b[11]) << 16 | Int(b[12]) << 24
        var out: Data
        if fmt == 1 {
            out = raw.subdata(in: raw.startIndex + 19 ..< raw.endIndex)
        } else {
            let pcm = raw.subdata(in: raw.startIndex + 15 ..< raw.startIndex + min(raw.count, 15 + n))
            func le32(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8 & 255), UInt8(v >> 16 & 255), UInt8(v >> 24 & 255)] }
            func le16(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8 & 255)] }
            var h: [UInt8] = Array("RIFF".utf8) + le32(36 + pcm.count) + Array("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(ch)
            h += le32(rate) + le32(rate * ch * bits / 8) + le16(ch * bits / 8) + le16(bits) + Array("data".utf8) + le32(pcm.count)
            out = Data(h); out.append(pcm)
        }
        cache[key] = out
        return out
    }

    // MARK: effects

    /// Play an effect once (nothing if the game has no such sound).
    @discardableResult
    func play(_ name: String, volume: Float = 1) -> Bool {
        guard let d = data(name), let p = try? AVAudioPlayer(data: d) else {
            if ProcessInfo.processInfo.environment["H4DEBUG"] != nil { print("sound missing: \(name)") }
            return false
        }
        effects.removeAll { !$0.isPlaying }
        p.volume = effectVolume * volume
        p.play()
        effects.append(p)
        return true
    }
    /// A combat actor's state sound ("Squire" + "melee" -> sound.Squire.Melee).
    func actor(_ model: String, _ state: String) { play("\(model).\(state)") }

    /// A sound that repeats until stopped (a walk); `key` identifies it.
    func startLoop(_ name: String, key: String) {
        guard loops[key] == nil, let d = data(name), let p = try? AVAudioPlayer(data: d) else { return }
        p.numberOfLoops = -1; p.volume = effectVolume
        p.play()
        loops[key] = p
    }
    func stopLoop(_ key: String) { loops.removeValue(forKey: key)?.stop() }

    // MARK: music

    /// Play a piece of music (looping), unless it is already playing.
    func playMusic(_ name: String, loop: Bool = true) {
        guard musicName != name else { return }
        playlist = []
        startMusic(name, loop: loop)
    }
    /// Play one piece, then the list in turn, the list repeating.
    func playMusic(first: String?, then list: [String]) {
        playlist = list
        if let f = first { startMusic(f, loop: false) } else { nextInList() }
    }
    private func startMusic(_ name: String, loop: Bool) {
        music?.stop(); music = nil; musicName = name
        guard let d = data(name), let p = try? AVAudioPlayer(data: d) else {
            if ProcessInfo.processInfo.environment["H4DEBUG"] != nil { print("music missing: \(name)") }
            return
        }
        if ProcessInfo.processInfo.environment["H4DEBUG"] != nil { print("music: \(name) \(p.duration)s") }
        p.numberOfLoops = loop ? -1 : 0
        p.volume = musicVolume
        p.delegate = self
        p.play()
        music = p
    }
    private func nextInList() {
        guard !playlist.isEmpty else { return }
        let n = playlist.removeFirst()
        playlist.append(n)
        startMusic(n, loop: false)
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if player === music { nextInList() }
    }
    func stopMusic() { music?.stop(); music = nil; musicName = nil; playlist = [] }
}
