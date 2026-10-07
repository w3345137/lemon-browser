import Foundation
import Security

@main
enum TestCredentialSaveDecision {
    @MainActor
    static func main() {
        let existing = WebCredential(scope: "https://login.example.com", username: "test-user")
        var saved = [existing: "dummy-original"]
        let lookup: (WebCredential) throws -> String? = { saved[$0] }
        func decision(_ scope: String = "https://login.example.com", _ username: String = "test-user", _ password: String = "dummy-original") -> CredentialSaveDecision {
            CredentialStore.saveDecision(scope: scope, username: username, password: password, lookup: lookup)
        }
        precondition(decision() == .unchanged)
        precondition(decision("https://LOGIN.example.com:443/login?next=home") == .unchanged)
        precondition(decision("https://login.example.com", "test-user", "dummy-changed") == .update)
        precondition(decision("https://login.example.com", "new-user") == .save)
        precondition(decision("http://login.example.com") == .save)
        precondition(decision("https://other.example.com") == .save)
        precondition(decision("https://login.example.com:8443") == .save)
        for changed in ["DUMMY-original", "dummy-original ", " dummy-original"] {
            precondition(decision(existing.scope, existing.username, changed) == .update)
        }
        saved[existing] = "caf\u{00E9}"
        precondition(decision(existing.scope, existing.username, "caf\u{00E9}") == .unchanged)
        precondition(decision(existing.scope, existing.username, "cafe\u{0301}") == .update)
        saved[existing] = "dummy-changed"
        precondition(decision("https://login.example.com", "test-user", "dummy-changed") == .unchanged)
        precondition(decision() == .update)
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecDecode] {
            precondition(CredentialStore.saveDecision(scope: existing.scope, username: existing.username, password: "dummy-original") { _ in
                throw CredentialStoreError.keychain(status)
            } == .unavailable)
        }
        var lookedUp = false
        for (scope, password) in [("file:///tmp/login.html", "dummy"), (existing.scope, "")] {
            precondition(CredentialStore.saveDecision(scope: scope, username: existing.username, password: password) { _ in
                lookedUp = true
                return nil
            } == .unavailable)
        }
        precondition(!lookedUp)
        print("credential-save-decision-tests=passed")
    }
}
