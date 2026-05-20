import Foundation
@testable import BPM

final class InMemoryICloudKeyValueStore: ICloudKeyValueStore {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    func synchronize() -> Bool {
        true
    }

    func object(forKey aKey: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[aKey]
    }

    func string(forKey aKey: String) -> String? {
        object(forKey: aKey) as? String
    }

    func bool(forKey aKey: String) -> Bool {
        switch object(forKey: aKey) {
        case let value as Bool:
            value
        case let value as NSNumber:
            value.boolValue
        default:
            false
        }
    }

    func data(forKey aKey: String) -> Data? {
        object(forKey: aKey) as? Data
    }

    func set(_ anObject: Any?, forKey aKey: String) {
        lock.lock()
        defer { lock.unlock() }
        values[aKey] = anObject
    }

    func removeObject(forKey aKey: String) {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: aKey)
    }
}
