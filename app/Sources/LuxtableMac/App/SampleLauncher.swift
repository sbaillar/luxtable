import Foundation
import LuxtableCore

/// "Try with Sample Photos": a second Luxtable, in demo mode, on its own scratch support
/// folder (`LT_SUPPORT_ROOT`), so it has its own preferences and instance lock and never
/// reads or changes the user's library. Opening it again brings the running one forward.
public enum SampleLauncher {
    /// The demo's support folder: in the temporary folder, emptied by macOS in time.
    public static var supportRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Luxtable Samples", isDirectory: true)
    }

    /// `open`'s arguments to start the bundle at `app` in demo mode on `supportRoot`.
    public static func openArguments(app: URL, supportRoot: URL) -> [String] {
        ["-n", "-a", app.path, "--env", "LT_SUPPORT_ROOT=\(supportRoot.path)", "--args", "--demo", flag]
    }

    /// Marks the launch as the sample window (it skips first-run setup).
    public static let flag = "--samples"

    /// This process is the sample window: demo mode, started with `flag`.
    public static func isSampleWindow(arguments: [String], mode: AppMode) -> Bool {
        mode == .demo && arguments.contains(flag)
    }

    /// The launcher for this process: only when it runs from an app bundle in live mode (a
    /// test or `swift run` has no bundle for `open` to start).
    public static func live(bundle: URL = Bundle.main.bundleURL, mode: AppMode) -> (@MainActor () -> Void)? {
        guard mode == .live, bundle.pathExtension == "app" else { return nil }
        return {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = openArguments(app: bundle, supportRoot: supportRoot)
            try? p.run()
        }
    }
}
