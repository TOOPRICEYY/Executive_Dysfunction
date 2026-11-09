#include "WorkspaceService.h"
#include <sddl.h>
#include <codecvt>
#include <fstream>
#include <locale>
#include <ctime>

namespace {
using holdfast::Json;
struct Time { int64_t now; int day; int minute; };
Time Clock() {
    // A backwards clock change cannot prolong temporary grants in this process.
    static const int64_t started = static_cast<int64_t>(std::time(nullptr));
    static const ULONGLONG tick = GetTickCount64();
    const auto now = std::max<int64_t>(std::time(nullptr), started + (GetTickCount64() - tick) / 1000);
    const std::time_t date = now; std::tm local{}; localtime_s(&local, &date);
    return {now, local.tm_wday + 1, local.tm_hour * 60 + local.tm_min};
}
bool WaitIO(HANDLE pipe, OVERLAPPED& operation, HANDLE stop, DWORD timeout, DWORD& bytes) {
    HANDLE events[]{stop, operation.hEvent};
    const auto wait = WaitForMultipleObjects(2, events, FALSE, timeout);
    if (wait != WAIT_OBJECT_0 + 1) { CancelIoEx(pipe, &operation); WaitForSingleObject(operation.hEvent, INFINITE); return false; }
    return GetOverlappedResult(pipe, &operation, &bytes, FALSE) != FALSE;
}
bool Transfer(HANDLE pipe, void* buffer, DWORD length, bool write, HANDLE stop, DWORD& transferred) {
    OVERLAPPED operation{}; operation.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!operation.hEvent) return false;
    const auto result = write ? WriteFile(pipe, buffer, length, &transferred, &operation) : ReadFile(pipe, buffer, length, &transferred, &operation);
    const bool success = result || (GetLastError() == ERROR_IO_PENDING && WaitIO(pipe, operation, stop, 5000, transferred));
    CloseHandle(operation.hEvent); return success;
}
}
WorkspaceService::WorkspaceService(std::filesystem::path directory, HANDLE stop, std::function<bool(const std::vector<std::u16string>&)> validate) : directory_(std::move(directory)), stop_(stop), validate_(std::move(validate)) {
    const auto path = directory_ / L"workspace.json";
    auto document = holdfast::Workspace::Empty();
    if (std::filesystem::exists(path)) {
        if (std::filesystem::file_size(path) > 4 * 1024 * 1024) throw std::runtime_error("Workspace exceeds safety limit");
        std::ifstream input(path); document = Json::parse(input);
    }
    workspace_ = std::make_unique<holdfast::Workspace>(std::move(document), [this](const auto& value){ Save(value); });
    server_ = std::thread([this]{ Serve(); });
}
WorkspaceService::~WorkspaceService() { if (server_.joinable()) server_.join(); }
void WorkspaceService::Save(const Json& document) {
    const auto data = document.dump();
    if (data.size() > 4 * 1024 * 1024) throw std::runtime_error("Workspace is full; no changes saved");
    const auto target = directory_ / L"workspace.json", temporary = directory_ / L"workspace.new";
    // The installer protects this directory. Refuse reparse points at both leaf paths.
    for (const auto& path : {target, temporary}) {
        const auto attributes = GetFileAttributesW(path.c_str());
        if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) throw std::runtime_error("Refusing a redirected workspace file");
    }
    HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) throw std::runtime_error("Cannot create workspace transaction");
    DWORD written = 0;
    const bool saved = WriteFile(file, data.data(), static_cast<DWORD>(data.size()), &written, nullptr) && written == data.size() && FlushFileBuffers(file);
    CloseHandle(file);
    if (!saved || !MoveFileExW(temporary.c_str(), target.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) throw std::runtime_error("Cannot commit workspace; existing settings retained");
}
std::vector<std::u16string> WorkspaceService::ActivePaths() {
    std::lock_guard lock(mutex_); const auto time = Clock();
    plannedRevision_ = workspace_->document().at("revision").get<uint64_t>();
    std::vector<std::u16string> result; std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> codec;
    for (const auto& path : workspace_->ActiveApplications(time.now, time.day, time.minute)) result.push_back(codec.from_bytes(path));
    return result;
}
void WorkspaceService::Acknowledge(bool success, size_t filters, DWORD error) {
    std::lock_guard lock(mutex_);
    acknowledgedRevision_ = success ? plannedRevision_ : 0;
    filters_ = filters; error_ = error;
}
Json WorkspaceService::Handle(const Json& request) {
    std::lock_guard lock(mutex_); const auto time = Clock();
    Json reply{{"version", 1}, {"id", request.value("id", "")}, {"ok", false}};
    try {
        if (request.at("version") != 1 || !request.at("id").is_string() || request.at("id").get<std::string>().size() != 36) throw std::runtime_error("Invalid protocol request");
        if (request.at("command").at("type") == "saveGroup") {
            std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> codec;
            std::vector<std::u16string> paths;
            for (const auto& path : request.at("command").at("group").at("applications")) paths.push_back(codec.from_bytes(path.get<std::string>()));
            if (!validate_(paths)) throw std::runtime_error("One of these application files is missing, protected, or redirected. Choose the installed executable again.");
        }
        auto result = workspace_->Handle(request.at("command"), time.now, time.day, time.minute);
        if (result.contains("snapshot")) {
            auto& snapshot = result["snapshot"];
            const bool acknowledged = acknowledgedRevision_ == workspace_->document().at("revision").get<uint64_t>();
            snapshot["enforcement"] = {{"state", error_ != 0 ? "error" : !acknowledged ? "unknown" : filters_ > 0 ? "active" : "disabled"},
                {"title", error_ != 0 ? "Application filters need attention" : !acknowledged ? "Applying changes" : filters_ > 0 ? "Application networking blocked" : "Application filters idle"},
                {"detail", "Selected application networking only. Websites and all-device sync are not connected on Windows. Active WFP filters: " + std::to_string(filters_) + "."}};
            if (!acknowledged || error_ != 0) for (auto& group : snapshot["groups"]) if (group["status"] == "blocking") {
                group["status"] = "unsupported"; group["detail"] = "Waiting for a successful filter acknowledgement; blocking is not confirmed.";
            }
        }
        reply["ok"] = true; reply["result"] = result;
    } catch (const std::exception& error) { reply["error"] = error.what(); }
    return reply;
}
void WorkspaceService::Serve() {
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)", SDDL_REVISION_1, &descriptor, nullptr)) return;
    SECURITY_ATTRIBUTES security{sizeof(security), descriptor, FALSE};
    while (WaitForSingleObject(stop_, 0) == WAIT_TIMEOUT) {
        HANDLE pipe = CreateNamedPipeW(HoldfastWorkspacePipe, PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
            PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 4 * 1024 * 1024, 512 * 1024, 5000, &security);
        if (pipe == INVALID_HANDLE_VALUE) break;
        OVERLAPPED connect{}; connect.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        DWORD unused = 0;
        bool connected = ConnectNamedPipe(pipe, &connect) != FALSE;
        if (!connected) { const auto error = GetLastError(); connected = error == ERROR_PIPE_CONNECTED || (error == ERROR_IO_PENDING && WaitIO(pipe, connect, stop_, INFINITE, unused)); }
        CloseHandle(connect.hEvent);
        if (connected) {
            std::string input(512 * 1024, '\0'); DWORD bytes = 0;
            if (Transfer(pipe, input.data(), static_cast<DWORD>(input.size()), false, stop_, bytes)) {
                try {
                    auto response = Handle(Json::parse(input.data(), input.data() + bytes)).dump();
                    if (response.size() <= 4 * 1024 * 1024 && Transfer(pipe, response.data(), static_cast<DWORD>(response.size()), true, stop_, bytes)) {
                        // DisconnectNamedPipe discards unread outgoing bytes,
                        // even after an overlapped WriteFile completes. A bounded
                        // receipt avoids both lost replies and an unbounded
                        // FlushFileBuffers against a stalled client.
                        char receipt = 0;
                        Transfer(pipe, &receipt, 1, false, stop_, bytes);
                    }
                } catch (...) { /* malformed request: no state changes, disconnect */ }
            }
        }
        DisconnectNamedPipe(pipe); CloseHandle(pipe);
    }
    LocalFree(descriptor);
}
