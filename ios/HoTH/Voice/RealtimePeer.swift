import AVFoundation
import Foundation
import OSLog
import WebRTC

/// Errors from the WebRTC transport. None of them carry the ephemeral secret.
enum RealtimePeerError: Error, Equatable {
    case peerConnectionUnavailable
    case offerFailed(String)
    case localDescriptionFailed(String)
    case remoteDescriptionFailed(String)
    case sdpExchangeFailed(Int)
    case network(String)
    case audioSession(String)
}

/// Thin, non-actor wrapper around `RTCPeerConnection` + the `oai-events` data channel.
///
/// WebRTC calls its delegates on its own signaling thread, so this type is the delegate and
/// forwards everything through `@Sendable` callbacks; `RealtimeSession` hops to the main actor.
final class RealtimePeer: NSObject, @unchecked Sendable {
    static let callsURL = URL(string: "https://api.openai.com/v1/realtime/calls")!

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    private let logger = Logger(subsystem: "io.fomy.hoth", category: "RealtimePeer")
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var micTrack: RTCAudioTrack?

    var onMessage: (@Sendable (String) -> Void)?
    var onChannelOpen: (@Sendable () -> Void)?
    var onDisconnected: (@Sendable (String) -> Void)?

    // MARK: Audio session

    /// `.playAndRecord` + `.voiceChat` (echo cancellation), loudspeaker by default, Bluetooth headsets allowed.
    static func configureAudioSession() throws {
        let configuration = RTCAudioSessionConfiguration.webRTC()
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.mode = AVAudioSession.Mode.voiceChat.rawValue
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker]
        // Bluetooth HFP headsets (`.allowBluetoothHFP` on the iOS 26 SDK, formerly `.allowBluetooth`; same bit).
        // The raw value avoids a deprecation warning while still running on iOS 17.
        options.insert(AVAudioSession.CategoryOptions(rawValue: 0x4))
        configuration.categoryOptions = options
        RTCAudioSessionConfiguration.setWebRTC(configuration)

        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.setConfiguration(configuration, active: true)
            try session.overrideOutputAudioPort(.speaker)
        } catch {
            throw RealtimePeerError.audioSession(error.localizedDescription)
        }
    }

    static func deactivateAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        try? session.setActive(false)
    }

    // MARK: Connect

    /// Builds the peer connection (mic track + data channel), exchanges SDP with OpenAI and applies the answer.
    func connect(ephemeralKey: String, session: URLSession = .shared) async throws {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = Self.factory.peerConnection(
            with: configuration, constraints: constraints, delegate: self) else {
            throw RealtimePeerError.peerConnectionUnavailable
        }
        peerConnection = connection

        // Track and data channel must exist before the offer, or they are missing from the SDP.
        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let source = Self.factory.audioSource(with: audioConstraints)
        let track = Self.factory.audioTrack(with: source, trackId: "hoth-mic")
        connection.add(track, streamIds: ["hoth-stream"])
        micTrack = track

        let channelConfig = RTCDataChannelConfiguration()
        channelConfig.isOrdered = true
        let channel = connection.dataChannel(forLabel: "oai-events", configuration: channelConfig)
        channel?.delegate = self
        dataChannel = channel

        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "false"],
            optionalConstraints: nil)
        let offer = try await makeOffer(connection, constraints: offerConstraints)
        try await setLocal(connection, offer)
        await waitForIceGathering(connection, timeout: 2.0)

        let localSDP = connection.localDescription?.sdp ?? offer.sdp
        let answerSDP = try await exchangeSDP(localSDP, ephemeralKey: ephemeralKey, session: session)
        try await setRemote(connection, RTCSessionDescription(type: .answer, sdp: answerSDP))
    }

    // MARK: Runtime

    var isChannelOpen: Bool { dataChannel?.readyState == .open }

    @discardableResult
    func send(_ data: Data) -> Bool {
        guard let channel = dataChannel, channel.readyState == .open else { return false }
        return channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    func setMicEnabled(_ isEnabled: Bool) {
        micTrack?.isEnabled = isEnabled
    }

    /// Current (assistant output, resident mic) audio levels in 0...1 from WebRTC stats.
    func audioLevels(_ completion: @escaping @Sendable (Float, Float) -> Void) {
        guard let connection = peerConnection else { return completion(0, 0) }
        connection.statistics { report in
            var assistant: Float = 0
            var resident: Float = 0
            for stat in report.statistics.values {
                guard (stat.values["kind"] as? String) == "audio",
                      let level = (stat.values["audioLevel"] as? NSNumber)?.floatValue else { continue }
                switch stat.type {
                case "inbound-rtp": assistant = max(assistant, level)
                case "media-source": resident = max(resident, level)
                default: continue
                }
            }
            completion(assistant, resident)
        }
    }

    func close() {
        dataChannel?.delegate = nil
        dataChannel?.close()
        dataChannel = nil
        micTrack?.isEnabled = false
        micTrack = nil
        peerConnection?.delegate = nil
        peerConnection?.close()
        peerConnection = nil
        onMessage = nil
        onChannelOpen = nil
        onDisconnected = nil
    }

    // MARK: SDP helpers

    private func makeOffer(_ connection: RTCPeerConnection, constraints: RTCMediaConstraints) async throws
        -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            connection.offer(for: constraints) { description, error in
                if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: RealtimePeerError.offerFailed(error?.localizedDescription ?? "no offer"))
                }
            }
        }
    }

    private func setLocal(_ connection: RTCPeerConnection, _ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: RealtimePeerError.localDescriptionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func setRemote(_ connection: RTCPeerConnection, _ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: RealtimePeerError.remoteDescriptionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Lets host/STUN candidates land in the local SDP (no trickle ICE over HTTP). Bounded so we never hang.
    private func waitForIceGathering(_ connection: RTCPeerConnection, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while connection.iceGatheringState != .complete, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// POST offer SDP → answer SDP (plain text). Accepts any 2xx (the endpoint may answer 201).
    private func exchangeSDP(_ offerSDP: String, ephemeralKey: String, session: URLSession) async throws -> String {
        var request = URLRequest(url: Self.callsURL, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(ephemeralKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(offerSDP.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RealtimePeerError.network((error as? URLError)?.code.rawValue.description ?? "request failed")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status), let answer = String(data: data, encoding: .utf8),
              answer.contains("v=0") else {
            logger.error("Realtime SDP exchange failed with HTTP \(status, privacy: .public)")
            throw RealtimePeerError.sdpExchangeFailed(status)
        }
        return answer
    }
}

// MARK: - RTCPeerConnectionDelegate

extension RealtimePeer: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed || newState == .closed {  // .disconnected can recover on its own
            onDisconnected?("ice-\(newState.rawValue)")
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

// MARK: - RTCDataChannelDelegate

extension RealtimePeer: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        switch dataChannel.readyState {
        case .open: onChannelOpen?()
        case .closed: onDisconnected?("data-channel-closed")
        default: break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary, let text = String(data: buffer.data, encoding: .utf8) else { return }
        onMessage?(text)
    }
}
