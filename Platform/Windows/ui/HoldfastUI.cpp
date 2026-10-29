// Native window, origin boundary and read-only status adapter only.
// Screens, forms, themes and interactions all live in /SharedUI.
#include <windows.h>
#include <shlobj.h>
#include <wrl.h>
#include <WebView2.h>
#include <nlohmann/json.hpp>
#include <filesystem>
#include <fstream>
#include <ctime>
#include <string>
#include <thread>
#include "WorkspaceClient.h"

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Json = nlohmann::json;
namespace fs = std::filesystem;
namespace {
constexpr auto origin = L"https://holdfast.invalid/index.html";
ComPtr<ICoreWebView2Controller> controller;
ComPtr<ICoreWebView2> webview;
fs::path executableDirectory;
bool smokeTest = false, gotSnapshot = false;
bool workspaceConnected = false;
unsigned smokeTicks = 0;
HWND mainWindow = nullptr;
constexpr UINT replyMessage = WM_APP + 1;
std::string Utf8(const std::wstring& value);

Json PickApplications() {
    ComPtr<IFileOpenDialog> dialog;
    if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog)))) throw std::runtime_error("Cannot open application picker.");
    DWORD options; dialog->GetOptions(&options);
    dialog->SetOptions(options | FOS_ALLOWMULTISELECT | FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST);
    COMDLG_FILTERSPEC filter{L"Windows applications", L"*.exe"}; dialog->SetFileTypes(1, &filter);
    dialog->SetTitle(L"Choose applications whose networking Holdfast will block");
    const auto selected = dialog->Show(mainWindow);
    if (selected == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return {{"message", "Application selection cancelled."}};
    if (FAILED(selected)) throw std::runtime_error("Application picker failed.");
    ComPtr<IShellItemArray> items; dialog->GetResults(&items); DWORD count; items->GetCount(&count);
    Json paths = Json::array();
    for (DWORD i = 0; i < count; ++i) {
        ComPtr<IShellItem> item; items->GetItemAt(i, &item); PWSTR path = nullptr;
        if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) { paths.push_back(Utf8(path)); CoTaskMemFree(path); }
    }
    return {{"applications", paths}};
}

