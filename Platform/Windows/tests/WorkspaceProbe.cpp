// VM integration-test client. Not installed with the application.
#include "../ui/WorkspaceClient.h"
#include <iostream>
int main() {
    try {
        nlohmann::json request; std::cin >> request;
        const auto reply = CallWorkspace(request); std::cout << reply.dump() << '\n';
        return reply.value("ok", false) ? 0 : 2;
    } catch(const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
