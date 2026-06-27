import SwiftUI

/// SwiftUI bridge to the UIKit `WebViewController`.
struct WebContainerView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> WebViewController {
        WebViewController()
    }

    func updateUIViewController(_ uiViewController: WebViewController, context: Context) {}
}
