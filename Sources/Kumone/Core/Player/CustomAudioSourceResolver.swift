import Foundation
import os.log

/// 用用户导入的第三方音源解析播放地址：按模板发请求，从返回里按 urlPath 取地址。
enum CustomAudioSourceResolver {
    private static let log = Logger(subsystem: "sb.moe.kumone", category: "audio-source")

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 7
        config.timeoutIntervalForResource = 12
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// 并发尝试全部已启用的导入音源，第一个可用地址直接返回（慢源/失效源不拖住播放）。
    static func resolveFirst(
        track: Track,
        sources: [CustomAudioSource],
        quality: ThirdPartyAudioQuality
    ) async -> ResolvedAudioSource? {
        let enabled = sources.filter(\.enabled)
        guard !enabled.isEmpty else { return nil }
        return await withTaskGroup(of: ResolvedAudioSource?.self) { group in
            for source in enabled {
                group.addTask {
                    do {
                        return try await resolve(track: track, source: source, quality: quality)
                    } catch {
                        log.error(
                            "custom source=\(source.name, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                        )
                        return nil
                    }
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    static func resolve(
        track: Track,
        source: CustomAudioSource,
        quality: ThirdPartyAudioQuality
    ) async throws -> ResolvedAudioSource? {
        guard source.enabled, !source.template.isEmpty else { return nil }
        let keyword = AudioSourceTrackMatcher.keyword(for: track)
        let urlString = source.template
            .replacingOccurrences(of: "{id}", with: String(track.id))
            .replacingOccurrences(
                of: "{keyword}",
                with: keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            )
            .replacingOccurrences(of: "{source}", with: Upstream.tag)
            .replacingOccurrences(of: "{quality}", with: quality.templateValue)
        guard let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https"
        else { throw AudioSourceProviderError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 7
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        for (field, value) in source.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AudioSourceProviderError.invalidResponse
        }
        guard let playURL = extractPlayURL(data: data, urlPath: source.urlPath) else {
            throw AudioSourceProviderError.missingStreamURL
        }
        return ResolvedAudioSource(id: .custom, displayName: source.name, url: playURL)
    }

    /// 从响应里取播放地址：纯文本地址直接用；JSON 按 urlPath（"data.url" 这种点分路径）逐级取；
    /// urlPath 为空且响应本身就是字符串地址时也直接用。
    private static func extractPlayURL(data: Data, urlPath: String) -> URL? {
        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            text.hasPrefix("http") {
            return validatedURL(text)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let string = object as? String {
            return validatedURL(string)
        }
        let path = urlPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        var current: Any? = object
        for key in path.split(separator: ".") {
            if let dict = current as? [String: Any] {
                current = dict[String(key)]
            } else if let array = current as? [Any],
                      let index = Int(key),
                      array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        guard let urlString = current as? String else { return nil }
        return validatedURL(urlString)
    }

    private static func validatedURL(_ string: String) -> URL? {
        var value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("http://") {
            value = "https://" + value.dropFirst("http://".count)
        }
        guard let url = URL(string: value),
              url.scheme == "https" || url.scheme == "http"
        else { return nil }
        return url
    }
}
