import Foundation

protocol ICloudKeyValueStore: AnyObject {
    @discardableResult
    func synchronize() -> Bool
    func object(forKey aKey: String) -> Any?
    func string(forKey aKey: String) -> String?
    func bool(forKey aKey: String) -> Bool
    func data(forKey aKey: String) -> Data?
    func set(_ anObject: Any?, forKey aKey: String)
    func removeObject(forKey aKey: String)
}

extension NSUbiquitousKeyValueStore: ICloudKeyValueStore {}
