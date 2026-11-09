#pragma once
#include <nlohmann/json.hpp>
#include <functional>
#include <string>
#include <vector>

namespace holdfast {
using Json = nlohmann::json;
// All times supplied by the trusted host. Renderer values never authorize a grant.
class Workspace {
public:
    using Save = std::function<void(const Json&)>;
    Workspace(Json document, Save save);
    static Json Empty();
    Json Handle(const Json& command, int64_t now, int weekday, int minute);
    Json Snapshot(int64_t now, int weekday, int minute) const;
    std::vector<std::string> ActiveApplications(int64_t now, int weekday, int minute) const;
    const Json& document() const { return document_; }
    static bool Scheduled(const Json& group, int weekday, int minute);
    static bool SameOrStricter(const Json& oldGroup, const Json& newGroup);
private:
    Json document_;
    Json challenges_ = Json::object();
    Save save_;
    void Commit(Json next);
    Json Challenge(const Json& command, int words, int64_t now, const std::string& title);
    Json ApplyChallenge(const Json& command, int64_t now);
    const Json& Group(const std::string& id) const;
    bool Unlocked(const Json& group, int64_t now) const;
    int PassageWords(const Json& group, int64_t now) const;
};
std::string ISOTime(int64_t seconds);
std::string NewIdentifier();
}
