#include "Workspace.h"
#include "Policy.h"
#include <algorithm>
#include <array>
#include <bitset>
#include <cctype>
#include <codecvt>
#include <ctime>
#include <iomanip>
#include <locale>
#include <memory>
#include <random>
#include <set>
#include <sstream>
#include <stdexcept>

namespace holdfast {
namespace {
void Require(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }
bool Integer(const Json& value, int min, int max) { return value.is_number_integer() && value >= min && value <= max; }
std::string Text(const Json& value, size_t max = 256) {
    Require(value.is_string(), "Expected text.");
    auto text = value.get<std::string>();
    Require(text.size() <= max && text.find('\0') == std::string::npos, "Text is too long or contains a null character.");
    return text;
}
std::string Fold(std::string value) { for (auto& c : value) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c))); return value; }
std::string NormalizedPassage(const std::string& value) {
    std::istringstream input(value); std::string word, result;
    while (input >> word) { if (!result.empty()) result += ' '; result += Fold(word); }
    return result;
}
int Delay(const Json& policy) { return policy.at("kind") == "passage" || policy.at("kind") == "none" ? 0 : policy.at("delayDays").get<int>(); }
void ValidateChange(const Json& p) {
    const std::set<std::string> kinds{"none", "passage", "delay", "checkpoints"};
    Require(kinds.contains(Text(p.at("kind"))) && Integer(p.at("words"), 20, 300)
        && Integer(p.at("delayDays"), 0, 365), "Invalid change policy.");
}
void ValidateGroup(const Json& g) {
    Require(!Text(g.at("id"), 80).empty() && !Text(g.at("name"), 120).empty(), "A group needs an ID and name.");
    Require(g.at("enabled").is_boolean(), "Invalid enabled value.");
    ValidateChange(g.at("changePolicy"));
    const auto& t = g.at("temporaryPolicy");
    Require(t.at("allowed").is_boolean() && Integer(t.at("words"), 20, 300)
        && Integer(t.at("maximumMinutes"), 10, 480)
        && (t.at("resetDays").is_null() || Integer(t.at("resetDays"), 1, 365)), "Invalid temporary access policy (maximum eight hours).");
    const auto& schedule = g.at("schedule");
    Require(schedule.at("mode") == "allow" || schedule.at("mode") == "block", "Invalid window mode.");
    Require(schedule.at("slots").is_array() && schedule.at("slots").size() <= 128, "Too many schedule windows.");
    for (const auto& s : schedule.at("slots")) {
        Text(s.at("id"), 80);
        Require(s.at("weekdays").is_array() && !s.at("weekdays").empty() && s.at("weekdays").size() <= 7
            && Integer(s.at("startMinutes"), 0, 1439) && Integer(s.at("endMinutes"), 0, 1440), "Invalid time window.");
        for (const auto& d : s.at("weekdays")) Require(Integer(d, 1, 7), "Invalid weekday.");
    }
    Require(g.at("domains").is_array() && g.at("domains").size() <= 256, "Invalid domains.");
    // Never silently turn a website request into an application-only rule.
    Require(g.at("domains").empty(), "Website filtering is not implemented by the Windows service. Select applications instead; no website rule was saved.");
    Require(g.at("applications").is_array() && g.at("applications").size() <= ED_GUARD_MAX_RULES, "Too many applications.");
    auto wire = std::make_unique<ED_GUARD_POLICY>();
    wire->version = ED_GUARD_POLICY_VERSION; wire->revision = 1; wire->issuedAtUnixSeconds = 100; wire->validUntilUnixSeconds = 200;
    std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> codec;
    for (const auto& app : g.at("applications")) {
        const auto path = codec.from_bytes(Text(app, ED_GUARD_MAX_PATH_CHARS * 4));
        Require(path.size() < ED_GUARD_MAX_PATH_CHARS, "Application path is too long.");
        auto& rule = wire->rules[wire->ruleCount++];
        for (size_t i = 0; i < path.size(); ++i) rule.path[i] = static_cast<ED_GUARD_CHAR>(path[i]);
    }
    Require(ValidatePolicy(*wire, sizeof(*wire), 100, 0).valid, "An application path is invalid, duplicated, or protected.");
    Require(!g.at("enabled").get<bool>() || !g.at("applications").empty(), "Choose at least one application before enabling this group.");
}
bool Superset(const Json& larger, const Json& smaller) {
    std::set<std::string> values;
    for (const auto& v : larger) values.insert(Fold(v.get<std::string>()));
    for (const auto& v : smaller) if (!values.contains(Fold(v.get<std::string>()))) return false;
    return true;
}
bool PolicyStricter(const Json& old, const Json& next) {
    if (old.at("kind") == "none") return true;
    return next.at("kind") != "none" && Delay(next) >= Delay(old) && next.at("words") >= old.at("words")
        && (old.at("kind") != "checkpoints" || next.at("kind") == "checkpoints");
}
Json CleanGroup(const Json& g) {
    Json result;
    for (const auto* field : {"id", "name", "enabled", "domains", "applications", "schedule", "changePolicy", "temporaryPolicy"}) result[field] = g.at(field);
    return result;
}
int64_t PauseUntil(const Json& doc, const std::string& id) {
    return doc.at("pauses").contains(id) ? doc.at("pauses").at(id).at("until").get<int64_t>() : 0;
}
}
std::string NewIdentifier() {
    std::random_device random; std::ostringstream output;
    output << std::hex << std::setfill('0');
    for (int i = 0; i < 4; ++i) output << std::setw(8) << static_cast<uint32_t>(random());
    return output.str();
}
std::string ISOTime(int64_t seconds) {
    const auto value = static_cast<std::time_t>(seconds); std::tm time{};
#ifdef _WIN32
    gmtime_s(&time, &value);
#else
    gmtime_r(&value, &time);
#endif
    std::ostringstream out; out << std::put_time(&time, "%Y-%m-%dT%H:%M:%SZ"); return out.str();
}
Json Workspace::Empty() {
    return {{"schema", 1}, {"revision", uint64_t{1}}, {"enabled", false}, {"groups", Json::array()},
        {"pauses", Json::object()}, {"unlocks", Json::object()}, {"backoff", Json::object()}, {"history", Json::array()}};
}
Workspace::Workspace(Json document, Save save) : document_(std::move(document)), save_(std::move(save)) {
    Require(document_.at("schema") == 1 && document_.at("revision").is_number_integer() && document_.at("revision") > 0
        && document_.at("enabled").is_boolean() && document_.at("groups").is_array()
        && document_.at("groups").size() <= 256, "Invalid saved workspace. Recover its backup before changing rules.");
    std::set<std::string> ids;
    for (const auto& group : document_.at("groups")) { ValidateGroup(group); Require(ids.insert(group.at("id").get<std::string>()).second, "Duplicate saved group."); }
    for (const auto* key : {"pauses", "unlocks", "backoff"}) Require(document_.at(key).is_object(), "Invalid saved authorization state.");
    Require(document_.at("history").is_array() && document_.at("history").size() <= 10000, "Invalid saved history.");
}
void Workspace::Commit(Json next) {
    std::set<std::string> applications;
    for (const auto& group : next.at("groups")) for (const auto& path : group.at("applications")) applications.insert(Fold(path.get<std::string>()));
    Require(applications.size() <= ED_GUARD_MAX_RULES, "A workspace supports at most 256 distinct application paths.");
    next["revision"] = document_.at("revision").get<uint64_t>() + 1;
    save_(next); // Atomic durable commit before acknowledging success or changing in-memory intent.
    document_ = std::move(next); challenges_.clear();
}
const Json& Workspace::Group(const std::string& id) const {
    for (const auto& g : document_.at("groups")) if (g.at("id") == id) return g;
    throw std::runtime_error("This blocking group no longer exists.");
}
bool Workspace::Scheduled(const Json& g, int weekday, int minute) {
    bool inside = false;
    for (const auto& s : g.at("schedule").at("slots")) {
        int start = s.at("startMinutes"), end = s.at("endMinutes");
        for (int d : s.at("weekdays")) {
            if (start < end) inside |= weekday == d && minute >= start && minute < end;
            else inside |= (weekday == d && minute >= start) || (weekday == d % 7 + 1 && minute < end);
        }
    }
    return g.at("schedule").at("mode") == "allow" ? !inside : inside;
}
bool Workspace::SameOrStricter(const Json& old, const Json& next) {
    if (old.at("enabled").get<bool>() && !next.at("enabled").get<bool>()) return false;
    if (!Superset(next.at("applications"), old.at("applications")) || !Superset(next.at("domains"), old.at("domains"))) return false;
    if (!PolicyStricter(old.at("changePolicy"), next.at("changePolicy"))) return false;
    const auto& a = old.at("temporaryPolicy"); const auto& b = next.at("temporaryPolicy");
    if (b.at("allowed").get<bool>() && (!a.at("allowed").get<bool>() || b.at("words") < a.at("words")
        || b.at("maximumMinutes") > a.at("maximumMinutes")
        || (!a.at("resetDays").is_null() && (b.at("resetDays").is_null() || b.at("resetDays") < a.at("resetDays"))))) return false;
    for (int d = 1; d <= 7; ++d) for (int m = 0; m < 1440; ++m)
        if (Scheduled(old, d, m) && !Scheduled(next, d, m)) return false;
    return true;
}
bool Workspace::Unlocked(const Json& group, int64_t now) const {
    const auto& policy = group.at("changePolicy");
    if (policy.at("kind") == "none") return true;
    const auto id = group.at("id").get<std::string>();
    if (!document_.at("unlocks").contains(id)) return false;
    const auto& unlock = document_.at("unlocks").at(id);
    if (unlock.at("policy") != policy) return false;
    const int64_t start = unlock.at("started"), end = start + static_cast<int64_t>(Delay(policy)) * 86400;
    if (now < end || now >= end + 86400) return false;
    return policy.at("kind") != "checkpoints" || unlock.at("confirmations").get<int>() >= Delay(policy);
}
int Workspace::PassageWords(const Json& group, int64_t now) const {
    const auto id = group.at("id").get<std::string>(); const auto& policy = group.at("temporaryPolicy");
    int factor = 1;
    if (PauseUntil(document_, id) > now) factor = 1 << std::min(11, document_.at("pauses").at(id).at("grants").get<int>());
    if (!policy.at("resetDays").is_null() && document_.at("backoff").contains(id)) {
        const auto& history = document_.at("backoff").at(id);
        if (now < history.at("started").get<int64_t>() + policy.at("resetDays").get<int64_t>() * 86400)
            factor = std::max(factor, std::min(1920, history.at("grants").get<int>()) + 1);
    }
    return std::min(38400, policy.at("words").get<int>() * factor);
}
Json Workspace::Challenge(const Json& command, int words, int64_t now, const std::string& title) {
    static constexpr const char* vocabulary[]{"river", "attention", "quiet", "return", "choice", "ground", "breathe", "time", "steady", "notice", "space", "patient", "present", "enough", "kind", "begin"};
    std::random_device random; std::string passage;
    for (int i = 0; i < words; ++i) { if (i) passage += ' '; passage += vocabulary[random() % std::size(vocabulary)]; }
    const auto id = NewIdentifier();
    if (challenges_.size() >= 16) challenges_.clear();
    constexpr int64_t lifetime = 30 * 60;
    challenges_[id] = {{"command", command}, {"words", words}, {"passage", passage}, {"expires", now + lifetime}, {"revision", document_.at("revision")}};
    return {{"challenge", {{"id", id}, {"title", title}, {"passage", passage}, {"expiresAt", ISOTime(now + lifetime)},
        {"detail", "Type the passage. You have 30 minutes; any saved policy change invalidates it. Blocking remains in force until the service accepts it."}}}};
}
Json Workspace::ApplyChallenge(const Json& command, int64_t now) {
    const auto id = Text(command.at("challengeID"), 80);
    Require(challenges_.contains(id), "This passage expired or was already used. Request a new one.");
    const auto challenge = challenges_.at(id);
    Require(challenge.at("expires").get<int64_t>() > now && challenge.at("revision") == document_.at("revision"), "Settings changed or the passage expired.");
    Require(NormalizedPassage(Text(command.at("typed"), 400000)) == challenge.at("passage").get<std::string>(), "The passage does not match.");
    const auto& action = challenge.at("command"); const auto type = action.at("type").get<std::string>();
    auto next = document_;
    std::string message;
    if (type == "setEnforcement") {
        next["enabled"] = false; message = "Application blocking disabled.";
    } else if (type == "requestGroupUnlock") {
        const auto groupID = action.at("groupID").get<std::string>(); const auto& group = Group(groupID); const auto& policy = group.at("changePolicy");
        auto unlock = next["unlocks"].value(groupID, Json::object());
        const int days = Delay(policy);
        bool restart = unlock.empty() || unlock.value("policy", Json()) != policy;
        if (!restart && policy.at("kind") == "checkpoints") {
            const int count = unlock.at("confirmations");
            const int64_t due = unlock.at("started").get<int64_t>() + static_cast<int64_t>(count + 1) * 86400;
            restart = now > due + 86400;
            if (!restart) Require(count < days && now >= due, "The next confirmation is not due yet.");
        } else if (!restart) restart = now >= unlock.at("started").get<int64_t>() + static_cast<int64_t>(days + 1) * 86400;
        if (restart) unlock = {{"started", now}, {"confirmations", 0}, {"policy", policy}};
        else if (policy.at("kind") == "checkpoints") unlock["confirmations"] = unlock.at("confirmations").get<int>() + 1;
        next["unlocks"][groupID] = unlock;
        message = days == 0 ? "Editing is unlocked for 24 hours. Reopen the group before saving." : "Unlock request recorded. Blocking continues during the waiting period; daily policies require their checkpoints.";
    } else if (type == "requestTemporaryAccess") {
        const auto groupID = action.at("groupID").get<std::string>(); const auto& group = Group(groupID);
        Require(group.at("temporaryPolicy").at("allowed").get<bool>(), "Temporary access is no longer allowed.");
        Require(PassageWords(group, now) == challenge.at("words"), "Passage length changed. Request a new passage.");
        const int minutes = action.at("minutes");
        const auto existing = next["pauses"].value(groupID, Json::object()); const bool continuing = PauseUntil(document_, groupID) > now;
        const int total = (continuing ? existing.at("total").get<int>() : 0) + minutes;
        Require(total <= group.at("temporaryPolicy").at("maximumMinutes").get<int>(), "This allowance session would exceed its saved maximum.");
        const int64_t until = std::max(now, PauseUntil(document_, groupID)) + minutes * 60;
        next["pauses"][groupID] = {{"until", until}, {"total", total}, {"grants", continuing ? existing.at("grants").get<int>() + 1 : 1}};
        const auto& reset = group.at("temporaryPolicy").at("resetDays");
        if (!reset.is_null()) {
            auto history = next["backoff"].value(groupID, Json{{"started", now}, {"grants", 0}});
            if (now >= history.at("started").get<int64_t>() + reset.get<int64_t>() * 86400) history = {{"started", now}, {"grants", 0}};
            history["grants"] = std::min(38400, history.at("grants").get<int>() + 1); next["backoff"][groupID] = history;
        }
        next["history"].push_back({{"id", NewIdentifier()}, {"groupID", groupID}, {"groupName", group.at("name")},
            {"startedAt", ISOTime(now)}, {"endsAt", ISOTime(until)}, {"reason", action.at("reason")}, {"reflection", action.at("reflection")}});
        if (next["history"].size() > 10000) next["history"].erase(next["history"].begin());
        message = "Temporary access granted until " + ISOTime(until) + ".";
    } else throw std::runtime_error("Unknown passage action.");
    Commit(std::move(next)); return {{"message", message}};
}
Json Workspace::Handle(const Json& command, int64_t now, int weekday, int minute) {
    const auto type = Text(command.at("type"));
    if (type == "snapshot") return {{"snapshot", Snapshot(now, weekday, minute)}};
    Json reply;
    if (type == "submitChallenge") reply = ApplyChallenge(command, now);
    else {
        Require(command.at("revision") == std::to_string(document_.at("revision").get<uint64_t>()), "Settings changed. Close this dialog and refresh before saving.");
        if (type == "saveGroup") {
            auto group = CleanGroup(command.at("group")); ValidateGroup(group);
            auto next = document_; bool replaced = false;
            for (auto& old : next["groups"]) if (old.at("id") == group.at("id")) {
                Require(Unlocked(old, now) || SameOrStricter(old, group), "Unlock this group before weakening its restrictions.");
                old = group; replaced = true; break;
            }
            if (!replaced) { Require(next["groups"].size() < 256, "Maximum 256 groups."); next["groups"].push_back(group); }
            Commit(std::move(next)); reply["message"] = "Blocking group saved by the service.";
        } else if (type == "deleteGroup") {
            const auto id = Text(command.at("groupID")); const auto& group = Group(id);
            Require(Unlocked(group, now), "Unlock this group before deleting it.");
            auto next = document_;
            auto& groups = next["groups"]; groups.erase(std::remove_if(groups.begin(), groups.end(), [&](const auto& g){ return g.at("id") == id; }), groups.end());
            next["pauses"].erase(id); next["unlocks"].erase(id); Commit(std::move(next)); reply["message"] = "Blocking group deleted.";
        } else if (type == "setEnforcement") {
            Require(command.at("enabled").is_boolean(), "Invalid enforcement value.");
            if (command.at("enabled") == false && document_.at("enabled") == true) return Challenge(command, 80, now, "Disable application blocking");
            auto next = document_; next["enabled"] = command.at("enabled"); Commit(std::move(next)); reply["message"] = "Application enforcement setting saved. Check the filter status for acknowledgement.";
        } else if (type == "requestTemporaryAccess") {
            const auto& group = Group(Text(command.at("groupID"))); const auto& policy = group.at("temporaryPolicy");
            Require(policy.at("allowed").get<bool>(), "This group's saved policy does not allow temporary access.");
            const int minutes = command.at("minutes").get<int>();
            Require((minutes == 10 || minutes == 30 || minutes == 60) && minutes <= policy.at("maximumMinutes").get<int>(), "Choose an allowed duration.");
            Require(command.at("reason") == "conscious" || command.at("reason") == "edulgence", "Choose the reason for this exception.");
            std::istringstream reflection(Text(command.at("reflection"), 1120));
            std::string word; int count = 0; while (reflection >> word) ++count;
            Require(count >= 4, "Describe what this time is for in at least four words.");
            return Challenge(command, PassageWords(group, now), now, "Temporary access: " + group.at("name").get<std::string>());
        } else if (type == "requestGroupUnlock") {
            const auto& group = Group(Text(command.at("groupID")));
            if (Unlocked(group, now)) reply["message"] = "This group is already unlocked. Reopen it to edit.";
            else {
                const auto id = group.at("id").get<std::string>(); const auto& policy = group.at("changePolicy");
                if (document_.at("unlocks").contains(id)) {
                    const auto& unlock = document_.at("unlocks").at(id);
                    if (unlock.at("policy") == policy) {
                        const auto due = unlock.at("started").get<int64_t>() + 86400 * (policy.at("kind") == "checkpoints" ? unlock.at("confirmations").get<int64_t>() + 1 : Delay(policy));
                        if (now < due) return {{"message", "Blocking continues. The next unlock step is available at " + ISOTime(due) + "."}};
                    }
                }
                return Challenge(command, group.at("changePolicy").at("words"), now, "Unlock group changes");
            }
        } else if (type == "cancelTemporaryAccess") {
            const auto id = Text(command.at("groupID")); Group(id);
            auto next = document_; next["pauses"].erase(id); Commit(std::move(next)); reply["message"] = "Temporary access ended. The normal schedule applies again.";
        } else throw std::runtime_error("This Windows capability is not available. No change was made.");
    }
    reply["snapshot"] = Snapshot(now, weekday, minute); return reply;
}
std::vector<std::string> Workspace::ActiveApplications(int64_t now, int weekday, int minute) const {
    std::set<std::string> paths;
    if (document_.at("enabled").get<bool>()) for (const auto& g : document_.at("groups")) {
        if (!g.at("enabled").get<bool>() || PauseUntil(document_, g.at("id").get<std::string>()) > now || !Scheduled(g, weekday, minute)) continue;
        for (const auto& path : g.at("applications")) paths.insert(Fold(path.get<std::string>()));
    }
    return {paths.begin(), paths.end()};
}
Json Workspace::Snapshot(int64_t now, int weekday, int minute) const {
    Json groups = Json::array();
    for (auto g : document_.at("groups")) {
        const auto until = PauseUntil(document_, g.at("id").get<std::string>());
        const bool active = document_.at("enabled").get<bool>() && g.at("enabled").get<bool>();
        g["status"] = !active ? "disabled" : until > now ? "suspended" : Scheduled(g, weekday, minute) ? "blocking" : "allowed";
        g["detail"] = !active ? "Application blocking disabled" : until > now ? "Temporarily suspended" : Scheduled(g, weekday, minute) ? "Scheduled to block application networking" : "Outside this group's blocking windows";
        if (until > now) g["suspendedUntil"] = ISOTime(until);
        g["canEdit"] = Unlocked(g, now);
        g["temporaryPassageWords"] = PassageWords(g, now);
        groups.push_back(std::move(g));
    }
    return {{"schema", 1}, {"platform", "windows"}, {"revision", std::to_string(document_.at("revision").get<uint64_t>())},
        {"capabilities", {"editGroups", "temporaryAccess", "pickApplications", "enforcementControl"}},
        {"enforcementEnabled", document_.at("enabled")},
        {"enforcement", {{"state", "unknown"}, {"title", "Waiting for filter acknowledgement"}, {"detail", "Application-network enforcement only. Website filtering and all-device sync are not available on Windows yet."}}},
        {"sync", {{"state", "unavailable"}, {"detail", "Stored securely on this Windows device. All-device lockdowns and retreats are unavailable until sync is connected."}}},
        {"groups", groups}, {"retreats", Json::array()}, {"bypasses", document_.at("history")}, {"lockdown", nullptr}};
}
}
