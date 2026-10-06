import Foundation

/// One element of an array that may not be readable, decoded as nil rather
/// than failing the whole array: a shortcut or a rule with a typo in it should
/// cost the user that one entry, not every other one beside it.
///
/// A wrapper rather than `try?` around each element, because an unkeyed
/// container does not move past an element that failed to decode.
struct Forgiving<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: any Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}
