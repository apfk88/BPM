import Foundation

/// Only these fixed categories may leave the device. Advertisement and Device
/// Information strings are classification inputs, never telemetry parameters.
struct SensorAnalyticsIdentity: Equatable {
    enum Source: String { case unknown, advertisement, deviceInformation = "device_information" }
    enum Vendor: String, CaseIterable {
        case unknown, polar, garmin, wahoo, coospo, scosche, movesense, suunto, magene, moofit, coros
    }

    enum Model: String, CaseIterable {
        case unknown
        case polarH10 = "polar_h10", polarH9 = "polar_h9", polarH7 = "polar_h7"
        case polarVeritySense = "polar_verity_sense", polarOH1 = "polar_oh1"
        case garminHRMProPlus = "garmin_hrm_pro_plus", garminHRMPro = "garmin_hrm_pro"
        case garminHRMDual = "garmin_hrm_dual", garminHRMFit = "garmin_hrm_fit"
        case garminHRM600 = "garmin_hrm_600", garminHRM200 = "garmin_hrm_200"
        case wahooTickrX = "wahoo_tickr_x", wahooTickrFit = "wahoo_tickr_fit"
        case wahooTickr = "wahoo_tickr", wahooTrackrHR = "wahoo_trackr_hr"
        case coospoH6 = "coospo_h6", coospoH9Z = "coospo_h9z", coospoH808S = "coospo_h808s"
        case coospoHW9 = "coospo_hw9", coospoHW807 = "coospo_hw807", coospoHW706 = "coospo_hw706"
        case scoscheRhythmPlus = "scosche_rhythm_plus", scoscheRhythm24 = "scosche_rhythm_24"
        case suuntoSmartSensor = "suunto_smart_sensor"
        case mageneH64 = "magene_h64", mageneH303 = "magene_h303", mageneH603 = "magene_h603"
        case moofitHR6 = "moofit_hr6", corosHRM = "coros_hrm"
    }

    let vendor: Vendor
    let model: Model
    let source: Source
    init(vendor: Vendor, model: Model = .unknown, source: Source = .advertisement) {
        self.vendor = vendor
        self.model = model
        self.source = vendor == .unknown ? .unknown : source
    }
    static let unknown = SensorAnalyticsIdentity(vendor: .unknown)
    var parameters: [String: String] {
        ["sensor_vendor": vendor.rawValue, "sensor_model": model.rawValue, "sensor_identity_source": source.rawValue]
    }

    static func classify(advertisedName: String?, manufacturerName: String? = nil, modelNumber: String? = nil) -> Self {
        let advertisement = normalized(advertisedName)
        let manufacturer = normalized(manufacturerName)
        let deviceModel = normalized(modelNumber)
        // A recognized Device Information manufacturer takes precedence over an
        // arbitrary advertised name; an unrecognized model remains unknown.
        let manufacturerVendor = vendor(in: manufacturer)
        let advertisedVendor = vendor(in: advertisement)
        let modelVendor = vendor(in: deviceModel)
        let resolvedVendor = manufacturerVendor != .unknown ? manufacturerVendor
            : (advertisedVendor != .unknown ? advertisedVendor : modelVendor)
        let candidates: [(String, Source)] = [(deviceModel, .deviceInformation), (advertisement, .advertisement)]
        for (candidate, source) in candidates where !candidate.isEmpty {
            if let match = knownModel(in: candidate, vendor: resolvedVendor) {
                return Self(vendor: match.vendor, model: match.model, source: source)
            }
        }
        let source: Source = manufacturerVendor != .unknown || (advertisedVendor == .unknown && modelVendor != .unknown)
            ? .deviceInformation : .advertisement
        return Self(vendor: resolvedVendor, source: source)
    }

