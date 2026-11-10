import SwiftUI
import VaultCore

@MainActor final class Preferences: ObservableObject {
    @Published var sopsPath: String { didSet { defaults.set(sopsPath, forKey: "sopsPath") } }
    @Published var keyPath: String { didSet { defaults.set(keyPath, forKey: "keyPath") } }
    @Published var useAuthentication: Bool { didSet { defaults.set(useAuthentication, forKey: "useAuthentication") } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sopsPath = defaults.string(forKey: "sopsPath") ?? ""
        keyPath = defaults.string(forKey: "keyPath") ?? "~/.config/sops/age/keys.txt"
        useAuthentication = defaults.bool(forKey: "useAuthentication")
    }
    var configuration: SOPSConfiguration { .init(executablePath: sopsPath, ageKeyPath: keyPath) }
}
