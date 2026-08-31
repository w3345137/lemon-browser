import Foundation

@main
enum TestSessionImportRequestPolicy {
    static func main() {
        let token = "one-time-secret"
        let valid = """
        POST /import/one-time-secret HTTP/1.1\r
        Host: 127.0.0.1:18765\r
        Origin: chrome-extension://abcdefghijklmnop\r
        Content-Type: application/json\r
        \r
        """
        precondition(SessionImportRequestPolicy.isAuthorizedImport(valid, token: token))

        let wrongToken = valid.replacingOccurrences(
            of: "/import/one-time-secret",
            with: "/import/stolen"
        )
        precondition(!SessionImportRequestPolicy.isAuthorizedImport(wrongToken, token: token))

        let forgedWebOrigin = valid.replacingOccurrences(
            of: "chrome-extension://abcdefghijklmnop",
            with: "https://evil.example"
        )
        precondition(!SessionImportRequestPolicy.isAuthorizedImport(forgedWebOrigin, token: token))

        let tokenRead = """
        GET /token HTTP/1.1\r
        Origin: chrome-extension://abcdefghijklmnop\r
        \r
        """
        precondition(!SessionImportRequestPolicy.isAuthorizedImport(tokenRead, token: token))
        print("session-import-request-policy-tests=passed")
    }
}
