import Foundation

/// Decodes a JSON array element by element, skipping elements that fail to
/// decode instead of failing the whole array. Persisted mixes (the last
/// session, saved presets) are arrays of `SoundSource`; one element written
/// by a newer build or damaged on disk used to throw away every layer.
struct LossyDecodableArray<Element: Decodable>: Decodable {
    var elements: [Element]
    /// How many elements were dropped, so callers can log the loss.
    var skippedCount: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var skipped = 0
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
                continue
            }
            // A failed decode doesn't advance the container, so step past
            // the bad element explicitly. `Skip` accepts any JSON value.
            skipped += 1
            guard (try? container.decode(Skip.self)) != nil else { break }
        }
        self.elements = elements
        self.skippedCount = skipped
    }

    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }
}
