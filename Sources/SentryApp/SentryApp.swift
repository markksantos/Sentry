import SwiftUI
import SentryUI

@main
struct SentryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var viewModel = DashboardViewModel()

    var body: some Scene {
        MenuBarExtra("Sentry", systemImage: "network") {
            MenuBarView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
