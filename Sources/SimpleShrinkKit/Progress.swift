// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Foundation

/// The stages of a run. Emitted verbatim as the `stage` field of progress events, so
/// a host can label its own UI without parsing prose.
public enum Stage: String, Sendable, CaseIterable, Codable {
    case open, attach, probe, check, resize, verify, arm, detach, partition, truncate, done
}

/// Maps stage-local progress onto one monotonic 0…1 fraction.
///
/// A shrink is not linearly measurable — `resize2fs` reports little and what it does
/// report is not proportional to time — so each stage owns a slice of the bar and
/// interpolates inside it. The fraction never decreases.
public struct ProgressModel: Sendable {
    public static let weights: [Stage: ClosedRange<Double>] = [
        .open: 0.00...0.02,
        .attach: 0.02...0.04,
        .probe: 0.04...0.05,
        .check: 0.05...0.25,
        .resize: 0.25...0.80,
        .verify: 0.80...0.90,
        .arm: 0.90...0.93,
        .detach: 0.93...0.95,
        .partition: 0.95...0.98,
        .truncate: 0.98...1.00,
        .done: 1.00...1.00,
    ]

    private var highWaterMark: Double = 0

    public init() {}

    /// - Parameter within: progress inside the stage, 0…1, when the tool gives one.
    public mutating func fraction(for stage: Stage, within: Double = 1.0) -> Double {
        let range = ProgressModel.weights[stage] ?? 0...1
        let clamped = min(max(within, 0), 1)
        let value = range.lowerBound + (range.upperBound - range.lowerBound) * clamped
        highWaterMark = max(highWaterMark, value)
        return highWaterMark
    }
}
