import EndpointSecurity
import Foundation

private let policyLoader = ResilientDesktopPolicyLoader()

private func string(from token: es_string_token_t) -> String {
    guard token.length > 0, let data = token.data else { return "" }
    return String(data: Data(bytes: data, count: Int(token.length)), encoding: .utf8) ?? ""
}

private var client: OpaquePointer?
let creationResult = es_new_client(&client) { client, message in
    guard message.pointee.event_type == ES_EVENT_TYPE_AUTH_EXEC else {
        _ = es_respond_auth_result(client, message, ES_AUTH_RESULT_ALLOW, false)
        return
    }

    let target = message.pointee.event.exec.target.pointee
    let signingIdentifier = string(from: target.signing_id)
    let executablePath = string(from: target.executable.pointee.path)
    let blocked = policyLoader.current().blocksApplication(
        signingIdentifier: signingIdentifier,
        executablePath: executablePath
    )
    _ = es_respond_auth_result(
        client,
        message,
        blocked ? ES_AUTH_RESULT_DENY : ES_AUTH_RESULT_ALLOW,
        !blocked
    )
}

guard creationResult == ES_NEW_CLIENT_RESULT_SUCCESS, let client else {
    FileHandle.standardError.write(Data("Unable to create Endpoint Security client: \(creationResult.rawValue)\n".utf8))
    exit(EXIT_FAILURE)
}

var events = [ES_EVENT_TYPE_AUTH_EXEC]
guard es_subscribe(client, &events, UInt32(events.count)) == ES_RETURN_SUCCESS else {
    es_delete_client(client)
    exit(EXIT_FAILURE)
}

dispatchMain()
