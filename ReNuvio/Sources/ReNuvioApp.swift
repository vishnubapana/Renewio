import SwiftUI

@main
struct ReNuvioApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("ReNuvio", systemImage: "arrow.triangle.2.circlepath") {
            Group {
                if model.showOnboarding {
                    OnboardingView()
                        .environmentObject(model)
                } else {
                    MenuPopoverView()
                        .environmentObject(model)
                }
            }
            .frame(width: ReNuvioTheme.popoverWidth)
            .background(AmbientBackdrop())
            .environment(\.colorScheme, .dark)
        }
        .menuBarExtraStyle(.window)
    }
}
