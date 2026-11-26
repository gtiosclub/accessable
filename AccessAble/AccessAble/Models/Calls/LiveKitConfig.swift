import Foundation
import LiveKit

/// The LiveKit server URL comes from the untracked Secrets.xcconfig (LIVEKIT_URL) through Info.plist.
/// The API key and secret are never in the app; they live only in the Cloudflare Worker.
enum LiveKitConfig {
    /// Nil until the member has made their own AccessAble/Config/Secrets.xcconfig.
    static var serverURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "LiveKitURL") as? String,
              !raw.isEmpty, !raw.contains("$(") else { return nil }
        return URL(string: raw)
    }
    
    /// The getCallToken Worker (VOLUNTEER-6), from Secrets.xcconfig (CALL_TOKEN_URL) through Info.plist.
    /// Nil until it's set; calls then stay on the placeholder.
    static var callTokenURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CallTokenURL") as? String,
              !raw.isEmpty, !raw.contains("$("), !raw.contains("YOUR-SUBDOMAIN") else { return nil }
        return URL(string: raw)
    }

    /// The LiveKit room type; the real `VideoCallSession` builds on it. Referencing it here keeps the
    /// package linked, so a broken package setup fails the build now instead of in MATCH-x.
    typealias CallRoom = Room
}
