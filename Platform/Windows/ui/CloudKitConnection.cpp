#include "CloudKitConnection.h"
#include <windows.h>
#include <winhttp.h>
#include <wincrypt.h>
#include <shlobj.h>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <vector>

using Json = nlohmann::json;
namespace fs = std::filesystem;
namespace {
constexpr auto callbackBase = "cloudkit-icloud.com.gabrielprice.holdfast://auth";
std::string SafeErrorCode(const Json& response) {
    if (!response.contains("serverErrorCode") || !response.at("serverErrorCode").is_string()) return "NONE";
    const auto code = response.at("serverErrorCode").get<std::string>();
    if (code.empty() || code.size() > 64) return "UNRECOGNIZED";
    for (char c : code) if (!(c >= 'A' && c <= 'Z') && c != '_') return "UNRECOGNIZED";
    return code;
}
std::wstring Wide(const std::string& text) {
    auto count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), int(text.size()), nullptr, 0);
    if (!count && !text.empty()) throw std::runtime_error("Invalid UTF-8.");
    std::wstring result(count, 0);
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), int(text.size()), result.data(), count);
    return result;
}
std::string Encode(const std::string& text) {
    constexpr char hex[] = "0123456789ABCDEF";
    std::string result;
    for (unsigned char c : text) {
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~') result += char(c);
        else { result += '%'; result += hex[c >> 4]; result += hex[c & 15]; }
    }
    return result;
}
std::string Decode(const std::string& text) {
    auto nibble = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        throw std::runtime_error("Malformed sign-in callback.");
    };
    std::string result;
    for (size_t i = 0; i < text.size(); ++i) {
        if (text[i] == '%') {
            if (i + 2 >= text.size()) throw std::runtime_error("Malformed sign-in callback.");
            auto c = char(nibble(text[i+1]) * 16 + nibble(text[i+2]));
            if (!c) throw std::runtime_error("Malformed sign-in callback.");
            result += c; i += 2;
        } else result += text[i] == '+' ? ' ' : text[i];
    }
    return result;
}
struct InternetHandle {
    HINTERNET value;
    explicit InternetHandle(HINTERNET h) : value(h) {
        if (!value) throw std::runtime_error("Cannot open a secure CloudKit connection.");
    }
    ~InternetHandle() { WinHttpCloseHandle(value); }
    InternetHandle(const InternetHandle&) = delete;
};
std::vector<unsigned char> Read(const fs::path& path, size_t maximum) {
    if (fs::file_size(path) > maximum) throw std::runtime_error("CloudKit connection file is too large.");
    std::ifstream stream(path, std::ios::binary);
    if (!stream) throw std::runtime_error("Cannot read CloudKit connection file.");
    return {std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
}
}

CloudKitConnection::CloudKitConnection(const fs::path& directory) {
    const auto bytes = Read(directory / L"cloudkit-development.json", 8192);
    config_ = Json::parse(bytes);
    if (config_.at("container") != "iCloud.com.GabrielPrice.Holdfast" || config_.at("environment") != "development"
        || config_.at("origin") != "https://holdfast.invalid" || config_.at("callback") != callbackBase
        || !config_.at("apiToken").is_string() || config_.at("apiToken").get<std::string>().size() != 64)
        throw std::runtime_error("This probe accepts only Holdfast's development configuration.");
    PWSTR folder = nullptr;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &folder))) throw std::runtime_error("Local application storage is unavailable.");
    const auto local = fs::path(folder) / L"Holdfast" / L"CloudKitDevelopment";
    CoTaskMemFree(folder);
    fs::create_directories(local);
    credentialPath_ = local / L"session.dpapi";
    if (fs::exists(credentialPath_)) {
        auto encrypted = Read(credentialPath_, 128 * 1024);
        DATA_BLOB input{DWORD(encrypted.size()), encrypted.data()}, output{};
        if (!CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output))
            throw std::runtime_error("The saved CloudKit session cannot be decrypted by this Windows user.");
        try { credential_ = Json::parse(output.pbData, output.pbData + output.cbData); }
        catch (...) { SecureZeroMemory(output.pbData, output.cbData); LocalFree(output.pbData); throw; }
        SecureZeroMemory(output.pbData, output.cbData); LocalFree(output.pbData);
    }
}

