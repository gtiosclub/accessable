import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Synchronization
import Testing
@testable import SceneGeometry

/// Records what it was asked and answers with a fixed reply, standing in for the model.
private final class RecordingResponder: AskAIResponder {
    struct Call: Sendable {
        let question: String
        let facts: ImageFacts
    }

    private let reply: @Sendable (String) async throws -> String
    private let recorded = Mutex<[Call]>([])

    init(reply: @escaping @Sendable (String) async throws -> String) {
        self.reply = reply
    }

    var calls: [Call] { recorded.withLock { $0 } }

    func answer(_ question: String, facts: ImageFacts) async throws -> String {
        recorded.withLock { $0.append(Call(question: question, facts: facts)) }
        return try await reply(question)
    }
}

private func roomSignData() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "room210", withExtension: "jpg"))
    return try Data(contentsOf: url)
}

private func detection(_ label: String, metres: Double?, degrees: Double, hazard: Bool = false) -> Detection {
    Detection(label: label, confidence: 0.8, boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
              distance: metres, bearing: RelativeBearing(degrees: degrees), origin: .model, isHazard: hazard)
}

private func text(_ string: String, x: CGFloat, y: CGFloat = 0.5) -> RecognizedText {
    RecognizedText(string: string, confidence: 0.9, boundingBox: CGRect(x: x - 0.05, y: y - 0.05, width: 0.1, height: 0.1))
}

@Suite("T19 — Ask AI")
struct AskAITests {
    @Test("a saved image and a question produce the model's answer")
    func answersQuestion() async throws {
        let responder = RecordingResponder { _ in "  Room 210 is ahead.\n" }

        let response = try await AskAI(responder: responder).answer("Where is Room 210?", imageData: roomSignData())

        #expect(response.answer == "Room 210 is ahead.")
    }

    @Test("the model gets the question and what Vision read in the image")
    func passesQuestionAndImageFacts() async throws {
        let responder = RecordingResponder { _ in "Room 210 is ahead." }

        _ = try await AskAI(responder: responder).answer("  Where is Room 210? ", imageData: roomSignData())

        let call = try #require(responder.calls.first)
        #expect(call.question == "Where is Room 210?")
        let read = call.facts.text.map(\.string).joined(separator: " ").lowercased()
        #expect(read.contains("210"))
        #expect(call.facts.people.isEmpty)

        let prompt = AskAIPrompt.prompt(question: call.question, facts: call.facts)
        #expect(prompt.contains("Question: Where is Room 210?"))
        #expect(prompt.lowercased().contains("210"))
    }

    @Test("an empty question is rejected before any work")
    func emptyQuestion() async throws {
        let responder = RecordingResponder { _ in "unused" }

        await #expect(throws: AskAIError.emptyQuestion) {
            try await AskAI(responder: responder).answer(" \n", imageData: roomSignData())
        }
        #expect(responder.calls.isEmpty)
    }

    @Test("empty or undecodable image data is rejected", arguments: [Data(), Data("not an image".utf8)])
    func invalidImage(data: Data) async {
        let responder = RecordingResponder { _ in "unused" }

        await #expect(throws: AskAIError.invalidImage) {
            try await AskAI(responder: responder).answer("What is in front of me?", imageData: data)
        }
        #expect(responder.calls.isEmpty)
    }

    @Test("a model failure reaches the caller")
    func modelFailurePropagates() async throws {
        let responder = RecordingResponder { _ in throw AskAIError.modelFailed("model unavailable") }

        await #expect(throws: AskAIError.modelFailed("model unavailable")) {
            try await AskAI(responder: responder).answer("Is there a chair nearby?", imageData: roomSignData())
        }
    }

    @Test("a blank answer is an error, not silence", arguments: ["", "   \n\t"])
    func blankAnswer(reply: String) async throws {
        let responder = RecordingResponder { _ in reply }

        await #expect(throws: AskAIError.emptyAnswer) {
            try await AskAI(responder: responder).answer("Which door is the exit?", imageData: roomSignData())
        }
    }

    @Test("latency covers the whole request, in milliseconds")
    func measuresLatency() async throws {
        let responder = RecordingResponder { _ in
            try await Task.sleep(for: .milliseconds(50))
            return "Nothing I can read."
        }

        let response = try await AskAI(responder: responder).answer("What is directly in front of me?", imageData: roomSignData())

        #expect(response.latencyMilliseconds >= 50)
        #expect(response.latencyMilliseconds < 10_000)
    }

    @Test("concurrent questions each get their own answer")
    func concurrentRequests() async throws {
        let ask = AskAI(responder: RecordingResponder { question in "Answer to \(question)" })
        let image = try roomSignData()
        let questions = (1...8).map { "Question \($0)?" }

        let answers = try await withThrowingTaskGroup(of: (String, String).self) { group in
            for question in questions {
                group.addTask { (question, try await ask.answer(question, imageData: image).answer) }
            }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }

        #expect(answers.count == questions.count)
        for question in questions {
            #expect(answers[question] == "Answer to \(question)")
        }
    }
}

