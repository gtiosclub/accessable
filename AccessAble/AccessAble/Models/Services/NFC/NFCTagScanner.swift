import CoreNFC
import Foundation

enum NFCScanPurpose: Sendable {
    /// Read the tag ID off an AccessAble sticker.
    case read
    /// Read the ID, or write a new one onto a blank sticker (volunteers setting up a tag).
    case setUp
}

enum NFCScanResult: Equatable, Sendable {
    /// The sticker already had an AccessAble tag ID.
    case found(tagID: String)
    /// The sticker was blank and a new ID was written to it.
    case created(tagID: String)

    var tagID: String {
        switch self {
        case .found(let id), .created(let id): id
        }
    }
}

enum NFCScanError: Error, Equatable, Sendable {
    /// No NFC reader (Simulator, iPad, older iPhone) or the entitlement is missing.
    case unavailable
    /// The user closed the scan sheet, or it timed out.
    case cancelled
    /// Read mode found a sticker that isn't an AccessAble tag.
    case notAccessAbleTag
    /// Set-up mode found a sticker with someone else's data; it is left as is.
    case tagHasOtherData
    case readOnly
    case tooSmall
    case failed

    var message: String {
        switch self {
        case .unavailable: "This iPhone can't scan NFC tags."
        case .cancelled: "Scan cancelled."
        case .notAccessAbleTag: "That isn't an AccessAble tag."
        case .tagHasOtherData: "That sticker already has other data on it, so it wasn't changed. Use a blank sticker."
        case .readOnly: "That sticker is locked and can't be set up."
        case .tooSmall: "That sticker is too small to hold a tag ID."
        case .failed: "Couldn't read the tag. Try holding your phone still near it."
        }
    }
}

@MainActor
protocol NFCTagScanning: AnyObject {
    var isAvailable: Bool { get }
    func scan(_ purpose: NFCScanPurpose) async throws(NFCScanError) -> NFCScanResult
}

/// Core NFC reader. Shows the system scan sheet, reads the sticker's NDEF message and, in
/// set-up mode, writes an `InfoTagLink` URL onto a blank sticker.
///
/// The session is created with the main queue, so the delegate and every tag completion
/// handler run on the main thread; `MainActor.assumeIsolated` checks that at runtime.
@MainActor
final class CoreNFCTagScanner: NSObject, NFCTagScanning {
    private var session: NFCNDEFReaderSession?
    private var continuation: CheckedContinuation<NFCScanResult, any Error>?
    private var purpose: NFCScanPurpose = .read

    var isAvailable: Bool { NFCNDEFReaderSession.readingAvailable }

