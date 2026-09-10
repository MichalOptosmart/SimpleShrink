// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Testing

@testable import SimpleShrinkKit

@Suite("Progress")
struct ProgressTests {
    @Test("Every stage owns a slice of the bar, and they cover it exactly once")
    func stagesTileTheBar() {
        let ranges = Stage.allCases.compactMap { ProgressModel.weights[$0] }
        #expect(ranges.count == Stage.allCases.count)
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.map(\.upperBound).max() == 1)

        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            #expect(previous.upperBound == next.lowerBound)
        }
    }

    @Test("Progress inside a stage is interpolated within that stage's slice")
    func interpolatesWithinAStage() {
        var model = ProgressModel()
        let range = ProgressModel.weights[.resize]!
        #expect(model.fraction(for: .resize, within: 0) == range.lowerBound)
        #expect(model.fraction(for: .resize, within: 0.5) == (range.lowerBound + range.upperBound) / 2)
        #expect(model.fraction(for: .resize, within: 1) == range.upperBound)
    }

    @Test("The reported fraction never goes backwards")
    func neverDecreases() {
        var model = ProgressModel()
        _ = model.fraction(for: .resize, within: 0.9)
        // e2fsck restarting a pass, or a retry with a bigger margin, must not rewind the bar.
        #expect(model.fraction(for: .check, within: 0.1) >= 0.7)
        #expect(model.fraction(for: .resize, within: 0.2) >= 0.7)
        #expect(model.fraction(for: .done, within: 1) == 1)
    }

    @Test("Out-of-range input is clamped rather than escaping the stage")
    func clampsInput() {
        var model = ProgressModel()
        #expect(model.fraction(for: .check, within: 5) == ProgressModel.weights[.check]!.upperBound)
        var other = ProgressModel()
        #expect(other.fraction(for: .check, within: -3) == ProgressModel.weights[.check]!.lowerBound)
    }
}
