import SwiftUI

private struct BypassReportMenu: View {
    let title: String
    @Binding var selection: String
    let options: [(value: String, title: String)]
    var identifier = ""
    @State private var showingOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            control
        }
    }
    @ViewBuilder private var control: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 0) {
            Button { showingOptions.toggle() } label: { controlLabel }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(options.first { $0.value == selection }?.title ?? "All")
                .accessibilityIdentifier(identifier)
            if showingOptions {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(options, id: \.value) { option in
                            Button {
                                selection = option.value
                                showingOptions = false
                            } label: {
                                HStack {
                                    Text(option.title).multilineTextAlignment(.leading)
                                    Spacer()
                                    if selection == option.value { Image(systemName: "checkmark") }
                                }.padding(12).frame(maxWidth: .infinity, minHeight: 44)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: CGFloat(min(5, options.count)) * 48)
                    .background(Color.secondary.opacity(0.08))
            }
        }
        #else
        Menu { optionButtons } label: { controlLabel }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel(title)
            .accessibilityValue(options.first { $0.value == selection }?.title ?? "All")
            .accessibilityIdentifier(identifier)
        #endif
    }
    private var optionButtons: some View {
        ForEach(options, id: \.value) { option in
            Button(option.title) { selection = option.value }
        }
    }
    private var controlLabel: some View {
        HStack {
            Text(options.first { $0.value == selection }?.title ?? "All")
                .lineLimit(2).multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Image(systemName: "chevron.down").font(.caption)
        }.padding(10).frame(minHeight: 42)
            .overlay { Rectangle().stroke(Color.secondary.opacity(0.4)).allowsHitTesting(false) }
            .contentShape(Rectangle())
    }
}

