import Foundation

@main
struct TestTabMemoryPressurePolicy {
    static func main() {
        let now = Date()
        let oldest = UUID()
        let middle = UUID()
        let newest = UUID()
        let pinned = UUID()
        let loading = UUID()
        let candidates = [
            TabMemoryPressureCandidate(id: newest, isPinned: false, isLoading: false, lastAccessedAt: now),
            TabMemoryPressureCandidate(id: pinned, isPinned: true, isLoading: false, lastAccessedAt: now.addingTimeInterval(-500)),
            TabMemoryPressureCandidate(id: oldest, isPinned: false, isLoading: false, lastAccessedAt: now.addingTimeInterval(-300)),
            TabMemoryPressureCandidate(id: loading, isPinned: false, isLoading: true, lastAccessedAt: now.addingTimeInterval(-600)),
            TabMemoryPressureCandidate(id: middle, isPinned: false, isLoading: false, lastAccessedAt: now.addingTimeInterval(-100))
        ]

        let warning = TabMemoryPressurePolicy.discardIDs(from: candidates, level: .warning)
        precondition(warning == [oldest])

        let critical = TabMemoryPressurePolicy.discardIDs(from: candidates, level: .critical)
        precondition(critical == [oldest, middle, newest, loading, pinned])

        let protectedOnly = [
            TabMemoryPressureCandidate(id: pinned, isPinned: true, isLoading: false, lastAccessedAt: now),
            TabMemoryPressureCandidate(id: loading, isPinned: false, isLoading: true, lastAccessedAt: now)
        ]
        precondition(TabMemoryPressurePolicy.discardIDs(from: protectedOnly, level: .warning).isEmpty)
        print("tab-memory-pressure-policy-tests=passed")
    }
}
