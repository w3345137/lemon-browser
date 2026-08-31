import Foundation

@main
struct TestSessionCookieVault {
    static func main() {
        let source = HTTPCookie(properties: [
            .name: "session-id",
            .value: "test-value",
            .domain: ".example.com",
            .path: "/",
            .secure: "TRUE",
            .discard: "TRUE",
            HTTPCookiePropertyKey(rawValue: "HttpOnly"): "TRUE",
            .sameSitePolicy: "lax"
        ])!
        let record = SessionCookieRecord(cookie: source)!
        let restored = record.cookie!

        precondition(restored.name == source.name)
        precondition(restored.value == source.value)
        precondition(restored.domain == source.domain)
        precondition(restored.path == source.path)
        precondition(restored.expiresDate == nil)
        precondition(restored.isSecure)
        precondition(restored.isHTTPOnly)

        let persistent = HTTPCookie(properties: [
            .name: "persistent",
            .value: "value",
            .domain: "example.com",
            .path: "/",
            .expires: Date(timeIntervalSinceNow: 3600)
        ])!
        precondition(SessionCookieRecord(cookie: persistent) == nil)

        let nonSecure = HTTPCookie(properties: [
            .name: "http-session",
            .value: "value",
            .domain: "localhost",
            .path: "/",
            .discard: "TRUE"
        ])!
        let restoredNonSecure = SessionCookieRecord(cookie: nonSecure)!.cookie!
        precondition(!restoredNonSecure.isSecure)
        print("session-cookie-vault-tests=passed")
    }
}
