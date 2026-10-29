#pragma once

#include <stdint.h>
#if defined(_WIN32)
#if !defined(_KERNEL_MODE)
#include <windows.h>
#endif
#include <winioctl.h>
typedef wchar_t ED_GUARD_CHAR;
#else
typedef char16_t ED_GUARD_CHAR;
#endif

#define ED_GUARD_DEVICE_PATH L"\\\\.\\HoldfastGuard"
#define ED_GUARD_MAX_RULES 256
#define ED_GUARD_MAX_PATH_CHARS 520

#if defined(_WIN32)
#define IOCTL_ED_GUARD_REPLACE_POLICY \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_WRITE_DATA)
#endif

#define ED_GUARD_POLICY_VERSION 2
#define ED_GUARD_MAX_LEASE_SECONDS 86400

typedef struct _ED_GUARD_PATH_RULE {
    ED_GUARD_CHAR path[ED_GUARD_MAX_PATH_CHARS];
} ED_GUARD_PATH_RULE;

typedef struct _ED_GUARD_POLICY {
    uint32_t version;
    uint32_t ruleCount;
    uint64_t revision;
    uint64_t issuedAtUnixSeconds;
    uint64_t validUntilUnixSeconds;
    ED_GUARD_PATH_RULE rules[ED_GUARD_MAX_RULES];
} ED_GUARD_POLICY;

#if defined(__cplusplus)
static_assert(sizeof(ED_GUARD_CHAR) == 2, "Protocol requires UTF-16");
static_assert(sizeof(ED_GUARD_POLICY) == 32 + 256 * 520 * 2, "Unexpected policy layout");
#endif
