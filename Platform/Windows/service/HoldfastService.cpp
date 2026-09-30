#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsvc.h>
#include <strsafe.h>
#include <cstdarg>
#include <cwchar>
#include <filesystem>
#include <fstream>
#include <string>
#include "../include/guard_protocol.h"
#include "WfpNetworkEnforcer.h"

namespace {
constexpr wchar_t kServiceName[] = L"HoldfastEnforcement";
constexpr wchar_t kRegistryPath[] = L"SOFTWARE\\Holdfast";
constexpr wchar_t kRevisionValue[] = L"AcceptedPolicyRevision";
SERVICE_STATUS_HANDLE gStatusHandle = nullptr;
HANDLE gStopEvent = nullptr;
ULONGLONG gLastFailureLogTick = 0;

std::filesystem::path PolicyPath();

void AppendDiagnostic(const wchar_t* format, ...) {
    const auto directory = PolicyPath().parent_path();
    const auto current = directory / L"enforcement.log";
    const auto previous = directory / L"enforcement.previous.log";
    HANDLE file = ::CreateFileW(
        current.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;

    LARGE_INTEGER size{};
    if (::GetFileSizeEx(file, &size) && size.QuadPart >= 1024 * 1024) {
        ::CloseHandle(file);
        ::MoveFileExW(current.c_str(), previous.c_str(), MOVEFILE_REPLACE_EXISTING);
        file = ::CreateFileW(
            current.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) return;
    }

    SYSTEMTIME now{};
    ::GetSystemTime(&now);
    wchar_t message[1024]{};
    int prefix = ::StringCchPrintfW(
        message, ARRAYSIZE(message), L"%04u-%02u-%02uT%02u:%02u:%02u.%03uZ ",
        now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond, now.wMilliseconds
    ) == S_OK ? static_cast<int>(::wcslen(message)) : 0;
    va_list arguments;
    va_start(arguments, format);
    ::StringCchVPrintfW(message + prefix, ARRAYSIZE(message) - prefix, format, arguments);
    va_end(arguments);
    ::StringCchCatW(message, ARRAYSIZE(message), L"\r\n");
    DWORD written = 0;
    ::WriteFile(file, message, static_cast<DWORD>(::wcslen(message) * sizeof(wchar_t)), &written, nullptr);
    ::CloseHandle(file);
}

bool ShouldLogFailure() {
    const ULONGLONG now = ::GetTickCount64();
    if (gLastFailureLogTick != 0 && now - gLastFailureLogTick < 60'000) return false;
    gLastFailureLogTick = now;
    return true;
}

void SetState(DWORD state, DWORD error = NO_ERROR) {
    SERVICE_STATUS status{};
    status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    status.dwCurrentState = state;
    status.dwWin32ExitCode = error;
    status.dwControlsAccepted = state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP : 0;
    ::SetServiceStatus(gStatusHandle, &status);
}

std::filesystem::path PolicyPath() {
    wchar_t data[MAX_PATH]{};
    DWORD length = ::GetEnvironmentVariableW(L"ProgramData", data, ARRAYSIZE(data));
    if (!length || length >= ARRAYSIZE(data)) return {};
    return std::filesystem::path(data) / L"Holdfast" / L"policy.bin";
}

bool LoadPolicy(ED_GUARD_POLICY& policy) {
    // policy.bin is produced by the signed desktop client after it validates
    // the authenticated JSON envelope. The directory ACL must grant write only
    // to SYSTEM and Administrators; the service rechecks size/version/revision.
    std::ifstream input(PolicyPath(), std::ios::binary);
    if (!input.read(reinterpret_cast<char*>(&policy), sizeof(policy))) return false;
    if (policy.version != 1 || policy.revision == 0 || policy.ruleCount > ED_GUARD_MAX_RULES) {
        return false;
    }
    for (unsigned long index = 0; index < policy.ruleCount; ++index) {
        if (policy.rules[index].path[0] == L'\0'
            || policy.rules[index].path[ED_GUARD_MAX_PATH_CHARS - 1] != L'\0') return false;
    }
    return true;
}

unsigned long long AcceptedRevision() {
    unsigned long long value = 0;
    DWORD bytes = sizeof(value);
    const LSTATUS status = ::RegGetValueW(
        HKEY_LOCAL_MACHINE, kRegistryPath, kRevisionValue,
        RRF_RT_REG_QWORD, nullptr, &value, &bytes);
    return status == ERROR_SUCCESS ? value : 0;
}

bool SaveAcceptedRevision(unsigned long long value) {
    HKEY key = nullptr;
    DWORD disposition = 0;
    LSTATUS status = ::RegCreateKeyExW(
        HKEY_LOCAL_MACHINE, kRegistryPath, 0, nullptr, 0,
        KEY_SET_VALUE, nullptr, &key, &disposition);
    if (status != ERROR_SUCCESS) return false;
    status = ::RegSetValueExW(
        key, kRevisionValue, 0, REG_QWORD,
        reinterpret_cast<const BYTE*>(&value), sizeof(value));
    ::RegCloseKey(key);
    return status == ERROR_SUCCESS;
}

bool SendPolicyToDriver(const ED_GUARD_POLICY& policy) {
    HANDLE device = ::CreateFileW(
        ED_GUARD_DEVICE_PATH, GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL, nullptr);
    if (device == INVALID_HANDLE_VALUE) return false;
    DWORD returned = 0;
    BOOL ok = ::DeviceIoControl(
        device, IOCTL_ED_GUARD_REPLACE_POLICY,
        const_cast<ED_GUARD_POLICY*>(&policy), sizeof(policy),
        nullptr, 0, &returned, nullptr);
    ::CloseHandle(device);
    return ok == TRUE;
}

bool NormalizePathForKernel(wchar_t* path, size_t capacity) {
    // PS_CREATE_NOTIFY_INFO generally reports an NT device path while WFP's
    // app-id helper expects a Win32 path. Keep the file copy in Win32 form and
    // normalize only the copy sent to the process-creation driver.
    if (!path || capacity == 0 || path[0] == L'\0') return false;
    if (path[0] == L'\\' && path[1] != L'\\') return true;
    if (path[1] != L':') return false;

    wchar_t drive[3] = {path[0], L':', L'\0'};
    wchar_t device[ED_GUARD_MAX_PATH_CHARS]{};
    if (!::QueryDosDeviceW(drive, device, ARRAYSIZE(device))) return false;
    std::wstring normalized(device);
    normalized.append(path + 2);
    if (normalized.size() >= capacity) return false;
    ::StringCchCopyW(path, capacity, normalized.c_str());
    return true;
}

bool NormalizePolicyForKernel(ED_GUARD_POLICY& policy) {
    for (unsigned long index = 0; index < policy.ruleCount; ++index) {
        if (!NormalizePathForKernel(policy.rules[index].path, ED_GUARD_MAX_PATH_CHARS)) return false;
    }
    return true;
}

DWORD WINAPI ControlHandler(DWORD control, DWORD, void*, void*) {
    if (control == SERVICE_CONTROL_STOP) {
        SetState(SERVICE_STOP_PENDING);
        ::SetEvent(gStopEvent);
    }
    return NO_ERROR;
}

void WINAPI ServiceMain(DWORD, wchar_t**) {
    gStatusHandle = ::RegisterServiceCtrlHandlerExW(kServiceName, ControlHandler, nullptr);
    if (!gStatusHandle) return;
    gStopEvent = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!gStopEvent) { SetState(SERVICE_STOPPED, ::GetLastError()); return; }
    SetState(SERVICE_RUNNING);
    AppendDiagnostic(L"event=service-start");

    FILETIME lastWrite{};
    while (::WaitForSingleObject(gStopEvent, 2000) == WAIT_TIMEOUT) {
        WIN32_FILE_ATTRIBUTE_DATA attributes{};
        const auto path = PolicyPath();
        if (!::GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &attributes)) continue;
        if (::CompareFileTime(&attributes.ftLastWriteTime, &lastWrite) <= 0) continue;
        ED_GUARD_POLICY policy{};
        if (!LoadPolicy(policy)) {
            if (ShouldLogFailure()) AppendDiagnostic(L"event=policy-invalid");
            continue;
        }
        const auto acceptedRevision = AcceptedRevision();
        if (policy.revision < acceptedRevision) {
            if (ShouldLogFailure()) AppendDiagnostic(
                L"event=policy-rollback-rejected revision=%llu acceptedRevision=%llu",
                policy.revision, acceptedRevision);
            continue;
        }
        ED_GUARD_POLICY kernelPolicy = policy;
        const bool kernelReady = NormalizePolicyForKernel(kernelPolicy)
            && SendPolicyToDriver(kernelPolicy);
        const bool needsRevisionUpdate = policy.revision > acceptedRevision;
        // Equal revisions are intentionally retryable. They can also carry a
        // different active rule set when a schedule boundary rewrites the
        // policy snapshot without changing the authenticated policy revision.
        // Always reconcile WFP with the accepted snapshot; otherwise persistent
        // filters from the previous active window survive indefinitely.
        const WfpReplaceResult network = ReplacePersistentWfpApplicationBlocks(policy);
        const bool networkReady = network.success;
        const bool revisionReady = !needsRevisionUpdate
            || (kernelReady && networkReady && SaveAcceptedRevision(policy.revision));
        if (kernelReady && networkReady && revisionReady) {
            lastWrite = attributes.ftLastWriteTime;
            gLastFailureLogTick = 0;
            AppendDiagnostic(
                L"event=policy-applied revision=%llu acceptedRevision=%llu ruleCount=%lu wfpFilters=%lu",
                policy.revision, acceptedRevision, policy.ruleCount, network.filtersAdded);
        } else if (ShouldLogFailure()) {
            AppendDiagnostic(
                L"event=policy-apply-failed revision=%llu acceptedRevision=%llu ruleCount=%lu kernelReady=%u wfpReady=%u wfpStage=%ls wfpError=%lu revisionReady=%u",
                policy.revision, acceptedRevision, policy.ruleCount,
                kernelReady ? 1u : 0u, networkReady ? 1u : 0u,
                network.stage, network.errorCode, revisionReady ? 1u : 0u);
        }
    }
    AppendDiagnostic(L"event=service-stop");
    ::CloseHandle(gStopEvent);
    SetState(SERVICE_STOPPED);
}
} // namespace

int wmain() {
    SERVICE_TABLE_ENTRYW table[] = {
        {const_cast<wchar_t*>(kServiceName), ServiceMain},
        {nullptr, nullptr}
    };
    return ::StartServiceCtrlDispatcherW(table) ? 0 : static_cast<int>(::GetLastError());
}
