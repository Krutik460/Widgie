import Foundation
import WidgetHosting

/// How this build gets the account the server runs its automations under (tasks/phase-3-ai-block.md, "Account and
/// credential"). The upload registers on first need, the first time the payload has an automation.
enum Registration: Sendable {
    /// A phone: `POST /v1/account` signed with the install's App Attest key, the one building signs with.
    case attested(AttestedModel)
    /// The simulator in a Debug build, which cannot attest: `POST /v1/account` with the dev Worker's registration
    /// secret, which only `dev` accepts.
    case dev(base: URL, secret: String, transport: any HTTPTransport)

    /// The path for this build: the dev secret on the simulator, where the Debug build carries one, and App Attest
    /// on a phone, which never sends the secret. Nil when neither is there.
    static func path(
        simulator: Bool, base: URL?, devSecret: String?, attested: AttestedModel?,
        transport: any HTTPTransport = URLSessionTransport()
    ) -> Registration? {
        guard simulator else { return attested.map(Registration.attested) }
        guard let base, let devSecret, !devSecret.isEmpty else { return nil }
        return .dev(base: base, secret: devSecret, transport: transport)
    }

    /// This build's path. The secret is the `WidgieDevSecret` Info.plist key, which only a Debug build has, written
    /// by the Debug build phase in project.yml from `WIDGIE_DEV_SECRET`.
    static let configured: Registration? = {
        #if targetEnvironment(simulator)
            let simulator = true
        #else
            let simulator = false
        #endif
        #if DEBUG
            let secret = Bundle.main.object(forInfoDictionaryKey: "WidgieDevSecret") as? String
        #else
            let secret: String? = nil
        #endif
        return path(
            simulator: simulator, base: ModelService.service, devSecret: secret, attested: ModelService.attested)
    }()

    /// `register` on this build's path, or nil when it has none.
    static var configuredRegister: AccountClient.Register? {
        guard let configured else { return nil }
        return { try await configured.register() }
    }

    /// A new account token.
    func register() async throws -> String {
        switch self {
        case .attested(let model):
            return try await model.registerAccount()
        case .dev(let base, let secret, let transport):
            var request = URLRequest(url: base.appending(path: "v1/account"), timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue(secret, forHTTPHeaderField: "X-Widgie-Dev-Secret")
            let (data, response) = try await transport.send(request)
            guard response.statusCode == 200,
                let token = (try? JSONDecoder().decode([String: String].self, from: data))?["token"]
            else { throw AccountClient.Refused(data, status: response.statusCode) }
            return token
        }
    }
}
