import SwiftUI

@main
struct SportHealthApp: App {
    @State private var viewModel = HealthViewModel()

    var body: some Scene {
        WindowGroup {
            // 闪屏仅用 LaunchScreen.storyboard，避免系统启动页与 App 内第二层闪屏错位叠影
            RootTabView()
                .environment(viewModel)
        }
    }
}
