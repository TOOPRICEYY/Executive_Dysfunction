import Foundation

/// Builds the Mac's diagnostic report.
///
/// The Mac's characteristic failure is different from the iPhone's: the filter
/// is a separate process holding its own accepted policy, so the app can
/// publish a change that the extension never takes. That gap is invisible from
/// the UI -- the rules simply stop having an effect -- so the report puts the
/// published revision and the enforced revision next to each other and says so
/// when they differ.
enum MacDiagnosticsReport {
    static func build(
        document: CloudPreferencesDocument,
        syncStatus: String,
        enforcementStatus: MacEnforcementController.Status,
        enforcementHealth: FilterEnforcementSummary.Health,
        filterStatus: FilterEnforcementStatus?,
        publishedRevision: UInt64,
        isBlockingDisabled: Bool,
        removalState: DesktopRemovalGate.State,
        deliveryError: String?,
        recoveryWarning: String? = nil,
        activationSafetyRequiresRestart: Bool,
        activationSafetyReason: String?,
        retreatUnlockPhases: [UUID: UnlockPhase],
        traceEvents: [DesktopDiagnosticTraceEvent],
        redaction: HoldfastDiagnosticRedaction,
        now: Date = Date()
    ) -> HoldfastDiagnosticReport {
        let redactor = HoldfastDiagnosticRedactor(redaction)
        let enforcedRevision = filterStatus?.revision

        var sections: [HoldfastDiagnosticSection] = [
            hostSection(),
            enforcementSection(
                status: enforcementStatus,
                health: enforcementHealth,
                publishedRevision: publishedRevision,
                enforcedRevision: enforcedRevision,
                isBlockingDisabled: isBlockingDisabled,
                removalState: removalState,
                deliveryError: deliveryError,
                recoveryWarning: recoveryWarning,
                activationSafetyRequiresRestart: activationSafetyRequiresRestart,
                activationSafetyReason: activationSafetyReason,
                syncStatus: syncStatus
            )
        ]
        sections.append(filterSection(status: filterStatus, redactor: redactor))
        sections.append(contentsOf: HoldfastDiagnosticDocumentSections.sections(
            document: document,
            redactor: redactor,
            now: now
        ))
        sections.append(retreatLockSection(retreatUnlockPhases: retreatUnlockPhases, redactor: redactor))
        sections.append(traceSection(events: traceEvents))

        var warnings = HoldfastDiagnosticDocumentSections.warnings(
            document: document,
            redactor: redactor,
            now: now
        )
        warnings.append(contentsOf: enforcementWarnings(
            status: enforcementStatus,
            health: enforcementHealth,
            filterStatus: filterStatus,
            publishedRevision: publishedRevision,
            isBlockingDisabled: isBlockingDisabled,
            activationSafetyRequiresRestart: activationSafetyRequiresRestart,
            document: document,
            now: now
        ))
        if let recoveryWarning {
            warnings.append(HoldfastDiagnosticWarning(
                code: "enforcement.recovery-warning", severity: .warning,
                message: recoveryWarning,
                hint: "If browsing is affected, the enforcement banner offers Disable All Web Blocks With Passage."
            ))
        }

        return HoldfastDiagnosticReport(
            generatedAt: now,
            platform: "macos",
            redaction: redaction,
            warnings: warnings,
            sections: sections
        )
    }

    // MARK: - Findings

