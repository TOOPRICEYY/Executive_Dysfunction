#include "Policy.h"
#include <algorithm>
#include <cstring>
#include <iostream>
#include <stdexcept>

namespace {
int assertions = 0;
void Check(bool result, const char* message) {
    ++assertions;
    if (!result) throw std::runtime_error(message);
}
ED_GUARD_POLICY Policy(const std::u16string& path = u"C:\\Apps\\Browser\\browser.exe") {
    ED_GUARD_POLICY p{};
    p.version = ED_GUARD_POLICY_VERSION; p.ruleCount = 1; p.revision = 2;
    p.issuedAtUnixSeconds = 1000; p.validUntilUnixSeconds = 1015;
    std::copy(path.begin(), path.end(), p.rules[0].path);
    return p;
}
bool Valid(const ED_GUARD_POLICY& p) { return holdfast::ValidatePolicy(p, sizeof(p), 1000, 1).valid; }
}
int main() {
    try {
        auto p = Policy(); Check(Valid(p), "valid policy");
        Check(!holdfast::ValidatePolicy(p, sizeof(p) - 1, 1000, 1).valid, "truncated policy");
        Check(!holdfast::ValidatePolicy(p, sizeof(p) + 1, 1000, 1).valid, "trailing payload");
        p.version = 1; Check(!Valid(p), "reject unbounded legacy format");
        p = Policy(); p.ruleCount = 257; Check(!Valid(p), "rule count bounds");
        p = Policy(); p.revision = 0; Check(!Valid(p), "zero revision");
        p = Policy(); Check(!holdfast::ValidatePolicy(p, sizeof(p), 1000, 3).valid, "rollback");
        p = Policy(); p.validUntilUnixSeconds = 1000; Check(!Valid(p), "empty lease");
        p = Policy(); p.validUntilUnixSeconds = UINT64_MAX; Check(!Valid(p), "unbounded lease");
        p = Policy(); p.issuedAtUnixSeconds = 2000; Check(!Valid(p), "future issue");
        p = Policy(); std::fill(std::begin(p.rules[0].path), std::end(p.rules[0].path), u'x');
        Check(!Valid(p), "unterminated path");
        p = Policy(); p.rules[0].path[500] = u'x'; Check(!Valid(p), "hidden suffix");
        const std::u16string badPaths[] = {u"browser.exe", u"C:browser.exe", u"C:/browser.exe", u"\\\\host\\share\\app.exe",
            u"C:\\Apps\\..\\Windows\\app.exe", u"C:\\Apps\\.\\app.exe", u"C:\\Apps\\*\\app.exe",
            u"C:\\Apps\\app.exe:stream", u"C:\\Apps.\\app.exe", u"C:\\Apps \\app.exe",
            u"C:\\Windows\\System32\\svchost.exe", u"C:\\Apps\\holdfastctl.exe", u"C:\\Apps\\qemu-ga.exe",
            u"C:\\Apps\\wireguard.exe", u"C:\\Apps\\openvpn.exe", u"C:\\Apps\\svchost.exe"};
        for (const auto& path : badPaths) Check(!Valid(Policy(path)), "reject unsafe executable path");
        p = Policy(); p.ruleCount = 2; p.rules[1] = p.rules[0]; Check(!Valid(p), "duplicate executable");
        p = Policy(u"C:\\Apps\\\uD7FF.exe"); Check(Valid(p), "valid non-ASCII UTF16");
        p.rules[0].path[9] = static_cast<ED_GUARD_CHAR>(0xD800); Check(!Valid(p), "unpaired UTF16");
        holdfast::PolicyState state;
        Check(state.Accept(Policy(), sizeof(p), 1000).valid, "accept snapshot");
        Check(state.ActivePaths(1000).size() == 1, "active at exact start");
        Check(state.ActivePaths(1014).size() == 1, "active before deadline");
        Check(state.ActivePaths(1015).empty(), "expire without a file rewrite");
        Check(state.ActivePaths(999).empty(), "clock rollback does not prolong current enforcement");
        p = Policy(); p.ruleCount = 0;
        Check(state.Accept(p, sizeof(p), 1001).valid, "same revision can clear active snapshot");
        Check(state.ActivePaths(1001).empty(), "equal revision removal applied");
        p = Policy(); p.revision = 1;
        Check(!state.Accept(p, sizeof(p), 1001).valid, "stale data rejected");
        Check(state.ActivePaths(1001).empty(), "invalid update cannot mutate accepted state");
        std::cout << assertions << " policy checks passed\n";
        return 0;
    } catch (const std::exception& e) { std::cerr << "FAIL: " << e.what() << '\n'; return 1; }
}