@Suite("T19 — Ask AI with the live pipeline's detections")
struct AskAIPipelineTests {
    @Test("what the pipeline saw reaches the model, most important first and capped")
    func passesDetections() async throws {
        let responder = RecordingResponder { _ in "A bottle is on your left." }
        var ask = AskAI(responder: responder)
        ask.maxDetections = 2
        let observation = SceneObservation(
            detections: [
                detection("cup", metres: 3, degrees: 0),
                detection("bottle", metres: 1, degrees: -60),
                detection("chair", metres: 2, degrees: 20, hazard: true),
            ],
            elevationHazards: [ElevationHazard(type: .stepDown, distance: 1.5, heightChange: -0.15)]
        )

        _ = try await ask.answer("Is there a bottle?", imageData: roomSignData(), observation: observation)

        let facts = try #require(responder.calls.first).facts
        #expect(facts.detections.map(\.label) == ["chair", "bottle"])
        #expect(facts.elevationHazards.count == 1)
        #expect(facts.text.map(\.string).joined().lowercased().contains("210"))

        let prompt = AskAIPrompt.prompt(question: "Is there a bottle?", facts: facts)
        #expect(prompt.contains("- Step down 1.5 metres ahead."))
        #expect(prompt.contains("- Bottle on your left, 1 metre."))
    }

    @Test("people the pipeline found replace Vision's, which have no distance")
    func noDoubleCountedPeople() async throws {
        let responder = RecordingResponder { _ in "One person ahead." }
        var extractor = ImageFactExtractor()
        extractor.maxLabels = 0

        _ = try await AskAI(extractor: extractor, responder: responder).answer(
            "Is anyone here?", imageData: roomSignData(),
            observation: SceneObservation(detections: [detection("person", metres: 2, degrees: 0)])
        )

        let facts = try #require(responder.calls.first).facts
        #expect(facts.people.isEmpty)
        #expect(facts.detections.map(\.label) == ["person"])
    }
}

@Suite("T19 — object colours")
struct ObjectColorTests {
    @Test("sRGB colours get the names people use", arguments: [
        (0.10, 0.10, 0.10, "black"), (0.95, 0.95, 0.95, "white"), (0.60, 0.60, 0.62, "gray"),
        (0.85, 0.10, 0.10, "red"), (0.95, 0.55, 0.10, "orange"), (0.45, 0.28, 0.12, "brown"),
        (0.95, 0.90, 0.15, "yellow"), (0.15, 0.70, 0.20, "green"), (0.10, 0.55, 0.60, "teal"),
        (0.15, 0.30, 0.85, "blue"), (0.50, 0.20, 0.80, "purple"), (0.95, 0.40, 0.70, "pink"),
    ])
    func names(red: Double, green: Double, blue: Double, expected: String) {
        #expect(colorName(red: red, green: green, blue: blue) == expected)
    }

    /// Left half teal, right half red, in a 200 × 100 PNG.
    private func twoToneImage() throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.55, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.setFillColor(CGColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test("each detected object gets the colour inside its box")
    func colorPerDetection() async throws {
        let bottle = Detection(label: "bottle", confidence: 0.8, boundingBox: CGRect(x: 0.05, y: 0.1, width: 0.4, height: 0.8),
                               distance: 1, bearing: RelativeBearing(degrees: -30), origin: .model, isHazard: false)
        let cup = Detection(label: "cup", confidence: 0.8, boundingBox: CGRect(x: 0.55, y: 0.1, width: 0.4, height: 0.8),
                            distance: 1, bearing: RelativeBearing(degrees: 30), origin: .model, isHazard: false)
        let responder = RecordingResponder { _ in "The bottle looks teal." }

        _ = try await AskAI(responder: responder).answer(
            "What colour is the bottle?", imageData: twoToneImage(),
            observation: SceneObservation(detections: [bottle, cup])
        )

        let facts = try #require(responder.calls.first).facts
        #expect(facts.detectionColors[bottle.id] == "teal")
        #expect(facts.detectionColors[cup.id] == "red")
        #expect(AskAIPrompt.prompt(question: "What colour is the bottle?", facts: facts)
            .contains("- Bottle slightly left, 1 metre. Main colour: teal."))
    }

