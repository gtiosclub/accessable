import Foundation

/// The voice agent's system prompt and tool definitions. Kept constant so the request prefix
/// (tools, then system) stays byte-identical between requests and can be cached.
enum VoiceAgentTools {
    static let press = "press_control"
    static let typeText = "type_text"
    static let setToggle = "set_toggle"
    static let setValue = "set_value"
    static let navigate = "navigate"
    static let describeSurroundings = "describe_surroundings"
    static let whereAmI = "where_am_i"
    static let repeatLast = "repeat_last_announcement"
    static let lookWithCamera = "look_with_camera"

    static let systemPrompt = """
        You are the voice assistant inside AccessAble, a walking-guidance app for blind and low-vision \
        people. The user talks to you hands-free and you operate the app for them. Their words come from \
        on-device speech recognition, so expect misheard words and fix obvious mistakes yourself.

        Every user message says which screen is open and lists its controls with ids, top to bottom. \
        Use the tools to do what the user asks: press buttons, type into text fields, flip toggles, set \
        sliders and choices, or jump to another screen. Each tool result shows the screen as it is after \
        the action, so you can take the next step of a longer request. Only use control ids from the \
        latest listing. If what the user wants isn't on screen, navigate to where it is; if you can't \
        find it, say so.

        Your reply is spoken aloud, often while the user is walking. Answer in one short sentence of \
        plain text with no lists or formatting, for example "Opened settings." or "Searching for the \
        library." When a tool gives you something to tell the user, such as a description of the \
        surroundings, pass it on faithfully and briefly. Answer simple general questions yourself. For \
        anything about what is physically around the user, use look_with_camera or \
        describe_surroundings rather than guessing. Never tell the user it is safe to cross a street.

        If a request is unclear or was probably misheard, ask one short question instead of guessing.

        The microphone is always on, so you will sometimes hear things not meant for you: the app's or \
        VoiceOver's own speech (an obstacle warning, a control name followed by "button"), or the user \
        talking to someone else. When the text doesn't sound like a request to you, call no tools and \
        reply with nothing at all.

        Some actions, such as calling a volunteer, ending a trip, or changing a setting, need the \
        user's confirmation. The app asks the user itself before doing them, and the tool result \
        tells you whether they said yes. Don't ask for confirmation yourself.
        """

    /// Tool definitions in Messages API form. `strict` guarantees the inputs match the schema.
    static let definitions: [JSONValue] = [
        tool(
            press,
            "Press a button on the current screen, including rows, tabs and chips listed as buttons.",
            properties: ["control_id": controlID]
        ),
        tool(
            typeText,
            "Replace the text in a text field on the current screen. Set submit to true to also press "
                + "the keyboard's return or search key, which runs the search or sends the message.",
            properties: [
                "control_id": controlID,
                "text": ["type": "string", "description": "The full text the field should contain."],
                "submit": ["type": "boolean", "description": "Press return after typing."],
            ]
        ),
        tool(
            setToggle,
            "Turn a toggle on the current screen on or off.",
            properties: [
                "control_id": controlID,
                "on": ["type": "boolean", "description": "true for on, false for off."],
            ]
        ),
        tool(
            setValue,
            "Set a slider to a number within its listed range, or pick one of a choice control's listed options.",
            properties: [
                "control_id": controlID,
                "value": [
                    "type": "string",
                    "description": "A number for a slider, or the exact option name for a choice.",
                ],
            ]
        ),
        tool(
            navigate,
            "Go to another part of the app without pressing a control: back one screen, home, place "
                + "search, settings, call help (volunteers), or the camera guidance screen.",
            properties: [
                "destination": [
                    "type": "string",
                    "enum": .array(AgentDestination.allCases.map { .string($0.rawValue) }),
                ],
            ]
        ),
        tool(
            describeSurroundings,
            "Get a quick description of what the camera currently sees around the user."
        ),
        tool(
            whereAmI,
            "Get the user's current location, such as the street they are on and the direction they face."
        ),
        tool(
            repeatLast,
            "Say the app's last spoken announcement again. The app speaks it itself; reply with nothing."
        ),
        tool(
            lookWithCamera,
            "Take a fresh camera picture and answer a question about it, such as what a sign says, "
                + "where the door is, or what is in front of the user. Takes a few seconds.",
            properties: [
                "question": ["type": "string", "description": "The user's question as a full sentence."],
            ]
        ),
    ]

    private static let controlID: JSONValue = [
        "type": "string",
        "description": "The control's id from the latest screen listing, such as c12.",
    ]

    private static func tool(_ name: String, _ description: String, properties: [String: JSONValue] = [:]) -> JSONValue {
        [
            "name": .string(name),
            "description": .string(description),
            "strict": true,
            "input_schema": [
                "type": "object",
                "properties": .object(properties),
                "required": .array(properties.keys.sorted().map { .string($0) }),
                "additionalProperties": false,
            ],
        ]
    }
}
