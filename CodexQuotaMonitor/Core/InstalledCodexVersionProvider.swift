import Foundation

struct VerifiedInstalledCodexVersionProvider: InstalledCodexVersionProviding {
    func installedVersion() async -> String {
        do {
            let manifest = try CodexTrustManifest.bundled()
            let verifier = CodexExecutableVerifier(
                manifest: manifest,
                requestedArguments: manifest.arguments,
                requestedEnvironmentKeys: manifest.environmentKeys
            )
            return try verifier.verifyBeforeSpawn().observedVersion
        } catch {
            return ""
        }
    }
}
