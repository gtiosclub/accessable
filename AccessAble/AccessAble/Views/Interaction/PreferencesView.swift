//
//  PreferencesView.swift
//  AccessAble
//
//  Created by Ria Sharma on 11/2/26.
//
// This is a view to test the implemented UI of preference settings.

import SwiftUI
 
struct PreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsStyle) private var style
 
    var body: some View {
        ZStack {
            style.background.ignoresSafeArea()
 
            ScrollView {
                VStack(alignment: .leading, spacing: style.cardSpacing) {
                    header
 
                    // MARK: Basics
                    // Toggle settings.
                    sectionTitle("Basics")
                    StoredSettingToggleRow(item: .haptics)
                    StoredSettingToggleRow(item: .speechSounds)
                    StoredSettingToggleRow(item: .phoneAimingHelp)
                    StoredSettingToggleRow(item: .useTimeForDistance)
                    StoredSettingToggleRow(item: .useMetricForDistance)
 
                    // MARK: Navigation Info Output Control
                    // Checkmark settings
                    sectionTitle("Navigation Info Output Control")
                        .padding(.top, 4)
                    StoredSettingChoiceCard(item: .autoRepeat)
                    StoredSettingChoiceCard(item: .prioritizedInformation)
 
                    // MARK: Prompted VS. Unprompted Info
                    sectionTitle("Prompted VS. Unprompted Info")
                        .padding(.top, 4)
 
                    StoredSettingChoiceCard(item: .unpromptedAnnouncements)
                    StoredSettingChoiceCard(item: .promptedAnnouncements)
 
                    // MARK: Advanced
                    sectionTitle("Advanced")
                        .padding(.top, 4)
 
                    StoredSettingToggleRow(item: .systemScreenReader)
                    StoredSettingToggleRow(item: .quickSettings)
                    StoredSettingToggleRow(item: .resetToDefaults)
                }
                .padding(.horizontal, style.screenHorizontalPadding)
                .padding(.bottom, 32)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }
 
    // MARK: - Pieces
 
    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(style.textColor)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Back")
 
            Text("Settings")
                .font(style.screenTitleFont)
                .foregroundStyle(style.textColor)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.top, 8)
    }
 
    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(style.sectionFont)
            .foregroundStyle(style.textColor)
            .accessibilityAddTraits(.isHeader)
    }
}
 
#Preview {
    NavigationStack {
        PreferencesView()
    }
}
 
