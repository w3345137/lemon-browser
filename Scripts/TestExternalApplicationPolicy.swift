import Foundation

@main
enum TestExternalApplicationPolicy {
    static func main() {
        precondition(
            ExternalApplicationPolicy.externalScheme(
                for: URL(string: "wemeet://page/inmeeting?meeting_code=123")
            ) == "wemeet"
        )
        precondition(
            ExternalApplicationPolicy.externalScheme(
                for: URL(string: "WEMEET3://action/yuanbao_hosting")
            ) == "wemeet3"
        )
        precondition(ExternalApplicationPolicy.externalScheme(for: URL(string: "https://meeting.tencent.com")) == nil)
        precondition(ExternalApplicationPolicy.externalScheme(for: URL(string: "file:///tmp/test.html")) == nil)
        precondition(ExternalApplicationPolicy.externalScheme(for: URL(string: "javascript:void(0)")) == nil)

        let now = Date(timeIntervalSince1970: 100)
        precondition(
            ExternalApplicationPolicy.isRecentGesture(
                at: Date(timeIntervalSince1970: 98),
                now: now
            )
        )
        precondition(
            !ExternalApplicationPolicy.isRecentGesture(
                at: Date(timeIntervalSince1970: 96),
                now: now
            )
        )
        precondition(!ExternalApplicationPolicy.isRecentGesture(at: nil, now: now))
        precondition(
            !ExternalApplicationPolicy.isRecentGesture(
                at: Date(timeIntervalSince1970: 101),
                now: now
            )
        )
        print("external-application-policy-tests=passed")
    }
}
