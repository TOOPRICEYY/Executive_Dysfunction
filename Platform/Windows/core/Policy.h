#pragma once
#include "../include/guard_protocol.h"
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace holdfast {
struct Validation {
    bool valid;
    const char* reason;
};
Validation ValidatePolicy(const ED_GUARD_POLICY&, size_t bytes, uint64_t now, uint64_t acceptedRevision);
bool IsProtectedExecutable(const std::u16string&);
std::u16string NormalizePath(const ED_GUARD_CHAR*);

/// Pure planner used by the Windows service and host-side tests. Expiry is
/// evaluated on every tick, not only when the policy file changes.
class PolicyState {
public:
    Validation Accept(const ED_GUARD_POLICY&, size_t bytes, uint64_t now);
    std::vector<std::u16string> ActivePaths(uint64_t now) const;
    uint64_t revision() const { return accepted_; }
    uint64_t deadline() const { return policy_.validUntilUnixSeconds; }
private:
    uint64_t accepted_ = 0;
    ED_GUARD_POLICY policy_{};
};
}
