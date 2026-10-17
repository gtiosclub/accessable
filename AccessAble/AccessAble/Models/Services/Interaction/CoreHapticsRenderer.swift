import CoreHaptics
import Foundation
import os
 
private let log = Logger(subsystem: "AccessAble", category: "Haptics")
 
/// Owner: Haptics (3.2). Plays the AHAP files named by `HapticID`, one at a time.
/// `intensity` (the user's Haptic intensity setting, 0...1) scales the whole pattern.
actor CoreHapticsRenderer: HapticRendering {
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var patterns: [HapticID: CHHapticPattern] = [:]
    private let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
 
    func play(_ id: HapticID, intensity: Float) async {
        guard supportsHaptics, intensity > 0, let pattern = pattern(for: id) else { return }
        do {
            let engine = try runningEngine()
            try? player?.stop(atTime: CHHapticTimeImmediate)
 
            let player = try engine.makeAdvancedPlayer(with: pattern)
            if let period = id.loopPeriod {
                player.loopEnabled = true
                player.loopEnd = period
            }
            try player.sendParameters(
                [CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: min(intensity, 1), relativeTime: 0)],
                atTime: CHHapticTimeImmediate
            )
            try player.start(atTime: CHHapticTimeImmediate)
            self.player = player
        } catch {
            log.error("haptic \(id.rawValue) failed: \(error.localizedDescription)")
        }
    }
 
    func stop() async {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
    }
 
    /// Loads and caches the AHAP file. Missing files (e.g. not designed yet) are skipped.
    private func pattern(for id: HapticID) -> CHHapticPattern? {
        if let cached = patterns[id] { return cached }
        guard let url = id.ahapURL else {
            log.info("no AHAP file for \(id.rawValue)")
            return nil
        }
        do {
            let pattern = try CHHapticPattern(contentsOf: url)
            patterns[id] = pattern
            return pattern
        } catch {
            log.error("bad AHAP file \(id.rawValue): \(error.localizedDescription)")
            return nil
        }
    }
 
    private func runningEngine() throws -> CHHapticEngine {
        if let engine { return engine }
        let engine = try CHHapticEngine()
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = true
        // The system can reset the engine (e.g. app backgrounded); rebuild it on the next play.
        engine.resetHandler = { [weak self] in
            Task { await self?.discardEngine() }
        }
        try engine.start()
        self.engine = engine
        return engine
    }
 
    private func discardEngine() {
        engine = nil
        player = nil
    }
}
