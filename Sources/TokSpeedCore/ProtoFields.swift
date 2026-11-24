import Foundation

// Minimal, bounds-checked protobuf reader. Only fields used below are decoded;
// prompts, tool arguments and other conversation content are never interpreted.
struct ProtoFields {
    struct Field { let number: Int; let integer: UInt64?; let bytes: Data? }
    let fields: [Field]

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        var index = 0
        func varint() -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard index < bytes.count else { return nil }
                let byte = bytes[index]; index += 1
                if shift == 63 && byte > 1 { return nil }
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
            }
            return nil
        }
        var result: [Field] = []
        while index < bytes.count {
            guard let tag = varint(), tag >> 3 > 0, tag >> 3 <= UInt64(Int.max) else { return nil }
            let number = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                guard let value = varint() else { return nil }
                result.append(Field(number: number, integer: value, bytes: nil))
            case 2:
                guard let size = varint(), size <= UInt64(bytes.count - index) else { return nil }
                let end = index + Int(size)
                result.append(Field(number: number, integer: nil, bytes: Data(bytes[index..<end])))
                index = end
            case 1, 5:
                let size = tag & 7 == 1 ? 8 : 4
                guard size <= bytes.count - index else { return nil }
                index += size
            default: return nil
            }
        }
        fields = result
    }

    func integer(_ n: Int) -> UInt64? { fields.first { $0.number == n }?.integer }
    func bytes(_ n: Int) -> Data? { fields.first { $0.number == n }?.bytes }
    func message(_ n: Int) -> ProtoFields? { bytes(n).flatMap(ProtoFields.init) }
    func duration(_ n: Int) -> Double? {
        guard let value = message(n) else { return nil }
        let rawSeconds = value.integer(1) ?? 0
        let nanos = Double(value.integer(2) ?? 0)
        guard rawSeconds <= UInt64(Int64.max), nanos < 1_000_000_000 else { return nil }
        return Double(rawSeconds) + nanos / 1_000_000_000
    }

    func generationDuration(_ n: Int) -> Double? {
        // Protobuf writers may omit a zero-valued duration.
        fields.contains { $0.number == n } ? duration(n) : 0
    }
}
