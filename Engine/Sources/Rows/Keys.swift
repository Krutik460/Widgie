import CryptoKit
import Foundation
import Spec

/// A widget's identity: a UUID, minted on the device that created it, stable across revisions and shares.
package struct WidgetKey: Hashable, Sendable {
    package let raw: String

    package static func mint() -> WidgetKey { WidgetKey(uuid: UUID()) }

    /// Accepts any UUID spelling and keeps the lowercase one, so equal ids compare equal.
    package init?(parsing raw: String) {
        guard let uuid = UUID(uuidString: raw) else { return nil }
        self.init(uuid: uuid)
    }

    private init(uuid: UUID) {
        raw = uuid.uuidString.lowercased()
    }
}

/// A dataset's identity: the rows of one table, which every widget bound to it reads and writes. A UUID,
/// minted when a widget first declares the table, stable across revisions and, later, shares.
package struct DatasetKey: Hashable, Sendable {
    package let raw: String

    package static func mint() -> DatasetKey { DatasetKey(uuid: UUID()) }

    /// Accepts any UUID spelling and keeps the lowercase one, so equal ids compare equal.
    package init?(parsing raw: String) {
        guard let uuid = UUID(uuidString: raw) else { return nil }
        self.init(uuid: uuid)
    }

    private init(uuid: UUID) {
        raw = uuid.uuidString.lowercased()
    }
}

/// A row's identity: a UUIDv7, minted on the writing device, so ids never collide across devices and sort
/// roughly by creation.
package struct RowKey: Hashable, Sendable {
    package let raw: String

    package init?(parsing raw: String) {
        guard let uuid = UUID(uuidString: raw) else { return nil }
        self.raw = uuid.uuidString.lowercased()
    }

    /// 48 bits of milliseconds, the version and variant bits, and 74 random bits.
    static func mint(milliseconds: Int64) -> RowKey {
        var bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        for index in 0..<6 {
            bytes[index] = UInt8(truncatingIfNeeded: milliseconds >> (8 * (5 - index)))
        }
        bytes[6] = 0x70 | (bytes[6] & 0x0f)
        bytes[8] = 0x80 | (bytes[8] & 0x3f)
        var text = bytes.hex
        for offset in [20, 16, 12, 8] {
            text.insert("-", at: text.index(text.startIndex, offsetBy: offset))
        }
        guard let key = RowKey(parsing: text) else {
            preconditionFailure("a formatted UUIDv7 always parses")
        }
        return key
    }
}

/// The name of stored bytes. This target hashes everything it names, so a name always matches its bytes.
func digest(of bytes: Data) -> Spec.Digest {
    guard let digest = Spec.Digest(hex: SHA256.hash(data: bytes).hex) else {
        preconditionFailure("a SHA-256 is always 64 lowercase hex digits")
    }
    return digest
}

extension Sequence<UInt8> {
    fileprivate var hex: String {
        let digits = Array("0123456789abcdef")
        var text = ""
        for byte in self {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0f)])
        }
        return text
    }
}
