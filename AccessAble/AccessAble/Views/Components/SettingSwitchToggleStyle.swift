//
//  SettingSwitchToggleStyle.swift
//  AccessAble
//
//  Created by Ria Sharma on 11/2/26.
//

import SwiftUI

/// Styles for "toggle on"/"toggle off".
struct SettingSwitchToggleStyle: ToggleStyle {
    let style: SettingsStyle
 
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                configuration.isOn.toggle()
            }
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? style.toggleOnColor : style.toggleOffColor)
 
                Capsule()
                    .fill(style.toggleThumbColor)
                    .shadow(
                        color: style.toggleThumbShadowColor,
                        radius: style.toggleThumbShadowRadius,
                        x: 0,
                        y: style.toggleThumbShadowY
                    )
                    .frame(
                        width: style.toggleThumbWidth,
                        height: style.toggleHeight - style.toggleThumbPadding * 2
                    )
                    .padding(style.toggleThumbPadding)
            }
            .frame(width: style.toggleWidth, height: style.toggleHeight)
        }
        .buttonStyle(.plain)
        // VoiceOver treats this as a real switch.
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}
