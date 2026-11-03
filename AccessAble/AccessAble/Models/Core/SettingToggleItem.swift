//
//  SettingToggleItem.swift
//  AccessAble
//
//  Created by Ria Sharma on 11/2/26.
//

import SwiftUI
 
// MARK: - Toggle Model
 
/// The text for one toggle setting. To add a new setting, copy any `static let below, change the name, key, title and description.
struct SettingToggleItem: Identifiable {
    let id: String
    let title: String
    let description: String
    let defaultValue: Bool
 
    init(key: String, title: String, description: String, defaultValue: Bool = true) {
        self.id = key
        self.title = title
        self.description = description
        self.defaultValue = defaultValue
    }
 
    /// Current value of a UserDefaults-backed item, readable from anywhere.
    var storedValue: Bool {
        UserDefaults.standard.object(forKey: id) as? Bool ?? defaultValue
    }
}
 
// MARK: - Dummy Settings from Figma Design
// For new setting items: copy/paste a block to add a new one

extension SettingToggleItem {
 
    static let haptics = SettingToggleItem(
        key: "pref.haptics",
        title: "Haptics",
        description: "Feel vibrations for turns, hazards, and crossings.",
        defaultValue: true
    )
 
    static let speechSounds = SettingToggleItem(
        key: "pref.speechSounds",
        title: "Speech Sounds",
        description: "Speech turned on for all announcements",
        defaultValue: true
    )
 
    static let phoneAimingHelp = SettingToggleItem(
        key: "pref.phoneAimingHelp",
        title: "Phone Aiming Help",
        description: "AI estimates which way the user should move their phone to get more information on camera.",
        defaultValue: true
    )
 
    static let useTimeForDistance = SettingToggleItem(
        key: "pref.useTimeForDistance",
        title: "Use Time for Distance",
        description: "Estimates the time it takes to walk a certain distance when giving directions.",
        defaultValue: true
    )
 
    static let useMetricForDistance = SettingToggleItem(
        key: "pref.useMetricForDistance",
        title: "Use Metric for Distance",
        description: "American unit will be used if not selected.",
        defaultValue: false
    )
 
    static let systemScreenReader = SettingToggleItem(
        key: "pref.systemScreenReader",
        title: "System Screen Reader",
        description: "Use your phone's screen reader instead of the app's screen reader.",
        defaultValue: true
    )
 
    static let quickSettings = SettingToggleItem(
        key: "pref.quickSettings",
        title: "Quick Settings",
        description: "Use a shorter version settings page to appear during navigation.",
        defaultValue: true
    )
 
    /// Title only (no description) in the Figma. It's a plain toggle for now: saves value but does not reset anything.
    static let resetToDefaults = SettingToggleItem(
        key: "pref.resetToDefaults",
        title: "Reset to Default Settings",
        description: "",
        defaultValue: true
    )
}
 
// MARK: - Editable Style of Settings
 
/// Current size, color and font for the settings screen based on Figma design.
struct SettingsStyle {
    // Screen
    var background = Color(red: 0.09, green: 0.16, blue: 0.23)       // Figma navy
    var screenHorizontalPadding: CGFloat = 24
    var cardSpacing: CGFloat = 16
 
    // Card
    var cardFill = Color(red: 0.31, green: 0.31, blue: 0.31)         // Figma: NeutralDarkGrey
    var cardBorderColor = Color(red: 0.94, green: 0.94, blue: 0.94)  // Figma: TextOffwhite
    var cardBorderWidth: CGFloat = 3
    var cardCornerRadius: CGFloat = 16
    var cardPadding: CGFloat = 16
    var contentSpacing: CGFloat = 16   // gap between text and toggle
    var textSpacing: CGFloat = 4
 
    // Text
    var titleFont: Font = .title3.weight(.semibold)   // Figma Title3/Emphasized (SF Pro 20 semibold)
    var descriptionFont: Font = .body                 // estimate, confirm in Figma
    var sectionFont: Font = .title3.weight(.semibold) // estimate, confirm in Figma
    var screenTitleFont: Font = .largeTitle.weight(.bold)
    var textColor = Color.white
 
    // Toggle (Figma: 54 x 24 track, fully rounded)
    var toggleWidth: CGFloat = 54
    var toggleHeight: CGFloat = 24            // Figma: ToggleSwitchTrackHeight
    var toggleThumbWidth: CGFloat = 32        // Figma: ToggleSwitchKnobWidth
    var toggleThumbPadding: CGFloat = 2       // Figma: 2 gap around knob (knob height 20)
    var toggleOnColor = SettingsStyle.accentBlue   // Accents/Blue (assumed same blue as the checkmark)
    var toggleOffColor = Color.black.opacity(0.2)   // Figma: Labels/Primary (opacity is an estimate)
    var toggleThumbColor = Color.white
    var toggleThumbShadowColor = Color.black.opacity(0.05)
    var toggleThumbShadowRadius: CGFloat = 18
    var toggleThumbShadowY: CGFloat = 3
 
    // Checkmark list cards
    var optionFont: Font = .body                      // Figma Body/Regular (SF Pro 17)
    var optionRowVerticalPadding: CGFloat = 16        // Figma: 16 above and below each row
    var headerBottomSpacing: CGFloat = 16             // gap between description and first divider
    var dividerColor = Color(red: 0.84, green: 0.84, blue: 0.84)   // Figma: NeutralLightGrey
    var dividerThickness: CGFloat = 1
    var checkmarkFont: Font = .title2                 // Figma Title2/Regular (SF Pro 22)
    var checkmarkColor = SettingsStyle.accentBlue
 
    /// Figma blue: Color(red: 0, green: 0.53, blue: 1)
    static let accentBlue = Color(red: 0, green: 0.53, blue: 1)
 
    static let standard = SettingsStyle()
}
 
private struct SettingsStyleKey: EnvironmentKey {
    static let defaultValue = SettingsStyle.standard
}
 
extension EnvironmentValues {
    var settingsStyle: SettingsStyle {
        get { self[SettingsStyleKey.self] }
        set { self[SettingsStyleKey.self] = newValue }
    }
}
 
extension View {
    /// Override the settings style for this view and its children.
    func settingsStyle(_ style: SettingsStyle) -> some View {
        environment(\.settingsStyle, style)
    }
}