std::string Utf8(const std::wstring& value) {
    const int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    std::string result(length, '\0');
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), length, nullptr, nullptr);
    return result;
}
std::wstring Wide(const std::string& value) {
    const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
    std::wstring result(length, L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), length);
    return result;
}
fs::path KnownFolder(REFKNOWNFOLDERID id) {
    PWSTR value = nullptr;
    if (FAILED(SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, nullptr, &value))) throw std::runtime_error("Known folder unavailable");
    fs::path result(value); CoTaskMemFree(value); return result;
}
bool ServiceRunning() {
    auto manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
    if (!manager) return false;
    auto service = OpenServiceW(manager, L"HoldfastEnforcement", SERVICE_QUERY_STATUS);
    SERVICE_STATUS_PROCESS state{}; DWORD bytes = 0;
    const bool running = service && QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO,
        reinterpret_cast<BYTE*>(&state), sizeof(state), &bytes) && state.dwCurrentState == SERVICE_RUNNING;
    if (service) CloseServiceHandle(service); CloseServiceHandle(manager);
    return running;
}
Json Snapshot() {
    Json snapshot = {
        {"schema", 1}, {"revision", "windows-unavailable"}, {"platform", "windows"}, {"capabilities", Json::array()},
        {"enforcement", {{"state", "unknown"}, {"title", "Service status unavailable"},
            {"detail", "The shared interface is connected. Group editing and website filtering are not connected to the Windows host yet."}}},
        {"sync", {{"state", "unavailable"}, {"detail", "Apple cross-device sync is not connected to this Windows build."}}},
        {"groups", Json::array()}, {"retreats", Json::array()}, {"bypasses", Json::array()}, {"lockdown", nullptr}
    };
    try {
        auto statusPath = KnownFolder(FOLDERID_ProgramData) / L"Holdfast" / L"status.json";
        if (!fs::exists(statusPath) || fs::file_size(statusPath) > 65536) return snapshot;
        std::ifstream stream(statusPath); auto status = Json::parse(stream);
        const auto revision = status.at("revision").get<unsigned long long>();
        const auto phase = status.at("phase").get<std::string>();
        const auto updated = status.at("updatedAtUnixSeconds").get<long long>();
        const auto now = static_cast<long long>(std::time(nullptr));
        snapshot["revision"] = std::to_string(revision);
        const bool running = ServiceRunning();
        const bool fresh = updated <= now + 2 && updated >= now - 10;
        auto& enforcement = snapshot["enforcement"];
        if (!running) {
            enforcement["state"] = "disabled"; enforcement["title"] = "Application service is stopped";
        } else if (!fresh) {
            enforcement["state"] = "unknown"; enforcement["title"] = "Waiting for fresh service status";
        } else if (phase == "idle") {
            enforcement["state"] = "disabled"; enforcement["title"] = "Application blocking is idle";
        } else if (phase == "enforcing" && status.value("errorCode", 0) == 0) {
            enforcement["state"] = "active"; enforcement["title"] = "Application-network filters active";
        } else {
            enforcement["state"] = "error"; enforcement["title"] = "Application service needs attention";
        }
        enforcement["detail"] = "Service phase: " + phase + ". Reported filters: " + std::to_string(status.at("filters").get<unsigned>())
            + ". This is application-network enforcement only; websites, group editing and sync are not connected yet.";
    } catch (...) { /* Never infer active enforcement from corrupt or inaccessible state. */ }
    return snapshot;
}
void Fail(const wchar_t* message) {
    if (smokeTest) { std::ofstream(executableDirectory / "ui-smoke.json") << Json({{"ok", false}, {"error", Utf8(message)}}).dump(); }
    else MessageBoxW(mainWindow, message, L"Holdfast", MB_OK | MB_ICONERROR);
    PostQuitMessage(1);
}
void Attach(ICoreWebView2Controller* created) {
    controller = created; controller->get_CoreWebView2(&webview);
    RECT bounds; GetClientRect(mainWindow, &bounds); controller->put_Bounds(bounds);
    ComPtr<ICoreWebView2Settings> settings; webview->get_Settings(&settings);
    settings->put_AreDevToolsEnabled(FALSE); settings->put_AreDefaultContextMenusEnabled(FALSE);
    settings->put_AreHostObjectsAllowed(FALSE); settings->put_IsStatusBarEnabled(FALSE);
    ComPtr<ICoreWebView2_3> mapping;
    if (FAILED(webview.As(&mapping)) || FAILED(mapping->SetVirtualHostNameToFolderMapping(
        L"holdfast.invalid", (executableDirectory / L"SharedUI").c_str(), COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY))) {
        Fail(L"The installed WebView2 runtime cannot load Holdfast's local interface."); return;
    }
    EventRegistrationToken token{};
    webview->add_NavigationStarting(Callback<ICoreWebView2NavigationStartingEventHandler>([](auto*, auto* args) -> HRESULT {
        LPWSTR uri = nullptr; args->get_Uri(&uri);
        if (!uri || std::wstring(uri) != origin) args->put_Cancel(TRUE);
        CoTaskMemFree(uri); return S_OK;
    }).Get(), &token);
    webview->add_FrameNavigationStarting(Callback<ICoreWebView2NavigationStartingEventHandler>([](auto*, auto* args) -> HRESULT {
        args->put_Cancel(TRUE); return S_OK;
    }).Get(), &token);
    webview->add_NewWindowRequested(Callback<ICoreWebView2NewWindowRequestedEventHandler>([](auto*, auto* args) -> HRESULT {
        args->put_Handled(TRUE); return S_OK;
    }).Get(), &token);
    webview->add_PermissionRequested(Callback<ICoreWebView2PermissionRequestedEventHandler>([](auto*, auto* args) -> HRESULT {
        args->put_State(COREWEBVIEW2_PERMISSION_STATE_DENY); return S_OK;
    }).Get(), &token);
    webview->add_WebMessageReceived(Callback<ICoreWebView2WebMessageReceivedEventHandler>([](auto*, auto* args) -> HRESULT {
        LPWSTR source = nullptr, text = nullptr; args->get_Source(&source);
        const bool trusted = source && std::wstring(source) == origin; CoTaskMemFree(source);
        if (!trusted) return S_OK;
        if (FAILED(args->get_WebMessageAsJson(&text)) || !text) return S_OK;
        const std::wstring input(text); CoTaskMemFree(text);
        if (input.size() > 512 * 1024) return S_OK;
        try {
            const auto request = Json::parse(Utf8(input));
            if (request.at("version") != 1 || !request.at("id").is_string()) return S_OK;
            const auto id = request.at("id").get<std::string>();
            if (id.size() != 36) return S_OK;
            if (request.at("command").at("type") == "pickApplications") {
                Json reply{{"version",1},{"id",id},{"ok",true}};
                try { reply["result"] = PickApplications(); }
                catch(const std::exception& error) { reply["ok"] = false; reply["error"] = error.what(); }
                webview->PostWebMessageAsJson(Wide(reply.dump()).c_str());
                return S_OK;
            }
            const HWND target = mainWindow;
            std::thread([request, target, id] {
                Json reply;
                try { reply = CallWorkspace(request); reply["workspaceConnected"] = true; }
                catch(const std::exception& error) {
                    if(request.at("command").at("type") == "snapshot") {
                        auto snapshot = Snapshot();
                        snapshot["enforcement"]["detail"] = std::string(error.what()) + " The installed service must include the workspace backend. No settings were changed.";
                        reply = {{"version",1},{"id",id},{"ok",true},{"result",{{"snapshot",snapshot}}}};
                    } else reply = {{"version",1},{"id",id},{"ok",false},{"error",error.what()}};
                }
                auto result = new Json(std::move(reply));
                if(!PostMessageW(target, replyMessage, 0, reinterpret_cast<LPARAM>(result))) delete result;
            }).detach();
        } catch (...) { /* Malformed requests have no native side effects. */ }
        return S_OK;
    }).Get(), &token);
    webview->Navigate(origin);
}
LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == replyMessage) {
        std::unique_ptr<Json> reply(reinterpret_cast<Json*>(lparam));
        if (webview) {
            if(reply->value("ok",false) && reply->contains("result") && (*reply)["result"].contains("snapshot")) {
                gotSnapshot = true; workspaceConnected = reply->value("workspaceConnected",false);
            }
            reply->erase("workspaceConnected"); webview->PostWebMessageAsJson(Wide(reply->dump()).c_str());
        }
        return 0;
    }
    if (message == WM_SIZE && controller) { RECT bounds; GetClientRect(window, &bounds); controller->put_Bounds(bounds); return 0; }
    if (message == WM_TIMER && smokeTest) {
        if (++smokeTicks > 20) { KillTimer(window, 1); Fail(L"The shared UI did not render and acknowledge its host within 20 seconds."); }
        else if (gotSnapshot && webview) {
            webview->ExecuteScript(L"document.querySelector('h1')?.textContent === 'Status' && !document.querySelector('[role=alert]')",
                Callback<ICoreWebView2ExecuteScriptCompletedHandler>([window](HRESULT result, LPCWSTR json) -> HRESULT {
                    if (SUCCEEDED(result) && json && std::wstring(json) == L"true") {
                        KillTimer(window, 1);
                        std::ofstream(executableDirectory / "ui-smoke.json") << Json({{"ok", true}, {"sharedUIRendered", true}, {"nativeSnapshotAcknowledged", true}, {"workspaceConnected", workspaceConnected}, {"noMutationsPerformed", true}}).dump();
                        PostMessageW(window, WM_CLOSE, 0, 0);
                    } return S_OK;
                }).Get());
        } return 0;
    }
    if (message == WM_DESTROY) { if (controller) controller->Close(); PostQuitMessage(0); return 0; }
    return DefWindowProcW(window, message, wparam, lparam);
}
}
int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR arguments, int show) {
    smokeTest = std::wstring(arguments) == L"--smoke-test";
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) return 1;
    wchar_t module[32768]{}; GetModuleFileNameW(nullptr, module, 32768); executableDirectory = fs::path(module).parent_path();
    if (!fs::exists(executableDirectory / L"SharedUI" / L"index.html")) { Fail(L"The shared interface assets are missing. Rebuild or reinstall the complete UI package."); return 1; }
    WNDCLASSW windowClass{}; windowClass.lpfnWndProc = WindowProc; windowClass.hInstance = instance;
    windowClass.lpszClassName = L"HoldfastSharedUI"; windowClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    windowClass.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(101)); RegisterClassW(&windowClass);
    mainWindow = CreateWindowExW(0, windowClass.lpszClassName, L"Holdfast — Shared interface development", WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT, 1280, 900, nullptr, nullptr, instance, nullptr);
    if (!mainWindow) return 1;
    ShowWindow(mainWindow, show);
    try {
        auto profile = KnownFolder(FOLDERID_LocalAppData) / L"Holdfast" / L"SharedUI-WebView2";
        const auto result = CreateCoreWebView2EnvironmentWithOptions(nullptr, profile.c_str(), nullptr,
            Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>([](HRESULT hr, ICoreWebView2Environment* environment) -> HRESULT {
                if (FAILED(hr) || !environment) { Fail(L"WebView2 could not start. Install or repair Microsoft's Evergreen WebView2 Runtime."); return S_OK; }
                environment->CreateCoreWebView2Controller(mainWindow,
                    Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>([](HRESULT result, ICoreWebView2Controller* created) -> HRESULT {
                        if (FAILED(result) || !created) Fail(L"Holdfast could not create its shared interface window."); else Attach(created);
                        return S_OK;
                    }).Get());
                return S_OK;
            }).Get());
        if (FAILED(result)) { Fail(L"WebView2 is unavailable. Install Microsoft's Evergreen WebView2 Runtime."); return 1; }
    } catch (...) { Fail(L"Holdfast's local interface profile could not be opened."); return 1; }
    if (smokeTest) SetTimer(mainWindow, 1, 1000, nullptr);
    MSG message{}; while (GetMessageW(&message, nullptr, 0, 0) > 0) { TranslateMessage(&message); DispatchMessageW(&message); }
    webview.Reset(); controller.Reset(); CoUninitialize(); return static_cast<int>(message.wParam);
}
