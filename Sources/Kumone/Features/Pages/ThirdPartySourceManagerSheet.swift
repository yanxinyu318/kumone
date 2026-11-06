import SwiftUI
import UniformTypeIdentifiers

/// 第三方音源管理 / 导入：粘贴文本、远程链接、本地文件三种导入方式 + 列表开关 / 删除 / 编辑。
struct ThirdPartySourceManagerSheet: View {
    @ObservedObject private var store = CustomAudioSourceStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var importMode: ImportMode = .paste
    @State private var importText = ""
    @State private var importURL = ""
    @State private var showFileImporter = false
    @State private var importStatus: String?
    @State private var showImportError = false
    @State private var importErrorMessage = ""
    @State private var editingSource: CustomAudioSource?

    private enum ImportMode: String, CaseIterable, Identifiable {
        case paste
        case url
        case file

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .paste: return String(localized: "文本")
            case .url: return String(localized: "链接")
            case .file: return String(localized: "文件")
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("导入音源") {
                    Picker("导入方式", selection: $importMode) {
                        ForEach(ImportMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    switch importMode {
                    case .paste:
                        TextEditor(text: $importText)
                            .frame(minHeight: 120)
                        Text("粘贴 JSON / 配置内容，也支持 LX Music / BakaMusic 风格的 JS 音源脚本。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .url:
                        TextField("输入远程音源地址", text: $importURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("支持 JSON 数组、单个配置、`SERVER_SCRIPT_CONFIG` 片段，以及 `@name` / `@template` 头部格式。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .file:
                        Button("选择本地文件") { showFileImporter = true }
                        Text("支持 JSON、JS、TXT 等文本文件。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("识别并导入") { Task { await importCurrent() } }
                    if let importStatus {
                        Text(importStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("已导入（\(store.sources.count) 个）") {
                    if store.sources.isEmpty {
                        Text("还没有音源，先导入一个吧。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.sources) { source in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                    .lineLimit(1)
                                Text(source.isScriptSource ? "脚本 · \(source.quality)" : source.template)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { source.enabled },
                                set: { enabled in
                                    var updated = source
                                    updated.enabled = enabled
                                    store.update(updated)
                                }
                            ))
                            .labelsHidden()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editingSource = source }
                    }
                    .onDelete { store.remove(at: $0) }
                }

                Section {
                    Text("模板占位符：{id} 歌曲 ID、{keyword} 歌名+歌手、{source} 平台、{quality} 所选音质；字段路径如 url 或 data.url，留空表示整个响应就是地址。JS 脚本音源播放时会在应用内执行脚本取地址。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("导入与管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.json, .plainText],
                allowsMultipleSelection: false
            ) { result in
                Task { await importFile(result) }
            }
            .alert("导入失败", isPresented: $showImportError) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(importErrorMessage)
            }
            .sheet(item: $editingSource) { source in
                ThirdPartySourceEditSheet(source: source)
            }
        }
    }

    private func importCurrent() async {
        do {
            let parsed: [CustomAudioSource]
            switch importMode {
            case .paste:
                parsed = try await CustomAudioSourceImportParser.parse(text: importText)
            case .url:
                guard let url = URL(string: importURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                      url.scheme == "http" || url.scheme == "https"
                else { throw CustomAudioSourceImportError.invalidURL }
                parsed = try await CustomAudioSourceImportParser.fetch(url: url)
            case .file:
                return
            }
            let added = store.add(parsed)
            importStatus = added > 0
                ? "已导入 \(added) 个音源"
                : "没有新增音源（可能已存在）"
        } catch {
            importErrorMessage = error.localizedDescription
            showImportError = true
        }
    }

    private func importFile(_ result: Result<[URL], Error>) async {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            let parsed = try CustomAudioSourceImportParser.parse(fileURL: url)
            let added = store.add(parsed)
            importStatus = added > 0
                ? "已导入 \(added) 个音源"
                : "没有新增音源（可能已存在）"
        } catch {
            importErrorMessage = error.localizedDescription
            showImportError = true
        }
    }
}

private struct ThirdPartySourceEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let source: CustomAudioSource

    @State private var name: String
    @State private var template: String
    @State private var urlPath: String
    @State private var quality: String
    @State private var enabled: Bool

    init(source: CustomAudioSource) {
        self.source = source
        _name = State(initialValue: source.name)
        _template = State(initialValue: source.template)
        _urlPath = State(initialValue: source.urlPath)
        _quality = State(initialValue: source.quality)
        _enabled = State(initialValue: source.enabled)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("音源名称", text: $name)
                if source.isScriptSource {
                    TextField("URL 模板", text: $template, axis: .vertical)
                        .disabled(true)
                    Text("该音源是 JS 脚本，播放时执行脚本取地址，模板不适用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("URL 模板", text: $template, axis: .vertical)
                    TextField("字段路径", text: $urlPath)
                }
                TextField("默认音质", text: $quality)
                Toggle("启用", isOn: $enabled)
            }
            .navigationTitle("编辑音源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var updated = source
                        updated.name = name
                        updated.template = template
                        updated.urlPath = urlPath
                        updated.quality = quality
                        updated.enabled = enabled
                        CustomAudioSourceStore.shared.update(updated)
                        dismiss()
                    }
                    .disabled(!source.isScriptSource && template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

enum CustomAudioSourceImportError: LocalizedError {
    case empty
    case unsupported
    case invalidURL
    case network(String)
    case noValidSource

    var errorDescription: String? {
        switch self {
        case .empty: return String(localized: "内容为空")
        case .unsupported: return String(localized: "无法识别该音源格式")
        case .invalidURL: return String(localized: "链接无效")
        case .network(let message): return message
        case .noValidSource: return String(localized: "没有可导入的音源")
        }
    }
}

/// 导入解析：JSON 单个对象或数组（name / template / urlPath / headers / quality，与 Beans 格式兼容）；
/// LX / Baka 风格 JS 音源脚本（`SERVER_SCRIPT_CONFIG` 片段、`@name` / `@template` 头部、或完整脚本）；
/// 粘贴纯链接时自动按链接方式取回再解析。
enum CustomAudioSourceImportParser {
    static func parse(text: String) async throws -> [CustomAudioSource] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CustomAudioSourceImportError.empty }
        if (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")),
           let url = URL(string: trimmed) {
            return try await fetch(url: url)
        }
        return try parseText(trimmed, fallbackName: nil)
    }

    static func parse(fileURL: URL) throws -> [CustomAudioSource] {
        let data = try Data(contentsOf: fileURL)
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .unicode)
        guard let text else { throw CustomAudioSourceImportError.unsupported }
        let fallbackName = fileURL.deletingPathExtension().lastPathComponent
        return try parseText(text, fallbackName: fallbackName)
    }

    static func fetch(url: URL) async throws -> [CustomAudioSource] {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw CustomAudioSourceImportError.invalidURL
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CustomAudioSourceImportError.network("HTTP \(http.statusCode)")
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .unicode)
        guard let text else { throw CustomAudioSourceImportError.unsupported }
        let fallbackName = url.deletingPathExtension().lastPathComponent
        return try parseText(text, fallbackName: fallbackName)
    }

    private static func parseText(_ text: String, fallbackName: String?) throws -> [CustomAudioSource] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CustomAudioSourceImportError.empty }
        if let jsonSources = parseJSON(trimmed, fallbackName: fallbackName), !jsonSources.isEmpty {
            return unique(jsonSources)
        }
        // 完整 LX 脚本里可能含 SERVER_SCRIPT_CONFIG 或 module.exports：先按脚本整体存下来。
        if isLXScript(trimmed),
           let scriptSources = parseLooseScript(trimmed, fallbackName: fallbackName),
           !scriptSources.isEmpty {
            return unique(scriptSources)
        }
        if let scriptSources = parseScript(trimmed, fallbackName: fallbackName), !scriptSources.isEmpty {
            return unique(scriptSources)
        }
        if let headerSources = parseHeaderStyle(trimmed, fallbackName: fallbackName), !headerSources.isEmpty {
            return unique(headerSources)
        }
        if let scriptSources = parseLooseScript(trimmed, fallbackName: fallbackName), !scriptSources.isEmpty {
            return unique(scriptSources)
        }
        throw CustomAudioSourceImportError.unsupported
    }

    // MARK: - JSON

    private static func parseJSON(_ text: String, fallbackName: String?) -> [CustomAudioSource]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let array = object as? [Any] {
            let sources = array.compactMap { parseDictionary($0 as? [String: Any], fallbackName: fallbackName) }
            return sources.isEmpty ? nil : sources
        }
        if let dict = object as? [String: Any] {
            if let nested = dict["sources"] as? [Any] {
                let sources = nested.compactMap { parseDictionary($0 as? [String: Any], fallbackName: fallbackName) }
                if !sources.isEmpty { return sources }
            }
            if let nested = dict["items"] as? [Any] {
                let sources = nested.compactMap { parseDictionary($0 as? [String: Any], fallbackName: fallbackName) }
                if !sources.isEmpty { return sources }
            }
            if let source = parseDictionary(dict, fallbackName: fallbackName) {
                return [source]
            }
        }
        return nil
    }

    private static func parseDictionary(_ dict: [String: Any]?, fallbackName: String?) -> CustomAudioSource? {
        guard let dict else { return nil }
        let name = string(in: dict, keys: ["name", "title", "sourceName"])
            ?? fallbackName
            ?? String(localized: "未命名音源")
        let script = string(in: dict, keys: ["script", "scriptText", "code"])
        let kind = string(in: dict, keys: ["kind", "type"])
            ?? (script == nil ? "keyword" : "script")
        let urlPath = string(in: dict, keys: ["urlPath", "path"]) ?? "url"
        let template = templateString(from: dict)
        guard !template.isEmpty || script?.isEmpty == false else { return nil }
        let quality = string(in: dict, keys: ["quality", "br"]) ?? "320k"

        var headers = dictionary(in: dict, key: "headers")
        if let qualities = qualityStrings(in: dict), !qualities.isEmpty {
            headers["qualities"] = qualities.joined(separator: ",")
        }
        for key in ["source", "quality", "br", "apiKey", "apiKeys", "signSalt", "fingerprint", "cookie", "tx_cookie", "wy_cookie"] {
            if let value = string(in: dict, keys: [key]), !value.isEmpty {
                headers[key] = value
            }
        }
        if headers["source"] == nil, let platform = platformCode(from: dict) {
            headers["source"] = platform
        }

        let enabled = bool(in: dict, keys: ["enabled"], defaultValue: true)
        return CustomAudioSource(
            name: name,
            kind: kind,
            template: template,
            urlPath: urlPath,
            headers: headers,
            quality: quality,
            script: script,
            enabled: enabled
        )
    }

    private static func templateString(from dict: [String: Any]) -> String {
        if let template = string(in: dict, keys: ["template"]), !template.isEmpty {
            return template
        }
        if let url = string(in: dict, keys: ["apiUrl", "baseURL", "baseUrl", "url", "endpoint"]), !url.isEmpty {
            if dict["apiKey"] != nil || dict["signSalt"] != nil || dict["fingerprint"] != nil {
                return url.hasSuffix("/url?source={source}&songId={id}&quality={quality}")
                    ? url
                    : url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        + "/url?source={source}&songId={id}&quality={quality}"
            }
            return url
        }
        return ""
    }

    // MARK: - Script / header blocks

    private static func parseScript(_ text: String, fallbackName: String?) -> [CustomAudioSource]? {
        let patterns = [
            #"SERVER_SCRIPT_CONFIG\s*=\s*(\{[\s\S]*?\})"#,
            #"globalThis\[['"]SERVER_SCRIPT_CONFIG['"]\]\s*=\s*(\{[\s\S]*?\})"#,
            #"module\.exports\s*=\s*(\{[\s\S]*?\})"#,
            #"export\s+default\s*(\{[\s\S]*?\})"#
        ]
        for pattern in patterns {
            if let json = extractFirstJSONObject(from: text, pattern: pattern),
               let data = json.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let source = parseDictionary(object, fallbackName: fallbackName) {
                return [source]
            }
        }
        return nil
    }

    private static func parseHeaderStyle(_ text: String, fallbackName: String?) -> [CustomAudioSource]? {
        guard let block = extractCommentBlock(text) else { return nil }
        var values: [String: String] = [:]
        for line in block.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "* "))
            guard cleaned.hasPrefix("@") else { continue }
            let content = cleaned.dropFirst()
            let pieces = content.split(maxSplits: 1, omittingEmptySubsequences: false) { $0 == " " || $0 == "\t" || $0 == "=" }
            guard let keyPart = pieces.first else { continue }
            let valuePart = pieces.count > 1 ? String(pieces[1]).trimmingCharacters(in: .whitespaces) : ""
            values[String(keyPart).lowercased()] = valuePart
        }

