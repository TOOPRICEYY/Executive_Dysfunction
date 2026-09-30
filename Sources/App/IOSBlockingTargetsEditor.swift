import FamilyControls
import SwiftUI

struct IOSBlockingTargetsEditor: View {
    @Binding var targets: CloudBlockingTargets
    @Binding var selection: FamilyActivitySelection
    @State private var showPicker = false
    @State private var domainInput = ""
    @State private var feedback = ""
    @State private var isClassifying = false
    @FocusState private var websiteFocused: Bool

    var body: some View {
        IOSBrutalCard {
            VStack(alignment: .leading, spacing: 24) {
                Text("APPS & WEBSITES").font(.headline)
                HStack(spacing: 12) {
                    Image(systemName: "app.badge").font(.title2).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Apps on this device").font(.body.weight(.semibold))
                        Text(selectionSummary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Choose") { showPicker = true }
                        .font(.subheadline.weight(.semibold)).buttonStyle(.plain)
                        .padding(.horizontal, 12).frame(minHeight: 44)
                        .overlay { Rectangle().stroke(IOSBrutalPalette.rule, lineWidth: 1) }
                        .accessibilityIdentifier("choose-blocking-apps")
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Websites").font(.body.weight(.semibold))
                        Spacer()
                        Text("\(targets.domains.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        TextField("example.com or URL", text: $domainInput)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.URL).submitLabel(.done).focused($websiteFocused)
                            .iosBrutalField().onSubmit(addWebsites)
                            .accessibilityLabel("Website address").accessibilityIdentifier("blocking-website-input")
                        Button(action: addWebsites) { Image(systemName: "plus").frame(width: 44, height: 44) }
                            .buttonStyle(.plain)
                            .overlay { Rectangle().stroke(IOSBrutalPalette.rule, lineWidth: 1) }
                            .accessibilityLabel("Add websites")
                            .disabled(domainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !feedback.isEmpty { Text(feedback).font(.caption).foregroundStyle(.secondary) }
                    if targets.domains.isEmpty {
                        Text("Add a website, or paste several addresses at once.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(targets.domains, id: \.domain) { domain in
                                HStack(spacing: 12) {
                                    Image(systemName: "globe").foregroundStyle(.secondary).accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(domain.domain).font(.body).textSelection(.enabled)
                                        if !targets.websiteCategories.contains(domain.category) {
                                            Text("Excluded by category filter").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Button { targets.domains.removeAll { $0.domain == domain.domain } } label: {
                                        Image(systemName: "minus.circle").frame(width: 44, height: 44)
                                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                                        .accessibilityLabel("Remove \(domain.domain)")
                                }.padding(.vertical, 4)
                                Divider()
                            }
                        }
                    }
                }
                DisclosureGroup("Advanced website filters") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Only websites in enabled categories are included. This does not change your Screen Time selections.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(BlockingTargetInput.categories, id: \.self) { category in
                            Toggle(category == "aiTools" ? "AI tools" : category.capitalized, isOn: Binding(
                                get: { targets.websiteCategories.contains(category) },
                                set: { if $0 { targets.websiteCategories.insert(category) } else { targets.websiteCategories.remove(category) } }
                            ))
                        }
                        Button(isClassifying ? "Classifying…" : "Classify websites automatically", action: classify)
                            .disabled(isClassifying || targets.domains.isEmpty)
                    }.padding(.top, 12)
                }.font(.subheadline).tint(.primary)
            }.font(.system(.body, design: .default))
        }
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
    }

    private var selectionSummary: String {
        let count = selection.applicationTokens.count + selection.categoryTokens.count + selection.webDomainTokens.count
        guard count > 0 else { return "Choose apps, categories or Screen Time websites" }
        return "\(selection.applicationTokens.count) apps · \(selection.categoryTokens.count) categories · \(selection.webDomainTokens.count) sites"
    }

    private func addWebsites() {
        let result = BlockingTargetInput.add(domainInput, to: &targets)
        feedback = result.message
        domainInput = result.invalid.joined(separator: " ")
        if result.invalid.isEmpty { websiteFocused = false }
    }

    private func classify() {
        isClassifying = true
        let domains = targets.domains.map(\.domain)
        Task {
            let results = await DomainClassifier.classify(domains)
            for result in results {
                guard let index = targets.domains.firstIndex(where: { $0.domain == result.domain }) else { continue }
                targets.domains[index] = CloudDomainPreference(domain: result.domain, category: result.category.rawValue, source: result.source.rawValue)
                targets.websiteCategories.insert(result.category.rawValue)
            }
            isClassifying = false
        }
    }
}
