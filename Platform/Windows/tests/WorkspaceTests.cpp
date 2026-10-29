#include "Workspace.h"
#include <iostream>
#include <stdexcept>
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
        std::cout << checks << " workspace checks passed\n";
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
