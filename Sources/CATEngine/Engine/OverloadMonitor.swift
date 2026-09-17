import CoreAudio

/// Registers HAL property listeners for xrun/overload/device-alive notifications.
/// The header for kAudioDeviceProcessorOverload explicitly warns it's "usually sent from
/// the AudioDevice's IO thread" — listener bodies here do the absolute minimum (an atomic
/// increment via a method call on the engine), no logging or allocation.
final class OverloadMonitor {
    private let deviceID: AudioObjectID
    private unowned let engine: AudioIOEngine
    private let queue = DispatchQueue(label: "core-audio-tester.overload-monitor")

    private var overloadAddr = AudioObjectProperty.address(kAudioDeviceProcessorOverload)
    private var stoppedAddr = AudioObjectProperty.address(kAudioDevicePropertyIOStoppedAbnormally)
    private var aliveAddr = AudioObjectProperty.address(kAudioDevicePropertyDeviceIsAlive)

    private var overloadBlock: AudioObjectPropertyListenerBlock?
    private var stoppedBlock: AudioObjectPropertyListenerBlock?
    private var aliveBlock: AudioObjectPropertyListenerBlock?

    init(deviceID: AudioObjectID, engine: AudioIOEngine) {
        self.deviceID = deviceID
        self.engine = engine
    }

    func install() throws {
        if AudioObjectProperty.exists(deviceID, overloadAddr) {
            let block: AudioObjectPropertyListenerBlock = { [weak engine] _, _ in engine?.recordOverload() }
            try caCheck(AudioObjectAddPropertyListenerBlock(deviceID, &overloadAddr, queue, block), "AddPropertyListenerBlock(overload)")
            overloadBlock = block
        }
        if AudioObjectProperty.exists(deviceID, stoppedAddr) {
            let block: AudioObjectPropertyListenerBlock = { [weak engine] _, _ in engine?.recordIOStoppedAbnormally() }
            try caCheck(AudioObjectAddPropertyListenerBlock(deviceID, &stoppedAddr, queue, block), "AddPropertyListenerBlock(ioStoppedAbnormally)")
            stoppedBlock = block
        }
        if AudioObjectProperty.exists(deviceID, aliveAddr) {
            let block: AudioObjectPropertyListenerBlock = { [weak engine] _, _ in engine?.checkStillAlive() }
            try caCheck(AudioObjectAddPropertyListenerBlock(deviceID, &aliveAddr, queue, block), "AddPropertyListenerBlock(deviceIsAlive)")
            aliveBlock = block
        }
    }

    func uninstall() {
        if let overloadBlock {
            AudioObjectRemovePropertyListenerBlock(deviceID, &overloadAddr, queue, overloadBlock)
        }
        if let stoppedBlock {
            AudioObjectRemovePropertyListenerBlock(deviceID, &stoppedAddr, queue, stoppedBlock)
        }
        if let aliveBlock {
            AudioObjectRemovePropertyListenerBlock(deviceID, &aliveAddr, queue, aliveBlock)
        }
        overloadBlock = nil
        stoppedBlock = nil
        aliveBlock = nil
    }
}
