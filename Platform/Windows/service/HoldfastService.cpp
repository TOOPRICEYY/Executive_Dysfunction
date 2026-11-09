#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsvc.h>
#include <strsafe.h>
#include <cstdarg>
#include <cwchar>
#include <filesystem>
#include <fstream>
#include <string>
#include <chrono>
#include <memory>
#include <vector>
#include <algorithm>
#include "../core/Policy.h"
#include "../include/guard_protocol.h"
#include "WfpNetworkEnforcer.h"
#ifdef HOLDFAST_WORKSPACE
#include "WorkspaceService.h"
#endif

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
    // This development protocol is authored by the elevated local control
    // tool. Its trust boundary is the installer-protected directory ACL, NOT
    // the Apple JSON/HMAC format. No cloud input is accepted by this service.
    // Readers must share delete access so an atomic policy replacement is not
    // intermittently rejected while the service samples the previous file.
    HANDLE file = ::CreateFileW(PolicyPath().c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER size{};
    DWORD read = 0;
    const bool valid = ::GetFileSizeEx(file, &size) && size.QuadPart == sizeof(policy) &&
        ::ReadFile(file, &policy, static_cast<DWORD>(sizeof(policy)), &read, nullptr) && read == sizeof(policy);
    ::CloseHandle(file);
    return valid;
}

uint64_t Now() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::system_clock::now().time_since_epoch()).count());
}

