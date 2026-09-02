import AppKit
import Darwin

enum AppDelegateLifetime {
    static func run<Owner: AnyObject>(
        retaining owner: Owner,
        _ operation: () -> Void
    ) {
        withExtendedLifetime(owner, operation)
    }
}

@main
enum CodexQuotaMonitorApp {
    @MainActor
    static func main() {
        let exitCode = CodexQuotaMonitorLaunchRouter.route(
            arguments: CommandLine.arguments,
            application: runApplication,
            relay: ClaudeRelayProduction.run
        )
        if let exitCode {
            Darwin.exit(exitCode)
        }
    }

    @MainActor
    private static func runApplication() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        AppDelegateLifetime.run(retaining: delegate) {
            application.run()
        }
    }
}
