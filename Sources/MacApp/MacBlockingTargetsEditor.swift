import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacBlockingTargetsEditor: View {
    @Binding var targets: CloudBlockingTargets
    @State private var drafts: [String: String] = [:]
    @State private var domainInput = ""
    @State private var feedback = ""
    @State private var appFeedback = ""
    @State private var showAppPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("APPS & WEBSITES").font(.title2.bold())
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Mac apps", systemImage: "app.badge").font(.headline)
                    Spacer()
                    Button("Choose apps…") { showAppPicker = true }
                }
                if targets.macApplicationIdentifiers.isEmpty {
                    Text("Choose installed apps to include in this group.").foregroundStyle(.secondary)
                }
                ForEach(targets.macApplicationIdentifiers.sorted(), id: \.self) { identifier in
                    MacBlockingApplicationRow(identifier: identifier) {
                        targets.macApplicationIdentifiers.remove(identifier)
                        drafts.removeValue(forKey: "Mac bundle identifiers")
                    }
                }
                if !appFeedback.isEmpty { Text(appFeedback).font(.caption).foregroundStyle(.secondary) }
                if targets.deviceLocalSelectionCount > 0 {
                    Text("\(targets.deviceLocalSelectionCount) Screen Time selections are managed on iPhone/iPad.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Websites", systemImage: "globe").font(.headline)
                    Spacer()
                    Text("\(targets.domains.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    TextField("example.com or website URL", text: $domainInput)
                        .macBrutalTextField().onSubmit(addWebsites)
                        .accessibilityLabel("Website address")
                    Button("Add", action: addWebsites)
                        .disabled(domainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !feedback.isEmpty { Text(feedback).font(.caption).foregroundStyle(.secondary) }
                if targets.domains.isEmpty {
                    Text("Add a website, or paste several addresses at once.").foregroundStyle(.secondary)
                }
                LazyVStack(spacing: 0) {
                    ForEach(targets.domains, id: \.domain) { domain in
                        HStack(spacing: 12) {
                            Image(systemName: "globe").foregroundStyle(.secondary).accessibilityHidden(true)
                            Text(domain.domain).textSelection(.enabled)
                            if !targets.websiteCategories.contains(domain.category) {
                                Text("Excluded by category filter").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button { targets.domains.removeAll { $0.domain == domain.domain } } label: {
                                Image(systemName: "minus.circle").frame(width: 28, height: 28)
                            }.buttonStyle(.plain).accessibilityLabel("Remove \(domain.domain)")
                        }.padding(.vertical, 8)
                        Divider()
                    }
                }
            }
            DisclosureGroup("Advanced filters & cross-platform targets") {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Website category filters").font(.headline)
                    Text("Only websites in enabled categories are included. App selections are independent.")
                        .font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)], alignment: .leading, spacing: 12) {
                        ForEach(BlockingTargetInput.categories, id: \.self) { category in
                            Toggle(category == "aiTools" ? "AI tools" : category.capitalized, isOn: Binding(
                                get: { targets.websiteCategories.contains(category) },
                                set: { if $0 { targets.websiteCategories.insert(category) } else { targets.websiteCategories.remove(category) } }
                            ))
                        }
                    }
                    Divider()
                    Text("Manual app identifiers").font(.headline)
                    Text("For apps on other computers. One identifier or path per line.")
                        .font(.caption).foregroundStyle(.secondary)
                    targetList("Mac bundle identifiers", key: \.macApplicationIdentifiers)
                    targetList("Windows executable paths", key: \.windowsExecutablePaths)
                    targetList("Windows publisher rules", key: \.windowsPublisherRules)
                }.padding(.top, 16)
            }
        }
        .font(.system(.body, design: .default))
        .fileImporter(isPresented: $showAppPicker, allowedContentTypes: [.applicationBundle], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                var invalid: [String] = []
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let identifier = Bundle(url: url)?.bundleIdentifier, !identifier.isEmpty {
                        targets.macApplicationIdentifiers.insert(identifier)
                    } else {
                        invalid.append(url.deletingPathExtension().lastPathComponent)
                    }
                }
                drafts.removeValue(forKey: "Mac bundle identifiers")
                appFeedback = invalid.isEmpty ? "" : "Could not read an app identifier for: " + invalid.joined(separator: ", ")
            case .failure(let error):
                appFeedback = "Could not select apps: " + error.localizedDescription
            }
        }
    }

    private func addWebsites() {
        let result = BlockingTargetInput.add(domainInput, to: &targets)
        feedback = result.message
        domainInput = result.invalid.joined(separator: " ")
    }

    private func targetList(_ title: String, key: WritableKeyPath<CloudBlockingTargets, Set<String>>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            TextEditor(text: Binding(get: { drafts[title] ?? targets[keyPath: key].sorted().joined(separator: "\n") }, set: {
                drafts[title] = $0
                targets[keyPath: key] = Set($0.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            })).font(.system(.body, design: .monospaced)).frame(height: 70).macBrutalTextField()
        }
    }
}

private struct MacBlockingApplicationRow: View {
    let identifier: String
    let remove: () -> Void
    @State private var name = ""
    @State private var icon: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28).accessibilityHidden(true)
            } else {
                Image(systemName: "app").frame(width: 28, height: 28).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(name.isEmpty ? identifier : name)
                if !name.isEmpty { Text(identifier).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            Button(action: remove) { Image(systemName: "minus.circle").frame(width: 28, height: 28) }
                .buttonStyle(.plain).accessibilityLabel("Remove \(name.isEmpty ? identifier : name)")
        }
        .task(id: identifier) {
            // Resolve once per row, not on every keystroke elsewhere in the editor.
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                name = FileManager.default.displayName(atPath: url.path)
                icon = NSWorkspace.shared.icon(forFile: url.path)
            }
        }
    }
}
