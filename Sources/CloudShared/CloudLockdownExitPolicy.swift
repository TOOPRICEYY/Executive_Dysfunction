import Foundation

/// Explicit, resolved policy: never interpret another device's app default.
struct CloudLockdownExitPolicy: Codable, Equatable {
    var severity = "passageOnly"
    var unlockDelayDays = 0
    var passageWordCount = 80
    var confirmationWindowHours = 24
    var editWindowHours = 1
}
