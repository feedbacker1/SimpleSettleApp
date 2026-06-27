import SwiftUI
import GoogleSignIn

@main
struct SimpleSettleAppApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // Handle the redirect back from the Google sign-in browser/SDK.
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
