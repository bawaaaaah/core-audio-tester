import CoreAudio
import Foundation

/// Registers HAL property listeners for overloads, abnormal IO stops, device loss and sample-rate
/// changes. Listener bodies only bump an atomic counter on the engine — no logging or allocation.
final class OverloadMonitor {
    private struct Registration {
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private let deviceID: AudioObjectID
    private unowned let engine: AudioIOEngine
    private let queue = DispatchQueue(label: "core-audio-tester.overload-monitor")
    private var registrations: [Registration] = []

    init(deviceID: AudioObjectID, engine: AudioIOEngine) {
        self.deviceID = deviceID
        self.engine = engine
    }

    func install() throws {
        try register(kAudioDeviceProcessorOverload) { [weak engine] in engine?.recordOverload() }
        try register(kAudioDevicePropertyIOStoppedAbnormally) { [weak engine] in engine?.recordIOStoppedAbnormally() }
        try register(kAudioDevicePropertyDeviceIsAlive) { [weak engine] in engine?.checkStillAlive() }
        try register(kAudioDevicePropertyNominalSampleRate) { [weak engine] in engine?.recordSampleRateChange() }
    }

    private func register(_ selector: AudioObjectPropertySelector, _ action: @escaping () -> Void) throws {
        var address = AudioObjectProperty.address(selector)
        guard AudioObjectProperty.exists(deviceID, address) else { return }
        let block: AudioObjectPropertyListenerBlock = { _, _ in action() }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block)
        guard status == noErr else {
            uninstall()
            throw CoreAudioError.osStatus(status, "AudioObjectAddPropertyListenerBlock(\(selector))")
        }
        registrations.append(Registration(address: address, block: block))
    }

    func uninstall() {
        for var registration in registrations {
            AudioObjectRemovePropertyListenerBlock(deviceID, &registration.address, queue, registration.block)
        }
        registrations = []
    }
}