    func scan(_ purpose: NFCScanPurpose) async throws(NFCScanError) -> NFCScanResult {
        guard isAvailable else { throw .unavailable }
        // Only one sheet at a time; a second scan ends the first.
        finish(.failure(.cancelled))
        session?.invalidate()

        do {
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.purpose = purpose
                let session = NFCNDEFReaderSession(delegate: self, queue: .main, invalidateAfterFirstRead: false)
                session.alertMessage = switch purpose {
                case .read: "Hold the top of your iPhone near the AccessAble tag."
                case .setUp: "Hold the top of your iPhone near the NFC sticker."
                }
                self.session = session
                session.begin()
            }
        } catch let error as NFCScanError {
            throw error
        } catch {
            throw .failed
        }
    }

    /// Resumes the caller once; later calls (e.g. the invalidation after a success) do nothing.
    private func finish(_ result: Result<NFCScanResult, NFCScanError>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result.mapError { $0 as any Error })
    }

    private func succeed(_ result: NFCScanResult, in session: NFCNDEFReaderSession, message: String) {
        finish(.success(result))
        session.alertMessage = message
        session.invalidate()
    }

    private func fail(_ error: NFCScanError, in session: NFCNDEFReaderSession) {
        finish(.failure(error))
        session.invalidate(errorMessage: error.message)
    }

    private func handle(_ tag: any NFCNDEFTag, in session: NFCNDEFReaderSession) {
        let nfc = MainQueueBox((tag: tag, session: session))
        session.connect(to: tag) { error in
            let failed = error != nil
            MainActor.assumeIsolated { self.didConnect(failed: failed, nfc) }
        }
    }

    private func didConnect(failed: Bool, _ nfc: MainQueueBox<(tag: any NFCNDEFTag, session: NFCNDEFReaderSession)>) {
        let (tag, session) = nfc.value
        if failed { return fail(.failed, in: session) }
        tag.queryNDEFStatus { status, capacity, error in
            let failed = error != nil
            MainActor.assumeIsolated {
                let (tag, session) = nfc.value
                if failed { return self.fail(.failed, in: session) }
                guard status != .notSupported else { return self.fail(.notAccessAbleTag, in: session) }
                tag.readNDEF { message, _ in
                    let message = MainQueueBox(message)
                    MainActor.assumeIsolated {
                        self.didRead(message.value, status: status, capacity: capacity, nfc)
                    }
                }
            }
        }
    }

    private func didRead(
        _ message: NFCNDEFMessage?, status: NFCNDEFStatus, capacity: Int,
        _ nfc: MainQueueBox<(tag: any NFCNDEFTag, session: NFCNDEFReaderSession)>
    ) {
        let (tag, session) = nfc.value
        // A blank sticker reports an error on read (zero-length message); treat it as empty.
        if let id = message.flatMap(Self.tagID(in:)) {
            return succeed(.found(tagID: id), in: session, message: "Tag found.")
        }
        guard purpose == .setUp else { return fail(.notAccessAbleTag, in: session) }
        if let message, Self.hasContent(message) { return fail(.tagHasOtherData, in: session) }
        guard status == .readWrite else { return fail(.readOnly, in: session) }

        let id = InfoTagLink.newID()
        guard let record = NFCNDEFPayload.wellKnownTypeURIPayload(url: InfoTagLink.url(for: id)) else {
            return fail(.failed, in: session)
        }
        let newMessage = NFCNDEFMessage(records: [record])
        guard newMessage.length <= capacity else { return fail(.tooSmall, in: session) }
        tag.writeNDEF(newMessage) { error in
            let failed = error != nil
            MainActor.assumeIsolated {
                let session = nfc.value.session
                if failed { return self.fail(.failed, in: session) }
                self.succeed(.created(tagID: id), in: session, message: "Tag set up.")
            }
        }
    }

    nonisolated private static func tagID(in message: NFCNDEFMessage) -> String? {
        message.records.lazy
            .compactMap { $0.wellKnownTypeURIPayload() }
            .compactMap(InfoTagLink.tagID(from:))
            .first
    }

    nonisolated private static func hasContent(_ message: NFCNDEFMessage) -> Bool {
        message.records.contains { $0.typeNameFormat != .empty && !$0.payload.isEmpty }
    }
}

/// Core NFC objects aren't Sendable. They only ever cross between completion handlers that
/// all run on the main queue the session was given, so carrying them across is safe.
private struct MainQueueBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

extension CoreNFCTagScanner: @preconcurrency NFCNDEFReaderSessionDelegate {
    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: any Error) {
        let code = (error as? NFCReaderError)?.code
        switch code {
        case .readerSessionInvalidationErrorUserCanceled, .readerSessionInvalidationErrorSessionTimeout:
            finish(.failure(.cancelled))
        case .readerErrorUnsupportedFeature, .readerErrorSecurityViolation:
            finish(.failure(.unavailable))
        default:
            finish(.failure(.failed))
        }
        if self.session === session { self.session = nil }
    }

    // Required by the protocol, but unused: implementing didDetect tags replaces it.
    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {}

    func readerSession(_ session: NFCNDEFReaderSession, didDetect tags: [any NFCNDEFTag]) {
        guard tags.count == 1, let tag = tags.first else {
            session.alertMessage = "More than one tag found. Hold your phone near just one."
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { session.restartPolling() }
            return
        }
        handle(tag, in: session)
    }
}
