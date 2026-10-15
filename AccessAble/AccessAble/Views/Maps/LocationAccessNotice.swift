import SwiftUI

struct LocationAccessNotice: View {
    let authorization: LocationAuthorization
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message(spoken: false), systemImage: "location.slash")
                // the map below would otherwise squeeze this to a truncated line, worst at large text sizes
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(message(spoken: true))

            if authorization == .denied {
                AccessibleActionButton(
                    title: "Open Settings",
                    systemImage: "gear",
                    hint: "Opens AccessAble's settings so you can allow location access"
                ) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The spoken variant writes the Settings path out in words so VoiceOver doesn't read the "›" separators.
    private func message(spoken: Bool) -> String {
        switch authorization {
        case .restricted:
            return "Location access is blocked by a device restriction. Ask whoever manages this device to allow it."
        default:
            let appPath = spoken ? "Settings, AccessAble, Location" : "Settings › AccessAble › Location"
            let systemPath = spoken
                ? "Settings, Privacy and Security, Location Services"
                : "Settings › Privacy & Security › Location Services"
            return "AccessAble needs your location for walking directions. Allow it in \(appPath). If Location Services is off for the whole phone, turn it on in \(systemPath)."
        }
    }
}

#Preview("Denied") {
    LocationAccessNotice(authorization: .denied)
        .padding()
}

#Preview("Restricted") {
    LocationAccessNotice(authorization: .restricted)
        .padding()
}
