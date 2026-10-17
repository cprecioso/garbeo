import PaseoKit
import SwiftUI

struct NewProjectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft = NewProjectDraft()
    @State private var isCreating = false
    @State private var error: String?
    #if os(macOS)
    @State private var choosingDirectory = false
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DirectoryField(text: $draft.path)
                        .accessibilityIdentifier(AccessibilityID.NewProject.path)
                    #if os(macOS)
                    // The daemon's directories are only this Mac's when it runs here.
                    if model.endpoint?.isLoopback == true {
                        Button("Choose…") { choosingDirectory = true }
                    }
                    #endif
                } header: {
                    Text("Directory")
                } footer: {
                    Text("A directory on \(model.serverInfo?.hostname ?? "the daemon's machine"), usually a Git repository.")
                }

                Section("Name") {
                    TextField("Name", text: $draft.name, prompt: Text(draft.namePrompt))
                        .accessibilityIdentifier(AccessibilityID.NewProject.name)
                }

                if let error = error ?? draft.problem {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier(AccessibilityID.NewProject.error)
                }
            }
            .formStyle(.grouped)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .onSubmit(create)
            .onChange(of: draft.path) { error = nil }
            .navigationTitle("New Project")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Create", action: create)
                            .disabled(!canCreate)
                            .accessibilityIdentifier(AccessibilityID.NewProject.create)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 300)
        .fileImporter(isPresented: $choosingDirectory, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { draft.path = url.path(percentEncoded: false) }
        }
        #endif
    }

    private var canCreate: Bool {
        draft.projectPath != nil && model.connection.isConnected && !isCreating
    }

    private func create() {
        guard canCreate, let projectPath = draft.projectPath else { return }
        isCreating = true
        error = nil
        Task {
            do {
                try await model.createProject(at: projectPath, name: draft.customName)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isCreating = false
        }
    }
}

/// What the New Project sheet has filled in.
struct NewProjectDraft {
    var path = ""
    var name = ""

    /// The directory to add, or nil while the path is invalid.
    var projectPath: ProjectPath? { try? ProjectPath.parse(path).get() }

    /// Why the path can't be used. Nil while it's empty, which just disables Create.
    var problem: String? {
        guard case .failure(let problem) = ProjectPath.parse(path), problem != .empty else { return nil }
        return problem.localizedDescription
    }

    /// The name the daemon would derive, shown until one is typed.
    var namePrompt: String { projectPath?.defaultName ?? "Automatic" }

    /// The name to give the project, or nil to keep the derived one.
    var customName: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == projectPath?.defaultName ? nil : trimmed
    }
}

/// A text field for a directory on the daemon's machine that suggests matching directories.
private struct DirectoryField: View {
    @Environment(AppModel.self) private var model
    @Binding var text: String
    @State private var suggestions: [String] = []
    #if os(iOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        TextField("Path", text: $text, prompt: Text(verbatim: "~/code/my-app"))
            .font(.body.monospaced())
            #if os(macOS)
            .textInputSuggestions(suggestions, id: \.self) { Text($0).textInputCompletion($0) }
            #else
            .focused($isFocused)
            .keyboardType(.URL)
            #endif
            .task(id: text) {
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { suggestions = []; return }
                // Debounce typing; a newer keystroke cancels this task.
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled,
                      let found = try? await model.directorySuggestions(query: text),
                      !Task.isCancelled
                else { return }
                suggestions = found
            }
        #if os(iOS)
        // iOS has no completion popup, so matches are rows below the field.
        if isFocused {
            ForEach(suggestions.prefix(5).filter { $0 != text }, id: \.self) { suggestion in
                Button {
                    text = suggestion
                } label: {
                    Label(suggestion, systemImage: "folder").font(.callout)
                }
            }
        }
        #endif
    }
}
