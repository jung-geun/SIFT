import Foundation
import Testing
@testable import todo

@Suite("Calendar schedule viewport coordinates")
@MainActor
struct CalendarScheduleScrollViewportTests {
    @Test("Rotation rejects old pixels interpreted with the new day width until positioning is acknowledged")
    func rotationPreservesLeadingDate() {
        let rotations: [(CGFloat, CGFloat, Int)] = [(232, 99, 7), (171, 284, 3), (99, 232, 3)]
        for (oldWidth, newWidth, visibleCount) in rotations {
            let oldOffset = 60 * oldWidth
            let targetOffset = 60 * newWidth
            let transitional = CalendarScheduleScrollViewport(offset: oldOffset, columnWidth: newWidth,
                visibleCount: visibleCount, expectedOffset: targetOffset)
            #expect(!transitional.usesColumnWidth(oldWidth))
            #expect(!transitional.acknowledgesPosition)
            #expect(transitional.columns.lowerBound != 60)

            let stale = CalendarScheduleScrollViewport(offset: oldOffset, columnWidth: oldWidth,
                visibleCount: 3)
            #expect(!stale.usesColumnWidth(newWidth))

            let settled = CalendarScheduleScrollViewport(offset: targetOffset + 0.25, columnWidth: newWidth,
                visibleCount: visibleCount, expectedOffset: targetOffset)
            #expect(settled.usesColumnWidth(newWidth))
            #expect(settled.acknowledgesPosition)
            #expect(settled.columns == 60..<(60 + visibleCount))
        }
    }

    @Test("Exact alignment excludes the next day while a genuinely exposed trailing day is included")
    func halfOpenVisibleColumns() {
        #expect(CalendarScheduleScrollViewport.columnRange(offset: 600, columnWidth: 100, visibleCount: 2) == 6..<8)
        #expect(CalendarScheduleScrollViewport.columnRange(offset: 601, columnWidth: 100, visibleCount: 2) == 6..<9)
        #expect(CalendarScheduleScrollViewport.columnRange(offset: 699, columnWidth: 100, visibleCount: 2) == 6..<9)
        #expect(CalendarScheduleScrollViewport.columnRange(offset: 700, columnWidth: 100, visibleCount: 2) == 7..<9)
    }

    @Test("Native subpixel quantization cannot turn the aligned date into yesterday")
    func subpixelBoundary() {
        let width: CGFloat = 697.0 / 7
        let target = 60 * width
        for discrepancy in [CGFloat(-0.4), 0, 0.4] {
            let viewport = CalendarScheduleScrollViewport(offset: target + discrepancy, columnWidth: width,
                visibleCount: 7, expectedOffset: target)
            #expect(viewport.columns == 60..<67)
            #expect(viewport.acknowledgesPosition)
        }
    }

    @Test("Rolling rebase preserves the exact visible dates and exposed trailing day")
    func rebasePreservesFractionalViewport() {
        let width: CGFloat = 171
        let before = CalendarScheduleScrollViewport.columnRange(offset: 20.25 * width, columnWidth: width, visibleCount: 2)
        let after = CalendarScheduleScrollViewport.columnRange(offset: 76.25 * width, columnWidth: width, visibleCount: 2)
        #expect(after.lowerBound - 56 == before.lowerBound)
        #expect(after.upperBound - 56 == before.upperBound)
    }

    @Test("Leading overscroll stays at the first date and unrequested scrolling is not a position acknowledgement")
    func leadingBounce() {
        let viewport = CalendarScheduleScrollViewport(offset: -20, columnWidth: 171, visibleCount: 2)
        #expect(viewport.columns == 0..<2)
        #expect(!viewport.acknowledgesPosition)
    }

    @Test("Repeated positioning recognizes an observed no-op without waiting for another geometry change")
    func observedNoOp() {
        let native = CalendarScheduleNativeScrollPosition()
        #expect(!native.matches(offset: 10_260, columnWidth: 171))
        native.record(CalendarScheduleScrollViewport(offset: 10_260.25, columnWidth: 171, visibleCount: 2))
        #expect(native.matches(offset: 10_260, columnWidth: 171))
        #expect(native.matches(offset: 10_260, columnWidth: 171))
        #expect(!native.matches(offset: 10_260, columnWidth: 284))

        // A subsequent user movement replaces the observation, even within the same day cohort.
        native.record(CalendarScheduleScrollViewport(offset: 10_270, columnWidth: 171, visibleCount: 2))
        #expect(!native.matches(offset: 10_260, columnWidth: 171))
        #expect(native.matches(offset: 10_270, columnWidth: 171))
    }
}