void WriteStatus(const char* phase, const holdfast::PolicyState& state, size_t paths, DWORD error) {
    const auto target = PolicyPath().parent_path() / L"status.json";
    const auto temporary = PolicyPath().parent_path() / L"status.tmp";
    std::ofstream out(temporary, std::ios::trunc);
    out << "{\"schemaVersion\":1,\"capability\":\"application-network-only\",\"phase\":\"" << phase
        << "\",\"updatedAtUnixSeconds\":" << Now() << ",\"revision\":" << state.revision()
        << ",\"validUntilUnixSeconds\":" << state.deadline() << ",\"applications\":" << paths
        << ",\"filters\":" << paths * 2 << ",\"errorCode\":" << error << "}\n";
    out.close();
    if (out) ::MoveFileExW(temporary.c_str(), target.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
}

bool SafeResolvedPaths(const std::vector<std::u16string>& paths) {
    wchar_t windows[MAX_PATH]{};
    if (!::GetWindowsDirectoryW(windows, ARRAYSIZE(windows))) return false;
    std::wstring protectedRoot(windows);
    protectedRoot += L"\\";
    for (const auto& path : paths) {
        const std::wstring native(path.begin(), path.end());
        HANDLE file = ::CreateFileW(native.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) return false;
        wchar_t resolved[32768]{};
        const DWORD count = ::GetFinalPathNameByHandleW(file, resolved, ARRAYSIZE(resolved), FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
        ::CloseHandle(file);
        if (!count || count >= ARRAYSIZE(resolved)) return false;
        std::wstring canonical(resolved);
        if (canonical.starts_with(L"\\\\?\\")) canonical.erase(0, 4);
        // Refuse aliases/junctions and system images; the file WFP resolves must
        // be precisely the path the administrator reviewed.
        if (_wcsicmp(canonical.c_str(), native.c_str()) != 0 ||
            _wcsnicmp(canonical.c_str(), protectedRoot.c_str(), protectedRoot.size()) == 0) return false;
    }
    return true;
}

bool ReadAcceptedRevision(uint64_t& value) {
    value = 0;
    DWORD bytes = sizeof(value);
    const LSTATUS status = ::RegGetValueW(
        HKEY_LOCAL_MACHINE, kRegistryPath, kRevisionValue,
        RRF_RT_REG_QWORD, nullptr, &value, &bytes);
    return status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND;
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

    auto state = std::make_unique<holdfast::PolicyState>();
    auto policy = std::make_unique<ED_GUARD_POLICY>();
    auto enforcer = std::make_unique<WfpNetworkEnforcer>();
    std::vector<std::u16string> applied;
    uint64_t acceptedRevision = 0;
    if (!ReadAcceptedRevision(acceptedRevision)) {
        AppendDiagnostic(L"event=revision-barrier-unreadable");
        WriteStatus("error", *state, 0, ERROR_INVALID_DATA);
        ::CloseHandle(gStopEvent);
        SetState(SERVICE_STOPPED, ERROR_INVALID_DATA);
        return;
    }
    bool reconciled = false;
    DWORD lastError = ERROR_SUCCESS;
    uint64_t healthTick = 0;
#ifdef HOLDFAST_WORKSPACE
    std::unique_ptr<WorkspaceService> workspace;
    try { workspace = std::make_unique<WorkspaceService>(PolicyPath().parent_path(), gStopEvent, SafeResolvedPaths); }
    catch (...) { AppendDiagnostic(L"event=workspace-load-failed"); }
#endif
    while (::WaitForSingleObject(gStopEvent, 1000) == WAIT_TIMEOUT) {
        const auto now = Now();
        if (LoadPolicy(*policy)) {
            auto validation = holdfast::ValidatePolicy(*policy, sizeof(*policy), now, acceptedRevision);
            if (validation.valid && (policy->revision == acceptedRevision || SaveAcceptedRevision(policy->revision))) {
                state->Accept(*policy, sizeof(*policy), now);
                acceptedRevision = policy->revision;
            } else if (ShouldLogFailure()) {
                AppendDiagnostic(L"event=policy-rejected revision=%llu acceptedRevision=%llu", policy->revision, acceptedRevision);
            }
        }
        auto desired = state->ActivePaths(now);
#ifdef HOLDFAST_WORKSPACE
        if (workspace) {
            const auto groups = workspace->ActivePaths();
            desired.insert(desired.end(), groups.begin(), groups.end());
            std::sort(desired.begin(), desired.end());
            desired.erase(std::unique(desired.begin(), desired.end()), desired.end());
        }
#endif
        if (::GetTickCount64() - healthTick >= 5000) {
            healthTick = ::GetTickCount64();
            if (reconciled && !applied.empty() && !enforcer->Healthy()) reconciled = false;
        }
        if (!reconciled || desired != applied) {
            if (!SafeResolvedPaths(desired)) {
                // Invalid targets never leave an unrelated/stale set installed.
                enforcer.reset(); enforcer = std::make_unique<WfpNetworkEnforcer>();
                applied.clear(); reconciled = false; lastError = ERROR_INVALID_NAME;
            } else {
                const auto result = enforcer->Replace(desired);
                lastError = result.errorCode;
                reconciled = result.success;
                applied = result.success ? desired : std::vector<std::u16string>{};
                if (result.success || ShouldLogFailure()) AppendDiagnostic(
                    L"event=wfp-reconcile revision=%llu ruleCount=%lu wfpFilters=%lu success=%u stage=%ls error=%lu",
                    state->revision(), static_cast<unsigned long>(desired.size()), result.filtersAdded,
                    result.success ? 1u : 0u, result.stage, result.errorCode);
            }
        }
        WriteStatus(!reconciled ? "error" : applied.empty() ? "idle" : "enforcing", *state, applied.size(), lastError);
#ifdef HOLDFAST_WORKSPACE
        if (workspace) workspace->Acknowledge(reconciled, applied.size() * 2, lastError);
#endif
    }
    enforcer.reset(); // Dynamic WFP session deletion also works on process crash.
#ifdef HOLDFAST_WORKSPACE
    workspace.reset(); // Stop event cancels pending IPC before the service exits.
#endif
    WriteStatus("stopped", *state, 0, ERROR_SUCCESS);
    AppendDiagnostic(L"event=service-stop");
    ::CloseHandle(gStopEvent);
    SetState(SERVICE_STOPPED);
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc == 2 && std::wstring(argv[1]) == L"--recover") {
        const auto result = RemoveAllOwnedWfpFilters();
        return result.success ? 0 : static_cast<int>(result.errorCode);
    }
    SERVICE_TABLE_ENTRYW table[] = {
        {const_cast<wchar_t*>(kServiceName), ServiceMain},
        {nullptr, nullptr}
    };
    return ::StartServiceCtrlDispatcherW(table) ? 0 : static_cast<int>(::GetLastError());
}
