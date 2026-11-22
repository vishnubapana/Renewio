import SwiftUI

@main
struct RenewioApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Renewio", systemImage: "arrow.triangle.2.circlepath") {
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
        }
        .menuBarExtraStyle(.window)
    }
}
