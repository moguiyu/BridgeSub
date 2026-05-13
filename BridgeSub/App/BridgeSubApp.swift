import SwiftUI

@main
struct BridgeSubApp: App {
    @State private var viewModel = WorkflowViewModel(environment: .live)

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 900, minHeight: 700)
        }
        .windowResizability(.contentSize)
        Settings {
            SettingsView(toolStatuses: viewModel.toolStatuses)
        }
    }
}
