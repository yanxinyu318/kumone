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
                        Text("粘贴 JSON / 配置内容（与 Beans 的导入格式兼容）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .url:
                        TextField("输入远程音源地址", text: $importURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("填写返回 JSON 的音源链接，会自动下载并识别。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .file:
                        Button("选择本地文件") { showFileImporter = true }
                        Text("支持 JSON、TXT 等文本文件。")
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
                                Text(source.template)
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
                    Text("模板占位符：{id} 歌曲 ID、{keyword} 歌名+歌手、{source} 平台、{quality} 所选音质；字段路径如 url 或 data.url，留空表示整个响应就是地址。脚本音源暂不支持，仅使用 URL 模板解析。")
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
                TextField("URL 模板", text: $template, axis: .vertical)
                TextField("字段路径", text: $urlPath)
                TextField("默认音质", text: $quality)
                Toggle("启用", isOn: $enabled)
                if source.script != nil {
                    Text("该音源含有脚本内容，Kumone 暂不支持脚本执行，仅使用 URL 模板解析。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                    .disabled(template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
/// 粘贴纯链接时自动按链接方式取回再解析；LX / JS 脚本暂不支持。
enum CustomAudioSourceImportParser {
    static func parse(text: String) async throws -> [CustomAudioSource] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CustomAudioSourceImportError.empty }
        if (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")),
           let url = URL(string: trimmed) {
            return try await fetch(url: url)
        }
        guard let sources = parseJSON(trimmed), !sources.isEmpty else {
            throw CustomAudioSourceImportError.unsupported
        }
        return sources
    }

    static func parse(fileURL: URL) throws -> [CustomAudioSource] {
        let data = try Data(contentsOf: fileURL)
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .unicode)
        guard let text else { throw CustomAudioSourceImportError.unsupported }
        guard let sources = parseJSON(text), !sources.isEmpty else {
            throw CustomAudioSourceImportError.unsupported
        }
        return sources
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
        guard let text, let sources = parseJSON(text), !sources.isEmpty else {
            throw CustomAudioSourceImportError.unsupported
        }
        return sources
    }

    private static func parseJSON(_ text: String) -> [CustomAudioSource]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        if let array = object as? [[String: Any]] {
            return unique(array.compactMap(decode))
        }
        if let dict = object as? [String: Any], let source = decode(dict) {
            return [source]
        }
        return nil
    }

    private static func decode(_ dict: [String: Any]) -> CustomAudioSource? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              var source = try? JSONDecoder().decode(CustomAudioSource.self, from: data),
              !source.template.isEmpty
        else { return nil }
        if source.name.isEmpty {
            source.name = String(localized: "未命名音源")
        }
        return source
    }

    private static func unique(_ sources: [CustomAudioSource]) -> [CustomAudioSource] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0.template).inserted }
    }
}
