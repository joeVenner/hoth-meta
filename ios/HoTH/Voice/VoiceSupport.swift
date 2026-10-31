import AVFoundation
import Foundation

/// Microphone permission (iOS 17 `AVAudioApplication` API).
enum VoiceMicPermission {
    enum Status: Equatable { case granted, denied, undetermined }

    static var status: Status {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    /// Asks only when undetermined; returns whether the mic can be used.
    static func request() async -> Bool {
        switch status {
        case .granted: return true
        case .denied: return false
        case .undetermined: return await AVAudioApplication.requestRecordPermission()
        }
    }
}
