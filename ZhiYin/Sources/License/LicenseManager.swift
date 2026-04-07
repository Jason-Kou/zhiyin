import Foundation

/// Manages license key validation, activation, and deactivation via Polar.sh API.
/// Uses Polar's public customer-portal endpoints (no auth token required).
class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    // MARK: - Configuration

    /// Switch between sandbox and production.
    /// Set to .production when ready to go live.
    enum Environment {
        case sandbox
        case production

        var baseURL: String {
            switch self {
            case .sandbox: return "https://sandbox-api.polar.sh"
            case .production: return "https://api.polar.sh"
            }
        }
    }

    /// Current environment — change this to .production for release builds.
    #if DEBUG
    static let environment: Environment = .sandbox
    #else
    static let environment: Environment = .production
    #endif

    // MARK: - Published State

    @Published var isActivating = false
    @Published var errorMessage = ""

    // MARK: - API Response Models

    struct ValidateResponse: Codable {
        let id: String
        let organizationId: String
        let userId: String?
        let key: String
        let status: String
        let limitActivations: Int?
        let activations: Int?
        let validationResponse: ValidationDetail?

        enum CodingKeys: String, CodingKey {
            case id
            case organizationId = "organization_id"
            case userId = "user_id"
            case key, status
            case limitActivations = "limit_activations"
            case activations
            case validationResponse = "validation"
        }
    }

    struct ValidationDetail: Codable {
        let valid: Bool
    }

    struct ActivateResponse: Codable {
        let id: String
        let licenseKeyId: String
        let label: String
        let meta: [String: String]?

        enum CodingKeys: String, CodingKey {
            case id
            case licenseKeyId = "license_key_id"
            case label
            case meta
        }
    }

    struct PolarError: Codable {
        let detail: String?
        let type: String?
    }

    // MARK: - Device Fingerprint

    /// Returns a stable hardware identifier for activation tracking.
    private var deviceFingerprint: String {
        // Use IOPlatformUUID as a stable device identifier
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                   IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }

        if let uuidData = IORegistryEntryCreateCFProperty(service,
                                                           "IOPlatformUUID" as CFString,
                                                           kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
            return uuidData
        }
        // Fallback: use a persisted UUID
        let key = "zhiyin_device_id"
        if let stored = UserDefaults.standard.string(forKey: key) {
            return stored
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

    // MARK: - Public API

    /// Validate and activate a license key. Sets isPro and licenseKey in UserDefaults on success.
    @MainActor
    func activate(key: String) async -> Bool {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Please enter a license key."
            return false
        }

        isActivating = true
        errorMessage = ""
        defer { isActivating = false }

        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)

        // Step 1: Validate the key
        do {
            let validation = try await validateKey(trimmedKey)
            guard validation.validationResponse?.valid == true || validation.status == "granted" else {
                errorMessage = "Invalid or expired license key."
                return false
            }
        } catch {
            errorMessage = "Validation failed: \(error.localizedDescription)"
            return false
        }

        // Step 2: Activate on this device
        do {
            _ = try await activateKey(trimmedKey)
        } catch {
            // If activation fails due to limit, still report the error
            errorMessage = "Activation failed: \(error.localizedDescription)"
            return false
        }

        // Step 3: Persist the pro status
        UserDefaults.standard.set(true, forKey: "isPro")
        UserDefaults.standard.set(trimmedKey, forKey: "licenseKey")
        return true
    }

    /// Deactivate the current license key on this device.
    @MainActor
    func deactivate() async {
        let key = UserDefaults.standard.string(forKey: "licenseKey") ?? ""
        let activationId = UserDefaults.standard.string(forKey: "licenseActivationId") ?? ""

        // Deactivate on Polar first, then clear local state
        if !key.isEmpty && !activationId.isEmpty {
            try? await deactivateKey(key, activationId: activationId)
        }

        UserDefaults.standard.set(false, forKey: "isPro")
        UserDefaults.standard.removeObject(forKey: "licenseKey")
        UserDefaults.standard.removeObject(forKey: "licenseActivationId")
    }

    // MARK: - Private API Calls

    private func validateKey(_ key: String) async throws -> ValidateResponse {
        let url = URL(string: "\(Self.environment.baseURL)/v1/customer-portal/license-keys/validate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "key": key,
            "organization_id": Self.organizationId
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LicenseError.networkError
        }

        guard httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(PolarError.self, from: data) {
                throw LicenseError.apiError(errorResponse.detail ?? "Unknown error")
            }
            throw LicenseError.httpError(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(ValidateResponse.self, from: data)
    }

    private func activateKey(_ key: String) async throws -> ActivateResponse {
        let url = URL(string: "\(Self.environment.baseURL)/v1/customer-portal/license-keys/activate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "key": key,
            "organization_id": Self.organizationId,
            "label": deviceFingerprint
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LicenseError.networkError
        }

        guard httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(PolarError.self, from: data) {
                throw LicenseError.apiError(errorResponse.detail ?? "Activation limit reached")
            }
            throw LicenseError.httpError(httpResponse.statusCode)
        }

        let activation = try JSONDecoder().decode(ActivateResponse.self, from: data)

        // Store activation ID for deactivation later
        await MainActor.run {
            UserDefaults.standard.set(activation.id, forKey: "licenseActivationId")
        }

        return activation
    }

    private func deactivateKey(_ key: String, activationId: String) async throws {
        let url = URL(string: "\(Self.environment.baseURL)/v1/customer-portal/license-keys/deactivate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "key": key,
            "organization_id": Self.organizationId,
            "activation_id": activationId
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            // Best-effort: don't throw on deactivation failure
            return
        }
    }

    // MARK: - Organization ID

    /// Polar organization ID — sandbox vs production.
    static var organizationId: String {
        #if DEBUG
        return "8b4aff80-f753-428e-8b75-639d75d59bbb"  // sandbox
        #else
        return "6630ab6c-a520-4673-9698-1ebf1339ff0e"  // production
        #endif
    }

    // MARK: - Checkout URL

    /// The Polar checkout link for purchasing a Pro license.
    static var checkoutURL: URL {
        #if DEBUG
        return URL(string: "https://sandbox-api.polar.sh/v1/checkout-links/polar_cl_vqX5fWREAYCdXsjjMbWPSnjsum1KlraFeNDPA0zee07/redirect")!
        #else
        return URL(string: "https://buy.polar.sh/polar_cl_ROCWYzbjskXA2UityAlCM1fbjKrWGEEfRb7734MHxNA")!
        #endif
    }

    // MARK: - Customer Portal URL

    /// The Polar customer portal where users can manage their license and billing.
    static var customerPortalURL: URL {
        #if DEBUG
        return URL(string: "https://sandbox.polar.sh/agentx-test-org/portal")!
        #else
        return URL(string: "https://polar.sh/agentlabx/portal")!
        #endif
    }

    // MARK: - Errors

    enum LicenseError: LocalizedError {
        case networkError
        case httpError(Int)
        case apiError(String)

        var errorDescription: String? {
            switch self {
            case .networkError:
                return "Network connection failed. Please check your internet."
            case .httpError(let code):
                return "Server error (HTTP \(code)). Please try again later."
            case .apiError(let message):
                return message
            }
        }
    }
}
