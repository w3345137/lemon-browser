import Foundation

enum TabCloseSelectionPolicy {
    /// 关闭当前标签后优先回到它左侧的标签；仅当它原本位于最左侧时，
    /// 才选择删除后留在第一个位置的标签。
    static func fallbackIndex(closedIndex: Int, remainingCount: Int) -> Int {
        precondition(remainingCount > 0)
        return min(max(closedIndex - 1, 0), remainingCount - 1)
    }
}
