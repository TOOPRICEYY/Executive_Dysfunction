import SwiftUI

struct MacActivityGroupEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var group: CloudActivityGroup
    @State private var domainText: String
    @State private var macApplicationText: String
    @State private var windowsExecutableText: String
    @State private var windowsPublisherText: String
    let onSave: (CloudActivityGroup) -> Void

    private let categoryNames = [
        "social", "video", "news", "shopping", "gaming", "adult",
        "aiTools", "productivity", "education", "finance", "health", "other"
    ]
    private let severityNames = ["appDefault", "none", "passageOnly", "delayed", "repeatedConfirmations"]

    init(initialGroup: CloudActivityGroup, onSave: @escaping (CloudActivityGroup) -> Void) {
        _group = State(initialValue: initialGroup)
        _domainText = State(initialValue: initialGroup.domains.map(\.domain).sorted().joined(separator: "\n"))
        _macApplicationText = State(initialValue: initialGroup.macApplicationIdentifiers.sorted().joined(separator: "\n"))
        _windowsExecutableText = State(initialValue: initialGroup.windowsExecutablePaths.sorted().joined(separator: "\n"))
        _windowsPublisherText = State(initialValue: initialGroup.windowsPublisherRules.sorted().joined(separator: "\n"))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    identitySection
                    websitesSection
                    applicationsSection
                    securitySection
                    ownershipNote
                }
                .padding(36)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom) { actionBar }
            .navigationTitle("")
        }
        .frame(minWidth: 720, idealWidth: 860, minHeight: 700, idealHeight: 820)
        .macBrutalSheet()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "NEW ACTIVITY GROUP" : "EDIT ACTIVITY GROUP")
                .font(.system(size: 44, weight: .black, design: .monospaced))
                .tracking(-1.8)
            Text("A REUSABLE LIVE COLLECTION. TARGET CHANGES PROPAGATE EVERYWHERE THIS GROUP IS LINKED.")
                .font(.system(.caption, design: .monospaced, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 20)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MacBrutalPalette.rule).frame(height: 2)
        }
    }

    private var identitySection: some View {
        editorSection("IDENTITY", subtitle: "NAME THE ACTIVITY, NOT A PARTICULAR BLOCKING RULE.") {
            VStack(alignment: .leading, spacing: 9) {
                editorLabel("GROUP NAME")
                TextField("ACTIVITY GROUP NAME", text: $group.name)
                    .macBrutalTextField()
                if group.deviceLocalSelectionCount > 0 {
                    HStack {
                        Text("DEVICE-LOCAL TARGETS")
                        Spacer()
                        Text("\(group.deviceLocalSelectionCount)")
                    }
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .padding(12)
                    .background(MacBrutalPalette.raisedSurface)
                    Text("These Screen Time selections remain on the device that created them and cannot be reconstructed here.")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var websitesSection: some View {
        editorSection("WEBSITE TARGETS", subtitle: "ADD EXPLICIT DOMAINS, BROAD CATEGORIES, OR BOTH.") {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 9) {
                    editorLabel("EXPLICIT DOMAINS — ONE PER LINE")
                    TextEditor(text: $domainText)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 130)
                        .background(MacBrutalPalette.surface)
                        .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
                }

                VStack(alignment: .leading, spacing: 10) {
                    editorLabel("CATEGORIES")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        ForEach(categoryNames, id: \.self) { category in
                            Button {
                                if group.websiteCategories.contains(category) {
                                    group.websiteCategories.remove(category)
                                } else {
                                    group.websiteCategories.insert(category)
                                }
                            } label: {
                                HStack {
                                    Text(categoryLabel(category).uppercased())
                                    Spacer()
                                    MacBrutalCheckboxIndicator(
                                        isOn: group.websiteCategories.contains(category)
                                    )
                                }
                                .font(.system(.caption, design: .monospaced, weight: .bold))
                                .padding(10)
                                .background(group.websiteCategories.contains(category) ? MacBrutalPalette.signal : MacBrutalPalette.surface)
                                .foregroundStyle(group.websiteCategories.contains(category) ? Color.black : Color.primary)
                                .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var applicationsSection: some View {
        editorSection("PORTABLE APPLICATION TARGETS", subtitle: "IDENTIFIERS SYNC. DEVICE-LOCAL PICKER TOKENS DO NOT.") {
            VStack(alignment: .leading, spacing: 18) {
                targetEditor("MACOS SIGNING IDENTIFIERS", text: $macApplicationText, minHeight: 76)
                targetEditor("WINDOWS EXECUTABLE PATHS", text: $windowsExecutableText, minHeight: 76)
                targetEditor("WINDOWS PUBLISHER RULES", text: $windowsPublisherText, minHeight: 64)
                Text("This approval-free macOS edition stores portable application targets but does not enforce application launches locally.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var securitySection: some View {
        editorSection("MODIFICATION SECURITY", subtitle: "DELETION COUNTS AS A MODIFICATION. THE MOST RESTRICTIVE CONTAINING POLICY WINS.") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    editorLabel("LOCK POLICY")
                    Spacer()
                    Picker("LOCK POLICY", selection: $group.modificationPolicy.severity) {
                        ForEach(severityNames, id: \.self) { severity in
                            Text(severityLabel(severity).uppercased()).tag(severity)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 250)
                    .padding(4)
                    .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
                }

                if group.modificationPolicy.severity == "delayed" || group.modificationPolicy.severity == "repeatedConfirmations" {
                    Stepper("UNLOCK WAIT: \(group.modificationPolicy.unlockDelayDays) DAYS", value: $group.modificationPolicy.unlockDelayDays, in: 0...365)
                }
                if group.modificationPolicy.severity != "none" && group.modificationPolicy.severity != "appDefault" {
                    Stepper("CONFIRMATION PASSAGE: \(group.modificationPolicy.passageWordCount) WORDS", value: $group.modificationPolicy.passageWordCount, in: 20...300)
                    Stepper("EDIT WINDOW: \(group.modificationPolicy.editWindowHours) HOURS", value: $group.modificationPolicy.editWindowHours, in: 1...72)
                }
                if group.modificationPolicy.severity == "repeatedConfirmations" {
                    Stepper("CONFIRMATION WINDOW: \(group.modificationPolicy.confirmationWindowHours) HOURS", value: $group.modificationPolicy.confirmationWindowHours, in: 1...48)
                }
                Toggle("PERMIT TEMPORARY ACCESS WHEN THIS GROUP IS INVOLVED", isOn: $group.modificationPolicy.allowsTimeExtensions)
                    .toggleStyle(MacBrutalCheckboxStyle())
                if group.modificationPolicy.allowsTimeExtensions {
                    Stepper("MAXIMUM TEMPORARY ACCESS: \(group.modificationPolicy.maximumTimeExtensionHours) HOURS", value: $group.modificationPolicy.maximumTimeExtensionHours, in: 1...8)
                }
            }
            .font(.system(.caption, design: .monospaced, weight: .medium))
        }
    }

    private var ownershipNote: some View {
        Text("SCHEDULES, USAGE BUDGETS, ENABLEMENT, AND ENFORCEMENT MODE BELONG TO BLOCKING GROUPS — NOT ACTIVITY GROUPS.")
            .font(.system(.caption2, design: .monospaced, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private var actionBar: some View {
        HStack {
            Text("LIVE OBJECT · SAVES TO ICLOUD")
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(.secondary)
            Spacer()
            Button("CANCEL") { dismiss() }
                .buttonStyle(MacBrutalButtonStyle())
            Button("SAVE ACTIVITY GROUP") { save() }
                .buttonStyle(MacBrutalButtonStyle(.primary))
                .disabled(group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 16)
        .background(MacBrutalPalette.canvas)
        .overlay(alignment: .top) { Rectangle().fill(MacBrutalPalette.rule).frame(height: 1) }
    }

    private func editorSection<Content: View>(
        _ title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(.title3, design: .monospaced, weight: .black))
                Text(subtitle)
                    .font(.system(.caption2, design: .monospaced, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacBrutalPalette.surface)
        .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
    }

    private func targetEditor(_ title: String, text: Binding<String>, minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            editorLabel(title)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: minHeight)
                .background(MacBrutalPalette.canvas)
                .overlay { Rectangle().stroke(MacBrutalPalette.rule, lineWidth: 1) }
        }
    }

    private func editorLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(.caption, design: .monospaced, weight: .bold))
            .foregroundStyle(.secondary)
    }

    private func save() {
        updateDomains()
        group.macApplicationIdentifiers = normalizedLines(macApplicationText)
        group.windowsExecutablePaths = normalizedLines(windowsExecutableText)
        group.windowsPublisherRules = normalizedLines(windowsPublisherText)
        onSave(group)
        dismiss()
    }

    private func updateDomains() {
        let domains = domainText
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
            .filter { !$0.isEmpty }
        let old = Dictionary(
            group.domains.map { ($0.domain.lowercased(), $0) },
            uniquingKeysWith: { current, _ in current }
        )
        group.domains = Array(Set(domains)).sorted().map {
            old[$0] ?? CloudDomainPreference(domain: $0, category: "other", source: "user")
        }
    }

    private func normalizedLines(_ text: String) -> Set<String> {
        Set(text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed.lowercased()
        })
    }

    private func categoryLabel(_ value: String) -> String {
        value == "aiTools" ? "AI Tools" : value.capitalized
    }

    private func severityLabel(_ value: String) -> String {
        switch value {
        case "appDefault": "App default"
        case "none": "No edit lock"
        case "passageOnly": "Passage only"
        case "delayed": "Delayed unlock"
        default: "Repeated confirmations"
        }
    }
}
