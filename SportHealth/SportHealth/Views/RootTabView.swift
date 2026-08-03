import SwiftUI

struct RootTabView: View {
    @Environment(HealthViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        TabView(selection: $vm.selectedTab) {
            DashboardView()
                .tabItem {
                    Label("概览", systemImage: "house.fill")
                }
                .tag(AppTab.home)
            WorkoutsView()
                .tabItem {
                    Label("运动", systemImage: "figure.run")
                }
                .tag(AppTab.workouts)
            SleepView()
                .tabItem {
                    Label("睡眠", systemImage: "moon.zzz.fill")
                }
                .tag(AppTab.sleep)
            BodyView()
                .tabItem {
                    Label("身体", systemImage: "person.fill")
                }
                .tag(AppTab.body)
            AIAdviceView()
                .tabItem {
                    Label("建议", systemImage: "sparkles")
                }
                .tag(AppTab.advice)
        }
    }
}
