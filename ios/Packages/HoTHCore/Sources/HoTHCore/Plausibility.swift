import Foundation

// Principle: make fraud expensive and obvious, not impossible.
// These are consistency checks and best-effort signals; they never claim to prove a photo is real.

public enum CaptureSource: String, Codable, Sendable {
    case liveCamera
    case demoLibrary
}

public struct GPSFix: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    /// Horizontal accuracy in metres.
    public let accuracyMeters: Double

    public init(latitude: Double, longitude: Double, accuracyMeters: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
    }
}

public enum PlausibilityStatus: Int, Comparable, Sendable {
    case accepted = 0
    case needsLivePhoto = 1
    case rejected = 2

    public static func < (lhs: PlausibilityStatus, rhs: PlausibilityStatus) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PlausibilityInput: Sendable {
    public let captureSource: CaptureSource
    public let capturedAt: Date
    public let now: Date
    public let gps: GPSFix?
    public let vision: VisionAnalysis
    /// Category the resident said (e.g. picked in the UI), if any.
    public let reportedCategory: ReportCategory?
    /// Demo mode allows the bundled demo photos; production never does.
    public let isDemoMode: Bool

    public init(captureSource: CaptureSource, capturedAt: Date, now: Date, gps: GPSFix?, vision: VisionAnalysis,
                reportedCategory: ReportCategory? = nil, isDemoMode: Bool = false) {
        self.captureSource = captureSource
        self.capturedAt = capturedAt
        self.now = now
        self.gps = gps
        self.vision = vision
        self.reportedCategory = reportedCategory
        self.isDemoMode = isDemoMode
    }
}

public struct PlausibilityResult: Equatable, Sendable {
    public let status: PlausibilityStatus
    public let reasonsEN: [String]
    public let reasonsAR: [String]
}

public enum Plausibility {
    /// Captures older than this at submit time must be retaken.
    public static let maxCaptureAge: TimeInterval = 120
    /// Allowed clock skew for capture times slightly in the future.
    public static let futureTolerance: TimeInterval = 60
    public static let maxGPSAccuracyMeters: Double = 100

    /// Runs every check and returns the worst status with all reasons (pure).
    public static func evaluate(_ input: PlausibilityInput) -> PlausibilityResult {
        var status = PlausibilityStatus.accepted
        var reasonsEN: [String] = []
        var reasonsAR: [String] = []

        func flag(_ level: PlausibilityStatus, _ en: String, _ ar: String) {
            status = max(status, level)
            reasonsEN.append(en)
            reasonsAR.append(ar)
        }

        let isDemoPhoto = input.captureSource == .demoLibrary
        if isDemoPhoto && !input.isDemoMode {
            flag(.rejected,
                 "Reports need a photo taken with the live camera, not one from the library.",
                 "البلاغ يحتاج صورة ملتقطة بالكاميرا مباشرة، وليس من المعرض.")
        }

        let age = input.now.timeIntervalSince(input.capturedAt)
        if !isDemoPhoto {
            if age < -futureTolerance {
                flag(.needsLivePhoto,
                     "The capture time looks wrong. Please take a new live photo.",
                     "وقت الالتقاط غير صحيح. يرجى التقاط صورة جديدة مباشرة.")
            } else if age > maxCaptureAge {
                flag(.needsLivePhoto,
                     "This photo was taken more than 2 minutes ago. Please take a fresh live photo from the spot.",
                     "التُقطت هذه الصورة قبل أكثر من دقيقتين. يرجى التقاط صورة جديدة من الموقع.")
            }
        }

        if let gps = input.gps {
            if gps.accuracyMeters < 0 || gps.accuracyMeters > maxGPSAccuracyMeters {
                flag(.needsLivePhoto,
                     "Your location is not precise enough. Move to an open spot and retake the photo.",
                     "موقعك غير دقيق بما يكفي. انتقل إلى مكان مفتوح وأعد التقاط الصورة.")
            }
        } else if !isDemoPhoto {
            flag(.rejected,
                 "Location is unavailable. Turn on location so neighbours know where the issue is.",
                 "الموقع غير متاح. فعّل خدمة الموقع ليعرف الجيران مكان المشكلة.")
        }

        let signals = input.vision.plausibility
        if signals.looksLikeScreenOrPrint {
            flag(.needsLivePhoto,
                 "This looks like a photo of a screen or a print. Please take a live photo from the spot.",
                 "تبدو هذه صورة لشاشة أو ورقة مطبوعة. يرجى التقاط صورة مباشرة من الموقع.")
        }
        if signals.looksLikeStockOrWatermarked {
            flag(.needsLivePhoto,
                 "This looks like a stock or watermarked image. Please take your own live photo.",
                 "تبدو هذه صورة جاهزة أو عليها علامة مائية. يرجى التقاط صورتك الخاصة مباشرة.")
        }
        if input.vision.category == .notAnIssue || !signals.showsReportedIssue {
            flag(.needsLivePhoto,
                 "I can't see a neighbourhood issue here. Could you retake it?",
                 "لا أرى مشكلة في الحي هنا. هل يمكنك إعادة التقاط الصورة؟")
        } else if let reported = input.reportedCategory, reported != input.vision.category, input.vision.category != .other {
            // Soft mismatch: keep the report, file it under what the photo shows.
            reasonsEN.append("Filed as \(input.vision.category.rawValue.replacingOccurrences(of: "_", with: " ")) based on the photo.")
            reasonsAR.append("تم تصنيف البلاغ حسب ما يظهر في الصورة.")
        }

        if status == .accepted && reasonsEN.isEmpty {
            reasonsEN.append("Live camera, fresh capture time and location all check out.")
            reasonsAR.append("الكاميرا المباشرة ووقت الالتقاط والموقع كلها متطابقة.")
        }
        return PlausibilityResult(status: status, reasonsEN: reasonsEN, reasonsAR: reasonsAR)
    }
}
