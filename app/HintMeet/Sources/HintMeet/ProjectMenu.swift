import SwiftUI

/// Keuze van één of meer kennisbanken, met vinkjes; samen doorzocht tijdens de meeting.
struct ProjectMenu: View {
    @ObservedObject var settings: Settings
    /// "Add Folder…": een map kiezen die met kb_prep een nieuwe kennisbank wordt (nil: niet tonen)
    var addFolder: (() -> Void)? = nil

    var body: some View {
        Menu(settings.project.isEmpty ? "— choose one or more projects —" : settings.projectLabel) {
            ForEach(settings.projects, id: \.self) { name in
                Toggle(name, isOn: Binding(get: { settings.selectedProjects.contains(name) },
                                           set: { _ in settings.toggleProject(name) }))
            }
            if settings.projects.isEmpty { Text("No projects in \(settings.kbRoot)") }
            if let addFolder {
                Divider()
                Button("Add Folder…", action: addFolder)
            }
        }
        .fixedSize()
        .help("Check several projects to search them together")
    }
}
