import CryptoKit
import Foundation

/// 第三方音源音质：导入音源解析时 `{quality}` 占位符的替换值。
enum ThirdPartyAudioQuality: String, CaseIterable, Identifiable, Sendable {
    case kb128
    case kb320
    case flac
    case hires24

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .kb128: return "128k"
        case .kb320: return "320k"
        case .flac: return String(localized: "无损 FLAC")
        case .hires24: return "FLAC 24 位"
        }
    }

    /// 填进 URL 模板 `{quality}` 的值。
    var templateValue: String {
        switch self {
        case .kb128: return "128"
        case .kb320: return "320"
        case .flac: return "flac"
        case .hires24: return "hires"
        }
    }

    /// 脚本音源调用时传给脚本的音质（LX 风格），按从高到低逐个试、自动降级。
    var fallbackChain: [String] {
        switch self {
        case .kb128: return ["128k"]
        case .kb320: return ["320k", "128k"]
        case .flac: return ["flac", "320k", "128k"]
        case .hires24: return ["flac24bit", "flac", "320k", "128k"]
        }
    }
}

/// 用户导入的第三方音源（与 Beans 的导入格式兼容：name / template / urlPath / headers / quality）。
/// template：请求 URL 模板，支持 `{id}`（歌曲 ID）、`{keyword}`（歌名+歌手，URL 编码后）、
/// `{source}`（平台标识）、`{quality}`（按上面音质选择替换）占位符。
/// urlPath：从返回 JSON 里取播放地址的字段路径，如 "url" 或 "data.url"；留空表示整个响应就是地址。
/// script：LX / Baka 风格 JS 脚本原文（仅保存，不执行；脚本音源暂不支持，只用 URL 模板解析）。
struct CustomAudioSource: Identifiable, Codable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var kind: String = "keyword"
    var template: String
    var urlPath: String = "url"
    var headers: [String: String] = [:]
    var quality: String = "320"
    var script: String?
    var enabled: Bool = true

    /// 是否脚本音源（LX / Baka 风格 JS 脚本）：靠执行脚本取播放地址，不走 URL 模板。
    var isScriptSource: Bool {
        kind.lowercased().contains("script")
            || script?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// 去重指纹：模板音源用模板，脚本音源用脚本内容的 MD5（跨启动稳定）。
    var dedupKey: String {
        if !template.isEmpty { return "template:\(template)" }
        return "script:\(scriptFingerprint)"
    }

    var scriptFingerprint: String {
        guard let script, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let digest = Insecure.MD5.hash(data: Data(script.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, template, urlPath, headers, quality, script, enabled
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        kind: String = "keyword",
        template: String,
        urlPath: String = "url",
        headers: [String: String] = [:],
        quality: String = "320",
        script: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.template = template
        self.urlPath = urlPath
        self.headers = headers
        self.quality = quality
        self.script = script
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? String(localized: "未命名音源")
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "keyword"
        template = try container.decodeIfPresent(String.self, forKey: .template) ?? ""
        urlPath = try container.decodeIfPresent(String.self, forKey: .urlPath) ?? "url"
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        quality = try container.decodeIfPresent(String.self, forKey: .quality) ?? headers["quality"] ?? "320"
        script = try container.decodeIfPresent(String.self, forKey: .script)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// 第三方音源管理：只保存用户导入的音源配置（无内置预设）。
@MainActor
final class CustomAudioSourceStore: ObservableObject {
    static let shared = CustomAudioSourceStore()
    private static let storageKey = "settings.customAudioSources"

    @Published var sources: [CustomAudioSource] {
        didSet { save() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let list = try? JSONDecoder().decode([CustomAudioSource].self, from: data) {
            var seen = Set<String>()
            sources = list.filter {
                (!$0.template.isEmpty || !$0.scriptFingerprint.isEmpty)
                    && seen.insert($0.dedupKey).inserted
            }
        } else {
            sources = []
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// 导入一批音源：模板或脚本相同的视为重复、跳过；返回实际新增的数量。
    @discardableResult
    func add(_ newSources: [CustomAudioSource]) -> Int {
        let existing = Set(sources.map(\.dedupKey))
        let fresh = newSources.filter {
            (!$0.template.isEmpty || !$0.scriptFingerprint.isEmpty)
                && !existing.contains($0.dedupKey)
        }
        guard !fresh.isEmpty else { return 0 }
        sources.append(contentsOf: fresh)
        return fresh.count
    }

    func remove(at offsets: IndexSet) {
        sources.remove(atOffsets: offsets)
    }

    func remove(_ source: CustomAudioSource) {
        sources.removeAll { $0.id == source.id }
    }

    func update(_ source: CustomAudioSource) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[index] = source
    }
}
