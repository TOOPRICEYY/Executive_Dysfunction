#pragma once

#include "../include/guard_protocol.h"

// Atomically replaces this product's persistent ALE connect filters. These
// filters are visible to Windows Firewall tooling and removable by an
// administrator; they are not a stealth persistence mechanism.
bool ReplacePersistentWfpApplicationBlocks(const ED_GUARD_POLICY& policy);

