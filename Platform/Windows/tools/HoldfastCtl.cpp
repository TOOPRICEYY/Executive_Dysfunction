#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include "../core/Policy.h"

static uint64_t Now() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::system_clock::now().time_since_epoch()).count());
}
static std::filesystem::path Directory() {
    wchar_t data[32768]{};
    DWORD count = GetEnvironmentVariableW(L"ProgramData", data, ARRAYSIZE(data));
    if (!count || count >= ARRAYSIZE(data)) throw std::runtime_error("ProgramData unavailable");
    return std::filesystem::path(data) / L"Holdfast";
}
static bool Administrator() {
    SID_IDENTIFIER_AUTHORITY authority = SECURITY_NT_AUTHORITY;
    PSID sid = nullptr; BOOL member = FALSE;
    if (AllocateAndInitializeSid(&authority, 2, SECURITY_BUILTIN_DOMAIN_RID, DOMAIN_ALIAS_RID_ADMINS,
        0, 0, 0, 0, 0, 0, &sid)) {
        CheckTokenMembership(nullptr, sid, &member); FreeSid(sid);
    }
    return member == TRUE;
}

int wmain(int argc, wchar_t** argv) {
    try {
        const auto root = Directory();
        if (argc == 2 && std::wstring(argv[1]) == L"--status") {
            std::ifstream status(root / L"status.json");
            if (!status) { std::cerr << "No service status. Install/start HoldfastEnforcement first.\n"; return 2; }
            std::cout << status.rdbuf();
            return 0;
        }
        if (argc < 2 || (std::wstring(argv[1]) != L"--apply" && std::wstring(argv[1]) != L"--clear")) {
            std::wcout << L"Holdfast Windows development control\n"
                L"  HoldfastCtl --status\n"
                L"  HoldfastCtl --apply --seconds 15 --app C:\\Apps\\browser.exe [--app ...]\n"
                L"  HoldfastCtl --clear\n"
                L"Administrator required for changes. Application networking only; no website filtering, app-launch guard or sync.\n";
            return argc == 1 ? 0 : 2;
        }
        if (!Administrator()) { std::cerr << "Run from an elevated administrator terminal.\n"; return 5; }
        if (!std::filesystem::is_directory(root)) throw std::runtime_error("Run Install.ps1 first; the protected policy directory is missing.");
        const bool clear = std::wstring(argv[1]) == L"--clear";
        auto policy = std::make_unique<ED_GUARD_POLICY>();
        policy->version = ED_GUARD_POLICY_VERSION;
        uint64_t seconds = clear ? 15 : 0;
        for (int i = 2; i < argc; ++i) {
            const std::wstring arg(argv[i]);
            if (arg == L"--seconds" && !clear && i + 1 < argc) {
                std::wstring value(argv[++i]);
                size_t consumed = 0; seconds = std::stoull(value, &consumed);
                if (consumed != value.size()) throw std::runtime_error("Invalid duration");
            } else if (arg == L"--app" && !clear && i + 1 < argc && policy->ruleCount < ED_GUARD_MAX_RULES) {
                const std::wstring path(argv[++i]);
                if (path.size() >= ED_GUARD_MAX_PATH_CHARS || !std::filesystem::is_regular_file(path))
                    throw std::runtime_error("Executable must exist and fit the protocol path bound");
                std::copy(path.begin(), path.end(), policy->rules[policy->ruleCount++].path);
            } else throw std::runtime_error("Unrecognized/incomplete argument");
        }
        if ((!clear && !policy->ruleCount) || !seconds || seconds > ED_GUARD_MAX_LEASE_SECONDS)
            throw std::runtime_error("Choose executable(s) and a duration from 1 to 86400 seconds");
        uint64_t accepted = 0; DWORD size = sizeof(accepted);
        const auto status = RegGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Holdfast", L"AcceptedPolicyRevision",
            RRF_RT_REG_QWORD, nullptr, &accepted, &size);
        if (status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND && status != ERROR_PATH_NOT_FOUND)
            throw std::runtime_error("Cannot read revision barrier");
        auto previous = std::make_unique<ED_GUARD_POLICY>();
        std::ifstream prior(root / L"policy.bin", std::ios::binary);
        if (prior.read(reinterpret_cast<char*>(previous.get()), sizeof(*previous)) &&
            prior.peek() == std::char_traits<char>::eof() && previous->version == ED_GUARD_POLICY_VERSION)
            accepted = std::max(accepted, previous->revision);
        // MSVC's stream handle does not share delete access. It must be closed
        // before MoveFileEx replaces the same policy, including --clear.
        prior.close();
        if (accepted == UINT64_MAX) throw std::runtime_error("Revision exhausted; administrator recovery required");
        policy->revision = accepted + 1;
        policy->issuedAtUnixSeconds = Now();
        policy->validUntilUnixSeconds = policy->issuedAtUnixSeconds + seconds;
        const auto valid = holdfast::ValidatePolicy(*policy, sizeof(*policy), Now(), accepted);
        if (!valid.valid) throw std::runtime_error(valid.reason);
        const auto temporary = root / (L"policy." + std::to_wstring(GetCurrentProcessId()) + L".tmp");
        const auto target = root / L"policy.bin";
        HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) throw std::runtime_error("Cannot create policy staging file");
        DWORD written = 0;
        const bool saved = WriteFile(file, policy.get(), static_cast<DWORD>(sizeof(*policy)), &written, nullptr)
            && written == sizeof(*policy) && FlushFileBuffers(file);
        CloseHandle(file);
        if (!saved || !MoveFileExW(temporary.c_str(), target.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
            DeleteFileW(temporary.c_str()); throw std::runtime_error("Atomic policy publication failed");
        }
        std::cout << "Published revision " << policy->revision << ", expires " << policy->validUntilUnixSeconds
            << ". Check --status for service acknowledgement.\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
