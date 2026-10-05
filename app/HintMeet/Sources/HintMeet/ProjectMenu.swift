import SwiftUI

/// Keuze van één of meer kennisbanken, met vinkjes; samen doorzocht tijdens de meeting.
struct ProjectMenu: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Menu(settings.project.isEmpty ? "— kies een of meer projecten —" : settings.projectLabel) {
            ForEach(settings.projects, id: \.self) { name in
                Toggle(name, isOn: Binding(get: { settings.selectedProjects.contains(name) },
                                           set: { _ in settings.toggleProject(name) }))
            }
            if settings.projects.isEmpty { Text("Geen projecten in \(settings.kbRoot)") }
        }
        .fixedSize()
        .help("Vink meerdere projecten aan om ze samen te doorzoeken")
    }
}
