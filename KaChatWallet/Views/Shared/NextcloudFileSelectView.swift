import SwiftUI

// MARK: - Folder selection (Settings > Storage > Nextcloud > Backup Folder)

/// Browses the connected account's folders and hands back the one chosen ("" = the files root).
struct NextcloudFolderSelectView: View {
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NextcloudFolderSelectList(path: "", title: "All Files") { selected in
                dismiss()
                onSelect(selected)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct NextcloudFolderSelectList: View {
    let path: String
    let title: String
    let onChoose: (String) -> Void

    @State private var folders: [NextcloudFile] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Button {
                    onChoose(path)
                } label: {
                    Label(path.isEmpty ? "Use All Files" : "Use This Folder", systemImage: "checkmark.circle")
                }
            }
            Section {
                ForEach(folders) { folder in
                    NavigationLink {
                        NextcloudFolderSelectList(path: folder.path, title: folder.name, onChoose: onChoose)
                    } label: {
                        Label(folder.name, systemImage: "folder")
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                if !isLoading && folders.isEmpty && errorMessage == nil {
                    Text("No subfolders.")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: path) {
            isLoading = true
            errorMessage = nil
            do {
                // Newest-first comes from listFolder; this only drops the non-folder entries.
                folders = try await NextcloudService.shared.listFolder(path)
                    .filter(\.isDirectory)
            } catch {
                errorMessage = UserFacingError.message(for: error)
            }
            isLoading = false
        }
    }
}

// MARK: - File selection (Address Book and Portfolio > Import from Nextcloud)

/// Browses the connected account's files and hands back the file the user taps. Starts in the
/// KaChat folder (where Export to Nextcloud
/// puts files) with "All Files" to go to the root. Only files whose extension is in
/// `allowedExtensions` can be picked; the rest show dimmed so a folder still reads as it is.
struct NextcloudFileSelectView: View {
    let allowedExtensions: Set<String>
    let onPick: (NextcloudFile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rootPath: String

    init(allowedExtensions: Set<String>, onPick: @escaping (NextcloudFile) -> Void) {
        self.allowedExtensions = allowedExtensions
        self.onPick = onPick
        _rootPath = State(initialValue: NextcloudService.backupFolderName)
    }

    var body: some View {
        NavigationStack {
            NextcloudFileSelectList(path: rootPath, title: rootTitle, allowedExtensions: allowedExtensions) { file in
                dismiss()
                onPick(file)
            }
            .id(rootPath) // switching to "All Files" swaps the navigation root
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                if !rootPath.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("All Files") { rootPath = "" }
                    }
                }
            }
        }
    }

    private var rootTitle: String {
        if rootPath.isEmpty { return "Nextcloud" }
        return rootPath.split(separator: "/").last.map(String.init) ?? "Nextcloud"
    }
}

private struct NextcloudFileSelectList: View {
    let path: String
    let title: String
    let allowedExtensions: Set<String>
    let onPick: (NextcloudFile) -> Void

    @State private var files: [NextcloudFile] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            ForEach(files) { file in
                if file.isDirectory {
                    NavigationLink {
                        NextcloudFileSelectList(path: file.path, title: file.name, allowedExtensions: allowedExtensions, onPick: onPick)
                    } label: {
                        Label(file.name, systemImage: "folder")
                    }
                } else {
                    let pickable = isPickable(file)
                    Button {
                        onPick(file)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: pickable ? "doc.text.fill" : "doc")
                                .foregroundColor(pickable ? .accentColor : .secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .foregroundColor(pickable ? .primary : .secondary)
                                    .lineLimit(1)
                                if let detail = detail(for: file) {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .disabled(!pickable)
                }
            }
            if !isLoading && files.isEmpty && errorMessage == nil {
                Text("This folder is empty.")
                    .foregroundColor(.secondary)
            }
        }
        .overlay {
            if isLoading && files.isEmpty { ProgressView() }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: path) { await load() }
        .refreshable { await load() }
    }

    private func isPickable(_ file: NextcloudFile) -> Bool {
        allowedExtensions.contains((file.name as NSString).pathExtension.lowercased())
    }

    private func detail(for file: NextcloudFile) -> String? {
        var parts: [String] = []
        if let size = file.size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let modified = file.modified { parts.append(modified.formatted(date: .abbreviated, time: .shortened)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            files = try await NextcloudService.shared.listFolder(path)
        } catch NextcloudError.httpError(404) {
            // The KaChat folder doesn't exist until something is first saved to it.
            files = []
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
        isLoading = false
    }
}
