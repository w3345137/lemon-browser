import Foundation
import CoreGraphics

@main
enum TestBookmarkFolderLayout {
    static func main() {
        let short = BookmarkFolderLayout(childCount: 4, maximumHeight: 780)
        precondition(short.columnCount == 1)
        precondition(short.contentSize.width == 344)
        precondition(short.contentSize.height == 170)

        let compactScreen = BookmarkFolderLayout(childCount: 18, maximumHeight: 372)
        precondition(compactScreen.rowsPerColumn == 10)
        precondition(compactScreen.columnCount == 2)
        precondition(compactScreen.contentSize.width == 689)
        precondition(compactScreen.contentSize.height == 372)
        let compactSplit = compactScreen.split(Array(0..<18))
        precondition(Array(compactSplit.first) == Array(0..<10))
        precondition(Array(compactSplit.second) == Array(10..<18))

        let veryLarge = BookmarkFolderLayout(childCount: 50, maximumHeight: 372)
        let largeSplit = veryLarge.split(Array(0..<50))
        precondition(largeSplit.first.count == 25)
        precondition(largeSplit.second.count == 25)

        let empty = BookmarkFolderLayout(childCount: 0, maximumHeight: 780)
        precondition(empty.columnCount == 1)
        precondition(empty.contentSize.height == BookmarkFolderLayout.minimumHeight)

        let overflow = BookmarkFolderLayout(
            childCount: 6,
            maximumHeight: 780,
            fixedChromeHeight: 8,
            minimumHeight: 46
        )
        precondition(overflow.columnCount == 1)
        precondition(overflow.contentSize.height == 188)

        let anchor = CGRect(x: 420, y: 690, width: 80, height: 30)
        let visibleFrame = CGRect(x: 0, y: 40, width: 1280, height: 760)
        let panelFrame = BookmarkFolderPanelGeometry.frame(
            below: anchor,
            contentSize: CGSize(width: 689, height: 620),
            within: visibleFrame
        )
        precondition(panelFrame.maxY == anchor.minY - BookmarkFolderPanelGeometry.edgeGap)
        precondition(panelFrame.minY >= visibleFrame.minY + BookmarkFolderPanelGeometry.screenMargin)
        precondition(panelFrame.maxX <= visibleFrame.maxX - BookmarkFolderPanelGeometry.screenMargin)

        print("Bookmark folder layout tests passed")
    }
}
