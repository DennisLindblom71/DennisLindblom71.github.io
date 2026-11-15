import SwiftUI
import UserNotifications

@main
struct MultiSearchApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = AppStore.shared

    var body: some Scene {
        WindowGroup {
            SearchView()
                .environment(store)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.pruneReminders() }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // Visa påminnelsen även när appen är öppen
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // Tryck på påminnelsen öppnar sökningen direkt
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["savedID"] as? String,
              let id = UUID(uuidString: raw) else { return }
        await MainActor.run { AppStore.shared.openSaved(id: id) }
    }
}
