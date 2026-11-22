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
                } else {
                    MenuPopoverView()
                        .environmentObject(model)
                }
            }
            .frame(width: RenewioTheme.popoverWidth)
            .background(AmbientBackdrop())
            .environment(\.colorScheme, .dark)
        }
        .menuBarExtraStyle(.window)
    }
}
