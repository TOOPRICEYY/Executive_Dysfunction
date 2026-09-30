import AppKit
import SwiftUI

/// Reads and exports this Mac's diagnostic report.
///
/// The activity trace has been recording all along with no way to get it out.
/// This is that way out, and it carries the report around it so the trace
/// arrives with the state that explains it.
struct MacDiagnosticsSheet: View {
    @ObservedObject var model: MacAppModel
    @Environment(\.dismiss) private var dismiss

    @State private var redaction = HoldfastDiagnosticRedaction.standard
    @State private var report: HoldfastDiagnosticReport?
    @State private var exportStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let report {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        TamperJournalList(events: TamperJournal.shared.events())
                        ForEach(report.renderedBlocks()) { block in
                            Text(block.body)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView("Collecting state…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 900, minHeight: 620)
        .macBrutalSheet()
        .onAppear(perform: rebuild)
        .onChange(of: redaction) { _, _ in rebuild() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("DIAGNOSTIC REPORT")
                    .font(.system(.title3, design: .monospaced, weight: .black))
                Text("FULL STATE OF THIS MAC, INCLUDING WHAT THE FILTER ITSELF REPORTS.")
                    .font(.system(.caption2, design: .monospaced, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $redaction) {
                Text("DIGEST NAMES").tag(HoldfastDiagnosticRedaction.standard)
                Text("INCLUDE NAMES").tag(HoldfastDiagnosticRedaction.full)
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
        }
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let report {
                let critical = report.criticalWarnings.count
                Text(critical > 0
                    ? "\(critical) CRITICAL FINDING\(critical == 1 ? "" : "S")"
                    : report.warnings.isEmpty ? "NO INCONSISTENCIES DETECTED" : "\(report.warnings.count) FINDING(S)")
                    .font(.system(.caption, design: .monospaced, weight: .black))
                    .foregroundStyle(critical > 0 ? Color.red : .secondary)
            }
            if let exportStatus {
                Text(exportStatus)
                    .font(.system(.caption2, design: .monospaced, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("REFRESH", action: rebuild)
                .buttonStyle(MacBrutalButtonStyle())
            Button("COPY", action: copyToPasteboard)
                .buttonStyle(MacBrutalButtonStyle())
            Button("EXPORT…", action: export)
                .buttonStyle(MacBrutalButtonStyle(.primary))
            Button("CLOSE") { dismiss() }
                .buttonStyle(MacBrutalButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func rebuild() {
        report = model.makeDiagnosticReport(redaction: redaction)
        exportStatus = nil
    }

    private func copyToPasteboard() {
        guard let report else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.renderedText(), forType: .string)
        exportStatus = "Copied the readable report."
    }

    private func export() {
        guard let report else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = "Choose where to write \(report.suggestedFileName).txt and .json"

        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            let written = try model.writeDiagnosticReport(report, to: directory)
            exportStatus = "Wrote \(written.count) file(s) to \(directory.lastPathComponent)."
        } catch {
            exportStatus = "Export failed: \(error.localizedDescription)"
        }
    }
}
