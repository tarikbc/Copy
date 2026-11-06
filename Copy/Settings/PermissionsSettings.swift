import AppKit
import CopyCore
import SwiftUI
import UniformTypeIdentifiers

struct PermissionsSettings: View {
    @Bindable var settings: SettingsStore
    @State private var selected: PasteStackPermission?
    @State private var accessError = false

    var body: some View {
        Form {
            Section {
                Toggle("Allow requests from external apps", isOn: Binding(
                    get: { settings.pasteStackExternalAccessEnabled },
                    set: { if !settings.setExternalPasteStackAccess($0) { accessError = true } }
                ))
            } footer: {
                Text("Enabling this may ask for authorization to access the Keychain.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if settings.pasteStackPermissions.isEmpty {
                    Text("No authorized apps").foregroundStyle(.secondary)
                } else {
                    List(settings.pasteStackPermissions, id: \.self, selection: $selected) { permission in
                        permissionRow(permission).tag(permission)
                    }
                    .frame(minHeight: 160)
                }
                HStack {
                    Button { addDeveloperException() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add Developer Exception")
                        .disabled(!settings.pasteStackExternalAccessEnabled)
                    Button {
                        guard let selected else { return }
                        if settings.setPasteStackPermissions(settings.pasteStackPermissions.filter { $0 != selected }) {
                            self.selected = nil
                        } else {
                            accessError = true
                        }
                    } label: { Image(systemName: "minus") }
                        .accessibilityLabel("Forget App")
                        .disabled(selected == nil || !settings.pasteStackExternalAccessEnabled)
                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } header: {
                Text("Paste Stack Access")
            } footer: {
                Text("Apps listed here can send items to Paste Stack. Existing items still require confirmation before replacement.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Text("Unsafe developer exceptions match an app's name and location without verifying its signing certificate.")
                Text("Only enable this for apps you are developing.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Developer Exceptions")
            }
        }
        .formStyle(.grouped)
        .alert("Keychain access unavailable", isPresented: $accessError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Copy could not securely save this setting. Check Keychain access and try again.")
        }
    }

    @ViewBuilder
    private func permissionRow(_ permission: PasteStackPermission) -> some View {
        switch permission {
        case let .signed(bundleID, _, _):
            VStack(alignment: .leading) {
                Text(bundleID)
                Text("Verified signature").font(.caption).foregroundStyle(.secondary)
            }
        case let .developer(bundleID, canonicalPath):
            VStack(alignment: .leading) {
                Text(bundleID)
                Text("Unsafe developer exception").font(.caption).foregroundStyle(.secondary)
                Text(canonicalPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func addDeveloperException() {
        guard settings.allowsExternalPasteStackRequests() else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL.resolvingSymlinksInPath(),
              let bundleID = Bundle(url: url)?.bundleIdentifier, !bundleID.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Add unsafe developer exception?"
        alert.informativeText = "Copy will trust any app at \(url.path) with the identifier \(bundleID), even if its signing certificate changes. Only enable this for apps you are developing."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Add Exception")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let permission = PasteStackPermission.developer(bundleID: bundleID, canonicalPath: url.path)
        if !settings.pasteStackPermissions.contains(permission) {
            if !settings.setPasteStackPermissions(settings.pasteStackPermissions + [permission]) { accessError = true }
        }
    }
}
