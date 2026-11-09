#include "Policy.h"
#include <algorithm>
#include <set>

namespace holdfast {
std::u16string NormalizePath(const ED_GUARD_CHAR* raw) {
    std::u16string result;
    for (size_t i = 0; i < ED_GUARD_MAX_PATH_CHARS && raw[i]; ++i) {
        char16_t c = static_cast<char16_t>(raw[i]);
        if (c >= u'A' && c <= u'Z') c += u'a' - u'A';
        result += c;
    }
    return result;
}

bool IsProtectedExecutable(const std::u16string& path) {
    if (path.size() < 4) return true;
    if (path.find(u"\\windows\\") != std::u16string::npos) return true;
    const auto filename = path.substr(path.find_last_of(u'\\') + 1);
    const std::u16string protectedNames[] = {
        u"svchost.exe", u"system", u"lsass.exe", u"services.exe", u"wininit.exe",
        u"winlogon.exe", u"csrss.exe", u"smss.exe", u"dns.exe", u"qemu-ga.exe",
        u"spice-webdavd.exe", u"vdservice.exe", u"vdagent.exe", u"msmpeng.exe",
        u"mpcmdrun.exe", u"sshd.exe", u"tailscaled.exe", u"wireguard.exe",
        u"openvpn.exe", u"forticlient.exe", u"fortiproxy.exe", u"vpnagent.exe"
    };
    return filename.starts_with(u"holdfast") ||
        std::find(std::begin(protectedNames), std::end(protectedNames), filename) != std::end(protectedNames);
}

Validation ValidatePolicy(const ED_GUARD_POLICY& p, size_t bytes, uint64_t now, uint64_t accepted) {
    if (bytes != sizeof(p)) return {false, "incorrect-size"};
    if (p.version != ED_GUARD_POLICY_VERSION) return {false, "unsupported-version"};
    if (!p.revision || p.revision < accepted) return {false, "revision-rollback"};
    if (p.ruleCount > ED_GUARD_MAX_RULES) return {false, "too-many-rules"};
    if (!p.issuedAtUnixSeconds || p.issuedAtUnixSeconds > now + 60) return {false, "invalid-issued-time"};
    if (p.validUntilUnixSeconds <= p.issuedAtUnixSeconds ||
        p.validUntilUnixSeconds - p.issuedAtUnixSeconds > ED_GUARD_MAX_LEASE_SECONDS)
        return {false, "invalid-lease"};
    std::set<std::u16string> seen;
    for (uint32_t i = 0; i < p.ruleCount; ++i) {
        const auto& raw = p.rules[i].path;
        size_t length = 0;
        while (length < ED_GUARD_MAX_PATH_CHARS && raw[length]) ++length;
        if (length == ED_GUARD_MAX_PATH_CHARS) return {false, "unterminated-path"};
        for (size_t j = length; j < ED_GUARD_MAX_PATH_CHARS; ++j)
            if (raw[j]) return {false, "hidden-path-suffix"};
        auto path = NormalizePath(raw);
        if (path.size() < 8 || path[0] < u'a' || path[0] > u'z' || path[1] != u':' || path[2] != u'\\' ||
            !path.ends_with(u".exe")) return {false, "not-absolute-executable"};
        if (path.find_first_of(u"/*?%\"<>|") != std::u16string::npos || path.find(u':', 2) != std::u16string::npos ||
            path.find(u"\\..\\") != std::u16string::npos || path.find(u"\\.\\") != std::u16string::npos ||
            path.find(u"\\\\") != std::u16string::npos) return {false, "ambiguous-path"};
        for (size_t j = 0; j < path.size(); ++j) {
            const auto c = path[j];
            if (c < 32 || c == 127) return {false, "control-character"};
            if (c >= 0xD800 && c <= 0xDBFF) {
                if (++j >= path.size() || path[j] < 0xDC00 || path[j] > 0xDFFF) return {false, "invalid-utf16"};
            } else if (c >= 0xDC00 && c <= 0xDFFF) return {false, "invalid-utf16"};
            if (c == u'\\' && j > 3 && (path[j - 1] == u'.' || path[j - 1] == u' ')) return {false, "ambiguous-path"};
        }
        if (IsProtectedExecutable(path)) return {false, "protected-network-or-recovery-process"};
        if (!seen.insert(path).second) return {false, "duplicate-path"};
    }
    return {true, "valid"};
}

Validation PolicyState::Accept(const ED_GUARD_POLICY& p, size_t bytes, uint64_t now) {
    auto result = ValidatePolicy(p, bytes, now, accepted_);
    if (result.valid) { policy_ = p; accepted_ = p.revision; }
    return result;
}

std::vector<std::u16string> PolicyState::ActivePaths(uint64_t now) const {
    std::vector<std::u16string> result;
    if (now < policy_.issuedAtUnixSeconds || now >= policy_.validUntilUnixSeconds) return result;
    for (uint32_t i = 0; i < policy_.ruleCount; ++i) result.push_back(NormalizePath(policy_.rules[i].path));
    std::sort(result.begin(), result.end());
    return result;
}
}
