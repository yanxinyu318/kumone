import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 触感反馈：点播放/暂停、切歌、喜欢时震一下。
/// 受设置里“触感反馈”开关控制，关掉就全不震；iOS 专属，macOS 上是空操作。
@MainActor
enum Haptics {
    /// 轻点一下（播放/暂停、切歌）。
    static func tap() {
        #if os(iOS)
        guard SettingsManager.shared.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// 收藏成功那种确认感（喜欢）。
    static func success() {
        #if os(iOS)
        guard SettingsManager.shared.hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}