    @Test("the template answers colour questions")
    func templateColors() {
        let bottle = detection("bottle", metres: 1, degrees: -60)
        let laptop = detection("laptop", metres: 1, degrees: 0)
        let facts = ImageFacts(detections: [bottle, laptop], detectionColors: [bottle.id: "teal", laptop.id: "gray"])
        let responder = TemplateAskAIResponder()

        #expect(responder.answer("What are the colors?", facts: facts) == "Bottle looks teal. Laptop looks gray.")
        #expect(responder.answer("What colour is the bottle?", facts: facts) == "Bottle on your left, 1 metre. It looks teal.")
    }
}

@Suite("T19 — still image encoding")
struct StillImageEncodingTests {
    @Test("a camera buffer becomes an upright JPEG")
    func encodesUprightJPEG() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 40, 20, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixelBuffer = try #require(buffer)

        // The rear camera is landscape; a portrait interface rotates it a quarter turn.
        let data = try stillImageJPEG(from: pixelBuffer, orientation: .right)

        #expect(data.prefix(2) == Data([0xFF, 0xD8]))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 20)
        #expect(image.height == 40)
    }

    @Test("the extractor reads the encoded still")
    func extractsFromSavedImage() throws {
        let facts = try ImageFactExtractor().facts(from: roomSignData())

        #expect(facts.text.map(\.string).joined(separator: " ").lowercased().contains("room 210"))
    }
}

@Suite("T19 — answers without the language model")
struct TemplateAskAIResponderTests {
    private let responder = TemplateAskAIResponder()

    @Test("a room asked for is located by its sign")
    func locatesRoom() {
        let facts = ImageFacts(text: [text("ROOM 210", x: 0.2, y: 0.1), text("ROOM 212", x: 0.8)])

        #expect(responder.answer("Where is Room 210?", facts: facts) == "\"ROOM 210\" is on your left, high up.")
    }

    @Test("an exit sign and a door are both mentioned")
    func exitAndDoor() {
        let facts = ImageFacts(text: [text("EXIT", x: 0.5)], labels: ["door", "hallway"])

        #expect(responder.answer("Which door is the exit?", facts: facts)
            == "\"EXIT\" is ahead. There seems to be a door in view.")
    }

    @Test("plural questions match singular labels")
    func plurals() {
        #expect(responder.answer("Are there any chairs?", facts: ImageFacts(labels: ["chair"]))
            == "There seems to be a chair in view.")
    }

    @Test("people are counted and placed")
    func people() {
        let facts = ImageFacts(people: [CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.5), CGRect(x: 0.8, y: 0.3, width: 0.1, height: 0.5)])

        #expect(responder.answer("Is anyone here?", facts: facts) == "I can see 2 people, ahead and on your right.")
    }

    @Test("it says so rather than guessing")
    func cannotTell() {
        #expect(responder.answer("Where is Room 210?", facts: ImageFacts(text: [text("ROOM 212", x: 0.5)], labels: ["door"]))
            == "I can't tell that from this picture. I can see \"ROOM 212\", door.")
        #expect(responder.answer("Where is Room 210?", facts: ImageFacts()) == "I can't tell that from this picture.")
    }

    @Test("an object the pipeline found is placed like Describe my surroundings")
    func pipelineObject() {
        let facts = ImageFacts(detections: [detection("bottle", metres: 1, degrees: -60)], labels: ["chair"])

        #expect(responder.answer("Is there a bottle nearby?", facts: facts) == "Bottle on your left, 1 metre.")
    }

    @Test("a general question gets the Describe my surroundings overview")
    func overview() {
        let facts = ImageFacts(
            detections: [detection("bottle", metres: 1, degrees: -60)],
            text: [text("EXIT", x: 0.8)]
        )

        #expect(responder.answer("What's in front of me?", facts: facts)
            == "Bottle on your left, 1 metre. EXIT is visible on your right.")
        #expect(responder.answer("Describe my surroundings", facts: facts)
            == responder.answer("What's in front of me?", facts: facts))
    }

    @Test("people asked about include the pipeline's")
    func pipelinePeople() {
        let facts = ImageFacts(detections: [detection("person", metres: 2, degrees: 0)])

        #expect(responder.answer("Is anyone here?", facts: facts) == "Person 2 metres ahead.")
    }

    @Test("what isn't there is named as not found, with what is")
    func notFoundListsDetections() {
        let facts = ImageFacts(detections: [detection("bottle", metres: 1, degrees: -60)])

        #expect(responder.answer("Is there a laptop?", facts: facts) == "I can't tell that from this picture. I can see bottle.")
    }
}
