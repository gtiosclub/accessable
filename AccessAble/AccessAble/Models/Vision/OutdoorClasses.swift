import Foundation

/// The classes the outdoor detector is trained on. Owner: Computer Vision (1.1).
///
/// COCO, which every stock detector is trained on, has no pole, bollard, sign post, tree,
/// trash can or traffic cone — the things a blind pedestrian actually walks into on a
/// sidewalk. The fine-tuned model (`rfdetr_s_outdoor`, built by `Scripts/training/`) names
/// these classes, in this order. The same list is `Scripts/training/taxonomy.json`, which
/// the training scripts read; `OutdoorClassesTests` keeps the two in step.
///
/// Geometry, not the model, decides what is in the way: these names are what the user hears
/// instead of "obstacle", and what the danger filter, size priors and fusion key on.
enum OutdoorClasses {
    /// Training order: index i is column i of the model's `confidence` output.
    static let all: [String] = [
        "person", "bicycle", "car", "motorcycle", "bus", "truck", "scooter",
        "stroller", "wheelchair", "dog",
        "pole", "bollard", "tree", "traffic light", "stop sign",
        "fire hydrant", "parking meter", "trash can", "bench", "bike rack",
        "traffic cone", "barrier", "stairs", "potted plant", "chair", "table",
    ]

    /// Ones a walker can collide with or trip over (people and dogs move, so tracking
    /// handles them instead).
    static let hazards: Set<String> = Set(all).subtracting(["person", "dog", "traffic light", "stop sign"])
}
