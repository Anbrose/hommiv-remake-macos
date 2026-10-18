import Foundation

/// The options dialog's three speed sliders (heroes4.exe t_options_dialog 0x7cb4d0 on top of the
/// combat options 0x6eb380; re/speed_options_spec.md): army speed, combat speed and enemy speed.
/// Each is a t_scrollbar (0x83ac10) from position -2 to 6 that keeps a percent (the registry's
/// army_speed / combat_speed / enemy_speed, defaults 150 / 150 / 200 from 0x7c91d0). The dialog
/// shows the position ("%d"); the enemy speed's last position shows "Off" (speed_off.options) and
/// stores 800, and OK sets show_enemy_moves = enemy speed < 800 (0x7cbe5b).
public enum SpeedOption {
    /// The slider's range (0x83ac10's min and max arguments: -2 and 6).
    public static let positions = -2...6
    /// The enemy speed that means "Off": the computer players' moves are not shown.
    public static let off = 800
    public static let defaultArmy = 150, defaultCombat = 150, defaultEnemy = 200

    /// The slider position of a percent (0x6ebe70): x = 2 log2(percent / 100), rounded half away
    /// from zero (x > 0: trunc(x + 0.5), else trunc(x - 0.5)), then held in the range (0x83b110).
    public static func position(percent: Int) -> Int {
        guard percent > 0 else { return positions.lowerBound }
        let x = 2 * log(Double(percent) * 0.01) / log(2.0)
        let p = x > 0 ? Int((x + 0.5).rounded(.towardZero)) : Int((x - 0.5).rounded(.towardZero))
        return min(max(p, positions.lowerBound), positions.upperBound)
    }
    /// The percent of a slider position (0x6ebec0): trunc(100 x 2^(position / 2) + 0.5):
    /// -2..6 -> 50 71 100 141 200 283 400 566 800.
    public static func percent(position: Int) -> Int {
        Int((pow(2.0, Double(position) * 0.5) * 100 + 0.5).rounded(.towardZero))
    }
    /// An arrow or a click on the track moves the thumb by one (the page is (max - min) / 5 = 1,
    /// 0x83ba83); the percent changes only when the position does (0x83b2b0 -> 0x7cbdb0), so an
    /// untouched slider keeps a percent between positions (the default 150 shows as 1).
    public static func stepped(percent: Int, by delta: Int) -> Int {
        let p = position(percent: percent)
        let q = min(max(p + delta, positions.lowerBound), positions.upperBound)
        return q == p ? percent : self.percent(position: q)
    }
    /// The enemy speed shows the computer players' moves (show_enemy_moves, 0x7c90c0).
    public static func showsEnemyMoves(_ enemyPercent: Int) -> Bool { enemyPercent < off }
}
