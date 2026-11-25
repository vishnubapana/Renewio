import Foundation

/// Backend endpoints for shared security scanning.
/// Configure via Info.plist keys or environment for debug builds.
enum SecurityConfig {
    static var supabaseURL: URL? {
        if let env = ProcessInfo.processInfo.environment["RENEWIO_SUPABASE_URL"], let url = URL(string: env) {
            return url
        }
        if let raw = Bundle.main.object(forInfoDictionaryKey: "RenewioSupabaseURL") as? String,
           let url = URL(string: raw), !raw.isEmpty {
            return url
        }
        return nil
    }

    static var supabaseAnonKey: String? {
        if let env = ProcessInfo.processInfo.environment["RENEWIO_SUPABASE_ANON_KEY"], !env.isEmpty {
            return env
        }
        if let raw = Bundle.main.object(forInfoDictionaryKey: "RenewioSupabaseAnonKey") as? String, !raw.isEmpty {
            return raw
        }
        return nil
    }

    static var isConfigured: Bool {
        supabaseURL != nil && supabaseAnonKey != nil
    }

    static let policyVersion = "v1"
}
