//
//  ModulesView.swift
//  NaiveFlow
//
//  Created by NodePassProject on 10/9/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ModulesView: View {
    @Environment(Operations.self) private var operations
    @Environment(ModuleStore.self) private var moduleStore

    @State private var showAddAlert = false
    @State private var newModuleName = ""

    @State private var importFormat: ModuleFormat = .surge
    @State private var importWarnings: String?
    @State private var showFileImporter = false
    @State private var importError: String?

    @State private var showLinkImporter = false

    var body: some View {
        NavigationStack {
            List {
                if !moduleStore.modules.isEmpty {
                    Section {
                        ForEach(moduleStore.modules) { module in
                            NavigationLink {
                                ModuleDetailView(moduleId: module.id)
                            } label: {
                                row(for: module)
                            }
                        }
                        .onDelete { offsets in
                            operations.modules.remove(atOffsets: offsets)
                        }
                        .onMove { source, destination in
                            operations.modules.move(fromOffsets: source, toOffset: destination)
                        }
                    }
                }
            }
            .overlay {
                if moduleStore.modules.isEmpty {
                    ContentUnavailableView {
                        Label("No Modules", systemImage: "shippingbox")
                    }
                }
            }
            .navigationTitle("Modules")
            .toolbar {
                if !moduleStore.modules.isEmpty {
                    ToolbarItem {
                        EditButton()
                    }
                }
                if #available(iOS 27.0, *),
                   !ProcessInfo.processInfo.isiOSAppOnMac /* Workaround */ {
                    ToolbarOverflowMenu {
                        menuItems
                    }
                } else {
                    ToolbarItem {
                        Menu("More", systemImage: "ellipsis") {
                            menuItems
                        }
                    }
                }
            }
            .alert("Add Module", isPresented: $showAddAlert) {
                TextField("Name", text: $newModuleName)
                Button("Add") {
                    let name = newModuleName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    operations.modules.addEmpty(name: name)
                    newModuleName = ""
                }
                Button("Cancel", role: .cancel) {
                    newModuleName = ""
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [UTType(filenameExtension: importFormat.fileExtension) ?? .data]
            ) { result in
                handleFileImport(result)
            }
            .alert("Import Failed", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .sheet(isPresented: $showLinkImporter) {
                ImportModuleLinkView()
            }
            .alert("Import Notes", isPresented: Binding(
                get: { importWarnings != nil },
                set: { if !$0 { importWarnings = nil } }
            )) {
                Button("OK") { importWarnings = nil }
            } message: {
                Text(importWarnings ?? "")
            }

        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button {
            showAddAlert = true
        } label: {
            Label("Add Module", systemImage: "plus")
        }
        Button {
            showLinkImporter = true
        } label: {
            Label("Import Module", systemImage: "link")
        }
        Menu {
            ForEach(ModuleFormat.allCases) { format in
                Button(format.displayName) {
                    importFormat = format
                    importError = nil
                    showFileImporter = true
                }
            }
        } label: {
            Label("Import Module File", systemImage: "square.and.arrow.down")
        }
    }

    @ViewBuilder
    private func row(for module: Module) -> some View {
        HStack {
            ModuleIconView(iconLight: module.iconLight, iconDark: module.iconDark)
            Text(module.name)
            Spacer()
            statusLabel(enabled: module.enabled)
        }
    }

    private func statusLabel(enabled: Bool) -> some View {
        Text(enabled ? "On" : "Off")
            .foregroundStyle(.secondary)
    }

    private func handleFileImport(_ result: Result<URL, Error>) {
        let format = importFormat
        Task {
            do {
                let url = try result.get()
                guard format.acceptsFile(url) else {
                    importError = String(localized: "Choose a .\(format.fileExtension) file.")
                    return
                }
                let body = try ConfigurationImport.read(from: url)
                let base = url.deletingPathExtension().lastPathComponent
                let made = try await ModuleOperations.makeModule(from: body, fallbackName: base.isEmpty ? "Imported" : base, format: format)
                operations.modules.add(made.module, routingSeeds: made.routingSeeds)
                showNotes(made.warnings)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func showNotes(_ warnings: [String]) {
        importWarnings = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
    }

}
