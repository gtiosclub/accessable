import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision

struct TextDetector: Sendable {
    func detectText(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) throws -> [RecognizedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )
        
        try handler.perform([request])
        
        guard let observations = request.results else {
            return []
        }
        
        var recognizedTexts: [RecognizedText] = []
        
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else {
                continue
            }
            
            let recognizedText = RecognizedText(
                string: candidate.string,
                confidence: candidate.confidence,
                boundingBox:
                    normalizedUprightRect(
                        fromVisionBox: observation.boundingBox
                )
            )
            recognizedTexts.append(recognizedText)
        }
        return recognizedTexts
    }
    
    func detectText(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) throws -> [RecognizedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: orientation,
            options: [:]
        )
        
        try handler.perform([request])
        
        guard let observations = request.results else {
            return []
        }
        
        var recognizedTexts: [RecognizedText] = []
        
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else {
                continue
            }
            
            let recognizedText = RecognizedText(
                string: candidate.string,
                confidence: candidate.confidence,
                boundingBox: normalizedUprightRect(
                    fromVisionBox: observation.boundingBox
                )
            )
            
            recognizedTexts.append(recognizedText)
        }
        
        return recognizedTexts
    }
}