bool CloudKitConnection::IsCallback(const std::string& url) {
    return url.size() <= 65536 && (url.starts_with(std::string(callbackBase) + "?") || url.starts_with(std::string(callbackBase) + "#"));
}
bool CloudKitConnection::IsAppleSignInURL(const std::string& url) {
    // Top-level navigation only. Never grant a native bridge to this window.
    if (url.size() > 65536) return false;
    std::wstring wide;
    try { wide = Wide(url); } catch (...) { return false; }
    URL_COMPONENTS components{}; components.dwStructSize = sizeof(components);
    components.dwHostNameLength = DWORD(-1); components.dwUserNameLength = DWORD(-1); components.dwPasswordLength = DWORD(-1);
    if (!WinHttpCrackUrl(wide.c_str(), DWORD(wide.size()), 0, &components) || components.nScheme != INTERNET_SCHEME_HTTPS
        || components.nPort != 443 || components.dwUserNameLength || components.dwPasswordLength) return false;
    const std::wstring host(components.lpszHostName, components.dwHostNameLength);
    return host == L"idmsa.apple.com" || host == L"appleid.apple.com" || host == L"account.apple.com"
        || host == L"www.icloud.com" || host == L"icloud.com" || host == L"api.apple-cloudkit.com"
        || host == L"cdn.apple-cloudkit.com";
}

Json CloudKitConnection::Request(const std::string& endpoint, const std::string& token, const Json* payload) {
    const auto deadline = GetTickCount64() + 45000;
    InternetHandle session(WinHttpOpen(L"Holdfast-CloudKit-Development/1", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, nullptr, nullptr, 0));
    WinHttpSetTimeouts(session.value, 10000, 10000, 10000, 15000);
    InternetHandle connection(WinHttpConnect(session.value, L"api.apple-cloudkit.com", INTERNET_DEFAULT_HTTPS_PORT, 0));
    auto path = std::string("/database/1/iCloud.com.GabrielPrice.Holdfast/development/private/") + endpoint + "?ckAPIToken="
        + Encode(config_.at("apiToken").get<std::string>());
    if (!token.empty()) path += "&ckWebAuthToken=" + Encode(token);
    InternetHandle request(WinHttpOpenRequest(connection.value, payload ? L"POST" : L"GET", Wide(path).c_str(), nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE));
    DWORD redirects = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    WinHttpSetOption(request.value, WINHTTP_OPTION_REDIRECT_POLICY, &redirects, sizeof(redirects));
    // TLS certificate validation stays enabled. Credentials never go to a redirected host.
    auto requestBody = payload ? payload->dump() : std::string();
    if (!WinHttpSendRequest(request.value, L"Origin: https://holdfast.invalid\r\nAccept: application/json\r\nContent-Type: application/json\r\n", DWORD(-1),
        requestBody.empty() ? nullptr : requestBody.data(), DWORD(requestBody.size()), DWORD(requestBody.size()), 0)
        || !WinHttpReceiveResponse(request.value, nullptr)) throw std::runtime_error("CloudKit connection failed. Check connectivity and try again.");
    DWORD status = 0, length = sizeof(status);
    if (!WinHttpQueryHeaders(request.value, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, nullptr, &status, &length, nullptr))
        throw std::runtime_error("CloudKit returned an invalid HTTP response.");
    std::string body;
    char buffer[8192]; DWORD read = 0;
    for (;;) {
        if (GetTickCount64() > deadline) throw std::runtime_error("CloudKit response timed out.");
        if (!WinHttpReadData(request.value, buffer, sizeof(buffer), &read)) throw std::runtime_error("CloudKit response was interrupted.");
        if (!read) break;
        if (body.size() + read > 128 * 1024) throw std::runtime_error("CloudKit response was too large.");
        body.append(buffer, read);
    }
    auto result = Json::parse(body);
    result["_httpStatus"] = status;
    return result;
}

Json CloudKitConnection::CurrentUser(const std::string& token) {
    auto result = Request("users/current", token);
    const auto status = result.at("_httpStatus").get<DWORD>();
    result.erase("_httpStatus");
    if (result.value("serverErrorCode", "") == "AUTHENTICATION_REQUIRED") {
        if (!result.contains("redirectURL") || !IsAppleSignInURL(result.at("redirectURL"))) throw std::runtime_error("CloudKit returned an unexpected sign-in destination.");
        return {{"state", "signInRequired"}, {"url", result.at("redirectURL")}};
    }
    if (status != 200 || result.contains("serverErrorCode") || !result.contains("userRecordName") || !result.at("userRecordName").is_string()
        || result.at("userRecordName").get<std::string>().empty()) throw std::runtime_error("CloudKit did not confirm the signed-in account.");
    return result;
}

