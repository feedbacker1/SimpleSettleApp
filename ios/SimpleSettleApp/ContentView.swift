import SwiftUI

struct ContentView: View {
    var body: some View {
        // The WebView fills the whole screen. We deliberately let the web content
        // draw edge-to-edge for the top (status bar) area to mirror the Android
        // `enableEdgeToEdge()` look, but keep the bottom safe area so content
        // isn't hidden behind the home indicator.
        //
        // NOTE: If your website draws its own header that should sit *below* the
        // notch/status bar (the typical case, matching the Android padding
        // behaviour), simply remove the `.ignoresSafeArea` modifier entirely so
        // SwiftUI insets the WebView by the full safe area on every edge.
        WebContainerView()
            .ignoresSafeArea(.container, edges: .bottom)
    }
}

#Preview {
    ContentView()
}
