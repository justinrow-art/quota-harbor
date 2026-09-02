import Darwin
import Foundation

protocol ClaudeExecutableLocating: Sendable {
    func locate() -> URL?
}

struct ClaudeExecutableLocator: ClaudeExecutableLocating {
    private let candidates: [URL]
    private let currentEffectiveUserID: uid_t
    private let trustedRootUserID: uid_t

    init(
        candidates: [URL],
        currentEffectiveUserID: uid_t = geteuid(),
        trustedRootUserID: uid_t = 0
    ) {
        self.candidates = candidates
        self.currentEffectiveUserID = currentEffectiveUserID
        self.trustedRootUserID = trustedRootUserID
    }

    func locate() -> URL? {
        candidates.first(where: isTrustedExecutable)
    }

    private func isTrustedExecutable(_ candidate: URL) -> Bool {
        guard isCanonicalAbsoluteLocalFileURL(candidate) else {
            return false
        }

        let descriptor = Darwin.open(
            candidate.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            return false
        }
        defer { _ = Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & (S_IWGRP | S_IWOTH) == 0
        else {
            return false
        }

        if status.st_uid == currentEffectiveUserID {
            return status.st_mode & S_IXUSR != 0
        }
        if status.st_uid == trustedRootUserID {
            return status.st_mode & S_IXOTH != 0
        }
        return false
    }

    private func isCanonicalAbsoluteLocalFileURL(_ url: URL) -> Bool {
        guard url.isFileURL,
              url.host == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.hasPrefix("/"),
              url.path != "/",
              !url.path.contains("\0")
        else {
            return false
        }
        return url.standardizedFileURL.path == url.path
    }
}

enum ClaudeExecutableCandidateSource {
    private static let productionAllowedDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]

    static func productionCandidates(
        pathEnvironment: String?,
        homeDirectory: URL,
        allowedDirectories: [String] = productionAllowedDirectories
    ) -> [URL] {
        var approvedDirectories = allowedDirectories.compactMap(safeDirectoryURL)
        if isSafeDirectoryURL(homeDirectory) {
            approvedDirectories.append(
                homeDirectory.appendingPathComponent(
                    ".local/bin",
                    isDirectory: true
                )
            )
            approvedDirectories.append(
                homeDirectory.appendingPathComponent(
                    ".npm-global/bin",
                    isDirectory: true
                )
            )
            approvedDirectories.append(
                homeDirectory.appendingPathComponent(
                    ".claude/local",
                    isDirectory: true
                )
            )
        }

        var approvedPaths: Set<String> = []
        approvedDirectories = approvedDirectories.filter {
            approvedPaths.insert($0.path).inserted
        }
        var directories: [URL] = []
        var selectedPaths: Set<String> = []
        if let pathEnvironment {
            let safePATHDirectories = pathEnvironment.split(
                separator: ":",
                omittingEmptySubsequences: false
            ).compactMap { safeDirectoryURL(String($0)) }
            for directory in safePATHDirectories
                where approvedPaths.contains(directory.path)
                    && selectedPaths.insert(directory.path).inserted
            {
                directories.append(directory)
            }
        }
        directories.append(contentsOf: approvedDirectories.filter {
            selectedPaths.insert($0.path).inserted
        })

        return directories.map { directory in
            directory.appendingPathComponent(
                "claude",
                isDirectory: false
            )
        }
    }

    static func canonicalizedProductionTargets(
        entryCandidates: [URL]
    ) -> [URL] {
        var seenPaths: Set<String> = []
        return entryCandidates.compactMap { entry in
            guard isSafeExecutableURL(entry) else {
                return nil
            }
            let target = entry.resolvingSymlinksInPath().standardizedFileURL
            guard isSafeExecutableURL(target),
                  seenPaths.insert(target.path).inserted
            else {
                return nil
            }
            return target
        }
    }

    private static func safeDirectoryURL(_ path: String) -> URL? {
        guard path.hasPrefix("/"),
              path != "/",
              !path.contains("\0")
        else {
            return nil
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return isSafeDirectoryURL(url) ? url : nil
    }

    private static func isSafeDirectoryURL(_ url: URL) -> Bool {
        url.isFileURL
            && url.host == nil
            && url.query == nil
            && url.fragment == nil
            && url.path.hasPrefix("/")
            && url.path != "/"
            && !url.path.contains("\0")
            && url.standardizedFileURL.path == url.path
    }

    private static func isSafeExecutableURL(_ url: URL) -> Bool {
        url.isFileURL
            && url.host == nil
            && url.query == nil
            && url.fragment == nil
            && url.path.hasPrefix("/")
            && url.path != "/"
            && !url.path.contains("\0")
            && url.standardizedFileURL.path == url.path
    }
}

private struct LazyProductionClaudeExecutableLocator:
    ClaudeExecutableLocating
{
    private let entryCandidates: [URL]
    private let canonicalizeProductionTargets:
        @Sendable ([URL]) -> [URL]

    init(
        entryCandidates: [URL],
        canonicalizeProductionTargets:
            @escaping @Sendable ([URL]) -> [URL]
    ) {
        self.entryCandidates = entryCandidates
        self.canonicalizeProductionTargets = canonicalizeProductionTargets
    }

    func locate() -> URL? {
        let targets = canonicalizeProductionTargets(entryCandidates)
        return ClaudeExecutableLocator(candidates: targets).locate()
    }
}

struct LocatedClaudeAuthStatusFetcher: ClaudeAuthStatusFetching {
    private static let allowedEnvironmentKeys = [
        "HOME",
        "PATH",
        "TMPDIR",
        "LANG",
        "LC_ALL",
        "CLAUDE_CONFIG_DIR",
    ]

    private let locator: any ClaudeExecutableLocating
    private let makeClient: @Sendable (URL) -> any ClaudeAuthStatusFetching

    init(
        locator: any ClaudeExecutableLocating,
        makeClient: @escaping @Sendable (URL) -> any ClaudeAuthStatusFetching
    ) {
        self.locator = locator
        self.makeClient = makeClient
    }

    func fetch() async -> ClaudeAuthState {
        guard let executableURL = locator.locate() else {
            return .notConnected
        }
        return await makeClient(executableURL).fetch()
    }

    static func live(
        environmentSource: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        canonicalizeProductionTargets:
            @escaping @Sendable ([URL]) -> [URL] =
                ClaudeExecutableCandidateSource.canonicalizedProductionTargets
    ) -> LocatedClaudeAuthStatusFetcher {
        let environment = allowedEnvironmentKeys.reduce(into: [:]) {
            filteredEnvironment, key in
            filteredEnvironment[key] = environmentSource[key]
        }
        let entryCandidates = ClaudeExecutableCandidateSource.productionCandidates(
            pathEnvironment: environment["PATH"],
            homeDirectory: homeDirectory
        )
        return LocatedClaudeAuthStatusFetcher(
            locator: LazyProductionClaudeExecutableLocator(
                entryCandidates: entryCandidates,
                canonicalizeProductionTargets: canonicalizeProductionTargets
            ),
            makeClient: { executableURL in
                ClaudeAuthStatusClient(
                    executableURL: executableURL,
                    environmentSource: environment,
                    runner: ClaudeAuthProcessRunner()
                )
            }
        )
    }
}
