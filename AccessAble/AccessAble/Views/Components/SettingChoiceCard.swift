//
//  SettingChoiceCard.swift
//  AccessAble
//
//  Created by Ria Sharma on 11/3/26.
//

import SwiftUI
 
/// Reusable card with a title, a description and a list of checkmark options.
///  To use:   SettingChoiceCard(item: .autoRepeat, selection: someBinding)

struct SettingChoiceCard: View {
    let item: SettingChoiceItem
    @Binding var selection: Set<String>
 
    @Environment(\.settingsStyle) private var style
 
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title + description
            VStack(alignment: .leading, spacing: style.textSpacing) {
                Text(item.title)
                    .font(style.titleFont)
 
                Text(item.description)
                    .font(style.descriptionFont)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(style.textColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, style.headerBottomSpacing)
            .accessibilityElement(children: .combine)
 
            // Divider + option row, repeated
            ForEach(item.options) { option in
                divider
                optionRow(option)
            }
        }
        .padding(.top, style.cardPadding)
        .padding(.horizontal, style.cardPadding)
        .padding(.bottom, max(0, style.cardPadding - style.optionRowVerticalPadding))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: style.cardCornerRadius, style: .continuous)
                .fill(style.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: style.cardCornerRadius, style: .continuous)
                .strokeBorder(style.cardBorderColor, lineWidth: style.cardBorderWidth)
        )
    }
 
    // MARK: - Pieces
 
    private var divider: some View {
        Rectangle()
            .fill(style.dividerColor)
            .frame(height: style.dividerThickness)
            .accessibilityHidden(true)
    }
 
    private func optionRow(_ option: SettingChoiceOption) -> some View {
        let isSelected = selection.contains(option.id)
 
        return Button {
            select(option)
        } label: {
            HStack(alignment: .center, spacing: style.contentSpacing) {
                Text(option.title)
                    .font(style.optionFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
 
                // Always takes up space so rows stay the same height when unchecked.
                Image(systemName: "checkmark")
                    .font(style.checkmarkFont)
                    .foregroundStyle(style.checkmarkColor)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(style.textColor)
            .padding(.vertical, style.optionRowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityValue(isSelected ? "selected" : "not selected")
    }
 
    private func select(_ option: SettingChoiceOption) {
        switch item.mode {
        case .single:
            selection = [option.id]
        case .multiple:
            if selection.contains(option.id) {
                selection.remove(option.id)
            } else {
                selection.insert(option.id)
            }
        }
    }
}
 
/// Temporary version that saves its own selection in UserDefaults.
/// Can be replaced with `SettingChoiceCard(item:selection:)` once the setting lives in view model.
struct StoredSettingChoiceCard: View {
    let item: SettingChoiceItem
    @AppStorage private var raw: String
 
    init(item: SettingChoiceItem) {
        self.item = item
        _raw = AppStorage(
            wrappedValue: SettingChoiceStorage.encode(item.defaultSelection),
            item.id
        )
    }
 
    var body: some View {
        SettingChoiceCard(
            item: item,
            selection: Binding(
                get: { SettingChoiceStorage.decode(raw) ?? item.defaultSelection },
                set: { raw = SettingChoiceStorage.encode($0) }
            )
        )
    }
}
 
#Preview {
    ScrollView {
        VStack(spacing: 16) {
            SettingChoiceCard(item: .autoRepeat, selection: .constant(["Only when I ask"]))
            SettingChoiceCard(
                item: .prioritizedInformation,
                selection: .constant(SettingChoiceItem.prioritizedInformation.defaultSelection)
            )
        }
        .padding(24)
    }
    .background(SettingsStyle.standard.background)
}
