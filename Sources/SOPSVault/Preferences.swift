import SwiftUI
import VaultCore

@MainActor final class Preferences: ObservableObject {
    @Published var sopsPath: String { didSet { defaults.set(sopsPath, forKey: "sopsPath") } }
    @Published var keyPath: String { didSet { defaults.set(keyPath, forKey: "keyPath") } }
    @Published var useAuthentication: Bool { didSet { defaults.set(useAuthentication, forKey: "useAuthentication") } }
    /// "" follows the system; otherwise an ISO code from `languages`. Applies on next launch.
    @Published var language: String {
        didSet {
            defaults.set(language, forKey: "appLanguage")
            if language.isEmpty { defaults.removeObject(forKey: "AppleLanguages") } else { defaults.set([language], forKey: "AppleLanguages") }
        }
    }
    /// The language choice this process started with, to tell whether a restart is pending.
    let launchLanguage: String
    /// Shipped localizations, named in their own language.
    static let languages: [(code: String, name: String)] = [("en", "English"), ("es", "Español")]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sopsPath = defaults.string(forKey: "sopsPath") ?? ""
        keyPath = defaults.string(forKey: "keyPath") ?? "~/.config/sops/age/keys.txt"
        useAuthentication = defaults.bool(forKey: "useAuthentication")
        let saved = defaults.string(forKey: "appLanguage") ?? ""
        language = saved; launchLanguage = saved
    }
    var configuration: SOPSConfiguration { .init(executablePath: sopsPath, ageKeyPath: keyPath) }
}
