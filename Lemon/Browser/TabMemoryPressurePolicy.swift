import Foundation

enum TabMemoryPressureLevel {
    case warning
    case critical
}

struct TabMemoryPressureCandidate: Equatable {
    let id: UUID
    let isPinned: Bool
    let isLoading: Bool
    let lastAccessedAt: Date
}

enum TabMemoryPressurePolicy {
    static func discardIDs(
        from candidates: [TabMemoryPressureCandidate],
        level: TabMemoryPressureLevel
    ) -> [UUID] {
        switch level {
        case .warning:
            // 轻度压力只处理普通、已完成加载且最久未访问的后台标签。
            let eligible = candidates
                .filter { !$0.isPinned && !$0.isLoading }
                .sorted { $0.lastAccessedAt < $1.lastAccessedAt }
            guard !eligible.isEmpty else { return [] }
            let discardCount = max(1, (eligible.count + 2) / 3)
            return eligible.prefix(discardCount).map(\.id)

        case .critical:
            // 严重压力下需要尽快释放所有后台页面。普通标签先于固定标签，
            // 已完成加载的标签先于仍在加载的标签；当前标签不会进入候选集。
            return candidates
                .sorted {
                    let leftRank = protectionRank(for: $0)
                    let rightRank = protectionRank(for: $1)
                    if leftRank != rightRank { return leftRank < rightRank }
                    return $0.lastAccessedAt < $1.lastAccessedAt
                }
                .map(\.id)
        }
    }

    private static func protectionRank(for candidate: TabMemoryPressureCandidate) -> Int {
        (candidate.isPinned ? 2 : 0) + (candidate.isLoading ? 1 : 0)
    }
}
