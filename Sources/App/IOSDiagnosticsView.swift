import SwiftUI

/// Reads the diagnostic report on the device, and exports it.
///
/// Showing the findings in the app matters as much as the export: most of the
/// time the answer to "why is this blocked" is already in the findings list, and
/// having to send a file somewhere to read it would make the tool useless in the
/// moment it is needed.
struct IOSDiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var redaction = HoldfastDiagnosticRedaction.standard
    @State private var report: HoldfastDiagnosticReport?
    @State private var exportedFiles: [URL] = []
    @State private var exportError: String?
    @State private var isShowingFullText = false
    @State private var isConfirmingReset = false
    @State private var isResetting = false
    @State private var resetStatus: String?

    var body: some View {
        List {
            Section {
                Picker("Detail", selection: $redaction) {
                    Text("Digest names").tag(HoldfastDiagnosticRedaction.standard)
                    Text("Include names").tag(HoldfastDiagnosticRedaction.full)
                }
                .pickerStyle(.segmented)
                Text(redaction == .standard
                    ? "Rule names and domains are replaced by short digests. Two devices still produce the same digest for the same value, so reports stay comparable."
                    : "Rule names and domains appear in full. Prefer this only when you are keeping the report yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Report detail")
            }

            if let report {
                findingsSection(report)
                summarySection(report)

                Section {
                    Button("View full report") { isShowingFullText = true }
                    ShareLink(items: exportedFiles) {
                        Label("Export report", systemImage: "square.and.arrow.up")
                    }
                    .disabled(exportedFiles.isEmpty)
                } footer: {
                    Text("Exports a readable .txt and a machine-readable .json describing this device's full state at \(HoldfastDiagnosticReport.format(report.generatedAt)).")
                }
            } else {
                Section {
                    ProgressView("Collecting device state…")
                }
            }

            if let exportError {
                Section {
                    Label(exportError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            recoverySection
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Refresh", action: rebuild)
            }
        }
        .onAppear(perform: rebuild)
        .onChange(of: redaction) { _, _ in rebuild() }
        .onDisappear { model.discardExportedDiagnostics() }
        .alert("Clear all restrictions?", isPresented: $isConfirmingReset) {
            Button("Clear Restrictions", role: .destructive, action: reset)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This revokes Screen Time access, which discards every restriction this app holds — including ones it can no longer identify — then asks for access again and reapplies your current schedule.\n\nNothing is enforced until you grant access again. Your chosen apps and categories are stored on this device and are not deleted, but Apple's selection tokens are tied to the authorisation, so check that a rule still blocks during its next window.")
        }
        .sheet(isPresented: $isShowingFullText) {
            if let report {
                IOSDiagnosticsTextView(blocks: report.renderedBlocks())
            }
        }
    }

    @ViewBuilder
    private var recoverySection: some View {
        Section {
            Button(role: .destructive) {
                isConfirmingReset = true
            } label: {
                if isResetting {
                    ProgressView()
                } else {
                    Label("Reset Screen Time Restrictions", systemImage: "arrow.counterclockwise")
                }
            }
            .disabled(isResetting)

            if let resetStatus {
                Text(resetStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Recovery")
        } footer: {
            Text("Use this when something is still blocked and the report accounts for no shield. A restriction left under an identity the app can no longer name cannot be cleared any other way, because Screen Time offers no way to enumerate them.")
        }
    }

    private func reset() {
        isResetting = true
        resetStatus = nil
        Task {
            let outcome = await model.resetAllScreenTimeRestrictions()
            resetStatus = outcome
            isResetting = false
            rebuild()
        }
    }

    private func rebuild() {
        let built = model.makeDiagnosticReport(redaction: redaction)
        report = built
        do {
            exportedFiles = try model.writeDiagnosticReport(built)
            exportError = nil
        } catch {
            exportedFiles = []
            exportError = "The report could not be written: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func findingsSection(_ report: HoldfastDiagnosticReport) -> some View {
        Section {
            if report.warnings.isEmpty {
                Label("No inconsistencies detected.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                ForEach(report.warnings.sorted { $0.severity < $1.severity }) { warning in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(warning.message, systemImage: icon(for: warning.severity))
                            .foregroundStyle(color(for: warning.severity))
                            .font(.callout)
                        if let hint = warning.hint {
                            Text(hint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(warning.code)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Findings")
        } footer: {
            Text("Each finding names the condition it detected. The code is stable, so it can be searched for across reports.")
        }
    }

    @ViewBuilder
    private func summarySection(_ report: HoldfastDiagnosticReport) -> some View {
        ForEach(Array(report.sections.enumerated()), id: \.offset) { _, section in
            if !section.rows.isEmpty {
                Section(section.title) {
                    ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                        LabeledContent(row.key, value: row.value)
                            .font(.callout)
                    }
                }
            }
        }
    }

    private func icon(for severity: HoldfastDiagnosticWarning.Severity) -> String {
        switch severity {
        case .critical: "exclamationmark.octagon"
        case .warning: "exclamationmark.triangle"
        case .note: "info.circle"
        }
    }

    private func color(for severity: HoldfastDiagnosticWarning.Severity) -> Color {
        switch severity {
        case .critical: .red
        case .warning: .orange
        case .note: .secondary
        }
    }
}

/// The tables only make sense in a monospaced, horizontally scrollable view.
///
/// Laid out one block per section rather than as a single text run: the whole
/// report is long enough that one `Text` is slow to lay out and turns
/// accessibility traversal into a crawl.
private struct IOSDiagnosticsTextView: View {
    let blocks: [HoldfastDiagnosticReport.RenderedBlock]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(blocks) { block in
                        Text(block.body)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Full report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
