import Foundation

/// Ready-made starting points, so first-run setup is choosing rather than
/// designing. Each preset produces ordinary Activity and Blocking Groups that
/// the user can edit afterwards; nothing here is a live reference.
///
/// Setup is itself an executive-function task. Four presets cover the common
/// shapes (work hours, evenings, a focused retreat, a hard block) and hide the
/// object model until the user asks to customize.
enum HoldfastPresets {
    struct ActivityPreset: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var summary: String
        var domains: [String]
        var macApplicationIdentifiers: [String]

        func makeGroup(id: UUID = UUID(), at date: Date = Date()) -> CloudActivityGroup {
            CloudActivityGroup(
                id: id,
                modifiedAt: date,
                name: name,
                domains: domains.map { CloudDomainPreference(domain: $0, category: self.id, source: "preset") },
                macApplicationIdentifiers: Set(macApplicationIdentifiers)
            )
        }
    }

    struct BlockingPreset: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var summary: String
        /// Activity presets this group links.
        var activityPresetIDs: [String]
        /// (weekdays, start minute, end minute); weekday 1 = Sunday.
        var windows: [PresetWindow]
        var severity: String
        var unlockDelayDays: Int
        var passageWordCount: Int
        var allowsTimeExtensions: Bool
        var maximumTimeExtensionHours: Int

        func makeBlockingGroup(
            linking activityGroupIDs: [UUID],
            id: UUID = UUID(),
            at date: Date = Date()
        ) -> CloudBlockingGroup {
            CloudBlockingGroup(
                id: id,
                modifiedAt: date,
                name: name,
                activityGroupIDs: activityGroupIDs,
                timeWindow: CloudTimeWindowPlan(
                    paintMode: .block,
                    slots: windows.map {
                        CloudTimeWindow(weekdays: $0.weekdays, startMinutes: $0.startMinutes, endMinutes: $0.endMinutes)
                    }
                ),
                isEnabled: true,
                enforcementMode: "blockList",
                modificationPolicy: CloudRuleLockdownPreference(
                    severity: severity,
                    unlockDelayDays: unlockDelayDays,
                    passageWordCount: passageWordCount,
                    allowsTimeExtensions: allowsTimeExtensions,
                    maximumTimeExtensionHours: maximumTimeExtensionHours
                )
            )
        }
    }

    struct PresetWindow: Equatable, Sendable {
        var weekdays: Set<Int>
        var startMinutes: Int
        var endMinutes: Int
    }

    static let weekdays: Set<Int> = [2, 3, 4, 5, 6]
    static let everyDay: Set<Int> = [1, 2, 3, 4, 5, 6, 7]

    static let activityPresets: [ActivityPreset] = [
        ActivityPreset(
            id: "social",
            name: "Social media",
            summary: "Feeds built to keep you scrolling.",
            domains: ["facebook.com", "instagram.com", "x.com", "twitter.com", "tiktok.com",
                      "reddit.com", "threads.net", "bsky.app", "snapchat.com", "linkedin.com"],
            macApplicationIdentifiers: []
        ),
        ActivityPreset(
            id: "video",
            name: "Video and streaming",
            summary: "Autoplay and recommendation queues.",
            domains: ["youtube.com", "twitch.tv", "netflix.com", "hulu.com", "disneyplus.com",
                      "max.com", "primevideo.com", "kick.com"],
            macApplicationIdentifiers: []
        ),
        ActivityPreset(
            id: "news",
            name: "News and forums",
            summary: "Endless refresh and comment threads.",
            domains: ["news.ycombinator.com", "cnn.com", "foxnews.com", "nytimes.com",
                      "theguardian.com", "bbc.com", "news.google.com"],
            macApplicationIdentifiers: []
        ),
        ActivityPreset(
            id: "shopping",
            name: "Shopping",
            summary: "Browsing that turns into buying.",
            domains: ["amazon.com", "ebay.com", "etsy.com", "temu.com", "aliexpress.com", "shein.com"],
            macApplicationIdentifiers: []
        ),
        // A block list cannot see through a tunnel, so blocking the tunnel apps
        // themselves is how block-list mode degrades less badly. Identifiers are
        // vendor families; confirm any you rely on with `codesign -dv <app>`.
        // Work VPNs (for example FortiClient) are deliberately not listed.
        ActivityPreset(
            id: "tunnels",
            name: "VPN and proxy apps",
            summary: "Consumer VPNs and proxies that would route around web rules.",
            domains: ["nordvpn.com", "expressvpn.com", "protonvpn.com", "surfshark.com",
                      "privateinternetaccess.com", "mullvad.net", "windscribe.com", "torproject.org"],
            macApplicationIdentifiers: [
                "com.nordvpn.*", "com.expressvpn.*", "ch.protonvpn.*", "ch.protonmail.vpn.*",
                "com.surfshark.*", "com.privateinternetaccess.*", "net.mullvad.*",
                "com.windscribe.*", "com.cloudflare.1dot1dot1dot1.*", "com.wireguard.*",
                "net.tunnelblick.*", "org.torproject.*", "com.psiphon3.*"
            ]
        )
    ]

    static let blockingPresets: [BlockingPreset] = [
        BlockingPreset(
            id: "work-hours",
            name: "Work hours",
            summary: "Weekdays 9–5. Passage to change, up to 1 hour of extra time.",
            activityPresetIDs: ["social", "video", "news", "shopping"],
            windows: [PresetWindow(weekdays: weekdays, startMinutes: 9 * 60, endMinutes: 17 * 60)],
            severity: "passageOnly",
            unlockDelayDays: 0,
            passageWordCount: 40,
            allowsTimeExtensions: true,
            maximumTimeExtensionHours: 1
        ),
        BlockingPreset(
            id: "evenings-off",
            name: "Evenings off",
            summary: "Every night 21:00–07:00, so the phone and laptop wind down.",
            activityPresetIDs: ["social", "video", "news"],
            windows: [PresetWindow(weekdays: everyDay, startMinutes: 21 * 60, endMinutes: 7 * 60)],
            severity: "delayed",
            unlockDelayDays: 1,
            passageWordCount: 60,
            allowsTimeExtensions: false,
            maximumTimeExtensionHours: 1
        ),
        BlockingPreset(
            id: "deep-work",
            name: "Deep-work retreat",
            summary: "All day, every day, while a Retreat runs. No extra time.",
            activityPresetIDs: ["social", "video", "news", "shopping", "tunnels"],
            windows: [PresetWindow(weekdays: everyDay, startMinutes: 0, endMinutes: 24 * 60)],
            severity: "delayed",
            unlockDelayDays: 3,
            passageWordCount: 80,
            allowsTimeExtensions: false,
            maximumTimeExtensionHours: 1
        ),
        BlockingPreset(
            id: "hard-block",
            name: "Hard block",
            summary: "Always on. Changes need a week and daily confirmations.",
            activityPresetIDs: ["social", "tunnels"],
            windows: [PresetWindow(weekdays: everyDay, startMinutes: 0, endMinutes: 24 * 60)],
            severity: "repeatedConfirmations",
            unlockDelayDays: 7,
            passageWordCount: 120,
            allowsTimeExtensions: false,
            maximumTimeExtensionHours: 1
        )
    ]

    /// Adds a blocking preset (and any activity presets it needs that are not
    /// already present by name) to the Baseline. Returns the new group's ID.
    @discardableResult
    static func install(
        _ preset: BlockingPreset,
        into document: inout CloudPreferencesDocument,
        at date: Date = Date()
    ) -> UUID {
        var linked: [UUID] = []
        for presetID in preset.activityPresetIDs {
            guard let activity = activityPresets.first(where: { $0.id == presetID }) else { continue }
            if let existing = document.activityGroups.first(where: { $0.name == activity.name }) {
                linked.append(existing.id)
            } else {
                let group = activity.makeGroup(at: date)
                document.activityGroups.append(group)
                linked.append(group.id)
            }
        }
        let group = preset.makeBlockingGroup(linking: linked, at: date)
        document.baseline.blockingGroups.append(group)
        document.baseline.modifiedAt = date
        document.rebuildLegacyRuleProjection(at: date)
        return group.id
    }
}