    static func enforcementWarnings(
        status: MacEnforcementController.Status,
        health: FilterEnforcementSummary.Health,
        filterStatus: FilterEnforcementStatus?,
        publishedRevision: UInt64,
        isBlockingDisabled: Bool,
        activationSafetyRequiresRestart: Bool,
        document: CloudPreferencesDocument,
        now: Date
    ) -> [HoldfastDiagnosticWarning] {
        var warnings: [HoldfastDiagnosticWarning] = []
        let hasEnabledGroups = !document.dashboardBlockingRules(at: now).isEmpty

        if let filterStatus, filterStatus.revision < publishedRevision {
            warnings.append(HoldfastDiagnosticWarning(
                code: "filter.revision-behind",
                severity: .critical,
                message: "The filter reports enforcing revision \(filterStatus.revision) while this app has published revision \(publishedRevision). "
                    + "Everything changed since then is not in effect.",
                hint: "A policy the filter never accepted is otherwise invisible: the rules simply stop having any effect. Republish, or reinstall the web enforcement extension."
            ))
        }

        if filterStatus == nil, status == .active {
            warnings.append(HoldfastDiagnosticWarning(
                code: "filter.not-reporting",
                severity: .critical,
                message: "The content filter is marked active but is not reporting any status.",
                hint: "macOS drops traffic while a content filter is installed and not answering. Check whether the extension process is running."
            ))
        }

        if let filterStatus {
            let age = now.timeIntervalSince(filterStatus.updatedAt)
            if age > 60 {
                warnings.append(HoldfastDiagnosticWarning(
                    code: "filter.stale-heartbeat",
                    severity: .warning,
                    message: "The filter's last status update was \(Int(age))s ago. macOS may suspend an idle provider, so this alone does not establish a failure.",
                    hint: "Check ordinary browsing. If it is affected, use Disable All Web Blocks With Passage in the enforcement banner."
                ))
            }
        }

        if isBlockingDisabled, hasEnabledGroups {
            warnings.append(HoldfastDiagnosticWarning(
                code: "enforcement.blocking-disabled",
                severity: .warning,
                message: "Desktop blocking is switched off while Blocking Groups are enabled. Nothing is enforced on this Mac.",
                hint: "This is the deliberate pause state, not a fault."
            ))
        }

        if status != .active, hasEnabledGroups, !isBlockingDisabled {
            warnings.append(HoldfastDiagnosticWarning(
                code: "enforcement.not-active",
                severity: .critical,
                message: "Blocking Groups are enabled but web enforcement is \"\(status.description)\".",
                hint: "Install or approve the Network Extension in System Settings › General › Login Items & Extensions › Network Extensions."
            ))
        }

        if activationSafetyRequiresRestart {
            warnings.append(HoldfastDiagnosticWarning(
                code: "enforcement.restart-required",
                severity: .warning,
                message: "Web enforcement is safety-locked after a Network Extension failure.",
                hint: "Use Reset Enforcement Without Restart. It verifies removal and connectivity before allowing an explicit enable."
            ))
        }

        if health == .notReporting, status == .active {
            warnings.append(HoldfastDiagnosticWarning(
                code: "filter.health-not-reporting",
                severity: .warning,
                message: "Filter health is \"not reporting\" while the extension is active.",
                hint: "Usually transient right after activation. If it persists, the provider is not writing status."
            ))
        }

        return warnings
    }

    // MARK: - Sections

