#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsvc.h>
#include <strsafe.h>
#include <filesystem>
#include <fstream>
#include <string>
#include "../include/guard_protocol.h"
#include "WfpNetworkEnforcer.h"

namespace {
constexpr wchar_t kServiceName[] = L"ExecutiveDysfunctionEnforcement";
constexpr wchar_t kRegistryPath[] = L"SOFTWARE\\ExecutiveDysfunction";
constexpr wchar_t kRevisionValue[] = L"AcceptedPolicyRevision";
SERVICE_STATUS_HANDLE gStatusHandle = nullptr;
HANDLE gStopEvent = nullptr;

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
    return std::filesystem::path(data) / L"ExecutiveDysfunction" / L"policy.bin";
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

    FILETIME lastWrite{};
    while (::WaitForSingleObject(gStopEvent, 2000) == WAIT_TIMEOUT) {
        WIN32_FILE_ATTRIBUTE_DATA attributes{};
        const auto path = PolicyPath();
        if (!::GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &attributes)) continue;
        if (::CompareFileTime(&attributes.ftLastWriteTime, &lastWrite) <= 0) continue;
        ED_GUARD_POLICY policy{};
        if (!LoadPolicy(policy)) continue;
        const auto acceptedRevision = AcceptedRevision();
        if (policy.revision < acceptedRevision) continue;
        ED_GUARD_POLICY kernelPolicy = policy;
        const bool kernelReady = NormalizePolicyForKernel(kernelPolicy)
            && SendPolicyToDriver(kernelPolicy);
        const bool needsPersistentUpdate = policy.revision > acceptedRevision;
        const bool networkReady = !needsPersistentUpdate
            || ReplacePersistentWfpApplicationBlocks(policy);
        const bool revisionReady = !needsPersistentUpdate
            || (kernelReady && networkReady && SaveAcceptedRevision(policy.revision));
        if (kernelReady && networkReady && revisionReady) lastWrite = attributes.ftLastWriteTime;
    }
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