struct BypassIntentPicker: View {
    @Binding var selection: BypassEvent.Intent?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How would you describe this exception?").font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                ForEach(BypassEvent.Intent.allCases, id: \.self) { intent in
                    Button { selection = intent } label: {
                        Text(intent.title).font(.callout.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .padding(.horizontal, 8)
                            .background(selection == intent ? Color.accentColor.opacity(0.2) : Color.clear)
                            .overlay { Rectangle().stroke(selection == intent ? Color.accentColor : Color.secondary.opacity(0.5)) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(selection == intent ? "Selected" : "Not selected")
                    .accessibilityIdentifier("bypass-intent-\(intent.rawValue)")
                }
            }
            Text("Saved in bypass history. Neither choice changes the passage or access duration.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Asks what the time is for before the passage becomes available.
struct BypassReflectionField: View {
    let prompt: String
    @Binding var answer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(prompt).font(.subheadline.weight(.semibold))
            TextField("At least \(ReflectionPrompt.minimumWords) words", text: $answer, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("bypass-reflection")
            Text("Saved with this bypass in your history. It does not change the passage or the time.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct BypassActivityPanel: View {
    let groups: [BypassReport.Group]
    let defaults: UserDefaults
    var coverageNote: String? = nil
    var onOpen: ((UUID?) -> Void)? = nil
    @AppStorage("bypass-report.panel-period") private var period = BypassReport.Period.week.rawValue
    @State private var snapshot: BypassHistoryStore.Snapshot?
    @State private var loadedData: Data?
    @State private var showDetail = false
    @State private var selectedGroup: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Bypasses").font(.title3.weight(.semibold))
                Spacer()
                Picker("Period", selection: $period) {
                    ForEach(BypassReport.Period.allCases.filter { $0 != .custom }) { Text($0.title).tag($0.rawValue) }
                }.labelsHidden().pickerStyle(.menu)
            }
            Text("Successful temporary-access grants · this device")
                .font(.caption).foregroundStyle(.secondary)
            if let error = snapshot?.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            } else {
                let now = Date()
                let events = BypassReport.events(snapshot?.document.events ?? [], from: (BypassReport.Period(rawValue: period) ?? .week).start(at: now), through: now)
                let summaries = BypassReport.summaries(events: events, groups: groups)
                if events.isEmpty { Text("No recorded bypasses in this period.").foregroundStyle(.secondary).font(.callout) }
                ForEach(summaries.prefix(5)) { summary in
                    Button { open(summary.id) } label: {
                        HStack(spacing: 12) {
                            Text(summary.name).lineLimit(1)
                            Spacer()
                            Text("\(summary.count)").monospacedDigit().fontWeight(.semibold)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityLabel("\(summary.name), \(summary.count) bypasses. Open details")
                }
            }
            Divider()
            Button("View all bypasses & configure…") { open(nil) }
                .accessibilityIdentifier("open-bypass-history")
            Text("History starts with this update; older usage may be missing.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20)
        .overlay { Rectangle().stroke(Color.secondary.opacity(0.35)) }
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in reload() }
        .sheet(isPresented: $showDetail) {
            BypassHistoryDetailView(groups: groups, defaults: defaults, initialGroupID: selectedGroup, coverageNote: coverageNote)
        }
    }
    private func reload() {
        let data = defaults.data(forKey: BypassHistoryStore.key)
        guard snapshot == nil || data != loadedData else { return }
        snapshot = BypassHistoryStore.read(defaults: defaults)
        loadedData = defaults.data(forKey: BypassHistoryStore.key)
    }
    private func open(_ id: UUID?) {
        if let onOpen { onOpen(id) }
        else { selectedGroup = id; showDetail = true }
    }
}

struct BypassHistoryDetailView: View {
    let groups: [BypassReport.Group]
    let defaults: UserDefaults
    var coverageNote: String?
    @Environment(\.dismiss) private var dismiss
    @AppStorage("bypass-report.detail-period") private var period = BypassReport.Period.month.rawValue
    @AppStorage("bypass-report.source") private var source = "all"
    @AppStorage("bypass-report.intent") private var intent = "all"
    @AppStorage("bypass-report.sort") private var sort = "count"
    @AppStorage("bypass-report.show-zero") private var showZero = true
    @State private var groupID: UUID?
    @State private var fromDate = Calendar.current.startOfDay(for: Date())
    @State private var toDate = Date()
    @State private var snapshot: BypassHistoryStore.Snapshot?
    @State private var loadedData: Data?
    @State private var visibleCount = 100

    init(groups: [BypassReport.Group], defaults: UserDefaults, initialGroupID: UUID? = nil, coverageNote: String? = nil) {
        self.groups = groups
        self.defaults = defaults
        self.coverageNote = coverageNote
        _groupID = State(initialValue: initialGroupID)
    }

    private var allGroups: [BypassReport.Summary] {
        BypassReport.summaries(events: snapshot?.document.events ?? [], groups: groups).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var events: [BypassEvent] {
        let now = Date()
        let selected = BypassReport.Period(rawValue: period) ?? .month
        let start = selected == .custom ? Calendar.current.startOfDay(for: fromDate) : selected.start(at: now)
        let end = selected == .custom
            ? min(now, (Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: toDate)) ?? toDate).addingTimeInterval(-0.001)) : now
        return BypassReport.events(snapshot?.document.events ?? [], from: start, through: end,
            groupID: groupID, source: BypassEvent.Source(rawValue: source), intent: intent)
    }
    private func summaries(for events: [BypassEvent]) -> [BypassReport.Summary] {
        let result = BypassReport.summaries(events: events, groups: groups).filter {
            (groupID == nil || $0.id == groupID) && (showZero || $0.count > 0)
        }
        switch sort {
        case "name": return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "latest": return result.sorted { ($0.latest ?? .distantPast) > ($1.latest ?? .distantPast) }
        default: return result
        }
    }

    var body: some View {
        let events = events
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Review temporary access without changing your blocking policies.").foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 14) {
                        BypassReportMenu(title: "Period", selection: $period,
                            options: BypassReport.Period.allCases.map { ($0.rawValue, $0.title) })
                        BypassReportMenu(title: "Group", selection: Binding(
                            get: { groupID?.uuidString ?? "all" }, set: { groupID = UUID(uuidString: $0) }),
                            options: [("all", "All groups")] + allGroups.map { ($0.id.uuidString, $0.name) })
                        BypassReportMenu(title: "Source", selection: $source,
                            options: [("all", "All sources")] + BypassEvent.Source.allCases.map { ($0.rawValue, $0.title) })
                        BypassReportMenu(title: "Intention", selection: $intent,
                            options: [("all", "All intentions")] + BypassEvent.Intent.allCases.map { ($0.rawValue, $0.title) } + [("unspecified", "Unspecified")],
                            identifier: "bypass-intent-filter")
                        BypassReportMenu(title: "Sort groups", selection: $sort,
                            options: [("count", "Most bypasses"), ("latest", "Most recent"), ("name", "Name")])
                        Toggle("Show zero-count groups", isOn: $showZero)
                    }
                    if period == BypassReport.Period.custom.rawValue {
                        DatePicker("From", selection: $fromDate, in: ...toDate, displayedComponents: .date)
                        DatePicker("Through", selection: $toDate, in: fromDate...Date(), displayedComponents: .date)
                    }
                    if let error = snapshot?.error { Text(error).foregroundStyle(.orange) }
                    Text("\(events.count) \(events.count == 1 ? "bypass" : "bypasses") · \(events.reduce(0) { $0 + $1.grantedMinutes }) minutes granted")
                        .font(.title3.weight(.semibold)).monospacedDigit()
                    Text("Each successful grant or extension counts once. Minutes are authorized time, not measured usage; overlapping grants may overlap in time.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let coverageNote { Text(coverageNote).font(.caption).foregroundStyle(.secondary) }
                    if let document = snapshot?.document {
                        Text("Local recording started \(document.startedAt.formatted(date: .abbreviated, time: .shortened)). \(document.wasTruncated ? "Showing the newest 10,000 records; earlier records were dropped." : "Up to 10,000 records are kept. Older unrecorded usage is not included.")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Text("By Blocking Group").font(.headline)
                    ForEach(summaries(for: events)) { summary in
                        Button { groupID = summary.id } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(summary.name)
                                    if summary.isRemoved { Text("Not in current groups").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Text("\(summary.count) · \(summary.minutes) min").monospacedDigit()
                            }.contentShape(Rectangle()).padding(.vertical, 6)
                        }.buttonStyle(.plain)
                    }
                    Divider()
                    Text("Individual bypasses").font(.headline)
                    if events.isEmpty { Text("No recorded bypasses match these filters.").foregroundStyle(.secondary) }
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(events.prefix(visibleCount)) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(groups.first { $0.id == event.groupID }?.name ?? event.groupName).fontWeight(.semibold)
                                Text("\(event.grantedAt.formatted(date: .abbreviated, time: .shortened)) · \(event.grantedMinutes) min · \(event.source.title)")
                                Text(event.intent?.title ?? "Unspecified").foregroundStyle(.secondary)
                                if let reflection = event.reflection {
                                    Text("“\(reflection)”").italic().foregroundStyle(.secondary)
                                }
                                Text("Authorized until \(event.expiresAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                            }.font(.callout)
                        }
                    }
                    if events.count > visibleCount { Button("Show 100 more") { visibleCount += 100 } }
                }.padding(24)
            }
            .navigationTitle("Bypass history")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 720, idealWidth: 880, minHeight: 560, idealHeight: 720)
        #endif
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in reload() }
    }
    private func reload() {
        let data = defaults.data(forKey: BypassHistoryStore.key)
        guard snapshot == nil || data != loadedData else { return }
        snapshot = BypassHistoryStore.read(defaults: defaults)
        loadedData = defaults.data(forKey: BypassHistoryStore.key)
    }
}
