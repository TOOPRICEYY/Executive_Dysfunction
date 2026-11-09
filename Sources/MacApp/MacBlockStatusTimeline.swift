import SwiftUI

private enum MacBlockStatusPeriod: String, CaseIterable, Identifiable {
    case week
    case month

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

struct MacBlockStatusTimeline: View {
    let calendarRules: [BlockStatusCalendarRule]

    @State private var period = MacBlockStatusPeriod.week
    @State private var isolatedRuleID: UUID?
    @State private var snapshot = BlockStatusCalendarSnapshot.empty
    @State private var availableWidth: CGFloat = 1120

    private var calendar: Calendar { .current }
    private let timeLabelWidth = 62.0
    private let headerHeight = 48.0
    /// Two hours share one visual band. Event offsets still use their exact
    /// start/end minutes, so this reduces density without rounding schedules.
    private let twoHourBandHeight = 38.0

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
            Rectangle().fill(MacBrutalPalette.rule).frame(height: 2)

            if rules.isEmpty {
                Text("Enable a Blocking Group to see its schedule here.")
                    .font(.system(.callout, design: .monospaced, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                legend
                Rectangle().fill(MacBrutalPalette.rule.opacity(0.55)).frame(height: 1)
                calendarMap
            }
        }
        .background(MacBrutalPalette.surface)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
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
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Text("Blocking calendar")
                        .font(.system(.title2, design: .default, weight: .semibold))
                    Text(rangeLabel)
                        .font(.system(.caption2, design: .default, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text("Shows when groups block access. Hover over a group below to focus on it.")
                    .font(.system(.caption2, design: .monospaced, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 0) {
                ForEach(MacBlockStatusPeriod.allCases) { option in
                    Button(option.label) { period = option }
                        .buttonStyle(.plain)
                        .font(.system(.caption, design: .default, weight: .semibold))
                        .foregroundStyle(period == option ? Color.black : Color.primary)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background(period == option ? MacBrutalPalette.signal : MacBrutalPalette.surface)
                        .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
                }
            }
        }
        .padding(20)
    }

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(rules.indices, id: \.self) { index in
                    let rule = rules[index]
                    HStack(spacing: 8) {
                        Rectangle()
                            .fill(color(for: index))
                            .frame(width: 12, height: 22)
                        Text(rule.name.uppercased()).lineLimit(1)
                        Text(periodTotal(for: rule.id)).foregroundStyle(.secondary)
                    }
                    .font(.system(.caption2, design: .default, weight: .semibold))
                    .padding(.horizontal, 9)
                    .frame(height: 32)
                    .background(
                        isolatedRuleID == rule.id
                            ? color(for: index).opacity(0.18)
                            : MacBrutalPalette.raisedSurface
                    )
                    .overlay { Rectangle().stroke(MacBrutalPalette.rule.opacity(0.7), lineWidth: 1) }
                    .opacity(isolatedRuleID == nil || isolatedRuleID == rule.id ? 1 : 0.25)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { isolatedRuleID = rule.id }
                        else if isolatedRuleID == rule.id { isolatedRuleID = nil }
                    }
                    .help("Hover to isolate \(rule.name)")
                }
            }
            .padding(12)
        }
    }

    private var calendarMap: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            LazyHStack(alignment: .top, spacing: 0) {
                timeColumn
                ForEach(snapshot.days) { day in
                    dayColumn(day)
                }
            }
            .padding(16)
        }
        .frame(maxHeight: 560)
    }

    private var timeColumn: some View {
        VStack(spacing: 0) {
            Text("TIME")
                .font(.system(.caption2, design: .default, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: timeLabelWidth, height: headerHeight, alignment: .leading)

            VStack(spacing: 0) {
                ForEach(0..<12, id: \.self) { band in
                    Text(String(format: "%02d—%02d", band * 2, band * 2 + 2))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 8)
                        .frame(width: timeLabelWidth, height: twoHourBandHeight, alignment: .topTrailing)
                        .offset(y: -5)
                }
            }
        }
    }

    private func dayColumn(_ day: BlockStatusCalendarSnapshot.Day) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                if period == .week {
                    Text(day.date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                }
                Text(day.date.formatted(.dateTime.day()))
            }
            .font(.system(.caption2, design: .default, weight: .semibold))
            .foregroundStyle(calendar.isDateInToday(day.date) ? MacBrutalPalette.controlAccent : Color.secondary)
            .frame(width: dayWidth, height: headerHeight)
            .overlay { Rectangle().stroke(MacBrutalPalette.rule.opacity(0.55), lineWidth: 0.5) }

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
            ForEach(0..<12, id: \.self) { band in
                Rectangle()
                    .fill(band.isMultiple(of: 2)
                        ? MacBrutalPalette.raisedSurface.opacity(0.45)
                        : MacBrutalPalette.surface)
                    .frame(width: dayWidth, height: twoHourBandHeight)
                    .overlay(alignment: .top) {
                        Rectangle().fill(MacBrutalPalette.rule.opacity(0.45)).frame(height: 0.5)
                    }
            }
        }
        .overlay { Rectangle().stroke(MacBrutalPalette.rule.opacity(0.55), lineWidth: 0.5) }
    }

    private func eventCard(_ event: BlockStatusCalendarSnapshot.Event) -> some View {
        let geometry = BlockStatusCalendarEventGeometry.stacked(
            dayWidth: dayWidth,
            lane: event.lane,
            laneCount: event.laneCount,
            horizontalInset: 4
        )
        let height = max(6, Double(event.durationMinutes) / 60 * pixelsPerHour - 1)
        let y = Double(event.startMinute) / 60 * pixelsPerHour + 0.5

        return MacCalendarBlockEvent(
            event: event,
            color: color(for: event.colorIndex),
            showLabel: geometry.width >= 54 && height >= 24
        )
        .frame(width: geometry.width, height: height)
        .offset(x: geometry.x, y: y)
        .zIndex(Double(event.lane))
        .opacity(isolatedRuleID == nil || isolatedRuleID == event.ruleID ? 1 : 0.10)
        .help("\(event.ruleName) · \(timeLabel(event.startMinute))–\(timeLabel(event.endMinute))")
        .accessibilityLabel("\(event.ruleName), \(timeLabel(event.startMinute)) to \(timeLabel(event.endMinute))")
    }

    private func currentTimeLine(at date: Date) -> some View {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return Rectangle()
            .fill(MacBrutalPalette.signal)
            .frame(width: dayWidth, height: 2)
            .offset(y: Double(minute) / 60 * pixelsPerHour)
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

    private var dayWidth: Double {
        // Fit all seven days when the window permits; retain horizontal scroll
        // at very small widths and in month view instead of crushing labels.
        period == .week ? max(76, (Double(availableWidth) - timeLabelWidth - 32) / 7) : 76
    }
    private var pixelsPerHour: Double { twoHourBandHeight / 2 }
    private var canvasHeight: Double { twoHourBandHeight * 12 }

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

private struct MacCalendarBlockEvent: View {
    let event: BlockStatusCalendarSnapshot.Event
    let color: Color
    let showLabel: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(color.opacity(0.88))
            Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1)
            if showLabel {
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.ruleName.uppercased()).lineLimit(1)
                    Text(timeRange).opacity(0.82)
                }
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundStyle(Color.black)
                .padding(4)
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
