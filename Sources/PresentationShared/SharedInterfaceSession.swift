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
    /// Only the missing-bundle fallback opens the native controls now; every
    /// function they held is in the shared screens.
    @Published var showAdvancedControls = false
    /// Files the host offers through the system share sheet (iPhone diagnostics export).
    @Published var sharing: [URL]?
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

    static func readable(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Names the date the edit window opens, and says plainly when that falls
    /// after the Retreat has already finished on its own — otherwise the
    /// request looks like it is progressing when it can never come due.
    private func waitingMessage(
        retreatID: UUID,
        unlocksAt: Date,
        nextConfirmationAt: Date?
    ) -> String {
        var message = "The retreat change policy is still waiting. "
        if let nextConfirmationAt {
            message += "The next checkpoint is due by \(Self.readable(nextConfirmationAt)), and the edit window opens \(Self.readable(unlocksAt))."
        } else {
            message += "The edit window opens \(Self.readable(unlocksAt))."
        }
        if let retreat = model.retreats.first(where: { $0.id == retreatID }),
           unlocksAt >= retreat.plannedEnd {
            message += " That is after this Retreat ends on its own (\(Self.readable(retreat.plannedEnd))), so it will finish before the window opens."
        }
        return message
    }
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
    /// The models report sync as a sentence; the shared contract needs a state as well.
    static func syncState(_ status: String) -> String {
        let text = status.lowercased()
        if text.contains("fail") || text.contains("rejected") { return "unavailable" }
        if text == "not synced" || text.contains("pending") || text.contains("awaiting") || text.contains("proposed") { return "pending" }
        return "current"
    }
    /// Host-evaluated "what is this doing now". The renderer never derives this from a schedule.
    /// Works out, before any row is written, which group is actually holding
    /// each group's sites. A row cannot answer this alone: the answer depends
    /// on what every other group is doing at this instant.
    private func coverageHolders(
        liveRules: [CloudRulePreference],
        baselineIDs: Set<UUID>,
        now: Date
    ) -> [UUID: GroupCoverage.Holder] {
        var subjects: [GroupCoverage.Subject] = []
        var seen = Set<UUID>()
        for rule in liveRules where seen.insert(rule.id).inserted {
            let state = GroupNowStatus.evaluate(
                isEnabled: rule.isEnabled, windows: rule.windows, now: now,
                allowanceUntil: pause(rule.id), lockdownUntil: model.lockdownExpirations[rule.id]
            )
            subjects.append(GroupCoverage.Subject(
                id: rule.id,
                name: rule.name,
                isRetreatCopy: !baselineIDs.contains(rule.id),
                isBlockingNow: state.isBlocking,
                isAllowListFortress: rule.enforcementMode == "fortressAllowList",
                targets: GroupCoverage.targets(of: rule)
            ))
        }
        // A disabled group never blocks, so it is only ever a subject — but it
        // is exactly the row most likely to claim "Off" while its sites are
        // held by a Retreat copy of itself.
        for group in model.baseline.blockingGroups where !seen.contains(group.id) {
            let owned = group.owningTargets(
                from: model.activityGroups,
                containerPolicy: model.baseline.modificationPolicy
            )
            subjects.append(GroupCoverage.Subject(
                id: group.id,
                name: group.name,
                isRetreatCopy: false,
                isBlockingNow: false,
                isAllowListFortress: false,
                targets: GroupCoverage.targets(of: owned.targets)
            ))
        }
        return GroupCoverage.holders(for: subjects)
    }

    private func nowObject(
        _ state: GroupNowState,
        now: Date,
        coveredBy holder: GroupCoverage.Holder? = nil
    ) -> [String: Any] {
        let name: String
        switch state {
        case .lockdown: name = "lockdown"
        case .paused: name = "paused"
        case .blocking: name = "blocking"
        case .upcoming: name = "upcoming"
        case .idle: name = "idle"
        case .off: name = "off"
        }
        var value: [String: Any] = [
            "state": name,
            "headline": GroupNowStatus.headline(state, now: now, coveredBy: holder)
        ]
        if let at = state.changesAt { value["changesAt"] = iso(at) }
        if let holder {
            value["coveredBy"] = ["name": holder.name, "isComplete": holder.isComplete]
        }
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
        // Hostname blocking is in force while only IP retry protection is
        // incomplete, so groups are blocking even though the filter needs a look.
        let blockingConfirmed: Bool
        if case .limited = model.enforcementHealth { blockingConfirmed = enabled } else { blockingConfirmed = confirmed }
        let controller = model.enforcement
        let warning = controller.activationSafetyRequiresRestart || controller.recoveryWarning != nil || controller.deliveryError != nil
        let headline: String
        if controller.activationSafetyRequiresRestart { headline = "Safety locked" }
        else if controller.recoveryWarning != nil { headline = "Needs attention" }
        else if controller.deliveryError != nil { headline = "Delivery error" }
        else if controller.isBlockingDisabled { headline = "Web filter off" }
        else if controller.status == .active { headline = FilterEnforcementSummary.isHealthy(model.enforcementHealth) ? "Web filter on" : "Needs attention" }
        else { headline = controller.status.description }
        var enforcement: [String: Any] = ["state": !enabled ? "disabled" : warning ? "error" : confirmed ? "active" : "unknown",
            "title": model.enforcement.status.description, "detail": detail, "headline": headline]
        // Recovery lives in the shared screens: a locked or failed filter says
        // why and offers the one step that clears it.
        if controller.activationSafetyRequiresRestart {
            enforcement["problem"] = controller.isResettingEnforcement
                ? "Resetting enforcement safely. Blocking stays off until the reset has verified this Mac's connection."
                : "The web filter is safety locked after a failed start, so it cannot be turned on yet. Reset enforcement, or restart this Mac, then turn it on again."
            enforcement["actions"] = [["id": "resetEnforcement", "label": "Reset enforcement without restart",
                "detail": "Keeps blocking off, removes and verifies the filter preference, and tests connectivity before clearing the safety lock.",
                "running": controller.isResettingEnforcement] as [String: Any]]
        } else if controller.isBlockingDisabled, let failure = controller.deliveryError {
            enforcement["problem"] = failure
            enforcement["actions"] = [["id": "retryDisable", "label": "Retry turning the filter off"] as [String: Any]]
        } else if let recovery = controller.recoveryWarning {
            enforcement["problem"] = recovery
        }
        // The ordinary steps the native filter controls offered, with the same
        // gates: removal needs its fixed passage, enforced by the controller.
        if !controller.isRemoving {
            var controls: [[String: Any]] = []
            if controller.status == .awaitingApproval {
                controls.append(["id": "openSystemSettings", "label": "Open System Settings", "placement": "controls",
                    "detail": "Approve the Holdfast web filter under Login Items & Extensions › Network Extensions."])
            }
            if !controller.isBlockingDisabled, controller.status == .awaitingApproval || controller.status == .activating {
                controls.append(["id": "cancelEnable", "label": "Cancel enable", "placement": "controls"])
            }
            if controller.status != .notInstalled, !controller.isResettingEnforcement {
                controls.append(["id": "removeNetworkExtension", "label": "Remove Network Extension…", "placement": "controls", "danger": true,
                    "detail": "Turns the web filter off and uninstalls it. Needs the removal passage typed exactly."])
            }
            if !controls.isEmpty { enforcement["actions"] = (enforcement["actions"] as? [[String: Any]] ?? []) + controls }
        } else {
            enforcement["detail"] = controller.status == .rebootRequired
                ? "Restart this Mac to finish removing the Network Extension."
                : "Removing the Network Extension…"
        }
        if !model.heldWeakenings.isEmpty {
            enforcement["held"] = model.heldWeakenings.map { ["name": $0.name, "appliesAt": iso($0.appliesAt)] }
        }
        let sync = model.syncStatus
        #else
        let platform = "ios"
        let enabled = model.isAuthorized
        let blockingConfirmed = enabled
        let enforcement: [String: Any] = ["state": enabled ? "active" : "disabled", "title": "Screen Time: \(model.authorizationDescription)",
            "headline": enabled ? "Screen Time on" : "Connect Screen Time",
            "detail": enabled
                ? "Status reflects the native rules and Screen Time authorization. System monitor timing can be approximate; foreground reconciliation uses the exact time."
                : "Allow Screen Time access so Holdfast can block on this device. Your groups and schedules stay saved."]
        let sync = model.cloudSyncStatus
        #endif
        var summaryGroups: [DashboardNowSummary.Group] = []
        // Groups in force only through a running Retreat or a lockdown: shown, never edited here.
        #if os(macOS)
        let liveRules = model.dashboardActiveRules
        #else
        let liveRules = model.dashboardBlockingRules
        #endif
        let baselineIDs = Set(model.baseline.blockingGroups.map(\.id))
        let coverage = coverageHolders(liveRules: liveRules, baselineIDs: baselineIDs, now: now)
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
            case .lockdown: status = blockingConfirmed && hasDeviceTargets ? "lockdown" : "unsupported"
            case .blocking: status = blockingConfirmed && hasDeviceTargets ? "blocking" : "unsupported"
            default: status = "allowed"
            }
            value["status"] = status
            let holder = coverage[group.id]
            let sentence = GroupNowStatus.headline(state, now: now, coveredBy: holder)
            if status != "unsupported" { value["detail"] = sentence }
            else if !hasDeviceTargets { value["detail"] = "No apps or websites are selected for this device. Other devices keep their own targets." }
            else {
                #if os(macOS)
                // An unhealthy filter may still be blocking; only "off" means nothing is blocked.
                value["detail"] = enabled
                    ? "The web filter has not confirmed this schedule, so blocking is not confirmed on this Mac."
                    : "The web filter is off, so nothing is being blocked on this Mac."
                #else
                value["detail"] = "Screen Time access is off, so nothing is being blocked."
                #endif
            }
            value["canEdit"] = isUnlocked(group.id)
            value["now"] = nowObject(state, now: now, coveredBy: holder)
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
        var seenLive = Set<UUID>()
        let retreatGroups: [[String: Any]] = liveRules.filter { !baselineIDs.contains($0.id) && seenLive.insert($0.id).inserted }.map { rule in
            let state = GroupNowStatus.evaluate(isEnabled: rule.isEnabled, windows: rule.windows, now: now,
                allowanceUntil: pause(rule.id), lockdownUntil: model.lockdownExpirations[rule.id])
            summaryGroups.append(.init(name: rule.name, state: state))
            var value: [String: Any] = ["id": rule.id.uuidString, "name": rule.name,
                    "now": nowObject(state, now: now, coveredBy: coverage[rule.id]),
                    "enforced": blockingConfirmed,
                    "lock": Self.policyKinds[rule.lockdown.severity] ?? "inherited",
                    "delayDays": min(365, max(0, rule.lockdown.unlockDelayDays)),
                    "targets": HoldfastPresentation.targets(rule: rule)]
            #if os(iOS)
            // A block screen may name this copy; the answer needs its compiled
            // policy. `answerAccessRequest` re-checks it against `model.rules`.
            let p = rule.lockdown
            value["temporaryPolicy"] = ["allowed": p.allowsTimeExtensions,
                "words": min(300, max(20, p.effectiveTemporaryAccessPassageWordCount)),
                "maximumMinutes": min(1440, max(1, p.effectiveMaximumTemporaryAccessMinutes)),
                "resetDays": p.temporaryAllowanceResetDays.map { min(365, max(1, $0)) } ?? NSNull()] as [String: Any]
            let passageWords = model.timeAllowancePassageWordCount(for: rule.id)
            if passageWords >= 20 { value["temporaryPassageWords"] = min(38_400, passageWords) }
            #endif
            return value
        }
        let summary = DashboardNowSummary(groups: summaryGroups)
        let presets: [[String: Any]] = HoldfastPresets.blockingPresets.map {
            ["id": $0.id, "name": $0.name, "summary": $0.summary, "lock": Self.policyKinds[$0.severity] ?? "inherited"]
        }
        let retreats: [[String: Any]] = model.retreats.map { r in
            var value: [String: Any] = ["id": r.id.uuidString, "name": r.name, "startsAt": iso(r.plannedStart), "endsAt": iso(r.plannedEnd),
             "state": r.state == .endedEarly ? "cancelled" : r.state.rawValue,
             "version": r.currentVersionNumber, "groupNames": r.currentVersion?.blockingGroups.map(\.name) ?? [],
             "changePolicyLabel": r.modificationPolicy.severity, "canRequestEnd": r.state == .active]
            let editable = Self.isEditable(r, now: now)
            value["canEdit"] = editable
            if r.state == .active, let policy = model.retreatChangePolicy(for: r.id), policy.requiresAuthorization {
                value["unlock"] = unlockObject(model.retreatUnlockPhase(for: r.id))
            }
            if editable {
                let policy = Self.retreatPolicy(r)
                value["goal"] = r.goal
                value["changePolicy"] = ["kind": Self.policyKinds[policy.severity] ?? "inherited",
                    "words": min(300, max(20, policy.passageWordCount)), "delayDays": min(365, max(0, policy.unlockDelayDays))]
                value["groupIDs"] = r.currentVersion?.blockingGroups.map(\.id.uuidString) ?? []
                value["groupChoices"] = retreatChoices(r).map { ["id": $0.id.uuidString, "name": $0.name] }
            }
            return value
        }
        let events: [[String: Any]] = BypassHistoryStore.read(defaults: historyDefaults).document.events.map { event in
            return ["id": event.id.uuidString, "groupID": event.groupID.uuidString, "groupName": event.groupName,
                "startedAt": iso(event.grantedAt), "endsAt": iso(event.expiresAt), "reason": event.intent == nil ? "unspecified" : event.intent == .consciousIntervention ? "conscious" : "edulgence"]
        }
        var capabilities = ["editGroups", "temporaryAccess", "pickApplications", "retreats", "lockdown", "diagnostics", "enforcementControl",
            "appearance", "presets", "lockdownForm", "diagnosticsReport", "retreatForm", "groupDetails", "cancelUnlock", "retreatChanges",
            "recreateRetreat", "diagnosticsExport", "syncNow"]
        #if os(macOS)
        capabilities += ["lockdownPolicy", "debugTrace", "otherTargets"]
        #else
        capabilities += ["protection", "accessRequests", "classifyWebsites"]
        #endif
        var result: [String: Any] = ["schema": 1, "revision": try revision(), "platform": platform,
            "capabilities": capabilities,
            "appearance": appearance,
            "enforcementEnabled": enabled, "enforcement": enforcement,
            "sync": ["state": Self.syncState(sync), "detail": sync], "groups": groups, "retreats": retreats, "bypasses": events, "lockdown": NSNull(),
            "summary": ["headline": summary.headline, "next": summary.nextLine(now: now) ?? NSNull()] as [String: Any],
            "retreatGroups": retreatGroups, "schedule": ["days": scheduleDays(now: now)], "presets": presets]
        #if os(macOS)
        result["lockdownOptions"] = ["hours": DesktopLockdownSessionGate.offeredDurations.map { Int($0.seconds / 3_600) },
                                     "locks": ["passage", "delay", "checkpoints"]]
        result["debugTrace"] = ["recording": DesktopDiagnosticTrace.isEnabled]
        #else
        let lock = model.lockdownConfiguration
        result["protection"] = [
            "antiUninstall": ["on": model.antiUninstallEnabled],
            "appLock": ["enabled": lock.isEnabled, "unlockDelayDays": lock.unlockDelayDays, "repeatConfirmations": lock.repeatConfirmations,
                        "passageWordCount": lock.passageWordCount, "confirmationWindowHours": lock.confirmationWindowHours,
                        "editWindowHours": lock.editWindowHours,
                        "unlock": lock.isEnabled ? unlockObject(model.currentUnlockPhase(now: now)) : ["phase": "unlocked"] as [String: Any]] as [String: Any],
            "pendingSync": !model.pendingCloudRuleIDs.isEmpty]
        if let request = pendingAccessRequest(now: now) {
            var value: [String: Any] = ["id": request.id.uuidString, "groupIDs": request.eligibleRuleIDs.map(\.uuidString)]
            if let duration = request.duration { value["minutes"] = duration.rawValue }
            result["accessRequest"] = value
        }
        #endif
        if let end = model.lockdownExpirations.values.max() {
            #if os(macOS)
            let sessions: [[String: Any]] = model.activeLockdownSessions.map { session in
                ["id": session.id.uuidString, "endsAt": iso(session.endsAt),
                 "groupNames": model.rules.filter { session.ruleIDs.contains($0.id) }.map(\.name)]
            }
            #else
            let sessions: [[String: Any]] = model.activeTimedLockdowns.map { session in
                ["id": session.id.uuidString, "endsAt": iso(session.endsAt), "groupNames": session.rules.map(\.name)]
            }
            #endif
            result["lockdown"] = ["endsAt": iso(end), "groupNames": model.rules.filter { model.lockdownExpirations[$0.id] != nil }.map(\.name),
                "detail": model.lockdownSyncStatus, "sessions": sessions]
        }
        return result
    }
    private func issue(title: String, passage: String, detail: String? = nil, action: @escaping (String) throws -> Void) throws -> [String: Any] {
        let id = UUID().uuidString, expiry = Date().addingTimeInterval(30 * 60)
        challenges = [id: Challenge(passage: passage, revision: try revision(), expiry: expiry, action: action)]
        return ["challenge": ["id": id, "title": title, "passage": passage, "expiresAt": iso(expiry),
            "detail": detail ?? "Type the passage. You have 30 minutes; a policy change invalidates it. Native rules determine when the request takes effect."]]
    }
    /// A draft, a retreat that has not started, or a running one. A running
    /// retreat is held by its change policy: the models refuse any edit that
    /// would release something it enforces until that policy is satisfied.
    private static func isEditable(_ retreat: CloudRetreat, now: Date) -> Bool {
        ((retreat.state == .draft || retreat.state == .scheduled) && !retreat.isActive(at: now))
            || (retreat.state == .active && retreat.isActive(at: now))
    }
    #if os(iOS)
    /// The block screen's request, if a group it names still allows extra time;
    /// the same filter the native sheet applied before showing it.
    private func pendingAccessRequest(now: Date) -> PendingTemporaryAccessRequest? {
        guard let request = ShieldTemporaryAccessCoordinator.loadPendingRequest(now: now) else { return nil }
        let allowed = Set(model.rules.lazy.filter { $0.isEnabled && $0.lockdownPolicy.allowsTimeExtensions }.map(\.id))
        return allowed.isDisjoint(with: request.eligibleRuleIDs) ? nil : request
    }
    #endif
    private static func retreatPolicy(_ retreat: CloudRetreat) -> CloudRuleLockdownPreference {
        retreat.currentVersion?.modificationPolicy ?? retreat.modificationPolicy
    }
    /// The groups a retreat can be built from, exactly as the native editors
    /// offer them: its own copies first, so saving keeps them rather than
    /// re-copying the Blocking Group, then groups it does not hold yet.
    private func retreatChoices(_ retreat: CloudRetreat?) -> [CloudBlockingGroup] {
        guard let retreat else { return model.baseline.blockingGroups }
        let historical = retreat.currentVersion?.blockingGroups ?? []
        return historical + model.baseline.blockingGroups.filter { baseline in
            !historical.contains { CloudRetreatGroupVersioning.represents($0, baselineGroup: baseline) }
        }
    }
    /// ISO-8601 with a zone, with or without fractional seconds. Nothing looser.
    static func strictDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
    private func saveRetreat(_ input: Any?) throws -> [String: Any] {
        guard let r = input as? [String: Any], let rawName = r["name"] as? String, let goal = r["goal"] as? String,
              let sentStart = Self.strictDate(r["startsAt"]), let sentEnd = Self.strictDate(r["endsAt"]),
              let texts = r["groupIDs"] as? [String], let startNow = r["startNow"] as? Bool,
              let policy = r["changePolicy"] as? [String: Any], let kind = policy["kind"] as? String,
              let words = policy["words"] as? Int, let delayDays = policy["delayDays"] as? Int else {
            throw SharedInterfaceError("Invalid retreat.")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else { throw SharedInterfaceError("Enter a retreat name of at most 120 characters.") }
        guard goal.count <= 2_000 else { throw SharedInterfaceError("Keep the purpose under 2,000 characters.") }
        guard sentEnd > sentStart else { throw SharedInterfaceError("The retreat has to end after it starts.") }
        let now = Date()
        var existing: CloudRetreat?
        if let value = r["id"] {
            guard let text = value as? String, let id = UUID(uuidString: text),
                  let retreat = model.retreats.first(where: { $0.id == id }) else { throw SharedInterfaceError("This retreat no longer exists.") }
            guard Self.isEditable(retreat, now: now) else {
                throw SharedInterfaceError("This retreat has already started or finished, so it cannot be changed here.")
            }
            existing = retreat
        }
        let start = SharedInterfaceInstant.keepingStored(sentStart, stored: existing?.plannedStart)
        let end = SharedInterfaceInstant.keepingStored(sentEnd, stored: existing?.plannedEnd)
        // Starting is offered for a new retreat or a draft, as in the native editors.
        if startNow {
            guard existing == nil || existing?.state == .draft else {
                throw SharedInterfaceError(existing?.state == .active ? "This retreat is already running." : "This retreat is already scheduled.")
            }
            guard end > now else { throw SharedInterfaceError("That retreat would already be over. Choose a later end.") }
        }
        let choices = retreatChoices(existing)
        let ids = texts.compactMap(UUID.init(uuidString:))
        guard !ids.isEmpty, ids.count == texts.count, Set(ids).count == ids.count else {
            throw SharedInterfaceError("Choose at least one Blocking Group.")
        }
        let groups = try ids.map { id in
            guard let group = choices.first(where: { $0.id == id }) else {
                throw SharedInterfaceError("A chosen Blocking Group no longer exists. Reopen the retreat and choose again.")
            }
            return group
        }
        let previous = existing.map(Self.retreatPolicy)
        var lock: CloudRuleLockdownPreference
        if kind == "inherited" {
            // Only an existing app-default policy may stay inherited.
            guard let previous, previous.severity == "appDefault" else { throw SharedInterfaceError("Invalid change policy.") }
            lock = previous
        } else {
            let severities = ["none": "none", "passage": "passageOnly", "delay": "delayed", "checkpoints": "repeatedConfirmations"]
            guard let severity = severities[kind], (20...300).contains(words), (0...365).contains(delayDays) else {
                throw SharedInterfaceError("Invalid change policy.")
            }
            lock = previous ?? CloudRuleLockdownPreference(severity: severity)
            lock.severity = severity
            lock.passageWordCount = words
            lock.unlockDelayDays = kind == "delay" || kind == "checkpoints" ? delayDays : 0
        }
        #if os(macOS)
        model.saveRetreat(id: existing?.id, name: name, goal: goal, plannedStart: start, plannedEnd: end,
            sourceBlockingGroups: groups, modificationPolicy: lock, startImmediately: startNow)
        try ensure(model.errorMessage == nil)
        #else
        try ensure(model.saveRetreat(id: existing?.id, name: name, goal: goal, plannedStart: start, plannedEnd: end,
            sourceBlockingGroups: groups, modificationPolicy: lock, startImmediately: startNow))
        #endif
        let message = startNow
            ? (start > now ? "Retreat scheduled." : "Retreat started.")
            : (existing?.state == .scheduled || existing?.state == .active ? "Retreat changes saved." : "Retreat draft saved.")
        generation += 1; challenges.removeAll()
        return ["snapshot": try snapshot(), "message": message]
    }
    /// A typed passage must leave an unlock in progress or open; never report
    /// success for one that started nothing.
    private func ensureStarted(_ phase: UnlockPhase) throws {
        if phase.isIdleOrCancelled { throw SharedInterfaceError(model.errorMessage ?? "The unlock could not be started. Request it again.") }
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
        if type == "diagnostics" {
            let report = model.makeDiagnosticReport(redaction: c["names"] as? Bool == true ? .full : .standard)
            if c["copy"] as? Bool == true {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report.renderedText(), forType: .string)
                #else
                UIPasteboard.general.string = report.renderedText()
                #endif
                return ["message": "Copied the readable report."]
            }
            #if os(macOS)
            let events = TamperJournal.shared.events()
            #else
            let events = TamperJournalCloudMirror.read()
            #endif
            let journal: [[String: Any]] = events.suffix(50).reversed().map {
                ["at": iso($0.at), "title": $0.title, "detail": $0.detail.isEmpty ? $0.origin : "\($0.origin) · \($0.detail)"]
            }
            return ["diagnostics": ["text": report.renderedText(), "journal": journal, "findings": report.warnings.sorted { $0.severity < $1.severity }.map { warning in
                var finding: [String: Any] = ["severity": warning.severity.rawValue, "message": warning.message]
                if let hint = warning.hint { finding["hint"] = hint }
                return finding
            }] as [String: Any]]
        }
        if type == "exportDiagnostics" {
            let report = model.makeDiagnosticReport(redaction: c["names"] as? Bool == true ? .full : .standard)
            #if os(macOS)
            // The system's own folder chooser decides where the files go.
            let panel = NSOpenPanel()
            panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
            panel.prompt = "Export"
            panel.message = "Choose where to write \(report.suggestedFileName).txt and .json"
            guard await panel.begin() == .OK, let directory = panel.url else { return ["message": "Export cancelled."] }
            let written = try model.writeDiagnosticReport(report, to: directory)
            return ["message": "Wrote \(written.count) files to \(directory.lastPathComponent)."]
            #else
            sharing = try model.writeDiagnosticReport(report)
            return ["message": "Choose where to send the report."]
            #endif
        }
        if type == "syncNow" {
            #if os(macOS)
            model.refresh()
            #else
            model.syncICloudPreferences(); model.synchronize()
            #endif
            return ["snapshot": try snapshot(), "message": "Sync requested."]
        }
        #if os(macOS)
        if type == "setDebugTrace" {
            guard let enabled = c["enabled"] as? Bool else { throw SharedInterfaceError("Invalid setting.") }
            DesktopDiagnosticTrace.setEnabled(enabled)
            return ["snapshot": try snapshot(), "message": enabled ? "Trace recording. New activity is being recorded." : "Trace paused. Existing events are kept."]
        }
        if type == "exportDebugTrace" {
            DesktopDiagnosticTrace.record(component: "diagnostics", event: "trace_export_requested")
            let panel = NSSavePanel()
            panel.title = "Export Holdfast Debug Trace"
            panel.nameFieldStringValue = "Holdfast-debug-trace-\(Int(Date().timeIntervalSince1970)).jsonl"
            panel.allowedContentTypes = [.json]
            guard await panel.begin() == .OK, let url = panel.url else { return ["message": "Export cancelled."] }
            let data = try DesktopDiagnosticTrace.exportedData()
            try data.write(to: url, options: [.atomic])
            return ["message": "Exported \(data.count) bytes to \(url.lastPathComponent)."]
        }
        if type == "clearDebugTrace" {
            try DesktopDiagnosticTrace.clear()
            return ["message": "Trace cleared."]
        }
        #else
        if type == "classifyWebsites" {
            // On-device classification; nothing is saved until the group is.
            guard let texts = c["domains"] as? [String], texts.count <= 1000 else { throw SharedInterfaceError("Invalid websites.") }
            let domains = Array(Set(texts.compactMap(BlockingTargetInput.domain(from:)))).sorted()
            guard !domains.isEmpty else { throw SharedInterfaceError("Add websites before classifying them.") }
            let results = await DomainClassifier.classify(domains)
            return ["classified": results.map { ["domain": $0.domain, "category": $0.category.rawValue, "source": $0.source.rawValue] },
                    "message": "Classified \(results.count) website\(results.count == 1 ? "" : "s"). Review the categories, then save."]
        }
        if type == "dismissAccessRequest" {
            guard let text = c["requestID"] as? String, let id = UUID(uuidString: text) else { throw SharedInterfaceError("Invalid request.") }
            model.clearPendingTemporaryAccessRequest(id: id)
            return ["snapshot": try snapshot()]
        }
        #endif
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
        if type == "createRetreat" { nativePanel = type; return [:] }
        if type == "saveRetreat" { return try saveRetreat(c["retreat"]) }
        if type == "startLockdown" {
            guard let texts = c["groupIDs"] as? [String], let hours = c["hours"] as? Int else { nativePanel = type; return [:] }
            let ids = Set(texts.compactMap(UUID.init(uuidString:)))
            guard !ids.isEmpty, ids.count == texts.count, (1...720).contains(hours) else {
                throw SharedInterfaceError("Choose at least one group and one of the offered durations.")
            }
            #if os(iOS)
            guard hours <= 168, c["lock"] == nil else { throw SharedInterfaceError("Choose a duration between one hour and seven days.") }
            #endif
            #if os(macOS)
            // Without a lock, the defaults the Mac lockdown window starts with:
            // one typed passage to leave early. With one, the window's options.
            var severity = "passageOnly", words = 80, delay = 0
            if let lock = c["lock"] as? [String: Any] {
                let severities = ["passage": "passageOnly", "delay": "delayed", "checkpoints": "repeatedConfirmations"]
                guard let kind = lock["kind"] as? String, let chosen = severities[kind], let w = lock["words"] as? Int, (20...300).contains(w),
                      let d = lock["delayDays"] as? Int, (0...30).contains(d) else {
                    throw SharedInterfaceError("Choose a lock mode, a passage of 20 to 300 words and a delay of up to 30 days.")
                }
                severity = chosen; words = w; delay = kind == "passage" ? 0 : d
            }
            guard DesktopLockdownSessionGate.offeredDurations.contains(where: { Int($0.seconds) == hours * 3_600 }) else {
                throw SharedInterfaceError("Choose one of the offered durations.")
            }
            let before = Set(model.activeLockdownSessions.map(\.id))
            model.startLockdownSession(ruleIDs: ids, duration: Double(hours) * 3_600,
                lockdown: DesktopLockdownPolicy(severity: severity, unlockDelayDays: delay, passageWordCount: words,
                    confirmationWindowHours: 24, editWindowHours: 1, allowsTimeExtensions: false, maximumTimeExtensionHours: 0))
            try ensure(model.errorMessage == nil)
            guard Set(model.activeLockdownSessions.map(\.id)) != before else {
                throw SharedInterfaceError("The lockdown did not start. Check that the selected groups still exist and have websites or apps this Mac can filter.")
            }
            #else
            try ensure(model.startTimedLockdown(ruleIDs: ids, hours: hours))
            #endif
            generation += 1; challenges.removeAll()
            return ["snapshot": try snapshot(), "message": "Lockdown started."]
        }
        if type == "endLockdown" {
            guard let text = c["sessionID"] as? String, let id = UUID(uuidString: text) else { throw SharedInterfaceError("Invalid lockdown.") }
            #if os(macOS)
            guard let session = model.activeLockdownSessions.first(where: { $0.id == id }) else { throw SharedInterfaceError("That lockdown is no longer running.") }
            return try issue(title: "End lockdown early", passage: session.earlyExitPassage) { [weak self] typed in
                guard let self else { throw SharedInterfaceError("The window was closed.") }
                try ensure(model.endLockdownSession(id: id, passage: typed))
            }
            #else
            guard let session = model.activeTimedLockdowns.first(where: { $0.id == id }) else { throw SharedInterfaceError("That lockdown is no longer running.") }
            return try issue(title: "End lockdown early", passage: session.earlyExitPassage) { [weak self] typed in
                guard let self else { throw SharedInterfaceError("The window was closed.") }
                try ensure(model.endTimedLockdown(session, passage: typed))
            }
            #endif
        }
        if type == "enforcementAction" {
            #if os(macOS)
            let controller = model.enforcement
            switch c["id"] as? String {
            case "resetEnforcement": model.resetDesktopEnforcementWithoutRestart()
            case "retryDisable": model.disableDesktopBlockingImmediately()
            case "openSystemSettings": model.openNetworkExtensionSettings()
            case "cancelEnable":
                // Offered only while the filter is waiting for approval or
                // starting, exactly as natively; nothing is enforced yet.
                guard controller.status == .awaitingApproval || controller.status == .activating else {
                    throw SharedInterfaceError("The web filter is no longer starting. Refresh to see its state.")
                }
                model.disableDesktopBlockingImmediately()
            case "removeNetworkExtension":
                guard controller.status != .notInstalled, !controller.isRemoving, !controller.isResettingEnforcement else {
                    throw SharedInterfaceError("The Network Extension cannot be removed right now. Refresh to see its state.")
                }
                return try issue(title: "Remove Network Extension", passage: DesktopNetworkExtensionRemovalGate.requiredPassage,
                    detail: "Type the passage exactly, including capitals and punctuation. The web filter turns off and is uninstalled; macOS may ask for your password or a restart.") { [weak self] typed in
                    guard let self else { throw SharedInterfaceError("The window was closed.") }
                    guard model.removeDesktopNetworkExtension(passage: typed) == .authorized else {
                        throw SharedInterfaceError("The passage must match exactly, including capitals and punctuation.")
                    }
                }
            default: throw SharedInterfaceError("Unknown recovery step.")
            }
            generation += 1; challenges.removeAll()
            return ["snapshot": try snapshot()]
            #else
            throw SharedInterfaceError("Unknown recovery step.")
            #endif
        }
        if type == "setEnforcement" {
            #if os(macOS)
            if c["enabled"] as? Bool == true {
                model.installDesktopEnforcement(); try ensure(model.errorMessage == nil)
                // A refused install only sets the controller's own error. Without
                // this the button would appear to do nothing.
                if model.enforcement.isBlockingDisabled, model.enforcement.activationSafetyRequiresRestart {
                    throw SharedInterfaceError("The web filter is safety locked after a failed start, so it was not turned on. Open Advanced controls and press Reset Enforcement Without Restart, or restart this Mac, then try again.")
                }
                if model.enforcement.isBlockingDisabled, let reason = model.enforcement.deliveryError {
                    throw SharedInterfaceError(reason)
                }
            }
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
            if c["enabled"] as? Bool == true {
                await model.requestAuthorization()
                if !model.isAuthorized {
                    // Say what happened in plain words here; the raw system error stays in diagnostics.
                    model.errorMessage = nil
                    throw SharedInterfaceError("Screen Time access was not granted, so nothing is being blocked yet. You can try again at any time.")
                }
            }
            else {
                // Holdfast never switches Screen Time off itself; iOS owns that.
                return ["message": "Screen Time access stays on while Holdfast is blocking. To stop it, remove Holdfast under Settings › Screen Time on this iPhone, or use Reset Screen Time restrictions in Settings › Diagnostics here."]
            }
            #endif
        } else if type == "installPreset" {
            guard let id = c["presetID"] as? String, let preset = HoldfastPresets.blockingPresets.first(where: { $0.id == id }) else { throw SharedInterfaceError("Unknown preset.") }
            #if os(macOS)
            model.installPreset(preset); try ensure(model.errorMessage == nil)
            #else
            try ensure(model.installPreset(preset))
            #endif
        } else if type == "requestRetreatEnd" || type == "requestRetreatUnlock" {
            let finish = type == "requestRetreatEnd"
            guard let text = c["retreatID"] as? String, let id = UUID(uuidString: text), let policy = model.retreatChangePolicy(for: id) else { throw SharedInterfaceError("Retreat no longer exists.") }
            guard model.retreats.first(where: { $0.id == id })?.state == .active else { throw SharedInterfaceError("This retreat is not running.") }
            let phase = model.retreatUnlockPhase(for: id)
            if !policy.requiresAuthorization || { if case .unlocked = phase { return true }; return false }() {
                if finish { try ensure(model.finishRetreat(id)) }
                else {
                    generation += 1; challenges.removeAll()
                    return ["snapshot": try snapshot(), "message": policy.requiresAuthorization
                        ? "Changes to this retreat are unlocked. Save them before the window closes."
                        : "This retreat has no change policy; any change saves."]
                }
            }
            else {
                // The phase already knows when the window opens; saying only
                // "still waiting" leaves no way to tell a request that is
                // progressing from one that will never come due.
                switch phase {
                case let .waiting(unlocksAt, nextConfirmationAt):
                    throw SharedInterfaceError(waitingMessage(
                        retreatID: id, unlocksAt: unlocksAt, nextConfirmationAt: nextConfirmationAt
                    ))
                case let .confirmationDue(_, deadline, checkpoint, total):
                    throw SharedInterfaceError(
                        "Checkpoint \(checkpoint) of \(total) is due by \(Self.readable(deadline)). "
                        + "Request the end again before then to type it."
                    )
                default: break
                }
                return try issue(title: finish ? "End retreat early" : "Unlock retreat changes", passage: CommitmentPassage.generate(wordCount: policy.passageWordCount)) { [weak self] _ in
                    guard let self else { throw SharedInterfaceError("The window was closed.") }
                    guard model.retreatChangePolicy(for: id) == policy else { throw SharedInterfaceError("The retreat policy changed. Request a new passage.") }
                    if case .confirmationDue = model.retreatUnlockPhase(for: id) { model.confirmRetreatUnlock(id) }
                    else { model.startRetreatUnlock(id) }
                    try ensureStarted(model.retreatUnlockPhase(for: id))
                    if finish, case .unlocked = model.retreatUnlockPhase(for: id) { try ensure(model.finishRetreat(id)) }
                }
            }
        } else if type == "cancelRetreatUnlock" {
            // Only ever re-locks: abandoning an unlock or closing its window.
            guard let text = c["retreatID"] as? String, let id = UUID(uuidString: text) else { throw SharedInterfaceError("Retreat no longer exists.") }
            model.cancelRetreatUnlock(id)
        } else if type == "recreateRetreat" {
            guard let text = c["retreatID"] as? String, let id = UUID(uuidString: text),
                  let retreat = model.retreats.first(where: { $0.id == id }) else { throw SharedInterfaceError("Retreat no longer exists.") }
            guard retreat.state == .completed || retreat.state == .endedEarly else { throw SharedInterfaceError("Only a finished retreat can be recreated.") }
            #if os(macOS)
            try ensure(model.recreateRetreat(id))
            #else
            try ensure(model.recreateRetreat(retreat))
            #endif
            generation += 1; challenges.removeAll()
            return ["snapshot": try snapshot(), "message": "Recreated as a draft. Review it before starting."]
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
        } else if let reply = try await performProtection(type, c) {
            return reply
        } else {
            guard let text = c["groupID"] as? String, let id = UUID(uuidString: text), let group = owned(id) else { throw SharedInterfaceError("This group no longer exists.") }
            switch type {
            case "deleteGroup":
                try ensure(model.deleteBlockingGroup(group))
            case "cancelTemporaryAccess":
                try ensure(model.cancelTemporaryPause(for: id))
            case "cancelGroupUnlock":
                // Only ever re-locks: abandoning an unlock or closing its window.
                #if os(macOS)
                model.cancelRuleEditUnlock(id)
                #else
                model.cancelRuleUnlock(id)
                #endif
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
                    try ensureStarted(model.ruleUnlockPhase(for: id))
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
    /// App-wide protection and block-screen requests. Nil when `type` is not one of them.
    private func performProtection(_ type: String, _ c: [String: Any]) async throws -> [String: Any]? {
        #if os(iOS)
        switch type {
        case "setAntiUninstall":
            // Turning it off is refused by the model while any lock holds.
            guard let enabled = c["enabled"] as? Bool else { throw SharedInterfaceError("Invalid setting.") }
            model.setAntiUninstall(enabled); try ensure(model.errorMessage == nil)
        case "saveAppLock":
            guard let v = c["settings"] as? [String: Any], let enabled = v["enabled"] as? Bool, let delay = v["unlockDelayDays"] as? Int,
                  let repeats = v["repeatConfirmations"] as? Bool, let words = v["passageWordCount"] as? Int,
                  let checkpoint = v["confirmationWindowHours"] as? Int, let window = v["editWindowHours"] as? Int else {
                throw SharedInterfaceError("Invalid change protection.")
            }
            var configuration = model.lockdownConfiguration
            configuration.isEnabled = enabled; configuration.unlockDelayDays = delay
            configuration.repeatConfirmations = repeats; configuration.passageWordCount = words
            configuration.confirmationWindowHours = checkpoint; configuration.editWindowHours = window
            guard LockdownConfiguration.delayRange.contains(delay), LockdownConfiguration.passageWordRange.contains(words),
                  LockdownConfiguration.confirmationWindowRange.contains(checkpoint), LockdownConfiguration.editWindowRange.contains(window) else {
                throw SharedInterfaceError("A value is outside the range change protection allows.")
            }
            // Loosening while locked is refused by the model, as natively.
            model.updateLockdownConfiguration(configuration); try ensure(model.errorMessage == nil)
        case "requestAppUnlock":
            let expected = model.lockdownConfiguration
            guard expected.isEnabled else { throw SharedInterfaceError("Change protection is off.") }
            switch model.currentUnlockPhase() {
            case let .waiting(unlocksAt, next):
                throw SharedInterfaceError("The unlock is waiting. " + (next.map { "The next checkpoint is due by \(Self.readable($0)); " } ?? "")
                    + "editing opens \(Self.readable(unlocksAt)).")
            case .unlocked: throw SharedInterfaceError("Settings are already unlocked.")
            case .confirmationDue:
                return try issue(title: "Today's confirmation", passage: CommitmentPassage.generate(wordCount: expected.passageWordCount),
                    detail: "Type the passage to keep the unlock going. Missing a checkpoint cancels it.") { [weak self] _ in
                    guard let self else { throw SharedInterfaceError("The window was closed.") }
                    guard model.lockdownConfiguration == expected else { throw SharedInterfaceError("Change protection changed. Request a new passage.") }
                    model.confirmUnlock(); try ensure(model.errorMessage == nil)
                }
            default:
                return try issue(title: "Unlock app-wide settings", passage: CommitmentPassage.generate(wordCount: expected.passageWordCount),
                    detail: "Type the passage to start the unlock. Editing opens after \(expected.unlockDelayDays) day(s)\(expected.repeatConfirmations ? ", with a passage at each daily checkpoint" : "").") { [weak self] _ in
                    guard let self else { throw SharedInterfaceError("The window was closed.") }
                    guard model.lockdownConfiguration == expected else { throw SharedInterfaceError("Change protection changed. Request a new passage.") }
                    model.startUnlock()
                    try ensureStarted(model.currentUnlockPhase())
                }
            }
        case "cancelAppUnlock":
            // Only ever re-locks.
            model.cancelUnlock()
        case "resetScreenTime":
            // The same recovery the native diagnostics offer behind a confirmation;
            // iOS itself lets Screen Time access be revoked at any time.
            let message = await model.resetAllScreenTimeRestrictions()
            generation += 1; challenges.removeAll()
            return ["snapshot": try snapshot(), "message": message]
        case "answerAccessRequest":
            guard let requestText = c["requestID"] as? String, let requestID = UUID(uuidString: requestText),
                  let groupText = c["groupID"] as? String, let groupID = UUID(uuidString: groupText),
                  let minutes = c["minutes"] as? Int, let duration = TemporaryAccessDuration(rawValue: minutes),
                  let reason = c["reason"] as? String, ["conscious", "edulgence"].contains(reason),
                  let reflection = c["reflection"] as? String, let answer = ReflectionPrompt.normalized(reflection) else {
                throw SharedInterfaceError("Choose a duration and briefly describe what this time is for (at least four words).")
            }
            guard let request = pendingAccessRequest(now: Date()), request.id == requestID, request.eligibleRuleIDs.contains(groupID),
                  request.duration == nil || request.duration == duration else {
                throw SharedInterfaceError("This request expired or no longer matches that group.")
            }
            let intent: BypassEvent.Intent = reason == "conscious" ? .consciousIntervention : .eDulgance
            let words = model.timeAllowancePassageWordCount(for: groupID)
            return try issue(title: "Temporary access", passage: CommitmentPassage.generate(wordCount: words)) { [weak self] _ in
                guard let self else { throw SharedInterfaceError("The window was closed.") }
                guard model.timeAllowancePassageWordCount(for: groupID) == words else { throw SharedInterfaceError("The required passage changed. Request it again.") }
                try ensure(model.grantPendingTemporaryAccess(requestID: requestID, for: groupID, duration: duration,
                    verifiedWordCount: words, intent: intent, reflection: answer))
            }
        default: return nil
        }
        generation += 1; challenges.removeAll()
        return ["snapshot": try snapshot()]
        #else
        return nil
        #endif
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
