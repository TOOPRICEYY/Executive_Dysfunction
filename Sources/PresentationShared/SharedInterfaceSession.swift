import CryptoKit
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
typealias SharedInterfaceNativeModel = MacAppModel
#else
import FamilyControls
typealias SharedInterfaceNativeModel = AppModel
#endif

/// Thin native adapter. Screens never write a cloud document, grant an unlock,
/// or toggle enforcement directly. Existing model methods remain authoritative.
@MainActor
final class SharedInterfaceSession: ObservableObject {
    let model: SharedInterfaceNativeModel
    @Published var nativePanel: String?
    @Published var showAdvancedControls = false
    private var generation = 0
    private struct Challenge {
        let passage: String
        let revision: String
        let expiry: Date
        let action: (String) throws -> Void
    }
    private var challenges: [String: Challenge] = [:]
    #if os(iOS)
    @Published var pickingApplications = false
    @Published var selection = FamilyActivitySelection()
    private var picker: CheckedContinuation<[String: Any], Error>?
    private var pickerGroup: UUID?
    private var selections: [String: (UUID, FamilyActivitySelection)] = [:]
    #endif

    init(model: SharedInterfaceNativeModel) { self.model = model }
    private static let accentNames = ["themeDefault": "themeDefault", "yellow": "signalYellow", "green": "phosphorGreen", "blue": "electricBlue", "orange": "warningOrange", "magenta": "hotMagenta", "violet": "terminalViolet"]
    private var appearance: [String: String] {
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: "executiveDysfunction.highlightColor") ?? "themeDefault"
        return ["theme": defaults.string(forKey: "executiveDysfunction.interfaceTheme") ?? "light",
                "accent": Self.accentNames.first(where: { $0.value == stored })?.key ?? "themeDefault"]
    }
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try JSONSerialization.jsonObject(with: encoder.encode(value)) as! [String: Any]
    }
    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private func revision() throws -> String {
        // Include native-only policy fields, not merely the view model. Sorting
        // collections makes Set encoding stable without rewriting native data.
        func canonical(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] { return dictionary.mapValues(canonical) }
            if let array = value as? [Any] {
                return array.map(canonical).sorted {
                    let a = try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys])
                    let b = try? JSONSerialization.data(withJSONObject: $1, options: [.fragmentsAllowed, .sortedKeys])
                    return (a ?? Data()).lexicographicallyPrecedes(b ?? Data())
                }
            }
            return value
        }
        let document = CloudPreferencesDocument(activityGroups: model.activityGroups, baseline: model.baseline, retreats: model.retreats)
        var fingerprint = try object(document)
        #if os(iOS)
        fingerprint["nativeAppDefault"] = try object(model.lockdownConfiguration)
        #endif
        let data = try JSONSerialization.data(withJSONObject: canonical(fingerprint), options: .sortedKeys)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ":\(generation)"
    }
    private func owned(_ id: UUID) -> CloudBlockingGroup? {
        model.baseline.blockingGroups.first { $0.id == id }?.owningTargets(from: model.activityGroups, containerPolicy: model.baseline.modificationPolicy)
    }
    private func isUnlocked(_ id: UUID) -> Bool {
        #if os(macOS)
        if model.ruleEditPolicy(id)?.severity == "none" { return true }
        if case .unlocked = model.ruleEditPhase(id) { return true }
        return false
        #else
        return !model.isRuleEditingLocked(id)
        #endif
    }
    private func pause(_ id: UUID) -> Date? {
        #if os(macOS)
        // Same source as the native dashboard: local pauses plus the filter's own report.
        return model.temporaryAllowanceExpirations[id] ?? model.temporaryPause(for: id)?.expiresAt
        #else
        return model.activeTimeAllowance(for: id)?.expiresAt
        #endif
    }
    private static let policyKinds = ["none": "none", "passageOnly": "passage", "delayed": "delay", "repeatedConfirmations": "checkpoints"]
    /// Host-evaluated "what is this doing now". The renderer never derives this from a schedule.
    private func nowObject(_ state: GroupNowState, now: Date) -> [String: Any] {
        let name: String
        switch state {
        case .lockdown: name = "lockdown"
        case .paused: name = "paused"
        case .blocking: name = "blocking"
        case .upcoming: name = "upcoming"
        case .idle: name = "idle"
        case .off: name = "off"
        }
        var value: [String: Any] = ["state": name, "headline": GroupNowStatus.headline(state, now: now)]
        if let at = state.changesAt { value["changesAt"] = iso(at) }
        return value
    }
    private func unlockObject(_ phase: UnlockPhase) -> [String: Any] {
        switch phase {
        case let .waiting(unlocksAt, _): return ["phase": "waiting", "at": iso(unlocksAt)]
        case let .confirmationDue(_, deadline, _, _): return ["phase": "confirmationDue", "at": iso(deadline)]
        case let .unlocked(editWindowEndsAt): return ["phase": "unlocked", "at": iso(editWindowEndsAt)]
        case .cancelled: return ["phase": "cancelled"]
        default: return ["phase": "idle"]
        }
    }
    /// Concrete blocked intervals for the next seven local days, using the same
    /// calendar rules as the native lanes (retreat runs, lockdowns, DST).
    private func scheduleDays(now: Date) -> [[String: Any]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let rules = model.dashboardCalendarRules
        return (0..<7).compactMap { offset -> [String: Any]? in
            guard let start = calendar.date(byAdding: .day, value: offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            var seen = Set<UUID>()
            let lanes: [[String: Any]] = rules.compactMap { entry in
                guard seen.insert(entry.rule.id).inserted else { return nil }
                return ["id": entry.rule.id.uuidString,
                        "intervals": ScheduleLanes.intervals(for: entry, from: start, to: end, calendar: calendar)
                            .map { ["start": iso($0.start), "end": iso($0.end)] }]
            }
            return ["start": iso(start), "end": iso(end), "lanes": lanes]
        }
    }
    private var historyDefaults: UserDefaults {
        #if os(macOS)
        .standard
        #else
        SharedConfiguration.bypassHistoryDefaults
        #endif
    }
    func snapshot() throws -> [String: Any] {
        let now = Date()
        #if os(macOS)
        let platform = "macos"
        let detail = FilterEnforcementSummary.description(for: model.enforcementHealth)
        let enabled = !model.enforcement.isBlockingDisabled
        let confirmed: Bool
        switch model.enforcementHealth { case .enforcing, .idle: confirmed = enabled; default: confirmed = false }
        let controller = model.enforcement
        let warning = controller.activationSafetyRequiresRestart || controller.recoveryWarning != nil || controller.deliveryError != nil
        let headline: String
        if controller.activationSafetyRequiresRestart { headline = "Safety locked" }
        else if controller.recoveryWarning != nil { headline = "Needs attention" }
        else if controller.deliveryError != nil { headline = "Delivery error" }
        else if controller.isBlockingDisabled { headline = "Web filter off" }
        else if controller.status == .active { headline = FilterEnforcementSummary.isHealthy(model.enforcementHealth) ? "Web filter on" : "Needs attention" }
        else { headline = controller.status.description }
        let enforcement: [String: Any] = ["state": !enabled ? "disabled" : warning ? "error" : confirmed ? "active" : "unknown",
            "title": model.enforcement.status.description, "detail": detail, "headline": headline]
        let sync = model.syncStatus
        #else
        let platform = "ios"
        let enabled = model.isAuthorized
        let confirmed = enabled
        let enforcement: [String: Any] = ["state": enabled ? "active" : "disabled", "title": "Screen Time: \(model.authorizationDescription)",
            "headline": enabled ? "Screen Time on" : "Connect Screen Time",
            "detail": "Status reflects the native rules and Screen Time authorization. System monitor timing can be approximate; foreground reconciliation uses the exact time."]
        let sync = model.cloudSyncStatus
        #endif
        var summaryGroups: [DashboardNowSummary.Group] = []
        let groups: [[String: Any]] = try model.baseline.blockingGroups.map { original in
            let group = original.owningTargets(from: model.activityGroups, containerPolicy: model.baseline.modificationPolicy)
            var value = try object(SharedInterfaceGroup(group))
            // Optional resetDays must be explicit null in the shared contract.
            var temp = value["temporaryPolicy"] as! [String: Any]
            if temp["resetDays"] == nil { temp["resetDays"] = NSNull() }; value["temporaryPolicy"] = temp
            #if os(macOS)
            let passageWords = model.pausePassageWordCount(for: group.id, at: now)
            #else
            let passageWords = model.timeAllowancePassageWordCount(for: group.id)
            #endif
            if passageWords >= 20 { value["temporaryPassageWords"] = passageWords }
            let state = GroupNowStatus.evaluate(isEnabled: group.isEnabled, windows: group.timeWindow.effectiveBlockingSlots(), now: now,
                allowanceUntil: pause(group.id), lockdownUntil: model.lockdownExpirations[group.id])
            let hasWebTargets = !(group.targets?.domains.isEmpty ?? true) || !(group.targets?.websiteCategories.isEmpty ?? true)
            #if os(macOS)
            let hasDeviceTargets = hasWebTargets || !(group.targets?.macApplicationIdentifiers.isEmpty ?? true)
            #else
            let localSelection = model.selectionForBlockingGroup(group)
            let hasDeviceTargets = hasWebTargets || !localSelection.applicationTokens.isEmpty || !localSelection.categoryTokens.isEmpty || !localSelection.webDomainTokens.isEmpty
            #endif
            let status: String
            switch state {
            case .off: status = "disabled"
            case .paused: status = "suspended"
            case .lockdown: status = confirmed && hasDeviceTargets ? "lockdown" : "unsupported"
            case .blocking: status = confirmed && hasDeviceTargets ? "blocking" : "unsupported"
            default: status = "allowed"
            }
            value["status"] = status
            value["detail"] = status == "unsupported" ? (!hasDeviceTargets ? "This group has no selected targets available on this device. Other devices keep their own targets." : "Scheduled to block; enforcement is not confirmed. \(GroupNowStatus.headline(state, now: now))") : GroupNowStatus.headline(state, now: now)
            value["canEdit"] = isUnlocked(group.id)
            value["now"] = nowObject(state, now: now)
            if let until = model.lockdownExpirations[group.id], until > now { value["lockdownUntil"] = iso(until) }
            if group.modificationPolicy.severity != "none" {
                #if os(macOS)
                value["unlock"] = unlockObject(model.ruleEditPhase(group.id))
                #else
                value["unlock"] = unlockObject(model.ruleUnlockPhase(for: group.id))
                #endif
            }
            summaryGroups.append(.init(name: group.name, state: state))
            if let until = pause(group.id) { value["suspendedUntil"] = iso(until) }
            #if os(iOS)
            let s = model.selectionForBlockingGroup(group)
            value["applicationSummary"] = "\(s.applicationTokens.count) apps · \(s.categoryTokens.count) categories · \(s.webDomainTokens.count) Screen Time websites"
            #endif
            return value
        }
        // Groups in force only through a running Retreat or a lockdown: shown, never edited here.
        #if os(macOS)
        let liveRules = model.dashboardActiveRules
        #else
        let liveRules = model.dashboardBlockingRules
        #endif
        let baselineIDs = Set(model.baseline.blockingGroups.map(\.id))
        var seenLive = Set<UUID>()
        let retreatGroups: [[String: Any]] = liveRules.filter { !baselineIDs.contains($0.id) && seenLive.insert($0.id).inserted }.map { rule in
            let state = GroupNowStatus.evaluate(isEnabled: rule.isEnabled, windows: rule.windows, now: now,
                allowanceUntil: pause(rule.id), lockdownUntil: model.lockdownExpirations[rule.id])
            summaryGroups.append(.init(name: rule.name, state: state))
            return ["id": rule.id.uuidString, "name": rule.name, "now": nowObject(state, now: now),
                    "lock": Self.policyKinds[rule.lockdown.severity] ?? "inherited",
                    "delayDays": min(365, max(0, rule.lockdown.unlockDelayDays)),
                    "targets": HoldfastPresentation.targets(rule: rule)]
        }
        let summary = DashboardNowSummary(groups: summaryGroups)
        let presets: [[String: Any]] = HoldfastPresets.blockingPresets.map {
            ["id": $0.id, "name": $0.name, "summary": $0.summary, "lock": Self.policyKinds[$0.severity] ?? "inherited"]
        }
        let retreats: [[String: Any]] = model.retreats.map { r in
            ["id": r.id.uuidString, "name": r.name, "startsAt": iso(r.plannedStart), "endsAt": iso(r.plannedEnd),
             "state": r.state == .endedEarly ? "cancelled" : r.state.rawValue,
             "version": r.currentVersionNumber, "groupNames": r.currentVersion?.blockingGroups.map(\.name) ?? [],
             "changePolicyLabel": r.modificationPolicy.severity, "canRequestEnd": r.state == .active]
        }
        let events: [[String: Any]] = BypassHistoryStore.read(defaults: historyDefaults).document.events.map { event in
            return ["id": event.id.uuidString, "groupID": event.groupID.uuidString, "groupName": event.groupName,
                "startedAt": iso(event.grantedAt), "endsAt": iso(event.expiresAt), "reason": event.intent == nil ? "unspecified" : event.intent == .consciousIntervention ? "conscious" : "edulgence"]
        }
        var result: [String: Any] = ["schema": 1, "revision": try revision(), "platform": platform,
            "capabilities": ["editGroups", "temporaryAccess", "pickApplications", "retreats", "lockdown", "diagnostics", "enforcementControl", "appearance", "advancedControls", "presets"],
            "appearance": appearance,
            "enforcementEnabled": enabled, "enforcement": enforcement,
            "sync": ["state": "pending", "detail": sync], "groups": groups, "retreats": retreats, "bypasses": events, "lockdown": NSNull(),
            "summary": ["headline": summary.headline, "next": summary.nextLine(now: now) ?? NSNull()] as [String: Any],
            "retreatGroups": retreatGroups, "schedule": ["days": scheduleDays(now: now)], "presets": presets]
        if let end = model.lockdownExpirations.values.max() {
            result["lockdown"] = ["endsAt": iso(end), "groupNames": model.rules.filter { model.lockdownExpirations[$0.id] != nil }.map(\.name),
                "detail": model.lockdownSyncStatus]
        }
        return result
    }
    private func issue(title: String, passage: String, action: @escaping (String) throws -> Void) throws -> [String: Any] {
        let id = UUID().uuidString, expiry = Date().addingTimeInterval(30 * 60)
        challenges = [id: Challenge(passage: passage, revision: try revision(), expiry: expiry, action: action)]
        return ["challenge": ["id": id, "title": title, "passage": passage, "expiresAt": iso(expiry),
            "detail": "Type the passage. You have 30 minutes; a policy change invalidates it. Native rules determine when the request takes effect."]]
    }
    private func ensure(_ success: Bool) throws {
        if !success { throw SharedInterfaceError(model.errorMessage ?? "The native policy did not authorize this change.") }
    }
    func handle(_ data: Data) async throws -> Data {
        guard let c = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = c["type"] as? String else { throw SharedInterfaceError("Invalid command.") }
        let reply = try await perform(type, c)
        return try JSONSerialization.data(withJSONObject: reply, options: .sortedKeys)
    }
    private func perform(_ type: String, _ c: [String: Any]) async throws -> [String: Any] {
        if type == "snapshot" { return ["snapshot": try snapshot()] }
        if type == "setAppearance" {
            guard let key = c["key"] as? String, let value = c["value"] as? String else { throw SharedInterfaceError("Invalid appearance setting.") }
            if key == "theme", ["light", "dark"].contains(value) {
                UserDefaults.standard.set(value, forKey: "executiveDysfunction.interfaceTheme")
            } else if key == "accent", let native = Self.accentNames[value] {
                UserDefaults.standard.set(native, forKey: "executiveDysfunction.highlightColor")
            } else { throw SharedInterfaceError("Choose a supported theme or highlight color.") }
            #if os(iOS)
            IOSDynamicAppIcon.synchronize(theme: UserDefaults.standard.string(forKey: "executiveDysfunction.interfaceTheme") ?? "light",
                highlight: UserDefaults.standard.string(forKey: "executiveDysfunction.highlightColor") ?? "themeDefault")
            #endif
            return ["message": "Appearance saved."]
        }
        if type == "submitChallenge" {
            guard let id = c["challengeID"] as? String, let challenge = challenges[id], let typed = c["typed"] as? String,
                  typed.count <= 400_000, challenge.expiry > Date(), challenge.revision == (try revision()) else { throw SharedInterfaceError("This passage expired or settings changed. Request it again.") }
            guard CommitmentPassage.matches(typed, passage: challenge.passage) else { throw SharedInterfaceError("The passage does not match.") }
            challenges.removeValue(forKey: id)
            try challenge.action(typed); generation += 1
            return ["snapshot": try snapshot(), "message": "Request processed by the native policy. Check the updated status for waiting periods or enforcement acknowledgement."]
        }
        if type == "diagnostics" { nativePanel = "diagnostics"; return ["message": "Native diagnostics opened."] }
        if type == "openAdvancedControls" {
            showAdvancedControls = true
            return ["message": "Advanced native controls opened."]
        }
        if type == "pickApplications" {
            guard let text = c["groupID"] as? String, let id = UUID(uuidString: text) else { throw SharedInterfaceError("Invalid group.") }
            #if os(macOS)
            let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.canChooseFiles = true
            picker.allowsMultipleSelection = true; picker.allowedContentTypes = [.applicationBundle]
            guard await picker.begin() == .OK else { return ["message": "Selection cancelled."] }
            let identifiers = try picker.urls.map { url -> String in
                guard let id = Bundle(url: url)?.bundleIdentifier else { throw SharedInterfaceError("That application has no bundle identifier.") }; return id
            }
            return ["applications": Array(Set(identifiers)).sorted()]
            #else
            guard picker == nil else { throw SharedInterfaceError("The application picker is already open.") }
            pickerGroup = id; selection = owned(id).map(model.selectionForBlockingGroup) ?? FamilyActivitySelection()
            return try await withCheckedThrowingContinuation { continuation in picker = continuation; pickingApplications = true }
            #endif
        }
        guard c["revision"] as? String == (try revision()) else { throw SharedInterfaceError("Settings changed. Close this dialog and reopen it before saving.") }
        model.errorMessage = nil
        if type == "createRetreat" || type == "startLockdown" { nativePanel = type; return ["message": "Native configuration opened. Existing all-device policy checks remain in force."] }
        if type == "setEnforcement" {
            #if os(macOS)
            if c["enabled"] as? Bool == true { model.installDesktopEnforcement(); try ensure(model.errorMessage == nil) }
            else {
                let challenge = model.makeDesktopBlockingDisableChallenge()
                return try issue(title: "Disable web blocking", passage: challenge.requiredPassage) { [weak self] typed in
                    guard let self else { throw SharedInterfaceError("The window was closed.") }
                    try ensure(model.disableDesktopBlocking(challenge: challenge, passage: typed) == .authorized)
                }
            }
            #else
            // Disabling Screen Time is a distinct native recovery workflow;
            // it must not be conflated with the Mac's web-only switch.
            if c["enabled"] as? Bool == true { await model.requestAuthorization(); try ensure(model.isAuthorized) }
            else { nativePanel = "settings"; return ["message": "Use the native Screen Time recovery controls in Settings."] }
            #endif
        } else if type == "installPreset" {
            guard let id = c["presetID"] as? String, let preset = HoldfastPresets.blockingPresets.first(where: { $0.id == id }) else { throw SharedInterfaceError("Unknown preset.") }
            #if os(macOS)
            model.installPreset(preset); try ensure(model.errorMessage == nil)
            #else
            try ensure(model.installPreset(preset))
            #endif
        } else if type == "requestRetreatEnd" {
            guard let text = c["retreatID"] as? String, let id = UUID(uuidString: text), let policy = model.retreatChangePolicy(for: id) else { throw SharedInterfaceError("Retreat no longer exists.") }
            let phase = model.retreatUnlockPhase(for: id)
            if !policy.requiresAuthorization { try ensure(model.finishRetreat(id)) }
            else if case .unlocked = phase { try ensure(model.finishRetreat(id)) }
            else {
                switch phase { case .waiting: throw SharedInterfaceError("The retreat change policy is still waiting. Return when its next checkpoint or edit window opens."); default: break }
                return try issue(title: "Unlock retreat changes", passage: CommitmentPassage.generate(wordCount: policy.passageWordCount)) { [weak self] _ in
                    guard let self else { throw SharedInterfaceError("The window was closed.") }
                    guard model.retreatChangePolicy(for: id) == policy else { throw SharedInterfaceError("The retreat policy changed. Request a new passage.") }
                    if case .confirmationDue = model.retreatUnlockPhase(for: id) { model.confirmRetreatUnlock(id) }
                    else { model.startRetreatUnlock(id) }
                    if case .unlocked = model.retreatUnlockPhase(for: id) { try ensure(model.finishRetreat(id)) }
                }
            }
        } else if type == "saveGroup" {
            let input = try JSONSerialization.data(withJSONObject: c["group"] ?? [:])
            let dto = try JSONDecoder().decode(SharedInterfaceGroup.self, from: input)
            let group = try dto.merging(into: owned(dto.id))
            #if os(iOS)
            if let token = dto.selectionToken {
                guard let (id, selection) = selections[token], id == dto.id else { throw SharedInterfaceError("The selection expired. Open the system picker again.") }
                try ensure(model.saveBlockingGroup(group, selection: selection)); selections.removeValue(forKey: token)
            } else { try ensure(model.saveBlockingGroup(group)) }
            #else
            try ensure(model.saveBlockingGroup(group))
            #endif
        } else {
            guard let text = c["groupID"] as? String, let id = UUID(uuidString: text), let group = owned(id) else { throw SharedInterfaceError("This group no longer exists.") }
            switch type {
            case "deleteGroup":
                try ensure(model.deleteBlockingGroup(group))
            case "cancelTemporaryAccess":
                try ensure(model.cancelTemporaryPause(for: id))
            case "requestGroupUnlock":
                #if os(macOS)
                guard let policy = model.ruleEditPolicy(id) else { throw SharedInterfaceError("No saved change policy.") }
                if case .waiting = model.ruleEditPhase(id) { throw SharedInterfaceError("The unlock waiting period has not ended.") }
                return try issue(title: "Unlock group changes", passage: DesktopRemovalGate.passage(wordCount: DesktopRuleEditUnlock.configuration(policy).passageWordCount, seed: id)) { [weak self] typed in
                    guard let self else { throw SharedInterfaceError("The window was closed.") }
                    try ensure(model.submitRuleEditPassage(id, typed: typed, expectedPolicy: policy))
                }
                #else
                guard let rule = model.rules.first(where: { $0.id == id }) else { throw SharedInterfaceError("No saved rule.") }
                let expectedPolicy = model.ruleLockdownConfiguration(for: rule)
                if case .waiting = model.ruleUnlockPhase(for: id) { throw SharedInterfaceError("The unlock waiting period has not ended.") }
                return try issue(title: "Unlock group changes", passage: CommitmentPassage.generate(wordCount: model.ruleLockdownConfiguration(for: rule).passageWordCount)) { [weak self] _ in
                    guard let self else { throw SharedInterfaceError("The window was closed.") }
                    guard let current = model.rules.first(where: { $0.id == id }), model.ruleLockdownConfiguration(for: current) == expectedPolicy else { throw SharedInterfaceError("The change policy changed. Request a new passage.") }
                    if case .confirmationDue = model.ruleUnlockPhase(for: id) { model.confirmRuleUnlock(id) }
                    else { model.startRuleUnlock(id) }
                }
                #endif
            case "requestTemporaryAccess":
                guard let minutes = c["minutes"] as? Int, let duration = TemporaryAccessDuration(rawValue: minutes),
                      let reason = c["reason"] as? String, ["conscious", "edulgence"].contains(reason),
                      let reflection = c["reflection"] as? String, let answer = ReflectionPrompt.normalized(reflection) else { throw SharedInterfaceError("Choose a duration and briefly describe what this time is for (at least four words).") }
                let intent: BypassEvent.Intent = reason == "conscious" ? .consciousIntervention : .eDulgance
                #if os(macOS)
                guard model.allowsTemporaryPause(for: id), model.availablePauseDurations(for: id).contains(duration) else { throw SharedInterfaceError("This group cannot grant that temporary allowance.") }
                let words = model.pausePassageWordCount(for: id)
                #else
                guard model.lockdownExpirations[id] == nil, model.availableTemporaryAccessDurations(for: id).contains(duration) else { throw SharedInterfaceError("This group cannot grant that temporary allowance.") }
                let words = model.timeAllowancePassageWordCount(for: id)
                #endif
                return try issue(title: "Temporary access", passage: CommitmentPassage.generate(wordCount: words)) { [weak self] _ in
                    guard let self else { throw SharedInterfaceError("The window was closed.") }
                    #if os(macOS)
                    guard model.pausePassageWordCount(for: id) == words else { throw SharedInterfaceError("The required passage changed. Request it again.") }
                    try ensure(model.grantTemporaryPause(for: id, duration: duration, verifiedWordCount: words, intent: intent, reflection: answer))
                    #else
                    guard model.timeAllowancePassageWordCount(for: id) == words else { throw SharedInterfaceError("The required passage changed. Request it again.") }
                    try ensure(model.grantTimeAllowance(for: id, duration: duration, verifiedWordCount: words, intent: intent, reflection: answer))
                    #endif
                }
            default: throw SharedInterfaceError("Unsupported native command.")
            }
        }
        generation += 1; challenges.removeAll()
        return ["snapshot": try snapshot()]
    }
    #if os(iOS)
    func finishPicker(accept: Bool) {
        guard let continuation = picker, let id = pickerGroup else { return }
        picker = nil; pickerGroup = nil; pickingApplications = false
        if accept {
            selections = selections.filter { $0.value.0 != id }
            let token = UUID().uuidString; selections[token] = (id, selection)
            continuation.resume(returning: ["applications": [], "selectionToken": token,
                "applicationSummary": "\(selection.applicationTokens.count) apps · \(selection.categoryTokens.count) categories · \(selection.webDomainTokens.count) Screen Time websites"])
        } else { continuation.resume(returning: ["message": "Selection cancelled."]) }
    }
    #endif
}
