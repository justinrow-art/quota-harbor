import AppKit
import Foundation
import UniformTypeIdentifiers

enum ThemeEditorPanelError: Error, Equatable, Sendable {
    case unsafeSelection
    case importTooLarge(Int)
    case readFailed
    case writeFailed
}

enum ThemeEditorPanelKind: Equatable, Sendable {
    case raster
    case importTheme
    case exportTheme
}

struct ThemeEditorPanelRequest: Equatable, Sendable {
    let kind: ThemeEditorPanelKind
    let prompt: String
}

@MainActor
protocol ThemeEditorPanelAdapting: AnyObject {
    func pickRasterSelection() async throws -> ThemeRasterUserSelection?
    func pickThemeImportData() async throws -> Data?
    func writeThemeExportData(_ data: Data) async throws -> Bool
}

/// Panels are constructed only inside explicit user-initiated methods.
@MainActor
final class SystemThemeEditorPanelAdapter: ThemeEditorPanelAdapting {
    typealias PanelRunner = @MainActor (ThemeEditorPanelRequest) -> URL?

    let localizationModel: AppLocalizationRuntimeModel
    private let runPanel: PanelRunner

    init(
        localizationModel: AppLocalizationRuntimeModel,
        runPanel: @escaping PanelRunner
    ) {
        self.localizationModel = localizationModel
        self.runPanel = runPanel
    }

    convenience init(localizationModel: AppLocalizationRuntimeModel) {
        self.init(
            localizationModel: localizationModel,
            runPanel: Self.runSystemPanel
        )
    }

    func pickRasterSelection() async throws -> ThemeRasterUserSelection? {
        let request = ThemeEditorPanelRequest(
            kind: .raster,
            prompt: localizationModel.text.text(
                .themeEditorPanelChooseImage
            )
        )
        guard let url = runPanel(request) else {
            return nil
        }
        return .unsandboxedOpenPanelSelection(url)
    }

    func pickThemeImportData() async throws -> Data? {
        let request = ThemeEditorPanelRequest(
            kind: .importTheme,
            prompt: localizationModel.text.text(
                .themeEditorPanelImportTheme
            )
        )
        guard let url = runPanel(request) else {
            return nil
        }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize
        else {
            throw ThemeEditorPanelError.unsafeSelection
        }
        guard fileSize <= ThemeImportExportService.maximumTransferBytes else {
            throw ThemeEditorPanelError.importTooLarge(fileSize)
        }
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ThemeEditorPanelError.readFailed
        }
    }

    func writeThemeExportData(_ data: Data) async throws -> Bool {
        let request = ThemeEditorPanelRequest(
            kind: .exportTheme,
            prompt: localizationModel.text.text(
                .themeEditorPanelExportTheme
            )
        )
        guard let url = runPanel(request) else {
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            throw ThemeEditorPanelError.writeFailed
        }
    }

    private static func runSystemPanel(
        _ request: ThemeEditorPanelRequest
    ) -> URL? {
        switch request.kind {
        case .raster:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.png, .jpeg]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.prompt = request.prompt
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        case .importTheme:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.prompt = request.prompt
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        case .exportTheme:
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "CodexQuotaTheme.json"
            panel.prompt = request.prompt
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        }
    }
}

@MainActor
final class ProductionThemeRasterPicker: ThemeRasterPicking {
    private let panelAdapter: any ThemeEditorPanelAdapting
    private let stagingLocation: ThemeEditorStagingLocation

    init(
        panelAdapter: any ThemeEditorPanelAdapting,
        stagingRoot: URL,
        stagingDirectory: URL
    ) throws {
        self.panelAdapter = panelAdapter
        stagingLocation = try ThemeEditorStagingLocation(
            rootDirectory: stagingRoot,
            sessionDirectory: stagingDirectory
        )
    }

    func pickRaster() async throws -> PendingSanitizedThemeRaster? {
        guard let selection = try await panelAdapter.pickRasterSelection()
        else {
            return nil
        }
        let stagingDirectory = stagingLocation.sessionDirectory
        stagingLocation.remove()
        defer { stagingLocation.remove() }
        let reference = try await ThemeRasterProcessor(
            appThemeDirectory: stagingDirectory
        ).sanitize(userSelection: selection)
        let rasterURL = stagingDirectory
            .appendingPathComponent("Rasters", isDirectory: true)
            .appendingPathComponent(reference.relativeIdentifier)
        let data: Data
        do {
            data = try Data(contentsOf: rasterURL)
        } catch {
            throw ThemeEditorPanelError.readFailed
        }
        return PendingSanitizedThemeRaster(
            reference: reference,
            pngData: data
        )
    }
}
