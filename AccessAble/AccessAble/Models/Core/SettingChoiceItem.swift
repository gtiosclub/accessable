//
//  SettingChoiceItem.swift
//  AccessAble
//
//  Created by Ria Sharma on 11/3/26.
//
import SwiftUI
 
// MARK: - Option
 
/// One row in a checkmark list.
struct SettingChoiceOption: Identifiable, Hashable, ExpressibleByStringLiteral {
    let id: String
    var title: String { id }
 
    init(stringLiteral value: String) {
        self.id = value
    }
}
 
// MARK: - Item
 
enum SettingChoiceMode {
    /// Two possible choices for a choice item card:
    case single      // 1. picking one unchecks the others
    case multiple    // 2. each option is checked independently
}
 
/// One checkmark-list card. To add a new one, copy a `static let` below.
struct SettingChoiceItem: Identifiable {
    let id: String                         // UserDefaults key, keep unique
    let title: String
    let description: String
    let mode: SettingChoiceMode
    let options: [SettingChoiceOption]
    let defaultSelection: Set<String>      // option texts that start checked
 
    init(
        key: String,
        title: String,
        description: String,
        mode: SettingChoiceMode,
        options: [SettingChoiceOption],
        defaultSelection: Set<String>
    ) {
        self.id = key
        self.title = title
        self.description = description
        self.mode = mode
        self.options = options
        self.defaultSelection = defaultSelection
    }
 
    /// Current saved selection, readable from anywhere in the app.
    /// Example: `SettingChoiceItem.autoRepeat.storedSelection.contains("Once")`

    var storedSelection: Set<String> {
        guard let raw = UserDefaults.standard.string(forKey: id),
              let decoded = SettingChoiceStorage.decode(raw) else { return defaultSelection }
        return decoded
    }
}
 
// MARK: - Saving (selection <-> String)
 
enum SettingChoiceStorage {
    static func encode(_ selection: Set<String>) -> String {
        guard let data = try? JSONEncoder().encode(selection.sorted()),
              let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }
 
    static func decode(_ raw: String) -> Set<String>? {
        guard let data = raw.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return Set(array)
    }
}
 
// MARK: - Default Choice Settings from Figma
/// To use: copy/paste a block to add the data of a new custom choice
 
extension SettingChoiceItem {
 
    static let autoRepeat = SettingChoiceItem(
        key: "pref.autoRepeat",
        title: "Auto Repeat Announcements",
        description: "Choose how many times directions and non-hazard related announcements repeat as you approach them. Safety alerts have 1 minimum repetition regardless.",
        mode: .single,
        options: ["Only when I ask", "Once", "Twice", "Three times"],
        defaultSelection: ["Only when I ask"]
    )
 
    static let prioritizedInformation = SettingChoiceItem(
        key: "pref.prioritizedInformation",
        title: "Prioritized information",
        description: "Choose which type of information gets announced first when multiple information outputs at the same time.",
        mode: .multiple,
        options: [
            "Detailed description of view (includes aesthetic appearances)",
            "Traffic flow and crowd density",
            "Opening areas and obstacles",
            "Recognized signs/texts in view"
        ],
        defaultSelection: [
            "Detailed description of view (includes aesthetic appearances)",
            "Traffic flow and crowd density"
        ]
    )
 
    static let unpromptedAnnouncements = SettingChoiceItem(
        key: "pref.unpromptedAnnouncements",
        title: "Unprompted Announcements",
        description: "Choose which type of information gets announced automatically.",
        mode: .multiple,
        options: infoTypeOptions,
        defaultSelection: [
            "Directions",
            "Traffic flow and crowd density",
            "Opening areas and obstacles"
        ]
    )
 
    static let promptedAnnouncements = SettingChoiceItem(
        key: "pref.promptedAnnouncements",
        title: "Prompted Announcements",
        description: "Choose which type of information the AI Agent outputs when you click on “Describe My Surroundings” button.",
        mode: .multiple,
        options: infoTypeOptions,
        defaultSelection: [
            "Traffic flow and crowd density",
            "Locations and styles of recognized signs/texts in view",
            "Objects that are partly in view and which way to move to capture them.",
            "Basic information (size, distance, color) of structures and buildings."
        ]
    )
 
    /// List of choices shared by the Unprompted and Prompted cards.
    private static let infoTypeOptions: [SettingChoiceOption] = [
        "Directions",
        "Traffic flow and crowd density",
        "Opening areas and obstacles",
        "Locations and styles of recognized signs/texts in view",
        "Objects that are partly in view and which way to move to capture them.",
        "Basic information (size, distance, color) of structures and buildings.",
        "Detailed description of view (includes aesthetic appearances)"
    ]
}
