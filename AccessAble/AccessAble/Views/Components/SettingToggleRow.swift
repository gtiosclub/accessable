//
//  SettingToggleRow.swift
//  AccessAble
//
//  Created by Ria Sharma on 11/2/26.
//

import SwiftUI
 
/// Reusable card for one toggle setting.
// To use: SettingToggleRow(item: .haptics, isOn: someBinding)

struct SettingToggleRow: View {
    let item: SettingToggleItem
    @Binding var isOn: Bool
 
    @Environment(\.settingsStyle) private var style
 
    var body: some View {
        HStack(alignment: .center, spacing: style.contentSpacing) {
            VStack(alignment: .leading, spacing: style.textSpacing) {
                Text(item.title)
                    .font(style.titleFont)
 
                if !item.description.isEmpty {
                    Text(item.description)
                        .font(style.descriptionFont)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(style.textColor)
            .frame(maxWidth: .infinity, alignment: .leading)
 
            Toggle(item.title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(SettingSwitchToggleStyle(style: style))
        }
        .padding(style.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: style.cardCornerRadius, style: .continuous)
                .fill(style.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: style.cardCornerRadius, style: .continuous)
                .strokeBorder(style.cardBorderColor, lineWidth: style.cardBorderWidth)
        )
        // VoiceOver reads title + description + on/off state as one control.
        .accessibilityElement(children: .combine)
    }
}
 
/// Temporary version that saves its own value in UserDefaults.

struct StoredSettingToggleRow: View {
    let item: SettingToggleItem
    @AppStorage private var isOn: Bool
 
    init(item: SettingToggleItem) {
        self.item = item
        _isOn = AppStorage(wrappedValue: item.defaultValue, item.id)
    }
 
    var body: some View {
        SettingToggleRow(item: item, isOn: $isOn)
    }
}
 
#Preview {
    VStack(spacing: 16) {
        SettingToggleRow(item: .haptics, isOn: .constant(true))
        SettingToggleRow(item: .useMetricForDistance, isOn: .constant(false))
    }
    .padding()
    .background(SettingsStyle.standard.background)
}
 