    private static func hostSection() -> HoldfastDiagnosticSection {
        let bundle = Bundle.main
        let process = ProcessInfo.processInfo
        return HoldfastDiagnosticSection(
            title: "Host",
            rows: [
                HoldfastDiagnosticRow("app version", bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"),
                HoldfastDiagnosticRow("app build", bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"),
                HoldfastDiagnosticRow("bundle id", bundle.bundleIdentifier ?? "unknown"),
                HoldfastDiagnosticRow("bundle location", bundle.bundleURL.path.hasPrefix("/Applications/") ? "/Applications" : bundle.bundleURL.deletingLastPathComponent().path),
                HoldfastDiagnosticRow("system", process.operatingSystemVersionString),
                HoldfastDiagnosticRow("locale", Locale.current.identifier),
                HoldfastDiagnosticRow("time zone", TimeZone.current.identifier),
                HoldfastDiagnosticRow("uptime", "\(Int(process.systemUptime))s"),
                HoldfastDiagnosticRow("app group reachable", FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: DesktopEnforcementConstants.appGroupIdentifier
                ) != nil)
            ]
        )
    }

    private static func enforcementSection(
        status: MacEnforcementController.Status,
        health: FilterEnforcementSummary.Health,
        publishedRevision: UInt64,
        enforcedRevision: UInt64?,
        isBlockingDisabled: Bool,
        removalState: DesktopRemovalGate.State,
        deliveryError: String?,
        recoveryWarning: String?,
        activationSafetyRequiresRestart: Bool,
        activationSafetyReason: String?,
        syncStatus: String
    ) -> HoldfastDiagnosticSection {
        HoldfastDiagnosticSection(
            title: "Enforcement",
            explanation: "The published revision is what this app wrote. The enforced revision is what the filter says it accepted. "
                + "They must match, or the newest rules are not in effect.",
            rows: [
                HoldfastDiagnosticRow("status", status.description),
                HoldfastDiagnosticRow("health", String(describing: health)),
                HoldfastDiagnosticRow("published revision", String(publishedRevision)),
                HoldfastDiagnosticRow("enforced revision", enforcedRevision.map(String.init) ?? "not reporting"),
                HoldfastDiagnosticRow("revisions match", enforcedRevision == publishedRevision),
                HoldfastDiagnosticRow("blocking disabled", isBlockingDisabled),
                HoldfastDiagnosticRow("removal state", String(describing: removalState)),
                HoldfastDiagnosticRow("restart required", activationSafetyRequiresRestart),
                HoldfastDiagnosticRow("restart reason", activationSafetyReason ?? "—"),
                HoldfastDiagnosticRow("delivery error", deliveryError ?? "—"),
                HoldfastDiagnosticRow("recovery warning", recoveryWarning ?? "—"),
                HoldfastDiagnosticRow("icloud sync", syncStatus)
            ]
        )
    }

    private static func filterSection(
        status: FilterEnforcementStatus?,
        redactor: HoldfastDiagnosticRedactor
    ) -> HoldfastDiagnosticSection {
        guard let status else {
            return HoldfastDiagnosticSection(
                title: "Content filter",
                explanation: "The filter is not reporting. Nothing below could be read from it.",
                rows: [HoldfastDiagnosticRow("reporting", false)]
            )
        }

        // Appended one at a time on purpose: a single literal mixing these
        // initialiser overloads pushes the type checker past its time budget.
        var rows: [HoldfastDiagnosticRow] = []
        rows.append(HoldfastDiagnosticRow("reporting", true))
        rows.append(HoldfastDiagnosticRow("revision", String(status.revision)))
        rows.append(HoldfastDiagnosticRow("updated", status.updatedAt))
        rows.append(HoldfastDiagnosticRow("rules", status.ruleCount))
        rows.append(HoldfastDiagnosticRow("rules active", status.activeRuleCount))
        rows.append(HoldfastDiagnosticRow("active domains", status.activeDomainCount))
        rows.append(HoldfastDiagnosticRow("has active web restrictions", status.hasActiveWebRestrictions))
        rows.append(HoldfastDiagnosticRow("lockdown ends", status.lockdownEndsAt))
        var tables: [HoldfastDiagnosticTable] = []
        if let diagnostics = status.diagnostics {
            rows.append(HoldfastDiagnosticRow("provider session", diagnostics.sessionID))
            rows.append(HoldfastDiagnosticRow("provider build", diagnostics.providerBuild))
            rows.append(HoldfastDiagnosticRow("provider started", diagnostics.providerStartedAt))
            rows.append(HoldfastDiagnosticRow("provider policy revision", String(diagnostics.policyRevision)))
            rows.append(HoldfastDiagnosticRow("heartbeat sequence", String(diagnostics.heartbeatSequence)))
            rows.append(HoldfastDiagnosticRow("last event", diagnostics.lastEventAt))
            rows.append(HoldfastDiagnosticRow("last flow", diagnostics.lastFlowAt))
            rows.append(HoldfastDiagnosticRow("inspections in flight", diagnostics.currentInspections))
            rows.append(HoldfastDiagnosticRow("peak inspections", diagnostics.peakInspections))
            rows.append(HoldfastDiagnosticRow("fail-open active", diagnostics.failOpenActive))
            rows.append(HoldfastDiagnosticRow("fail-open until", diagnostics.failOpenUntil))
            rows.append(HoldfastDiagnosticRow("fail-open trips", diagnostics.failOpenTrips))
            rows.append(HoldfastDiagnosticRow("drop pressure warning", diagnostics.dropPressureWarningActive ?? false))
            rows.append(HoldfastDiagnosticRow("unidentified drops in window", diagnostics.unidentifiedDropsInWindow))

            tables.append(HoldfastDiagnosticTable(
                title: "Flow counters",
                columns: ["counter", "value"],
                rows: diagnostics.counters
                    .sorted { $0.key < $1.key }
                    .map { [$0.key, String($0.value)] },
                emptyMessage: "The provider reports no counters."
            ))
            tables.append(HoldfastDiagnosticTable(
                title: "Decision reasons",
                columns: ["reason", "count"],
                rows: diagnostics.decisionReasons
                    .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                    .map { [$0.key, String($0.value)] },
                emptyMessage: "The provider reports no decisions."
            ))
            tables.append(HoldfastDiagnosticTable(
                title: "Recent anomalies (newest last)",
                columns: ["time", "code", "stage", "reason", "transport", "port", "revision", "bytes"],
                rows: diagnostics.recentAnomalies.map { anomaly in
                    [
                        HoldfastDiagnosticReport.format(anomaly.timestamp),
                        String(describing: anomaly.code),
                        String(describing: anomaly.stage),
                        anomaly.reason.map { String(describing: $0) } ?? "—",
                        String(describing: anomaly.transport),
                        String(describing: anomaly.portClass),
                        String(anomaly.revision),
                        anomaly.bytes.map { String($0) } ?? "—"
                    ]
                },
                emptyMessage: "No anomalies recorded."
            ))
        }

        let blockPageTable = HoldfastDiagnosticTable(
            title: "Rules the filter is holding",
            columns: ["id", "name", "mode", "domains", "extensions", "passage"],
            rows: (status.blockPageRules ?? []).map { rule in
                [
                    redactor.identifier(rule.id),
                    redactor.userContent(rule.name),
                    rule.enforcementMode,
                    String(rule.domains.count),
                    rule.allowsTimeExtensions ? "yes" : "no",
                    String(rule.passageWordCount)
                ]
            },
            emptyMessage: "The filter reports no rules."
        )

        return HoldfastDiagnosticSection(
            title: "Content filter",
            explanation: "Read from the filter's own published status, so this is the extension's view rather than the app's.",
            rows: rows,
            tables: [blockPageTable] + tables
        )
    }

    private static func retreatLockSection(
        retreatUnlockPhases: [UUID: UnlockPhase],
        redactor: HoldfastDiagnosticRedactor
    ) -> HoldfastDiagnosticSection {
        HoldfastDiagnosticSection(
            title: "Retreat locks",
            tables: [HoldfastDiagnosticTable(
                title: "Unlock phases",
                columns: ["retreat", "phase"],
                rows: retreatUnlockPhases
                    .sorted { $0.key.uuidString < $1.key.uuidString }
                    .map { [redactor.identifier($0.key), describe($0.value)] },
                emptyMessage: "No unlock process is in progress."
            )]
        )
    }

    private static func traceSection(events: [DesktopDiagnosticTraceEvent]) -> HoldfastDiagnosticSection {
        let table = HoldfastDiagnosticTable(
            title: "Recent trace events (newest last)",
            columns: ["time", "process", "build", "component", "event", "fields"],
            rows: events.map { event in
                [
                    HoldfastDiagnosticReport.format(Date(timeIntervalSince1970: Double(event.timestampMilliseconds) / 1_000)),
                    event.process,
                    event.build,
                    event.component,
                    event.event,
                    event.fields
                        .sorted { $0.key < $1.key }
                        .map { "\($0.key)=\($0.value)" }
                        .joined(separator: " ")
                ]
            },
            emptyMessage: "No trace events recorded. The trace may be disabled."
        )
        return HoldfastDiagnosticSection(
            title: "Activity trace",
            explanation: "The app and the filter both append here, so this survives the extension being replaced. "
                + "It carries states, counts and error codes only -- never hostnames, URLs or payload data.",
            rows: [
                HoldfastDiagnosticRow("trace enabled", DesktopDiagnosticTrace.isEnabled),
                HoldfastDiagnosticRow("events included", events.count)
            ],
            tables: [table]
        )
    }

    // MARK: - Descriptions

    static func describe(_ phase: UnlockPhase) -> String {
        switch phase {
        case .idle: "idle"
        case .cancelled: "cancelled"
        case let .waiting(unlocksAt, _): "waiting until \(HoldfastDiagnosticReport.format(unlocksAt))"
        case let .confirmationDue(_, deadline, checkpoint, total):
            "checkpoint \(checkpoint)/\(total) due by \(HoldfastDiagnosticReport.format(deadline))"
        case let .unlocked(editWindowEndsAt):
            "unlocked until \(HoldfastDiagnosticReport.format(editWindowEndsAt))"
        }
    }

    /// The trace file is append-only and capped, but it can still hold far more
    /// than a report should carry. Only the newest events are included.
    static func recentTraceEvents(limit: Int = 400) -> [DesktopDiagnosticTraceEvent] {
        guard let data = try? DesktopDiagnosticTrace.exportedData(), !data.isEmpty else { return [] }
        return DesktopDiagnosticTrace.recentEvents(in: data, limit: limit)
    }
}