        guard !values.isEmpty else { return nil }
        let name = values["name"]?.isEmpty == false ? values["name"]! : (fallbackName ?? String(localized: "未命名音源"))
        let kind = values["kind"].flatMap { $0.isEmpty ? nil : $0 } ?? "keyword"
        let quality = values["quality"].flatMap { $0.isEmpty ? nil : $0 } ?? values["br"].flatMap { $0.isEmpty ? nil : $0 } ?? "320k"
        let template = values["template"].flatMap { $0.isEmpty ? nil : $0 }
            ?? values["apiurl"].flatMap { $0.isEmpty ? nil : $0 }
            ?? values["url"].flatMap { $0.isEmpty ? nil : $0 }
            ?? ""
        guard !template.isEmpty else { return nil }
        let urlPath = values["urlpath"].flatMap { $0.isEmpty ? nil : $0 } ?? "url"
        var headers: [String: String] = [:]
        if let headersValue = values["headers"], !headersValue.isEmpty {
            if let data = headersValue.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                headers = obj.compactMapValues { $0 as? String }
            } else {
                for pair in headersValue.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" }) {
                    let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    if parts.count == 2 {
                        headers[String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)] =
                            String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }
        for (key, value) in values where key != "name" && key != "kind" && key != "template" && key != "urlpath" && key != "headers" {
            if !value.isEmpty { headers[key] = value }
        }
        if headers["source"] == nil, let platform = values["source"], !platform.isEmpty {
            headers["source"] = platform
        }
        let enabled = boolString(values["enabled"], defaultValue: true)
        return [CustomAudioSource(
            name: name,
            kind: kind,
            template: template,
            urlPath: urlPath,
            headers: headers,
            quality: quality,
            enabled: enabled
        )]
    }

    private static func parseLooseScript(_ text: String, fallbackName: String?) -> [CustomAudioSource]? {
        guard looksLikeScript(text) else { return nil }
        let name = extractHeaderName(text) ?? fallbackName ?? String(localized: "未命名脚本音源")
        let headers = extractLooseHeaders(from: text)
        let quality = headers["quality"] ?? headers["br"] ?? "320k"
        let source = CustomAudioSource(
            name: name,
            kind: "script",
            template: "",
            urlPath: "url",
            headers: headers,
            quality: quality,
            script: text,
            enabled: true
        )
        return [source]
    }

    private static func looksLikeScript(_ text: String) -> Bool {
        let markers = [
            "globalThis.lx",
            "EVENT_NAMES",
            "request(",
            "on(EVENT_NAMES.request",
            "module.exports",
            "export default",
            "MusicPlugin",
            "customFetch",
            "function",
            "const ",
            "let ",
            "var ",
            "=>"
        ]
        return markers.contains { text.contains($0) }
    }

    private static func isLXScript(_ text: String) -> Bool {
        let markers = [
            "globalThis.lx",
            "globalThis['lx']",
            "globalThis[\"lx\"]",
            "EVENT_NAMES.request",
            "EVENT_NAMES['request']",
            "EVENT_NAMES[\"request\"]",
            "on(EVENT_NAMES",
            "lx.request"
        ]
        return markers.contains { text.contains($0) }
    }

    private static func extractHeaderName(_ text: String) -> String? {
        guard let block = extractCommentBlock(text) else { return nil }
        for line in block.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "* "))
            guard cleaned.hasPrefix("@name") else { continue }
            let value = cleaned.dropFirst("@name".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func extractLooseHeaders(from text: String) -> [String: String] {
        var headers: [String: String] = [:]
        guard let block = extractCommentBlock(text) else { return headers }
        for line in block.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "* "))
            guard cleaned.hasPrefix("@") else { continue }
            let content = cleaned.dropFirst()
            let pieces = content.split(maxSplits: 1, omittingEmptySubsequences: false) { $0 == " " || $0 == "\t" || $0 == "=" }
            guard let keyPart = pieces.first else { continue }
            let valuePart = pieces.count > 1 ? String(pieces[1]).trimmingCharacters(in: .whitespaces) : ""
            let key = String(keyPart).lowercased()
            if !valuePart.isEmpty {
                headers[key] = valuePart
            }
        }
        return headers
    }

    private static func extractCommentBlock(_ text: String) -> String? {
        if let start = text.range(of: "/*!"),
           let end = text.range(of: "*/", range: start.upperBound..<text.endIndex) {
            return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = text.range(of: "/*"),
           let end = text.range(of: "*/", range: start.upperBound..<text.endIndex) {
            return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func extractFirstJSONObject(from text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: - Helpers

    private static func unique(_ sources: [CustomAudioSource]) -> [CustomAudioSource] {
        var seen = Set<String>()
        return sources.filter { source in
            let fingerprint = "\(source.name)|\(source.kind)|\(source.template)|\(source.urlPath)|\(source.quality)|\(source.scriptFingerprint)|\(source.headers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&"))"
            return seen.insert(fingerprint).inserted
        }
    }

    private static func string(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let value = dict[key] as? NSNumber {
                return value.stringValue
            }
        }
        return nil
    }

    private static func dictionary(in dict: [String: Any], key: String) -> [String: String] {
        guard let raw = dict[key] else { return [:] }
        if let stringDict = raw as? [String: String] { return stringDict }
        if let obj = raw as? [String: Any] {
            return obj.compactMapValues { $0 as? String }
        }
        return [:]
    }

    private static func bool(in dict: [String: Any], keys: [String], defaultValue: Bool) -> Bool {
        for key in keys {
            if let value = dict[key] as? Bool { return value }
            if let value = dict[key] as? NSNumber { return value.boolValue }
            if let value = dict[key] as? String { return boolString(value, defaultValue: defaultValue) }
        }
        return defaultValue
    }

    private static func boolString(_ value: String?, defaultValue: Bool) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else {
            return defaultValue
        }
        switch value {
        case "1", "true", "yes", "on", "enabled": return true
        case "0", "false", "no", "off", "disabled": return false
        default: return defaultValue
        }
    }

    private static func platformCode(from dict: [String: Any]) -> String? {
        let platform = string(in: dict, keys: ["source", "platform", "provider", "musicSource"])?.lowercased()
        switch platform {
        case "netease", "wy", "neteasecloudmusic", "cloud": return "wy"
        case "qq", "tx", "qqmusic": return "tx"
        case "kugou", "kg": return "kg"
        default: return nil
        }
    }

    private static func qualityStrings(in dict: [String: Any]) -> [String]? {
        for key in ["qualities", "qualityOptions", "qualitys"] {
            guard let raw = dict[key] else { continue }
            if let values = raw as? [String] {
                let normalized = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if !normalized.isEmpty { return normalized }
            }
            if let values = raw as? [Any] {
                let normalized = values.compactMap { value -> String? in
                    if let string = value as? String { return string }
                    if let number = value as? NSNumber { return number.stringValue }
                    return nil
                }
                if !normalized.isEmpty { return normalized }
            }
            if let value = raw as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return [value]
            }
        }
        return nil
    }
}

