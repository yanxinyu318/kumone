import Foundation
import os.log

/// 诊断用：记录内置音源（pyncmd / 酷狗 / 酷我）最近一次未命中的简短原因，供试听 Toast 区分“无曲库资源”与“接口报错/限流”。
final class BuiltinSourceLastFailure: @unchecked Sendable {
    static let shared = BuiltinSourceLastFailure()
    private let lock = NSLock()
    private var entries: [String] = []

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }

    func record(source: AudioSourceID, status: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append("\(source.displayName)(\(status))")
    }

    func takeSummary() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !entries.isEmpty else { return nil }
        defer { entries.removeAll() }
        return "内置源：" + entries.joined(separator: " / ")
    }
}

/// Resolves gray tracks from the direct pyncmd source, then built-in search
/// providers when pyncmd cannot serve the original song ID.
enum UnblockService {
    private static let log = Logger(subsystem: "sb.moe.kumone", category: "audio-source")
    private static let httpClient = AudioSourceClient.shared
    private static let fallbackProviders: [any AudioSourceProvider] = [
        KugouAudioSourceProvider(),
        KuwoAudioSourceProvider(),
    ]

    struct Resolution {
        let source: ResolvedAudioSource?
        let attemptedSources: Set<AudioSourceID>
    }

    static func resolve(
        _ track: Track,
        enabledSources: Set<AudioSourceID>,
        excluding attemptedSources: Set<AudioSourceID>,
        customSources: [CustomAudioSource] = [],
        customQuality: ThirdPartyAudioQuality = .kb320
    ) async -> Resolution {
        var newlyAttemptedSources = Set<AudioSourceID>()
        guard !Task.isCancelled else { return Resolution(source: nil, attemptedSources: []) }

        if attemptedSources.isEmpty {
            BuiltinSourceLastFailure.shared.reset()
        }

        // 用户导入的音源优先：买来的高音质源先试，失败再走内置源。
        if enabledSources.contains(.custom), !attemptedSources.contains(.custom) {
            let enabled = customSources.filter(\.enabled)
            if !enabled.isEmpty {
                newlyAttemptedSources.insert(.custom)
                if let resolved = await CustomAudioSourceResolver.resolveFirst(
                    track: track,
                    sources: enabled,
                    quality: customQuality
                ) {
                    return Resolution(source: resolved, attemptedSources: newlyAttemptedSources)
                }
            }
        }

        if enabledSources.contains(.pyncmd), !attemptedSources.contains(.pyncmd) {
            newlyAttemptedSources.insert(.pyncmd)
            do {
                return Resolution(
                    source: try await pyncmd(track),
                    attemptedSources: newlyAttemptedSources
                )
            } catch AudioSourceProviderError.missingBitrate, AudioSourceProviderError.missingStreamURL {
                BuiltinSourceLastFailure.shared.record(source: .pyncmd, status: "无资源")
                logFailure(source: .pyncmd, operation: "resolve", error: AudioSourceProviderError.missingStreamURL)
            } catch {
                if Task.isCancelled { return Resolution(source: nil, attemptedSources: newlyAttemptedSources) }
                BuiltinSourceLastFailure.shared.record(source: .pyncmd, status: "接口失败")
                logFailure(source: .pyncmd, operation: "resolve", error: error)
            }
        }

        for provider in fallbackProviders where enabledSources.contains(provider.id)
            && !attemptedSources.contains(provider.id) {
            guard !Task.isCancelled else { break }
            newlyAttemptedSources.insert(provider.id)
            do {
                if let resolved = try await provider.resolve(track: track) {
                    return Resolution(source: resolved, attemptedSources: newlyAttemptedSources)
                } else {
                    BuiltinSourceLastFailure.shared.record(source: provider.id, status: "无匹配")
                }
            } catch {
                if Task.isCancelled { break }
                BuiltinSourceLastFailure.shared.record(source: provider.id, status: "接口失败")
                logFailure(source: provider.id, operation: "resolve", error: error)
            }
        }
        return Resolution(source: nil, attemptedSources: newlyAttemptedSources)
    }

    private static func pyncmd(_ track: Track) async throws -> ResolvedAudioSource {
        let urlString = "https://music-api.gdstudio.xyz/api.php?types=url&source=\(Upstream.tag)&id=\(track.id)&br=320"
        let data = try await httpClient.data(
            from: urlString,
            source: .pyncmd,
            operation: "resolve"
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AudioSourceProviderError.invalidResponse
        }
        guard let bitrate = object["br"] as? Int, bitrate > 0 else {
            throw AudioSourceProviderError.missingBitrate
        }
        guard let urlValue = object["url"] as? String, !urlValue.isEmpty else {
            throw AudioSourceProviderError.missingStreamURL
        }
        guard let url = URL(string: urlValue.replacingOccurrences(of: "http://", with: "https://")) else {
            throw AudioSourceProviderError.invalidURL
        }
        return ResolvedAudioSource(id: .pyncmd, displayName: AudioSourceID.pyncmd.displayName, url: url)
    }

    private static func logFailure(source: AudioSourceID, operation: String, error: Error) {
        log.error(
            "source=\(source.rawValue, privacy: .public) operation=\(operation, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
    }
}
