import Foundation

/// Stateless PCM level calculation shared by recording and input monitoring.
enum AudioLevelMeter {
    /// Maps RMS amplitude from -60...0 dB onto a UI-friendly 0...1 range.
    static func normalizedRMS(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Double = 0
        for sample in samples {
            let value = Double(sample)
            sumOfSquares += value * value
        }
        let rms = sqrt(sumOfSquares / Double(samples.count))
        guard rms.isFinite, rms > 0.001 else { return 0 }
        let decibels = 20 * log10(rms)
        return Float(min(1, max(0, (decibels + 60) / 60)))
    }
}
