import Foundation
import SwiftUI

private enum IOSBlockStatusPeriod: String, CaseIterable, Identifiable {
    case week
    case month

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

struct IOSBlockStatusTimeline: View {
    let calendarRules: [BlockStatusCalendarRule]

    @State private var period = IOSBlockStatusPeriod.week
    @State private var isolatedRuleID: UUID?
    @State private var snapshot = BlockStatusCalendarSnapshot.empty

    private var calendar: Calendar { .current }
    private let timeLabelWidth = 48.0
    private let headerHeight = 42.0
    private let hourHeight = 28.0

    init(rules: [CloudRulePreference]) {
        calendarRules = rules.map { BlockStatusCalendarRule(rule: $0) }
    }

    init(calendarRules: [BlockStatusCalendarRule]) {
        self.calendarRules = calendarRules
    }

    private var rules: [CloudRulePreference] { calendarRules.map(\.rule) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(IOSBrutalPalette.rule).frame(height: 2)

            if rules.isEmpty {
                Text("Enable a Blocking Group to see its schedule here.")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                legend
                Rectangle().fill(IOSBrutalPalette.rule.opacity(0.5)).frame(height: 1)
                calendarMap
            }
        }
        .background(IOSBrutalPalette.surface)
        .overlay { Rectangle().stroke(IOSBrutalPalette.rule, lineWidth: 1) }
        .onAppear(perform: rebuildSnapshot)
        .onChange(of: period) { _, _ in rebuildSnapshot() }
        .onChange(of: calendarRules) { _, _ in rebuildSnapshot() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            rebuildSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            rebuildSnapshot()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Blocking calendar")
                        .font(.system(.title2, design: .default, weight: .semibold))
                    Text(rangeLabel)
                        .font(.system(.caption2, design: .default, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 0) {
                    ForEach(IOSBlockStatusPeriod.allCases) { option in
                        Button(option.label) { period = option }
                            .buttonStyle(.plain)
                            .font(.system(.caption2, design: .default, weight: .semibold))
                            .foregroundStyle(period == option ? Color.black : Color.primary)
                            .frame(width: 64, height: 36)
                            .background(period == option ? IOSBrutalPalette.signal : IOSBrutalPalette.surface)
                            .overlay { Rectangle().stroke(IOSBrutalPalette.rule, lineWidth: 1) }
                    }
                }
            }

            Text("Shows when groups block access. Tap a group below to focus on it.")
                .font(.system(.caption2, design: .monospaced, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(rules.indices, id: \.self) { index in
                    let rule = rules[index]
                    Button {
                        isolatedRuleID = isolatedRuleID == rule.id ? nil : rule.id
                    } label: {
                        HStack(spacing: 7) {
                            Rectangle()
                                .fill(color(for: index))
                                .frame(width: 12, height: 22)
                            Text(rule.name.uppercased()).lineLimit(1)
                            Text(periodTotal(for: rule.id))
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(.caption2, design: .default, weight: .semibold))
                        .padding(.horizontal, 9)
                        .frame(height: 32)
                        .background(
                            isolatedRuleID == rule.id
                                ? color(for: index).opacity(0.18)
                                : IOSBrutalPalette.raised
                        )
                        .overlay { Rectangle().stroke(IOSBrutalPalette.rule.opacity(0.7), lineWidth: 1) }
                        .opacity(isolatedRuleID == nil || isolatedRuleID == rule.id ? 1 : 0.25)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Tap to isolate this Blocking Group")
                }
            }
            .padding(12)
        }
    }

    private var calendarMap: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyHStack(alignment: .top, spacing: 0) {
                timeColumn
                ForEach(snapshot.days) { day in
                    dayColumn(day)
                }
            }
            .padding(12)
        }
    }

