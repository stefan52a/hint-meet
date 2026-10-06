import SwiftUI

/// Keuze van één of meer kennisbanken, met vinkjes; samen doorzocht tijdens de meeting.
struct ProjectMenu: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Menu(settings.project.isEmpty ? "— choose one or more projects —" : settings.projectLabel) {
            ForEach(settings.projects, id: \.self) { name in
                Toggle(name, isOn: Binding(get: { settings.selectedProjects.contains(name) },
                                           set: { _ in settings.toggleProject(name) }))
            }
            if settings.projects.isEmpty { Text("No projects in \(settings.kbRoot)") }
        }
        .fixedSize()
        .help("Check several projects to search them together")
    }
}
