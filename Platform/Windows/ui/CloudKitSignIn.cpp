// Isolated development sign-in harness, not the privileged enforcement host.
// No settings are imported, published, unlocked or applied by this program.
#include "CloudKitConnection.h"
#include <windows.h>
#include <winhttp.h>
#include <shlobj.h>
#include <wrl.h>
#include <WebView2.h>
#include <fstream>
#include <memory>
#include <thread>

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Json = nlohmann::json;
namespace fs = std::filesystem;
namespace {
std::shared_ptr<CloudKitConnection> connection;
ComPtr<ICoreWebView2Controller> controller;
ComPtr<ICoreWebView2> view;
fs::path localDirectory;
HWND window = nullptr;
bool probeOnly = false, authenticating = false, awaitingCallback = false;
constexpr UINT completedMessage = WM_APP + 71;
std::string Utf8(const wchar_t* value) {
    const int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, nullptr, 0, nullptr, nullptr);
    if (count <= 0) return {};
    std::string result(count, 0);
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, result.data(), count, nullptr, nullptr);
    result.pop_back(); return result;
}
std::wstring Wide(const std::string& value) {
    const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), int(value.size()), nullptr, 0);
    std::wstring result(count, 0);
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), int(value.size()), result.data(), count);
    return result;
}
void Report(const Json& result) {
    // Deliberately no account ID, token, sign-in URL or callback in diagnostics.
    Json safe{{"state", result.value("state", "error")}, {"environment", "development"},
        {"settingsSyncEnabled", false}, {"enforcementChanged", false}};
    if (result.contains("error")) safe["error"] = result.at("error");
    if (result.contains("blockedHost")) safe["blockedHost"] = result.at("blockedHost");
    std::ofstream(localDirectory / L"connection-status.json", std::ios::trunc) << safe.dump(2);
}
void Dispatch(const std::string& callback = {}) {
    const auto current = connection; const HWND target = window;
    std::thread([current, target, callback] {
        Json result;
        try { result = callback.empty() ? current->Check() : current->Authenticate(callback); }
        catch (const std::exception&) {
            // Library/JSON errors can contain response fragments. Do not log them.
            result = {{"state", "error"}, {"error", "The iCloud connection could not be verified. No blocking settings were changed."}};
        }
        auto message = new Json(std::move(result));
        if (!PostMessageW(target, completedMessage, 0, reinterpret_cast<LPARAM>(message))) delete message;
    }).detach();
}
bool ConsumeCallback(const std::string& url) {
    if (!CloudKitConnection::IsCallback(url)) return false;
    if (awaitingCallback && !authenticating) {
        authenticating = true; awaitingCallback = false;
        SetWindowTextW(window, L"Holdfast — Verifying iCloud development connection…");
        Report({{"state", "verifying"}});
        Dispatch(url);
    }
    return true;
}
void Attach(ICoreWebView2Controller* created, const std::wstring& signIn) {
    controller = created; controller->get_CoreWebView2(&view);
    RECT bounds; GetClientRect(window, &bounds); controller->put_Bounds(bounds);
    ComPtr<ICoreWebView2Settings> settings; view->get_Settings(&settings);
    settings->put_AreHostObjectsAllowed(FALSE); settings->put_IsWebMessageEnabled(FALSE);
    settings->put_AreDevToolsEnabled(FALSE); settings->put_AreDefaultContextMenusEnabled(FALSE);
    settings->put_IsStatusBarEnabled(TRUE);
    ComPtr<ICoreWebView2Settings4> privacy;
    if (SUCCEEDED(settings.As(&privacy))) {
        privacy->put_IsPasswordAutosaveEnabled(FALSE); privacy->put_IsGeneralAutofillEnabled(FALSE);
    }
    EventRegistrationToken token{};
    view->add_NavigationStarting(Callback<ICoreWebView2NavigationStartingEventHandler>([](auto*, auto* args) -> HRESULT {
        LPWSTR address = nullptr; args->get_Uri(&address);
        const auto url = address ? Utf8(address) : std::string(); CoTaskMemFree(address);
        if (ConsumeCallback(url)) {
            args->put_Cancel(TRUE);
        } else if (!CloudKitConnection::IsAppleSignInURL(url)) {
            args->put_Cancel(TRUE);
            auto address = Wide(url);
            URL_COMPONENTS parsed{}; parsed.dwStructSize = sizeof(parsed); parsed.dwHostNameLength = DWORD(-1);
            std::string host = "non-HTTPS destination";
            if (WinHttpCrackUrl(address.c_str(), DWORD(address.size()), 0, &parsed) && parsed.nScheme == INTERNET_SCHEME_HTTPS) {
                const std::wstring hostname(parsed.lpszHostName, parsed.dwHostNameLength);
                host = Utf8(hostname.c_str());
            }
            Report({{"state", "blockedNavigation"}, {"blockedHost", host}});
        }
        return S_OK;
    }).Get(), &token);
    // Apple's completion page may use a frame or external-protocol launch.
    // Consume only our exact callback; never launch a guest OS protocol handler.
    view->add_FrameNavigationStarting(Callback<ICoreWebView2NavigationStartingEventHandler>([](auto*, auto* args) -> HRESULT {
        LPWSTR address = nullptr; args->get_Uri(&address);
        const auto url = address ? Utf8(address) : std::string(); CoTaskMemFree(address);
        if (ConsumeCallback(url)) args->put_Cancel(TRUE);
        return S_OK;
    }).Get(), &token);
    ComPtr<ICoreWebView2_18> external;
    if (SUCCEEDED(view.As(&external))) external->add_LaunchingExternalUriScheme(
        Callback<ICoreWebView2LaunchingExternalUriSchemeEventHandler>([](auto*, auto* args) -> HRESULT {
            args->put_Cancel(TRUE);
            LPWSTR address = nullptr; args->get_Uri(&address);
            const auto url = address ? Utf8(address) : std::string(); CoTaskMemFree(address);
            ConsumeCallback(url); return S_OK;
        }).Get(), &token);
    view->add_NewWindowRequested(Callback<ICoreWebView2NewWindowRequestedEventHandler>([](auto*, auto* args) -> HRESULT {
        args->put_Handled(TRUE);
        LPWSTR address = nullptr; args->get_Uri(&address);
        const auto url = address ? Utf8(address) : std::string(); CoTaskMemFree(address);
        ConsumeCallback(url); return S_OK;
    }).Get(), &token);
    view->add_PermissionRequested(Callback<ICoreWebView2PermissionRequestedEventHandler>([](auto*, auto* args) -> HRESULT {
        args->put_State(COREWEBVIEW2_PERMISSION_STATE_DENY); return S_OK;
    }).Get(), &token);
    ComPtr<ICoreWebView2_4> downloads;
    if (SUCCEEDED(view.As(&downloads))) downloads->add_DownloadStarting(Callback<ICoreWebView2DownloadStartingEventHandler>([](auto*, auto* args) -> HRESULT {
        args->put_Cancel(TRUE); return S_OK;
    }).Get(), &token);
    awaitingCallback = true;
    view->Navigate(signIn.c_str());
}
void SignIn(const std::string& url) {
    const auto destination = Wide(url);
    auto profile = localDirectory / L"Authentication-WebView2";
    HRESULT started = CreateCoreWebView2EnvironmentWithOptions(nullptr, profile.c_str(), nullptr,
        Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>([destination](HRESULT error, ICoreWebView2Environment* environment) -> HRESULT {
            if (FAILED(error) || !environment) {
                Report({{"state", "error"}, {"error", "Microsoft WebView2 is unavailable."}});
                MessageBoxW(window, L"Microsoft WebView2 could not open Apple sign-in.", L"Holdfast", MB_OK | MB_ICONERROR);
                PostMessageW(window, WM_CLOSE, 0, 0); return S_OK;
            }
            environment->CreateCoreWebView2Controller(window,
                Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>([destination](HRESULT error, ICoreWebView2Controller* created) -> HRESULT {
                    if (FAILED(error) || !created) { PostMessageW(window, WM_CLOSE, 0, 0); return S_OK; }
                    Attach(created, destination); return S_OK;
                }).Get());
            return S_OK;
        }).Get());
    if (FAILED(started)) PostMessageW(window, WM_CLOSE, 0, 0);
}
LRESULT CALLBACK WindowProc(HWND target, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == completedMessage) {
        std::unique_ptr<Json> result(reinterpret_cast<Json*>(lparam));
        Report(*result);
        if (probeOnly) { PostMessageW(target, WM_CLOSE, 0, 0); return 0; }
        if (result->value("state", "") == "signInRequired" && !authenticating) {
            SignIn(result->at("url")); return 0;
        }
        // A success dialog runs its own message loop. Do not let the old
        // sign-in deadline overwrite a verified connection while it is open.
        KillTimer(target, 1);
        const bool success = result->value("state", "") == "connected";
        MessageBoxW(target, success ? L"Apple confirmed the Windows iCloud development connection.\n\nNo groups have been imported or published. Settings sync is not enabled yet, and blocking was not changed."
            : L"Apple sign-in could not be verified. No settings or blocking rules were changed. Close this window and try again.",
            L"Holdfast — iCloud development test", MB_OK | (success ? MB_ICONINFORMATION : MB_ICONERROR));
        PostMessageW(target, WM_CLOSE, 0, 0); return 0;
    }
    if (message == WM_SIZE && controller) { RECT bounds; GetClientRect(target, &bounds); controller->put_Bounds(bounds); return 0; }
    if (message == WM_TIMER) {
        Report({{"state", "timedOut"}}); PostMessageW(target, WM_CLOSE, 0, 0); return 0;
    }
    if (message == WM_DESTROY) { if (controller) controller->Close(); PostQuitMessage(0); return 0; }
    return DefWindowProcW(target, message, wparam, lparam);
}
}
int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR arguments, int show) {
    probeOnly = std::wstring(arguments) == L"--probe";
    if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) return 1;
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    try {
        PWSTR folder = nullptr;
        if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &folder))) return 1;
        localDirectory = fs::path(folder) / L"Holdfast" / L"CloudKitDevelopment"; CoTaskMemFree(folder);
        fs::create_directories(localDirectory);
        wchar_t executable[32768]{}; GetModuleFileNameW(nullptr, executable, 32768);
        connection = std::make_shared<CloudKitConnection>(fs::path(executable).parent_path());
        WNDCLASSW type{}; type.lpfnWndProc = WindowProc; type.hInstance = instance;
        type.lpszClassName = L"HoldfastCloudKitDevelopment"; type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        type.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(101)); RegisterClassW(&type);
        window = CreateWindowExW(0, type.lpszClassName, L"Holdfast — Sign in to iCloud (development only)", WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT, CW_USEDEFAULT, 900, 820, nullptr, nullptr, instance, nullptr);
        if (!window) return 1;
        if (!probeOnly) ShowWindow(window, show);
        SetTimer(window, 1, probeOnly ? 60000 : 600000, nullptr);
        Dispatch();
        MSG message{};
        while (GetMessageW(&message, nullptr, 0, 0) > 0) { TranslateMessage(&message); DispatchMessageW(&message); }
        view.Reset(); controller.Reset(); connection.reset(); CoUninitialize();
        return 0;
    } catch (...) {
        if (!localDirectory.empty()) Report({{"state", "error"}, {"error", "Development connection configuration is missing or invalid."}});
        if (!probeOnly) MessageBoxW(nullptr, L"Holdfast's development CloudKit configuration is missing or invalid.", L"Holdfast", MB_OK | MB_ICONERROR);
        CoUninitialize(); return 1;
    }
}
