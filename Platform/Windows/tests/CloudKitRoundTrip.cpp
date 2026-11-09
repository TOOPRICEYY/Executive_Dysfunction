#include "../ui/CloudKitConnection.h"
#include <windows.h>
#include <shlobj.h>
#include <fstream>

int main(int argc, char** argv) {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    wchar_t executable[32768]{}; GetModuleFileNameW(nullptr, executable, 32768);
    PWSTR folder = nullptr;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &folder))) return 1;
    const auto directory = std::filesystem::path(folder) / L"Holdfast" / L"CloudKitDevelopment";
    CoTaskMemFree(folder); std::filesystem::create_directories(directory);
    nlohmann::json result;
    try {
        CloudKitConnection connection(std::filesystem::path(executable).parent_path());
        if (argc == 3 && std::string(argv[1]) == "--inspect-record") result = connection.InspectTestRecord(argv[2]);
        else if (argc == 1) result = connection.RoundTrip();
        else throw std::runtime_error("Invalid test arguments.");
    } catch (...) { result = {{"state", "error"}, {"settingsSyncEnabled", false}, {"enforcementChanged", false}}; }
    std::ofstream(directory / (argc == 1 ? L"roundtrip-status.json" : L"record-inspection-status.json")) << result.dump(2);
    CoUninitialize();
    return result.value("state", "") == "roundTripPassed" ? 0 : 1;
}
