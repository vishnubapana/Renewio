import SwiftUI
import UniformTypeIdentifiers

@main
struct RenewioApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            Group {
                if model.showOnboarding {
                    OnboardingView()
                        .environmentObject(model)
                        .transition(.opacity)
                } else {
                    MenuPopoverView()
                        .environmentObject(model)
                        .transition(.opacity)
                }
            }
            .animation(RenewioMotion.transition, value: model.showOnboarding)
            .frame(width: RenewioTheme.popoverWidth)
            .background(AmbientBackdrop())
            .environment(\.colorScheme, .dark)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleIPADrop(providers)
            }
        } label: {
            // Keep the label a plain Image — TimelineView / complex views often fail to show in the menu bar.
            Image(systemName: model.menuBarSystemImage)
                .symbolRenderingMode(.hierarchical)
                .accessibilityLabel("Renewio")
        }
        .menuBarExtraStyle(.window)
    }

    private func handleIPADrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }
            guard let fileURL = url, fileURL.pathExtension.lowercased() == "ipa" else { return }
            Task { @MainActor in
                model.openOnboardingWithLocalIPA(fileURL)
            }
        }
        return true
    }
}
