#pragma once
#include <windows.h>
#include "../core/Workspace.h"
#include <filesystem>
#include <memory>
#include <mutex>
#include <thread>
inline constexpr wchar_t HoldfastWorkspacePipe[] = L"\\\\.\\pipe\\Holdfast.Workspace.v1";
class WorkspaceService {
public:
    WorkspaceService(std::filesystem::path directory, HANDLE stop, std::function<bool(const std::vector<std::u16string>&)> validate);
    ~WorkspaceService();
    std::vector<std::u16string> ActivePaths();
    void Acknowledge(bool success, size_t filterCount, DWORD error);
private:
    std::unique_ptr<holdfast::Workspace> workspace_;
    std::filesystem::path directory_;
    HANDLE stop_;
    std::thread server_;
    std::mutex mutex_;
    uint64_t acknowledgedRevision_ = 0;
    uint64_t plannedRevision_ = 0;
    DWORD error_ = ERROR_SUCCESS;
    size_t filters_ = 0;
    std::function<bool(const std::vector<std::u16string>&)> validate_;
    void Serve();
    holdfast::Json Handle(const holdfast::Json& request);
    void Save(const holdfast::Json& document);
};
