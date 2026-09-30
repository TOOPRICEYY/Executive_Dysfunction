import Foundation

/// Minute-accurate, presentation-only projection of the schedule's blocking windows.
/// Do not quantize this through the painter: synced windows may end between cells.
enum BlockingSchedulePreview {
    struct Span: Equatable {
        var start: Int
        var end: Int
    }

    static func spans(for weekday: Int, plan: CloudTimeWindowPlan) -> [Span] {
        var spans: [Span] = []
        for window in plan.effectiveBlockingSlots() {
            guard (0..<1440).contains(window.startMinutes),
                  (0...1440).contains(window.endMinutes) else { continue }
            for day in window.weekdays where (1...7).contains(day) {
                if window.startMinutes < window.endMinutes {
                    if day == weekday { spans.append(.init(start: window.startMinutes, end: window.endMinutes)) }
                } else {
                    if day == weekday { spans.append(.init(start: window.startMinutes, end: 1440)) }
                    if AllowanceSchedulePainterCodec.nextWeekday(after: day) == weekday, window.endMinutes > 0 {
                        spans.append(.init(start: 0, end: window.endMinutes))
                    }
                }
            }
        }
        var merged: [Span] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    static func summary(_ spans: [Span]) -> String {
        if spans.isEmpty { return "No scheduled blocking" }
        if spans == [Span(start: 0, end: 1440)] { return "Blocked all day" }
        func time(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
        return "Blocked " + spans.map { "\(time($0.start))–\(time($0.end))" }.joined(separator: ", ")
    }
}
