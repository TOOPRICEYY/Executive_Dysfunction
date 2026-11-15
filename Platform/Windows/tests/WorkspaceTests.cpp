#include "Workspace.h"
#include <iostream>
#include <stdexcept>
#include <string>
using namespace holdfast;
int checks = 0;
void Check(bool value, const char* label) { ++checks; if (!value) throw std::runtime_error(label); }
template<class F> void Reject(F fn, const char* label) { bool rejected = false; try { fn(); } catch (...) { rejected = true; } Check(rejected, label); }
Json Group() {
    return {{"id", "test"}, {"name", "Test apps"}, {"enabled", true}, {"domains", Json::array()}, {"applications", {"C:\\Apps\\probe.exe"}},
        {"schedule", {{"mode", "block"}, {"slots", {{{"id", "window"}, {"weekdays", {1,2,3,4,5,6,7}}, {"startMinutes", 0}, {"endMinutes", 1440}}}}}},
        {"changePolicy", {{"kind", "passage"}, {"words", 20}, {"delayDays", 0}}},
        {"temporaryPolicy", {{"allowed", true}, {"words", 20}, {"maximumMinutes", 60}, {"resetDays", 2}}}};
}
Json WaitGroup(int wait) { auto g = Group(); g["temporaryPolicy"]["waitMinutes"] = wait; return g; }
Json Run(Workspace& w, Json command, int64_t now) {
    if (command.at("type") == "requestTemporaryAccess" && !command.contains("reflection")) command["reflection"] = "Read one intentional article";
    if (!command.contains("revision")) command["revision"] = std::to_string(w.document().at("revision").get<uint64_t>());
    return w.Handle(command, now, 2, 600);
}
Json Request(Workspace& w, int minutes, int64_t now) {
    return Run(w, {{"type", "requestTemporaryAccess"}, {"groupID", "test"}, {"minutes", minutes}, {"reason", "conscious"}}, now).at("challenge");
}
Json Submit(Workspace& w, const Json& challenge, int64_t now) {
    return Run(w, {{"type", "submitChallenge"}, {"challengeID", challenge.at("id")}, {"typed", challenge.at("passage")}}, now);
}
bool Blocked(const Workspace& w, int64_t now) { return w.ActiveApplications(now, 2, 600).size() == 1; }
Json Snap(const Workspace& w, int64_t now) { return w.Snapshot(now, 2, 600).at("groups")[0]; }
bool Mentions(const Json& text, const std::string& part) { return text.get<std::string>().find(part) != std::string::npos; }
template<class F> bool RejectsWith(F fn, const std::string& part) { try { fn(); } catch (const std::exception& e) { return std::string(e.what()).find(part) != std::string::npos; } return false; }
// One enforced group with the given wait; the saver keeps `disk` current.
struct Fixture {
    Json disk = Workspace::Empty();
    Workspace w{Workspace::Empty(), [this](const Json& value){ disk = value; }};
    Fixture(int wait, int64_t now) { Run(w, {{"type", "saveGroup"}, {"group", WaitGroup(wait)}}, now); Run(w, {{"type", "setEnforcement"}, {"enabled", true}}, now); }
    const Json& pause() const { return disk.at("pauses").at("test"); }
};
void WaitTests() {
    // Old saved data without waitMinutes still loads and means no wait; old pauses without opensAt are open.
    Json legacy = Workspace::Empty(); legacy["enabled"] = true; legacy["groups"].push_back(Group());
    legacy["pauses"]["test"] = {{"until", 5000}, {"total", 10}, {"grants", 1}};
    Workspace old(legacy, [](auto&){});
    Check(old.document().at("groups")[0].at("temporaryPolicy").at("waitMinutes") == 0, "missing waitMinutes decodes as zero");
    Check(Snap(old, 4000).at("temporaryPolicy").at("waitMinutes") == 0, "snapshot emits waitMinutes");
    Check(!Blocked(old, 4000) && Snap(old, 4000).contains("suspendedUntil") && !Snap(old, 4000).contains("accessOpensAt"), "pause without opensAt is open since grant");
    Check(Blocked(old, 5000), "legacy pause still ends");
    // Validation of waitMinutes.
    int64_t t = 2000000; Json sink; Workspace v(Workspace::Empty(), [&](const Json& value){ sink = value; });
    for (const Json& bad : {Json(-1), Json(1441), Json(1.5), Json("10")}) {
        auto g = Group(); g["id"] = "bad"; g["temporaryPolicy"]["waitMinutes"] = bad;
        Reject([&]{ Run(v, {{"type", "saveGroup"}, {"group", g}}, t); }, "invalid waitMinutes rejected");
    }
    Run(v, {{"type", "saveGroup"}, {"group", WaitGroup(0)}}, t);
    auto longest = WaitGroup(0); longest["id"] = "max"; longest["temporaryPolicy"]["waitMinutes"] = 1440;
    Run(v, {{"type", "saveGroup"}, {"group", longest}}, t);
    Check(sink.at("groups").size() == 2 && sink.at("groups")[1].at("temporaryPolicy").at("waitMinutes") == 1440, "waitMinutes 0 and 1440 accepted");
    Run(v, {{"type", "saveGroup"}, {"group", Group()}}, t);
    Check(sink.at("groups")[0].at("temporaryPolicy").at("waitMinutes") == 0, "saved group without waitMinutes stores zero");
    Run(v, {{"type", "saveGroup"}, {"group", WaitGroup(30)}}, t);
    Reject([&]{ Run(v, {{"type", "saveGroup"}, {"group", WaitGroup(10)}}, t); }, "lowering the wait needs unlock");
    // SameOrStricter.
    Check(!Workspace::SameOrStricter(WaitGroup(30), WaitGroup(10)), "shorter wait weakens");
    Check(!Workspace::SameOrStricter(WaitGroup(10), Group()), "dropping the wait weakens");
    Check(Workspace::SameOrStricter(WaitGroup(10), WaitGroup(30)) && Workspace::SameOrStricter(WaitGroup(10), WaitGroup(10))
        && Workspace::SameOrStricter(Group(), WaitGroup(10)), "longer or equal wait is stricter");
    // Grant timing: blocked through the wait, open from opensAt until until.
    for (int wait : {10, 30}) {
        Fixture f(wait, t);
        auto c = Request(f.w, 30, t);
        Check(Mentions(c.at("detail"), "Access opens " + std::to_string(wait) + " minutes after you finish the passage, then lasts 30 minutes."), "challenge states the wait");
        auto reply = Submit(f.w, c, t);
        const int64_t opens = t + wait * 60, until = opens + 1800;
        Check(reply.at("message").get<std::string>() == "Temporary access opens at " + ISOTime(opens) + " and lasts until " + ISOTime(until) + ".", "grant reply names the opening");
        Check(f.pause().at("opensAt") == opens && f.pause().at("until") == until && f.pause().at("total") == 30, "pending pause recorded");
        Check(f.disk.at("history")[0].at("startedAt").get<std::string>() == ISOTime(opens) && f.disk.at("history")[0].at("endsAt").get<std::string>() == ISOTime(until), "history spans opensAt to until");
        auto g = Snap(f.w, t);
        Check(Blocked(f.w, t) && g.at("status") == "blocking", "still blocked right after the passage");
        Check(g.at("accessOpensAt").get<std::string>() == ISOTime(opens) && !g.contains("suspendedUntil"), "pending snapshot has accessOpensAt only");
        Check(g.at("now").at("state") == "waiting" && g.at("now").at("changesAt").get<std::string>() == ISOTime(opens) && Mentions(g.at("now").at("headline"), "Access opens at " + ISOTime(opens)), "pending snapshot is waiting");
        Check(Blocked(f.w, opens - 1) && !Snap(f.w, opens - 1).contains("suspendedUntil"), "blocked one second before opening");
        g = Snap(f.w, opens);
        Check(!Blocked(f.w, opens) && g.at("status") == "suspended" && g.at("suspendedUntil").get<std::string>() == ISOTime(until)
            && !g.contains("accessOpensAt") && !g.contains("now"), "open at opensAt");
        Check(Blocked(f.w, until) && !Snap(f.w, until).contains("suspendedUntil") && !Snap(f.w, until).contains("accessOpensAt"), "blocked again at until");
    }
    // Cancel while pending: no passage, blocking continues, counters kept.
    {
        Fixture f(10, t); Submit(f.w, Request(f.w, 10, t), t);
        auto reply = Run(f.w, {{"type", "cancelTemporaryAccess"}, {"groupID", "test"}}, t + 60);
        Check(!f.disk.at("pauses").contains("test") && !reply.at("snapshot").at("groups")[0].contains("accessOpensAt"), "cancel removes pending pause");
        Check(Blocked(f.w, t + 60) && Blocked(f.w, t + 600) && f.disk.at("backoff").at("test").at("grants") == 1, "cancelled pending grant never opens and is not refunded");
    }
    // Stacking: contiguous requests extend; a request that would leave a gap is refused.
    {
        Fixture f(10, t); Submit(f.w, Request(f.w, 10, t), t);                 // opens t+600, until t+1200
        auto c = Request(f.w, 10, t + 300);
        Check(Mentions(c.at("detail"), "extend access already scheduled to end at " + ISOTime(t + 1200)), "stacking detail names the end");
        Submit(f.w, c, t + 300);                                                 // new opening t+900 <= t+1200
        Check(f.pause().at("opensAt") == t + 600 && f.pause().at("until") == t + 1800 && f.pause().at("total") == 20 && f.pause().at("grants") == 2, "pending stack keeps opensAt and extends until");
        Check(Blocked(f.w, t + 599) && !Blocked(f.w, t + 600) && !Blocked(f.w, t + 1799) && Blocked(f.w, t + 1800), "stacked access is one contiguous window");
        Check(RejectsWith([&]{ Request(f.w, 10, t + 1500); }, "Access is already scheduled. Request more after it ends at " + ISOTime(t + 1800)), "gap refused before issuing a passage");
        auto late = Request(f.w, 10, t + 1100);                                  // t+1700 <= t+1800 when requested
        Check(RejectsWith([&]{ Submit(f.w, late, t + 1300); }, "Access is already scheduled"), "gap re-checked when the passage is accepted");
        Check(f.pause().at("until") == t + 1800 && f.pause().at("grants") == 2, "refused stack leaves the pause unchanged");
    }
    // Wait 0 keeps today's behaviour.
    {
        Fixture f(0, t); auto c = Request(f.w, 10, t);
        Check(!Mentions(c.at("detail"), "Access opens"), "no wait wording without a wait");
        auto reply = Submit(f.w, c, t);
        Check(reply.at("message").get<std::string>() == "Temporary access granted until " + ISOTime(t + 600) + ".", "zero wait reply unchanged");
        Check(!Blocked(f.w, t) && Snap(f.w, t).at("suspendedUntil").get<std::string>() == ISOTime(t + 600) && !Snap(f.w, t).contains("accessOpensAt"), "zero wait opens immediately");
        Submit(f.w, Request(f.w, 10, t + 300), t + 300);
        Check(f.pause().at("opensAt") == t && f.pause().at("until") == t + 1200 && f.disk.at("history")[1].at("startedAt").get<std::string>() == ISOTime(t + 300), "zero wait stacks as before");
        Check(Blocked(f.w, t + 1200), "zero wait pause ends");
    }
}
int main() {
    try {
        int64_t now = 1000000; Json disk = Workspace::Empty(); bool failSave = false;
        Workspace workspace(disk, [&](const Json& value){ if(failSave) throw std::runtime_error("disk full"); disk = value; });
        auto run = [&](Json command){ if (command.at("type") == "requestTemporaryAccess" && !command.contains("reflection")) command["reflection"] = "Read one intentional article"; if(!command.contains("revision")) command["revision"] = std::to_string(workspace.document().at("revision").get<uint64_t>()); return workspace.Handle(command, now, 2, 600); };
        run({{"type", "saveGroup"}, {"group", Group()}});
        Check(workspace.ActiveApplications(now, 2, 600).empty(), "save must not enable global enforcement");
        run({{"type", "setEnforcement"}, {"enabled", true}});
        Reject([&]{run({{"type", "requestTemporaryAccess"}, {"groupID", "test"}, {"minutes", 10}, {"reason", "conscious"}, {"reflection", "short"}});}, "short reflection rejected before issuing passage");
        Check(workspace.ActiveApplications(now, 2, 600).size() == 1, "enabled scheduled group active");
        auto weaker = Group(); weaker["enabled"] = false;
        Reject([&]{run({{"type","saveGroup"},{"group",weaker}});}, "weakening needs unlock");
        auto stronger = Group(); stronger["temporaryPolicy"]["resetDays"] = 4;
        Check(Workspace::SameOrStricter(Group(), stronger), "longer backoff is stricter");
        stronger["temporaryPolicy"]["resetDays"] = 1;
        Check(!Workspace::SameOrStricter(Group(), stronger), "shorter backoff weakens");
        auto noBackoff = Group(); noBackoff["temporaryPolicy"]["resetDays"] = nullptr;
        Check(Workspace::SameOrStricter(noBackoff, Group()), "enabling backoff needs no unlock");
        auto allowed = Group(); allowed["schedule"]["mode"] = "allow";
        Check(!Workspace::SameOrStricter(Group(), allowed), "inverting windows weakens");
        auto overnight = Group(); overnight["schedule"]["slots"] = {{{"id","x"},{"weekdays",{1}},{"startMinutes",1380},{"endMinutes",60}}};
        Check(Workspace::Scheduled(overnight, 1, 1400) && Workspace::Scheduled(overnight,2,30) && !Workspace::Scheduled(overnight,2,61), "overnight Sunday to Monday");
        auto challenge = run({{"type","requestTemporaryAccess"},{"groupID","test"},{"minutes",10},{"reason","conscious"}}).at("challenge");
        Reject([&]{run({{"type","submitChallenge"},{"challengeID",challenge.at("id")},{"typed","wrong"}});}, "wrong passage rejected");
        Check(workspace.ActiveApplications(now,2,600).size()==1, "request alone cannot grant");
        now += 29 * 60;
        run({{"type","submitChallenge"},{"challengeID",challenge.at("id")},{"typed",challenge.at("passage")}});
        Check(workspace.ActiveApplications(now,2,600).empty(), "successful temporary pause excludes group");
        Check(workspace.Snapshot(now,2,600).at("groups")[0].at("status") == "suspended", "pause displayed");
        Check(workspace.Snapshot(now,2,600).at("groups")[0].at("temporaryPassageWords") == 40,
              "snapshot shows escalated next passage rather than twenty-word base");
        Check(disk.at("history").size()==1 && disk.at("backoff").at("test").at("grants")==1, "history durable after grant");
        Reject([&]{run({{"type","submitChallenge"},{"challengeID",challenge.at("id")},{"typed",challenge.at("passage")}});}, "replay rejected");
        auto next = run({{"type","requestTemporaryAccess"},{"groupID","test"},{"minutes",60},{"reason","edulgence"}}).at("challenge");
        Reject([&]{run({{"type","submitChallenge"},{"challengeID",next.at("id")},{"typed",next.at("passage")}});}, "cumulative maximum checked on grant");
        now += 601;
        Check(workspace.ActiveApplications(now,2,600).size()==1, "pause expires without renderer");
        now += 1200;
        Reject([&]{run({{"type","submitChallenge"},{"challengeID",next.at("id")},{"typed",next.at("passage")}});}, "expired passage rejected");
        auto unlock = run({{"type","requestGroupUnlock"},{"groupID","test"}}).at("challenge");
        run({{"type","submitChallenge"},{"challengeID",unlock.at("id")},{"typed",unlock.at("passage")}});
        Check(workspace.Snapshot(now,2,600).at("groups")[0].at("canEdit")==true, "passage unlock opens window");
        failSave = true;
        auto revision = workspace.document().at("revision");
        Reject([&]{run({{"type","saveGroup"},{"group",weaker}});}, "disk failure propagated");
        Check(workspace.document().at("revision")==revision && workspace.ActiveApplications(now,2,600).size()==1, "failed commit retains enforcement");
        failSave = false;
        Reject([&]{run({{"type","saveGroup"},{"revision","1"},{"group",weaker}});}, "stale write rejected");
        auto domains = Group(); domains["domains"] = {"example.com"};
        Reject([&]{run({{"type","saveGroup"},{"group",domains}});}, "unsupported website not falsely saved");
        auto protectedApp = Group(); protectedApp["applications"] = {"C:\\Windows\\System32\\svchost.exe"};
        Reject([&]{run({{"type","saveGroup"},{"group",protectedApp}});}, "network system process protected");
        auto other = Group(); other["id"] = "other"; run({{"type","saveGroup"},{"group",other}});
        other["enabled"] = false;
        Reject([&]{run({{"type","saveGroup"},{"group",other}});}, "one group unlock cannot weaken another");
        auto disable = run({{"type","setEnforcement"},{"enabled",false}}).at("challenge");
        Check(workspace.document().at("enabled")==true, "disable request retains blocks");
        run({{"type","submitChallenge"},{"challengeID",disable.at("id")},{"typed",disable.at("passage")}});
        Check(workspace.ActiveApplications(now,2,600).empty(), "verified emergency disable works");
        Workspace restored(disk, [](auto&){});
        Check(restored.document().at("groups").size()==2 && restored.document().at("history").size()==1, "restart restores config and history");
        WaitTests();
        std::cout << checks << " workspace checks passed\n";
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