Json CloudKitConnection::RoundTrip() {
    // Only random test material is sent to this development-only database.
    // Never read, alter or delete an existing app/settings record.
    const auto checked = Check();
    if (checked.value("state", "") != "connected") return {{"state", "signInRequired"}, {"settingsSyncEnabled", false}, {"enforcementChanged", false}};
    std::lock_guard lock(mutex_);
    GUID identifier{};
    if (FAILED(CoCreateGuid(&identifier))) throw std::runtime_error("Cannot create test identifier.");
    wchar_t buffer[40]{}; StringFromGUID2(identifier, buffer, 40);
    std::string nonce;
    for (wchar_t c : std::wstring(buffer)) if (c != L'{' && c != L'}') nonce += char(c);
    const std::string name = "holdfast-connection-test-" + nonce;
    std::string stage = "create", serverError = "NONE";
    unsigned httpStatus = 0;
    auto request = [&](const std::string& endpoint, const Json& payload) {
        httpStatus = 0; serverError = "NONE";
        auto result = Request(endpoint, credential_.at("token"), &payload);
        httpStatus = result.at("_httpStatus").get<unsigned>();
        serverError = SafeErrorCode(result);
        if (result.contains("ckWebAuthToken")) {
            auto renewed = credential_; renewed["token"] = result.at("ckWebAuthToken"); Persist(renewed);
        }
        if (result.at("_httpStatus") != 200 || result.contains("serverErrorCode") || !result.contains("records")
            || !result.at("records").is_array() || result.at("records").size() != 1)
            throw std::runtime_error("CloudKit did not acknowledge the test request.");
        auto record = result.at("records").at(0);
        serverError = SafeErrorCode(record);
        if (record.contains("serverErrorCode") || record.value("recordName", "") != name)
            throw std::runtime_error("CloudKit did not acknowledge the test record.");
        return record;
    };
    const Json lookup{{"records", Json::array({Json{{"recordName", name}}})}};
    const Json create{{"operations", Json::array({Json{{"operationType", "create"}, {"record", {
        {"recordName", name}, {"recordType", "HoldfastConnectionTest"}, {"fields", {{"nonce", {{"value", nonce}}}}}}}}})}};
    bool created = false;
    try {
        auto saved = request("records/modify", create); created = true;
        stage = "readBack";
        auto fetched = request("records/lookup", lookup);
        if (fetched.at("fields").at("nonce").at("value") != nonce) throw std::runtime_error("Test record readback mismatch.");
        const Json remove{{"operations", Json::array({Json{{"operationType", "delete"}, {"record", {
            {"recordName", name}, {"recordChangeTag", fetched.at("recordChangeTag")}}}}})}};
        stage = "delete";
        auto deleted = request("records/modify", remove);
        if (!deleted.value("deleted", false)) throw std::runtime_error("Test record cleanup was not confirmed.");
        return {{"state", "roundTripPassed"}, {"created", true}, {"readBack", true}, {"testRecordDeleted", true},
            {"settingsSyncEnabled", false}, {"enforcementChanged", false}};
    } catch (...) {
        // Retain the exact generated name for diagnosis/targeted cleanup. No
        // blind write retries or broad cleanup of unrelated records.
        return {{"state", "roundTripFailed"}, {"testRecordName", name}, {"creationAcknowledged", created},
            {"stage", stage}, {"httpStatus", httpStatus}, {"serverErrorCode", serverError},
            {"cleanupRequired", true}, {"settingsSyncEnabled", false}, {"enforcementChanged", false}};
    }
}

bool CloudKitConnection::IsTestRecordName(const std::string& name) {
    constexpr std::string_view prefix = "holdfast-connection-test-";
    if (!name.starts_with(prefix) || name.size() != prefix.size() + 36) return false;
    const auto id = name.substr(prefix.size());
    for (size_t i = 0; i < id.size(); ++i) {
        if (i == 8 || i == 13 || i == 18 || i == 23) { if (id[i] != '-') return false; }
        else if (!(id[i] >= '0' && id[i] <= '9') && !(id[i] >= 'A' && id[i] <= 'F')) return false;
    }
    return true;
}

