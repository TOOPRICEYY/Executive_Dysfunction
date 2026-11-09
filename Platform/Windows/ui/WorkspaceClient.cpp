#include "WorkspaceClient.h"
#include <windows.h>
#include <stdexcept>
#include <string>
namespace {
bool Transfer(HANDLE pipe, void* buffer, DWORD size, bool write, DWORD& bytes) {
    OVERLAPPED operation{}; operation.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!operation.hEvent) return false;
    bool success = (write ? WriteFile(pipe, buffer, size, &bytes, &operation) : ReadFile(pipe, buffer, size, &bytes, &operation)) != FALSE;
    if (!success && GetLastError() == ERROR_IO_PENDING) {
        if (WaitForSingleObject(operation.hEvent, 5000) != WAIT_OBJECT_0) CancelIoEx(pipe, &operation);
        success = GetOverlappedResult(pipe, &operation, &bytes, TRUE) != FALSE;
    }
    CloseHandle(operation.hEvent); return success;
}
bool TrustedServer(HANDLE pipe) {
    ULONG pid = 0;
    if (!GetNamedPipeServerProcessId(pipe, &pid)) return false;
    auto manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
    if (!manager) return false;
    auto service = OpenServiceW(manager, L"HoldfastEnforcement", SERVICE_QUERY_STATUS);
    SERVICE_STATUS_PROCESS status{}; DWORD bytes = 0;
    const bool trusted = service && QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO,
        reinterpret_cast<BYTE*>(&status), sizeof(status), &bytes) && status.dwCurrentState == SERVICE_RUNNING && status.dwProcessId == pid;
    if (service) CloseServiceHandle(service); CloseServiceHandle(manager); return trusted;
}
}
nlohmann::json CallWorkspace(const nlohmann::json& request) {
    constexpr auto name = L"\\\\.\\pipe\\Holdfast.Workspace.v1";
    if (!WaitNamedPipeW(name, 3000)) throw std::runtime_error("The Holdfast service is unavailable. Start it before editing settings.");
    HANDLE pipe = CreateFileW(name, GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
        FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
    if (pipe == INVALID_HANDLE_VALUE) throw std::runtime_error("Cannot connect to the Holdfast service.");
    try {
        if (!TrustedServer(pipe)) throw std::runtime_error("Refusing an unverified service connection.");
        DWORD mode = PIPE_READMODE_MESSAGE;
        if (!SetNamedPipeHandleState(pipe, &mode, nullptr, nullptr)) throw std::runtime_error("Cannot configure service connection.");
        auto input = request.dump(); DWORD bytes = 0;
        if (input.size() > 512 * 1024 || !Transfer(pipe, input.data(), static_cast<DWORD>(input.size()), true, bytes) || bytes != input.size())
            throw std::runtime_error("The service did not receive this request. Refresh before retrying.");
        std::string output(4 * 1024 * 1024, '\0');
        if (!Transfer(pipe, output.data(), static_cast<DWORD>(output.size()), false, bytes)) throw std::runtime_error("No service acknowledgement. Refresh before retrying; the request may already have completed.");
        auto reply = nlohmann::json::parse(output.data(), output.data() + bytes);
        char receipt = 1; Transfer(pipe, &receipt, 1, true, bytes);
        CloseHandle(pipe); return reply;
    } catch (...) { CloseHandle(pipe); throw; }
}
