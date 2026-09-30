#pragma once

#include "../include/guard_protocol.h"

// Atomically replaces this product's persistent ALE connect filters. These
// filters are visible to Windows Firewall tooling and removable by an
// administrator; they are not a stealth persistence mechanism.
struct WfpReplaceResult {
    bool success;
    DWORD errorCode;
    const wchar_t* stage;
    unsigned long filtersAdded;
};

WfpReplaceResult ReplacePersistentWfpApplicationBlocks(const ED_GUARD_POLICY& policy);
