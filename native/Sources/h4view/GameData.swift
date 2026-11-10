import Foundation
import Metal
import H4Engine

// The game data the screens share, opened on first use (globals outside main.swift are lazy):
// the iOS app may have to import the data folder before anything reads it.

/// heroes4.h4r with the expansions' and patches' archives over it.
let archive: H4Archive = {
    let a = try! H4Archive(url: URL(fileURLWithPath: args[1]))
    for f in ["x2.h4r", "storm.h4r", "updates.h4r", "x2_override.h4r", "storm_override.h4r"] {
        if let s = try? H4Archive(url: URL(fileURLWithPath: args[1]).deletingLastPathComponent().appendingPathComponent(f)) { a.supplement(with: s) }
    }
    return a
}()
let movies = Movies(dataDirectory: URL(fileURLWithPath: args[1]).deletingLastPathComponent())
let gameSound = GameSound(dataDirectory: URL(fileURLWithPath: args[1]).deletingLastPathComponent())
let objNames = Set(archive.names(prefix: "adv_object.").map { String($0.dropFirst("adv_object.".count).dropLast(4)) })
let masks = try! TransitionMasks(data: archive.payload("transition.Transitions.h4d"))
let device = MTLCreateSystemDefaultDevice()!
