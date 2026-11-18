import CoreGraphics
import Foundation
import Testing
@testable import AccessAble

struct AgentActionParsingTests {
    @Test
    func parsesEveryControlTool() {
        #expect(parse(VoiceAgentTools.press, ["control_id": "c3"]) == .success(.press(controlID: "c3")))
        #expect(
            parse(VoiceAgentTools.typeText, ["control_id": "c1", "text": "library", "submit": true])
                == .success(.typeText(controlID: "c1", text: "library", submit: true))
        )
        #expect(parse(VoiceAgentTools.setToggle, ["control_id": "c2", "on": false]) == .success(.setToggle(controlID: "c2", isOn: false)))
        #expect(parse(VoiceAgentTools.setValue, ["control_id": "c9", "value": "0.5"]) == .success(.setValue(controlID: "c9", value: "0.5")))
    }

    @Test
    func parsesNavigationAndCommands() {
        #expect(parse(VoiceAgentTools.navigate, ["destination": "call_help"]) == .success(.navigate(.callHelp)))
        #expect(parse(VoiceAgentTools.describeSurroundings, [:]) == .success(.describeSurroundings))
        #expect(parse(VoiceAgentTools.whereAmI, [:]) == .success(.whereAmI))
        #expect(parse(VoiceAgentTools.repeatLast, [:]) == .success(.repeatLastAnnouncement))
        #expect(
            parse(VoiceAgentTools.lookWithCamera, ["question": " What does the sign say? "])
                == .success(.lookWithCamera(question: "What does the sign say?"))
        )
    }

    @Test
    func rejectsBadInput() {
        #expect(parse("delete_everything", [:]) == .failure(.unknownTool("delete_everything")))
        #expect(parse(VoiceAgentTools.press, [:]) == .failure(.missingField("control_id")))
        #expect(parse(VoiceAgentTools.setToggle, ["control_id": "c2", "on": "yes"]) == .failure(.missingField("on")))
        #expect(parse(VoiceAgentTools.navigate, ["destination": "moon"]) == .failure(.invalidValue("Unknown destination moon.")))
        #expect(parse(VoiceAgentTools.lookWithCamera, ["question": "  "]) == .failure(.invalidValue("The question is empty.")))
    }

    private func parse(_ name: String, _ input: [String: JSONValue]) -> Result<AgentAction, AgentAction.ParseError> {
        AgentAction.parse(name: name, input: input)
    }
}

struct ConfirmationReplyTests {
    @Test(arguments: ["Yes", "yes.", "Yeah", "ok", "Okay, do it", "Go ahead", "yes please", "Sure!"])
    func yes(_ text: String) {
        #expect(ConfirmationReply(text) == .yes)
    }

    @Test(arguments: ["No", "nope", "Cancel", "Don't", "don’t do it", "never mind", "Stop."])
    func no(_ text: String) {
        #expect(ConfirmationReply(text) == .no)
    }

    @Test(arguments: ["", "open settings", "yes and then take me to the library please", "what time is it"])
    func anythingElseIsANewRequest(_ text: String) {
        #expect(ConfirmationReply(text) == .other)
    }
}

struct AgentControlTests {
    @Test
    func promptLineDescribesTheControl() {
        let button = AgentControl(id: "c4", kind: .button, label: "Live tab", isSelected: true)
        #expect(button.promptLine == "- c4 button \"Live tab\" (selected)")

        let field = AgentControl(id: "c1", kind: .textField, label: "To", hint: "destination search", value: "lib")
        #expect(field.promptLine == "- c1 text field \"To\", text: \"lib\" — destination search")

        let choice = AgentControl(id: "c7", kind: .choice, label: "View", value: "Camera", options: ["Camera", "Map"], isEnabled: false)
        #expect(choice.promptLine == "- c7 choice \"View\", value: Camera, options: \"Camera\", \"Map\" (disabled)")
    }
}

@MainActor
struct AgentControlRegistryTests {
    @Test
    func assignsStableIDsAndListsTopToBottom() {
        let registry = AgentControlRegistry()
        let lower = UUID()
        let upper = UUID()
        registry.register(lower, control: control("Search Destination"), handlers: .init())
        registry.register(upper, control: control("Settings"), handlers: .init())
        registry.updateFrame(lower, frame: CGRect(x: 0, y: 700, width: 300, height: 50))
        registry.updateFrame(upper, frame: CGRect(x: 0, y: 60, width: 50, height: 50))

        #expect(registry.snapshot().map(\.label) == ["Settings", "Search Destination"])
        #expect(registry.snapshot().map(\.id) == ["c2", "c1"])

        // Updating keeps the id.
        registry.register(lower, control: control("Search Destination", isEnabled: false), handlers: .init())
        #expect(registry.control(id: "c1")?.isEnabled == false)
    }

    @Test
    func unregisteredControlsDisappear() {
        let registry = AgentControlRegistry()
        let token = UUID()
        var pressed = false
        registry.register(token, control: control("Pause Trip"), handlers: .init(press: { pressed = true }))
        registry.handlers(id: "c1")?.press?()
        #expect(pressed)

        registry.unregister(token, forget: true)
        #expect(registry.snapshot().isEmpty)
        #expect(registry.handlers(id: "c1") == nil)
    }

    private func control(_ label: String, isEnabled: Bool = true) -> AgentControl {
        AgentControl(id: "", kind: .button, label: label, isEnabled: isEnabled)
    }
}

struct VoiceAgentToolDefinitionTests {
    @Test
    func everyToolIsStrictWithAClosedSchema() throws {
        #expect(VoiceAgentTools.definitions.count == 9)
        for tool in VoiceAgentTools.definitions {
            let schema = try #require(tool["input_schema"])
            #expect(tool["strict"] == true)
            #expect(schema["additionalProperties"] == false)
            let properties = try #require(schema["properties"]?.objectValue)
            let required = try #require(schema["required"]?.arrayValue).compactMap(\.stringValue)
            // Strict tools must list every property as required.
            #expect(Set(required) == Set(properties.keys))
        }
    }

    @Test
    func jsonRoundTripsWithSortedKeys() throws {
        let value: JSONValue = ["b": [1, "two", true, .null], "a": ["nested": 2.5]]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        #expect(String(decoding: data, as: UTF8.self) == #"{"a":{"nested":2.5},"b":[1,"two",true,null]}"#)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }
}