    private var timeColumn: some View {
        VStack(spacing: 0) {
            Text("TIME")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: timeLabelWidth, height: headerHeight, alignment: .leading)

            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(String(format: "%02d:00", hour))
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 6)
                        .frame(width: timeLabelWidth, height: hourHeight, alignment: .topTrailing)
                        .offset(y: -5)
                }
            }
        }
    }

    private func dayColumn(_ day: BlockStatusCalendarSnapshot.Day) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 1) {
                if period == .week {
                    Text(day.date.formatted(.dateTime.weekday(.narrow)).uppercased())
                }
                Text(day.date.formatted(.dateTime.day()))
            }
            .font(.system(size: 9, weight: .black, design: .monospaced))
            .foregroundStyle(calendar.isDateInToday(day.date) ? IOSBrutalPalette.signal : Color.secondary)
            .frame(width: dayWidth, height: headerHeight)
            .overlay { Rectangle().stroke(IOSBrutalPalette.rule.opacity(0.5), lineWidth: 0.5) }

            ZStack(alignment: .topLeading) {
                hourGrid
                ForEach(day.events) { event in
                    eventCard(event)
                }
                if calendar.isDateInToday(day.date) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        currentTimeLine(at: context.date)
                    }
                }
            }
            .frame(width: dayWidth, height: canvasHeight)
            .clipped()
        }
    }

    private var hourGrid: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Rectangle()
                    .fill(hour.isMultiple(of: 2) ? IOSBrutalPalette.raised.opacity(0.45) : IOSBrutalPalette.surface)
                    .frame(width: dayWidth, height: hourHeight)
                    .overlay(alignment: .top) {
                        Rectangle().fill(IOSBrutalPalette.rule.opacity(0.42)).frame(height: 0.5)
                    }
            }
        }
        .overlay { Rectangle().stroke(IOSBrutalPalette.rule.opacity(0.5), lineWidth: 0.5) }
    }

    private func eventCard(_ event: BlockStatusCalendarSnapshot.Event) -> some View {
        let geometry = BlockStatusCalendarEventGeometry.stacked(
            dayWidth: dayWidth,
            lane: event.lane,
            laneCount: event.laneCount,
            horizontalInset: 3
        )
        let height = max(7, Double(event.durationMinutes) / 60 * hourHeight - 2)
        let y = Double(event.startMinute) / 60 * hourHeight + 1

        return Button {
            isolatedRuleID = isolatedRuleID == event.ruleID ? nil : event.ruleID
        } label: {
            IOSCalendarBlockEvent(
                event: event,
                color: color(for: event.colorIndex),
                showLabel: geometry.width >= 50 && height >= 27
            )
        }
        .buttonStyle(.plain)
        .frame(width: geometry.width, height: height)
        .offset(x: geometry.x, y: y)
        .zIndex(Double(event.lane))
        .opacity(isolatedRuleID == nil || isolatedRuleID == event.ruleID ? 1 : 0.10)
        .accessibilityLabel("\(event.ruleName), \(timeLabel(event.startMinute)) to \(timeLabel(event.endMinute))")
        .accessibilityHint("Tap to isolate this Blocking Group")
    }

    private func currentTimeLine(at date: Date) -> some View {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return Rectangle()
            .fill(IOSBrutalPalette.signal)
            .frame(width: dayWidth, height: 2)
            .offset(y: Double(minute) / 60 * hourHeight)
    }

    private var displayDates: [Date] {
        let today = calendar.startOfDay(for: Date())
        switch period {
        case .week:
            let weekday = calendar.component(.weekday, from: today)
            let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today) ?? today
            return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
        case .month:
            guard let interval = calendar.dateInterval(of: .month, for: today),
                  let range = calendar.range(of: .day, in: .month, for: interval.start) else { return [] }
            return range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: interval.start) }
        }
    }

    private var dayWidth: Double { period == .week ? 118 : 64 }
    private var canvasHeight: Double { hourHeight * 24 }

    private var rangeLabel: String {
        guard let first = snapshot.days.first?.date, let last = snapshot.days.last?.date else { return "" }
        if period == .month {
            return first.formatted(.dateTime.month(.wide).year()).uppercased()
        }
        return "\(first.formatted(.dateTime.month(.abbreviated).day()).uppercased()) — \(last.formatted(.dateTime.month(.abbreviated).day()).uppercased())"
    }

    private func rebuildSnapshot() {
        snapshot = BlockStatusCalendarLayout.makeSnapshot(
            calendarRules: calendarRules,
            dates: displayDates,
            calendar: calendar
        )
    }

    private func periodTotal(for ruleID: UUID) -> String {
        let hours = Double(snapshot.totalMinutesByRuleID[ruleID, default: 0]) / 60
        return "\(hours.formatted(.number.precision(.fractionLength(0...1))))H"
    }

    private func timeLabel(_ minutes: Int) -> String {
        minutes == 1_440
            ? "24:00"
            : String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    private func color(for index: Int) -> Color {
        let colors: [Color] = [
            Color(red: 0.05, green: 0.65, blue: 0.95),
            Color(red: 0.94, green: 0.24, blue: 0.55),
            Color(red: 1.00, green: 0.50, blue: 0.08),
            Color(red: 0.25, green: 0.78, blue: 0.36),
            Color(red: 0.62, green: 0.43, blue: 0.96),
            Color(red: 0.96, green: 0.79, blue: 0.08),
            Color(red: 0.05, green: 0.78, blue: 0.70),
            Color(red: 0.92, green: 0.31, blue: 0.22)
        ]
        return colors[index % colors.count]
    }
}

private struct IOSCalendarBlockEvent: View {
    let event: BlockStatusCalendarSnapshot.Event
    let color: Color
    let showLabel: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(color.opacity(0.88))
            Rectangle().stroke(IOSBrutalPalette.rule, lineWidth: 1)
            if showLabel {
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.ruleName.uppercased()).lineLimit(1)
                    Text(timeRange).opacity(0.82)
                }
                .font(.system(size: 7, weight: .black, design: .monospaced))
                .foregroundStyle(Color.black)
                .padding(3)
            }
        }
    }

    private var timeRange: String {
        "\(label(event.startMinute))–\(label(event.endMinute))"
    }

    private func label(_ minutes: Int) -> String {
        minutes == 1_440
            ? "24:00"
            : String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