Json CloudKitConnection::InspectTestRecord(const std::string& name) {
    if (!IsTestRecordName(name)) throw std::runtime_error("Not a generated connection-test record name.");
    if (Check().value("state", "") != "connected") return {{"state", "signInRequired"}};
    std::lock_guard lock(mutex_);
    const Json lookup{{"records", Json::array({Json{{"recordName", name}}})}};
    const auto response = Request("records/lookup", credential_.at("token"), &lookup);
    if (response.contains("ckWebAuthToken")) {
        auto renewed = credential_; renewed["token"] = response.at("ckWebAuthToken"); Persist(renewed);
    }
    Json result{{"state", "inspectionFailed"}, {"testRecordName", name},
        {"httpStatus", response.at("_httpStatus")}, {"serverErrorCode", SafeErrorCode(response)},
        {"settingsSyncEnabled", false}, {"enforcementChanged", false}};
    if (response.at("_httpStatus") == 200 && response.contains("records")
        && response.at("records").is_array() && response.at("records").size() == 1) {
        const auto& record = response.at("records").at(0);
        result["serverErrorCode"] = SafeErrorCode(record);
        if (record.value("recordName", "") == name) {
            if (record.value("serverErrorCode", "") == "NOT_FOUND") result["state"] = "testRecordAbsent";
            else if (!record.contains("serverErrorCode") && record.value("recordType", "") == "HoldfastConnectionTest")
                result["state"] = "testRecordExists";
        }
    }
    return result;
}

void CloudKitConnection::Persist(const Json& credential) {
    auto text = credential.dump();
    DATA_BLOB input{DWORD(text.size()), reinterpret_cast<BYTE*>(text.data())}, output{};
    if (!CryptProtectData(&input, L"Holdfast CloudKit development", nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output))
        throw std::runtime_error("Windows could not protect the iCloud session.");
    const auto pending = credentialPath_.wstring() + L".pending";
    HANDLE file = CreateFileW(pending.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, nullptr);
    DWORD written = 0;
    const bool saved = file != INVALID_HANDLE_VALUE && WriteFile(file, output.pbData, output.cbData, &written, nullptr)
        && written == output.cbData && FlushFileBuffers(file);
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    SecureZeroMemory(output.pbData, output.cbData); LocalFree(output.pbData);
    SecureZeroMemory(text.data(), text.size());
    if (!saved || !MoveFileExW(pending.c_str(), credentialPath_.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
        throw std::runtime_error("The protected iCloud session could not be saved.");
    credential_ = credential;
}

Json CloudKitConnection::Check() {
    std::lock_guard lock(mutex_);
    const auto result = CurrentUser(credential_.value("token", ""));
    if (result.value("state", "") == "signInRequired") return result;
    if (credential_.value("account", "") != result.at("userRecordName").get<std::string>()) throw std::runtime_error("iCloud account changed. Existing data has not been imported or replaced.");
    if (result.contains("ckWebAuthToken")) Persist({{"account", result.at("userRecordName")}, {"token", result.at("ckWebAuthToken")}});
    return {{"state", "connected"}, {"environment", "development"}, {"settingsSyncEnabled", false}, {"enforcementChanged", false}};
}

Json CloudKitConnection::Authenticate(const std::string& callback) {
    std::lock_guard lock(mutex_);
    const auto token = CallbackToken(callback);
    const auto result = CurrentUser(token);
    if (!result.contains("userRecordName")) throw std::runtime_error("Apple could not validate this sign-in. Please try again.");
    const auto account = result.at("userRecordName").get<std::string>();
    if (credential_.contains("account") && credential_.at("account") != account)
        throw std::runtime_error("This connection belongs to a different iCloud account. No account switch or data migration was performed.");
    Persist({{"account", account}, {"token", result.value("ckWebAuthToken", token)}});
    return {{"state", "connected"}, {"environment", "development"}, {"settingsSyncEnabled", false}, {"enforcementChanged", false}};
}

std::string CloudKitConnection::CallbackToken(const std::string& callback) {
    if (!IsCallback(callback)) throw std::runtime_error("Unexpected sign-in callback.");
    auto query = callback.substr(std::string(callbackBase).size() + 1);
    std::string token;
    bool tokenSeen = false;
    for (size_t start = 0; start < query.size();) {
        auto end = query.find('&', start); if (end == std::string::npos) end = query.size();
        const auto entry = query.substr(start, end - start);
        const auto equals = entry.find('=');
        if (equals != std::string::npos && Decode(entry.substr(0, equals)) == "ckWebAuthToken") {
            if (tokenSeen) throw std::runtime_error("Duplicate sign-in credential.");
            tokenSeen = true;
            token = Decode(entry.substr(equals + 1));
        }
        start = end + 1;
    }
    if (token.empty() || token.size() > 32768) throw std::runtime_error("Apple sign-in was cancelled or did not return a credential.");
    return token;
}
