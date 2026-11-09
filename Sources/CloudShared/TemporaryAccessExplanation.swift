import Foundation

/// Editor toggles are drafts; pause eligibility comes from the saved,
/// compiled policy. Explain that distinction without weakening enforcement.
enum TemporaryAccessExplanation {
    static func denied(draft: CloudBlockingGroup, saved: CloudBlockingGroup?,
                       activities: [CloudActivityGroup], containerPolicy: CloudRuleLockdownPreference) -> String {
        guard let saved else { return "Save this Blocking Group before requesting temporary access." }
        if draft.targets != nil || saved.targets != nil {
            if draft.modificationPolicy != saved.modificationPolicy {
                return "Unsaved protection changes. Temporary access uses the saved policy until you complete Unlock for Changes if required, then save and reopen."
            }
            return "This Blocking Group's saved protection policy does not allow temporary access. Complete Unlock for Changes, enable Allow Temporary Access, then save."
        }
        var messages: [String] = []
        if draft.modificationPolicy != saved.modificationPolicy || Set(draft.activityGroupIDs) != Set(saved.activityGroupIDs) {
            messages.append("Unsaved changes: the controls below are a draft. Temporary access still uses the saved policy. Complete Unlock for Changes if required, then save and reopen.")
        }
        // Match restrictiveMaximum: appDefault resolves to none for cloud
        // compilation, and a none policy does not veto another policy.
        func vetoes(_ policy: CloudRuleLockdownPreference) -> Bool {
            policy.severity != "none" && policy.severity != "appDefault" && !policy.allowsTimeExtensions
        }
        let inherited = activities.filter { saved.activityGroupIDs.contains($0.id) && vetoes($0.modificationPolicy) }
            .map(\.name).sorted()
        if !inherited.isEmpty {
            messages.append("Restricted by linked Activity Group(s): \(inherited.joined(separator: ", ")). Their saved policies disallow temporary access. Enabling it on this Blocking Group alone cannot override them.")
        }
        if vetoes(containerPolicy) {
            messages.append("The saved Baseline policy also disallows temporary access.")
        }
        if vetoes(saved.modificationPolicy) {
            messages.append("This Blocking Group's saved policy has Allow Temporary Access turned off.")
        }
        if messages.isEmpty {
            messages.append("The effective saved policy does not permit temporary access, despite the local toggle. Check inherited protection and pending sync changes; the toggle alone is not the final permission.")
        }
        return messages.joined(separator: "\n\n")
    }
}
