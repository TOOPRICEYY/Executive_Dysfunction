#pragma once

#include <winioctl.h>

#define ED_GUARD_DEVICE_PATH L"\\\\.\\ExecutiveDysfunctionGuard"
#define ED_GUARD_MAX_RULES 256
#define ED_GUARD_MAX_PATH_CHARS 520

#define IOCTL_ED_GUARD_REPLACE_POLICY \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_WRITE_DATA)

typedef struct _ED_GUARD_PATH_RULE {
    wchar_t path[ED_GUARD_MAX_PATH_CHARS];
} ED_GUARD_PATH_RULE;

typedef struct _ED_GUARD_POLICY {
    unsigned long version;
    unsigned long ruleCount;
    unsigned long long revision;
    ED_GUARD_PATH_RULE rules[ED_GUARD_MAX_RULES];
} ED_GUARD_POLICY;
