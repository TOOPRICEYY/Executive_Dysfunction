#pragma once
#include <nlohmann/json.hpp>
#include <filesystem>
#include <mutex>
#include <string>

// Development transport only. No access to the enforcement service or renderer.
// User authentication is protected by Windows DPAPI under the signed-in user.
class CloudKitConnection {
public:
    explicit CloudKitConnection(const std::filesystem::path& executableDirectory);
    nlohmann::json Check();
    nlohmann::json Authenticate(const std::string& callback);
    nlohmann::json RoundTrip();
    nlohmann::json InspectTestRecord(const std::string& name);
    static bool IsTestRecordName(const std::string& name);
    static bool IsAppleSignInURL(const std::string& url);
    static bool IsCallback(const std::string& url);
    static std::string CallbackToken(const std::string& url);
private:
    nlohmann::json config_, credential_ = nlohmann::json::object();
    std::filesystem::path credentialPath_;
    std::mutex mutex_;
    nlohmann::json CurrentUser(const std::string& token);
    nlohmann::json Request(const std::string& endpoint, const std::string& token, const nlohmann::json* payload = nullptr);
    void Persist(const nlohmann::json& credential);
};
