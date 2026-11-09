#pragma once
#include <windows.h>
#include <string>
#include <vector>

// Atomically replaces this service's dynamic ALE connect filters. Closing the
// engine (including service death) removes them. Only explicit application IDs
// can be blocked; no catch-all/IP/DNS filters are installed.
struct WfpReplaceResult {
    bool success;
    DWORD errorCode;
    const wchar_t* stage;
    unsigned long filtersAdded;
};

class WfpNetworkEnforcer {
public:
    WfpNetworkEnforcer() = default;
    ~WfpNetworkEnforcer();
    WfpNetworkEnforcer(const WfpNetworkEnforcer&) = delete;
    WfpNetworkEnforcer& operator=(const WfpNetworkEnforcer&) = delete;
    WfpReplaceResult Replace(const std::vector<std::u16string>& paths);
    bool Healthy() const;
private:
    HANDLE engine_ = nullptr;
    std::vector<UINT64> filters_;
};

// Explicit administrator recovery/migration only. Never delete another
// product's filters or change global firewall defaults.
WfpReplaceResult RemoveAllOwnedWfpFilters();
