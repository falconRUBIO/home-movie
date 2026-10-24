import SwiftUI
import UIKit

@MainActor final class OrientationPolicy {
    static let shared = OrientationPolicy()
    private(set) var mask: UIInterfaceOrientationMask = .allButUpsideDown
    private var owner: UUID?
    private weak var currentScene: UIWindowScene?
    func apply(owner: UUID, format: MovieFormat?, scene: UIWindowScene) {
        let next = Self.orientationMask(format: format, current: scene.interfaceOrientation)
        guard self.owner != owner || mask != next else { return }
        self.owner = owner; mask = next; currentScene = scene
        scene.windows.forEach { window in
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            window.rootViewController?.presentedViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        // Lock in place when the current side already matches. On unlock, retain
        // the existing auto-rotation request so a take/page can resume following the phone.
        if format == nil || !Self.contains(next, orientation: scene.interfaceOrientation) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: next)) { _ in }
        }
    }
    static func orientationMask(format: MovieFormat?, current: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        guard let format else { return .allButUpsideDown }
        if format == .portrait { return .portrait }
        switch current {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .landscape
        }
    }
    static func contains(_ mask: UIInterfaceOrientationMask, orientation: UIInterfaceOrientation) -> Bool {
        switch orientation {
        case .portrait: return mask.contains(.portrait)
        case .portraitUpsideDown: return mask.contains(.portraitUpsideDown)
        case .landscapeLeft: return mask.contains(.landscapeLeft)
        case .landscapeRight: return mask.contains(.landscapeRight)
        default: return false
        }
    }
    // A camera's sensor compensation angle describes video pixels, not the
    // orientation of the interface the user is currently looking at.
    static func interfaceFormat(_ orientation: UIInterfaceOrientation, observed: CGFloat) -> MovieFormat {
        switch orientation {
        case .portrait, .portraitUpsideDown: return .portrait
        case .landscapeLeft, .landscapeRight: return .landscape
        default: return MovieFormat.captureFormat(angle: observed) ?? .portrait
        }
    }
    func currentInterfaceFormat(observed: CGFloat) -> MovieFormat {
        Self.interfaceFormat(currentScene?.interfaceOrientation ?? .unknown, observed: observed)
    }
    func captureAngle(format: MovieFormat, observed: CGFloat) -> CGFloat {
        switch currentScene?.interfaceOrientation {
        case .portrait where format == .portrait: return 90
        case .portraitUpsideDown where format == .portrait: return 270
        case .landscapeLeft where format == .landscape: return 180
        case .landscapeRight where format == .landscape: return 0
        default: return format.recordingAngle(observed: observed)
        }
    }
    func release(owner: UUID, scene: UIWindowScene?) {
        guard self.owner == owner else { return }
        self.owner = nil; mask = .allButUpsideDown
        scene?.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        // Real navigation dismissal resumes the app's ordinary auto-rotation.
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .allButUpsideDown)) { _ in }
    }
}
@MainActor final class MovieAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = ApplePerformanceDiagnostics.shared
        return true
    }
    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        ReliabilityDiagnostics.shared.record(.lowMemory)
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationPolicy.shared.mask
    }
}
struct MovieOrientation: UIViewControllerRepresentable {
    let format: MovieFormat?
    func makeUIViewController(context: Context) -> MovieOrientationController { MovieOrientationController() }
    func updateUIViewController(_ controller: MovieOrientationController, context: Context) {
        controller.format = format; controller.apply()
    }
    static func dismantleUIViewController(_ controller: MovieOrientationController, coordinator: ()) {
        OrientationPolicy.shared.release(owner: controller.identity, scene: controller.view.window?.windowScene)
    }
}
@MainActor final class MovieOrientationController: UIViewController {
    let identity = UUID()
    var format: MovieFormat?
    private weak var lastScene: UIWindowScene?
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); apply() }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        OrientationPolicy.shared.release(owner: identity, scene: lastScene ?? view.window?.windowScene)
    }
    func apply() {
        guard let scene = view.window?.windowScene, scene.activationState == .foregroundActive else { return }
        lastScene = scene
        OrientationPolicy.shared.apply(owner: identity, format: format, scene: scene)
    }
}
