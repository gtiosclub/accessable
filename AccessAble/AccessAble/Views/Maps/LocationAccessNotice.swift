import SwiftUI

struct LocationAccessNotice: View {
    let authorization: LocationAuthorization
    @Environment(\.openURL) private var openURL
    
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "location.slash")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenMessage)
        
            if authorization == .denied {
                AccessibleActionButton(
                    title: "Open Settings",
                    systemImage: "gear",
                    hint: "Opens AccessAble's settings so you can allow location access") {
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
    
    private var message: String {
        if authorization == .restricted {
            return "Location access is blocked by a device restriction. Ask whoever manages this device to allow it."
        }
        return "AccessAble needs your location for walking directions. Make sure Location Services is on (Settings -> Privacy & Security -> Location Services) and AccessAble is allowed."
    }
    
    private var spokenMessage: String {
        if authorization == .restricted { return message }
        return "AccessAble needs your location for walking directions. Make sure Location Services is on in Settings, Privacy and Security, Location Services, and that AccessAble is allowed."
    }
}
