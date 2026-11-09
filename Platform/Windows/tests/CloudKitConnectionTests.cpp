#include "../ui/CloudKitConnection.h"
#include <iostream>
#include <stdexcept>

int main() {
    unsigned checks = 0;
    auto check = [&](bool pass) { ++checks; if (!pass) throw std::runtime_error("CloudKit boundary check failed."); };
    const std::string callback = "cloudkit-icloud.com.gabrielprice.holdfast://auth";
    check(CloudKitConnection::IsTestRecordName("holdfast-connection-test-ECFB5D81-C2AF-438E-A22D-1CD7FA93FB65"));
    for (const auto* name : {"settings", "holdfast-connection-test-*", "holdfast-connection-test-ECFB5D81-C2AF-438E-A22D-1CD7FA93FB65/other",
        "holdfast-connection-test-ECFB5D81-C2AF-438E-A22D-1CD7FA93FB6Z", "holdfast-connection-test-ECFB5D81XC2AF-438E-A22D-1CD7FA93FB65"})
        check(!CloudKitConnection::IsTestRecordName(name));
    check(!CloudKitConnection::IsAppleSignInURL(std::string("https://idmsa.apple.com/") + char(0xff)));
    for (const auto* url : {"https://idmsa.apple.com/appleauth/auth", "https://appleid.apple.com/", "https://account.apple.com/", "https://www.icloud.com/", "https://api.apple-cloudkit.com/", "https://cdn.apple-cloudkit.com/"})
        check(CloudKitConnection::IsAppleSignInURL(url));
    for (const auto* url : {"http://idmsa.apple.com/", "https://idmsa.apple.com.evil.test/", "https://evil.test/?idmsa.apple.com",
        "https://idmsa.apple.com:444/", "https://user@idmsa.apple.com/", "https://user:pass@idmsa.apple.com/", "file:///C:/Windows/", "javascript:alert(1)", "https://holdfast.invalid/",
        "https://cdn.apple-cloudkit.com.evil.test/", "https://cdn.apple-cloudkit.com:444/", "http://cdn.apple-cloudkit.com/", "https://user@cdn.apple-cloudkit.com/"})
        check(!CloudKitConnection::IsAppleSignInURL(url));
    check(CloudKitConnection::IsCallback(callback + "?ckWebAuthToken=test"));
    check(CloudKitConnection::IsCallback(callback + "#ckWebAuthToken=test"));
    check(!CloudKitConnection::IsCallback(callback + ".evil.test?ckWebAuthToken=test"));
    check(!CloudKitConnection::IsCallback(callback + "/?ckWebAuthToken=test"));
    check(CloudKitConnection::CallbackToken(callback + "?ckWebAuthToken=a%2Bb%2Fc%3D") == "a+b/c=");
    check(CloudKitConnection::CallbackToken(callback + "#other=1&ckWebAuthToken=test") == "test");
    for (const auto& url : {callback + "?ckWebAuthToken=", callback + "?ckWebAuthToken=a&ckWebAuthToken=b",
        callback + "?ckWebAuthToken=%", callback + "?ckWebAuthToken=%ZZ", callback + "?ckWebAuthToken=%00",
        callback + "?error=cancelled", callback + "?ckWebAuthToken=&ckWebAuthToken=b", callback + "?ckWebAuthToken=" + std::string(32769, 'a'),
        std::string("https://evil.test/?ckWebAuthToken=test")}) {
        bool rejected = false;
        try { CloudKitConnection::CallbackToken(url); } catch (...) { rejected = true; }
        check(rejected);
    }
    std::cout << checks << " CloudKit connection boundary checks passed\n";
}
