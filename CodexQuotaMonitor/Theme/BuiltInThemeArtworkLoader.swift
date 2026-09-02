import Foundation

struct BuiltInThemeArtworkLoader {
    private let dataProvider: (String) -> Data?

    init(bundle: Bundle = .main) {
        dataProvider = { resourceName in
            guard let url = bundle.url(
                forResource: resourceName,
                withExtension: nil
            ) else {
                return nil
            }
            return try? Data(contentsOf: url, options: .mappedIfSafe)
        }
    }

    init(_ dataProvider: @escaping (String) -> Data?) {
        self.dataProvider = dataProvider
    }

    static func resourceName(for id: BuiltInThemeID) -> String {
        switch id {
        case .morandi:
            "theme-morandi-background.png"
        case .cyberpunk:
            "theme-cyberpunk-background.png"
        case .warmHandDrawn:
            "theme-warm-hand-drawn-background.png"
        case .glass:
            "theme-glass-background.png"
        case .sketch:
            "theme-sketch-background.png"
        case .cartoonIllustration:
            "theme-cartoon-illustration-background.png"
        }
    }

    func data(for id: BuiltInThemeID) -> Data? {
        dataProvider(Self.resourceName(for: id))
    }
}
