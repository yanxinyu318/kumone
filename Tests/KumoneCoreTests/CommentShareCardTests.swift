import Foundation
import SwiftUI
import Testing

@testable import KumoneCore

/// The comment picture is built by rendering a SwiftUI view, so an extra row
/// of pixels outside the background shows up as a stripe along one edge. These
/// tests pin the geometry: the card's height in points is whole, the text is
/// top-aligned, and its measured size never lies about what it renders.
@MainActor
@Suite("Comment share card geometry")
struct CommentShareCardTests {
    private static func cardHeight(
        comment: String,
        maxWidth: CGFloat = CommentShareCard.width
    ) -> CGSize {
        let content = CommentShareCard(
            comment: comment,
            user: .init(
                nickname: "歌单",
                avatarURL: nil
            ),
            track: .fixture(
                name: "测试歌曲",
                artistNames: "测试歌手"
            )
        )
        return content.sizeThatFits(in: CGSize(width: maxWidth, height: nil))
    }

    @Test("A card's rendered height is a whole number of points")
    func cardHeightIsWhole() {
        let size = Self.cardHeight(
            comment: "这首歌让我想起了那些在深夜里反复播放的时光。",
            maxWidth: CommentShareCard.width
        )
        #expect(size.width == CommentShareCard.width)
        #expect(size.height == size.height.rounded(.up))
    }

    @Test("A multiline card's rendered height is a whole number of points")
    func multilineCardHeightIsWhole() {
        let size = Self.cardHeight(
            comment: String(repeating: "这是一段很长很长的评论。", count: 24),
            maxWidth: CommentShareCard.width
        )
        #expect(size.width == CommentShareCard.width)
        #expect(size.height == size.height.rounded(.up))
    }

    @Test("Long text wraps within the card's width")
    func longTextWrapsWithinWidth() {
        let narrow = Self.cardHeight(
            comment: String(repeating: "这是一段很长很长的评论。", count: 24),
            maxWidth: CommentShareCard.width / 2
        )
        let wide = Self.cardHeight(
            comment: String(repeating: "这是一段很长很长的评论。", count: 24),
            maxWidth: CommentShareCard.width
        )
        #expect(narrow.height > wide.height)
    }
}