    private static func normalized(_ value: String?) -> String {
        String((value ?? "").prefix(128)).lowercased()
            .replacingOccurrences(of: "+", with: " plus ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func vendor(in value: String) -> Vendor {
        let words = Set(value.split(separator: " ").map(String.init))
        for vendor in Vendor.allCases where vendor != .unknown {
            if words.contains(vendor.rawValue) { return vendor }
        }
        // Distinctive product names commonly omit the manufacturer in BLE adverts.
        if !words.isDisjoint(with: ["tickr", "trackr", "tickrx", "tickrfit", "trackrhr"]) { return .wahoo }
        let tokens = value.split(separator: " ")
        let knownGarminPrefix = tokens.count >= 2 && tokens[0] == "hrm"
            && ["pro", "proplus", "dual", "fit", "600", "200"].contains(String(tokens[1]))
        if knownGarminPrefix || !words.isDisjoint(with: ["hrmpro", "hrmproplus", "hrmdual", "hrmfit", "hrm600", "hrm200"]) { return .garmin }
        let knownScoschePrefix = tokens.count >= 2 && tokens[0] == "rhythm"
            && ["plus", "24"].contains(String(tokens[1]))
        if knownScoschePrefix || !words.isDisjoint(with: ["rhythm24", "rhythmplus"]) { return .scosche }
        return .unknown
    }

    private static func knownModel(in value: String, vendor: Vendor) -> Self? {
        // Match whole normalized product tokens, allowing a trailing sensor ID
        // without returning that ID. Short names (H10, HR6) require a known vendor.
        let tokens = value.split(separator: " ").map(String.init)
        func has(_ aliases: [String]) -> Bool {
            aliases.contains { alias in
                let sought = alias.split(separator: " ").map(String.init)
                guard tokens.count >= sought.count else { return false }
                return (0...(tokens.count - sought.count)).contains { start in
                    Array(tokens[start..<(start + sought.count)]) == sought
                }
            }
        }
        let match: Model?
        switch vendor {
        case .polar:
            if has(["verity sense", "veritysense"]) { match = .polarVeritySense }
            else if has(["h10"]) { match = .polarH10 }
            else if has(["h9"]) { match = .polarH9 }
            else if has(["h7"]) { match = .polarH7 }
            else if has(["oh1"]) { match = .polarOH1 }
            else { match = nil }
        case .garmin:
            if has(["hrm pro plus", "hrmproplus", "hrm proplus"]) { match = .garminHRMProPlus }
            else if has(["hrm pro", "hrmpro"]) { match = .garminHRMPro }
            else if has(["hrm dual", "hrmdual"]) { match = .garminHRMDual }
            else if has(["hrm fit", "hrmfit"]) { match = .garminHRMFit }
            else if has(["hrm 600", "hrm600"]) { match = .garminHRM600 }
            else if has(["hrm 200", "hrm200"]) { match = .garminHRM200 }
            else { match = nil }
        case .wahoo:
            if has(["tickr x", "tickrx"]) { match = .wahooTickrX }
            else if has(["tickr fit", "tickrfit"]) { match = .wahooTickrFit }
            else if has(["trackr hr", "trackr heart rate", "trackrhr"]) { match = .wahooTrackrHR }
            else if has(["tickr"]) { match = .wahooTickr }
            else { match = nil }
        case .coospo:
            if has(["h808s"]) { match = .coospoH808S }
            else if has(["h9z"]) { match = .coospoH9Z }
            else if has(["h6"]) { match = .coospoH6 }
            else if has(["hw807"]) { match = .coospoHW807 }
            else if has(["hw706"]) { match = .coospoHW706 }
            else if has(["hw9"]) { match = .coospoHW9 }
            else { match = nil }
        case .scosche:
            if has(["rhythm plus", "rhythmplus"]) { match = .scoscheRhythmPlus }
            else if has(["rhythm24", "rhythm 24"]) { match = .scoscheRhythm24 }
            else { match = nil }
        case .suunto: match = has(["smart sensor", "smartsensor"]) ? .suuntoSmartSensor : nil
        case .magene:
            if has(["h603"]) { match = .mageneH603 }
            else if has(["h303"]) { match = .mageneH303 }
            else if has(["h64"]) { match = .mageneH64 }
            else { match = nil }
        case .moofit: match = has(["hr6"]) ? .moofitHR6 : nil
        case .coros: match = has(["heart rate monitor", "hrm"]) ? .corosHRM : nil
        case .movesense, .unknown: match = nil
        }
        return match.map { Self(vendor: vendor, model: $0) }
    }
}

/// One user connection session, including automatic reconnects. Capabilities are
/// observed from packets, not inferred from model names, and only improve once.
final class SensorCompatibilityAnalytics {
    enum FailureStage: String { case connect, services, characteristics, subscribe, measurement }
    private let emit: (AppAnalytics.Event, [String: String]) -> Void
    private(set) var identity: SensorAnalyticsIdentity
    private var connectedReported = false
    private var readyReported = false
    private var disconnectedReported = false
    private var failures: Set<String> = []
    private var rrSupport = "unknown"
    private var contactSupport = "unknown"
    private var batterySupport = "unknown"
    private var lastCapabilities: [String: String]?

    init(identity: SensorAnalyticsIdentity, emit: @escaping (AppAnalytics.Event, [String: String]) -> Void = AppAnalytics.signal) {
        self.identity = identity
        self.emit = emit
    }

    func connected() {
        guard !connectedReported else { return }
        connectedReported = true
        signal("connected")
    }

    func updateIdentity(_ identity: SensorAnalyticsIdentity) {
        guard self.identity != identity else { return }
        self.identity = identity
        reportCapabilitiesIfChanged()
    }

    func observedBatteryService(present: Bool) {
        if !present, batterySupport == "unknown" { batterySupport = "unavailable" }
        reportCapabilitiesIfChanged()
    }

    func observedBatteryLevel(_ value: UInt8) {
        guard value <= 100 else { return }
        batterySupport = "supported"
        reportCapabilitiesIfChanged()
    }

    func receivedMeasurement(hasRRIntervals: Bool, contactSupported: Bool, hasUsableHeartRate: Bool) {
        if hasRRIntervals { rrSupport = "observed" }
        else if rrSupport == "unknown" { rrSupport = "not_yet_observed" }
        if contactSupported { contactSupport = "supported" }
        else if contactSupport == "unknown" { contactSupport = "unsupported" }
        guard hasUsableHeartRate else { return }
        if !readyReported {
            readyReported = true
            lastCapabilities = parameters
            signal("ready")
        } else {
            reportCapabilitiesIfChanged()
        }
    }

    func failed(stage: FailureStage, category: AppFailureCategory) {
        guard failures.insert(stage.rawValue + ":" + category.rawValue).inserted else { return }
        signal("failed", additional: ["stage": stage.rawValue, "reason": category.rawValue])
    }

    func disconnected(userInitiated: Bool) {
        guard !disconnectedReported else { return }
        disconnectedReported = true
        signal("disconnected", additional: ["reason": userInitiated ? "user" : "connection_lost"])
    }

    private var parameters: [String: String] {
        identity.parameters.merging([
            "rr_support": rrSupport, "contact_support": contactSupport,
            "battery_support": batterySupport
        ]) { _, new in new }
    }

    private func reportCapabilitiesIfChanged() {
        guard readyReported, lastCapabilities != parameters else { return }
        lastCapabilities = parameters
        signal("capabilities")
    }

    private func signal(_ outcome: String, additional: [String: String] = [:]) {
        var values = parameters
        values["outcome"] = outcome
        values.merge(additional) { _, new in new }
        emit(.sensorConnection, values)
    }
}
