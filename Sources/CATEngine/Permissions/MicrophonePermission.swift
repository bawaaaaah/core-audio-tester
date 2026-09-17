import AVFAudio

public enum MicrophonePermissionResult {
    case granted
    case denied
}

public enum MicrophonePermission {
    /// Only call when the plan actually selects input channels — a pure output-only run
    /// should never trigger the microphone privacy prompt.
    public static func ensureAccess() async -> MicrophonePermissionResult {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            return granted ? .granted : .denied
        @unknown default:
            return .denied
        }
    }
}
