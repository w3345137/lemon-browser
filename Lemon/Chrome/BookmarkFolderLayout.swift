import Foundation
import CoreGraphics

struct BookmarkFolderLayout {
    static let columnWidth: CGFloat = 344
    static let twoColumnWidth: CGFloat = columnWidth * 2 + 1
    static let rowStride: CGFloat = 30
    static let fixedChromeHeight: CGFloat = 50
    static let minimumHeight: CGFloat = 102

    let maximumHeight: CGFloat
    let rowsPerColumn: Int
    let columnCount: Int
    let contentSize: CGSize

    init(childCount: Int, maximumHeight: CGFloat) {
        let safeMaximumHeight = max(Self.minimumHeight, maximumHeight.rounded(.down))
        let availableRows = max(
            1,
            Int(floor((safeMaximumHeight - Self.fixedChromeHeight) / Self.rowStride))
        )
        let usesTwoColumns = childCount > availableRows
        let visibleRows = usesTwoColumns ? availableRows : max(0, childCount)
        // 一旦需要分列，菜单就向下用满可用高度；避免第二列已经出现，底部仍留出
        // 一截无意义空白，也让两列的滚动与拖放区域保持稳定。
        let naturalHeight = usesTwoColumns
            ? safeMaximumHeight
            : max(
                Self.minimumHeight,
                CGFloat(visibleRows) * Self.rowStride + Self.fixedChromeHeight
            )

        self.maximumHeight = safeMaximumHeight
        self.rowsPerColumn = availableRows
        self.columnCount = usesTwoColumns ? 2 : 1
        self.contentSize = CGSize(
            width: usesTwoColumns ? Self.twoColumnWidth : Self.columnWidth,
            height: min(safeMaximumHeight, naturalHeight)
        )
    }

    func split<Item>(_ items: [Item]) -> (first: ArraySlice<Item>, second: ArraySlice<Item>) {
        guard columnCount == 2 else {
            return (items[...], items[items.endIndex...])
        }

        // 常见情形严格按“第一列填满，再进入第二列”排列。极大文件夹超过
        // 两列一屏时平分为两条可同步滚动的长列，确保所有项目都可访问。
        let splitOffset: Int
        if items.count <= rowsPerColumn * 2 {
            splitOffset = min(rowsPerColumn, items.count)
        } else {
            splitOffset = Int(ceil(Double(items.count) / 2.0))
        }
        let splitIndex = items.index(items.startIndex, offsetBy: splitOffset)
        return (items[..<splitIndex], items[splitIndex...])
    }
}

struct BookmarkFolderPanelGeometry {
    static let edgeGap: CGFloat = 4
    static let screenMargin: CGFloat = 8

    static func frame(
        below anchorFrame: CGRect,
        contentSize: CGSize,
        within visibleFrame: CGRect
    ) -> CGRect {
        let maximumWidth = max(1, visibleFrame.width - screenMargin * 2)
        let width = min(contentSize.width, maximumWidth)
        let maximumHeight = max(
            1,
            anchorFrame.minY - edgeGap - visibleFrame.minY - screenMargin
        )
        let height = min(contentSize.height, maximumHeight)
        let minimumX = visibleFrame.minX + screenMargin
        let maximumX = max(minimumX, visibleFrame.maxX - screenMargin - width)
        let x = min(max(anchorFrame.minX, minimumX), maximumX)
        let y = anchorFrame.minY - edgeGap - height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
