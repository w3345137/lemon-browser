import Foundation

@main
struct TestTabCloseSelectionPolicy {
    static func main() {
        // 关闭中间标签：选择其左侧。
        precondition(
            TabCloseSelectionPolicy.fallbackIndex(closedIndex: 2, remainingCount: 4) == 1
        )

        // 关闭最右标签：选择新的最右标签，也就是被关闭标签的左侧。
        precondition(
            TabCloseSelectionPolicy.fallbackIndex(closedIndex: 4, remainingCount: 4) == 3
        )

        // 最左侧没有左邻居，只能选择删除后的第一个标签。
        precondition(
            TabCloseSelectionPolicy.fallbackIndex(closedIndex: 0, remainingCount: 3) == 0
        )

        print("tab-close-selection-policy-tests=passed")
    }
}
