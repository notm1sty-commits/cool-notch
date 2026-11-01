import CoreAudio
import Foundation

struct AudioOutputDevice: Equatable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    var isWireless: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// SF Symbol под тип устройства.
    var symbol: String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        default: return "hifispeaker.fill"
        }
    }
}

/// Следит за сменой устройства вывода звука (подключили AirPods, колонку и т. п.).
/// Работает через CoreAudio — без запросов разрешений и без опроса.
@MainActor
final class AudioOutputMonitor {
    var onChange: (@MainActor (_ device: AudioOutputDevice, _ previous: AudioOutputDevice?) -> Void)?
    private(set) var current: AudioOutputDevice?

    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var listener: AudioObjectPropertyListenerBlock?
    private var pendingCheck: DispatchWorkItem?

    init() {
        current = Self.defaultOutputDevice()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.scheduleCheck() }
            }
        }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    /// Система иногда шлёт несколько событий подряд — ждём, пока всё устаканится.
    private func scheduleCheck() {
        pendingCheck?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        pendingCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private func check() {
        guard let device = Self.defaultOutputDevice(), device.id != current?.id else { return }
        let previous = current
        current = device
        onChange?(device, previous)
    }

    static func defaultOutputDevice() -> AudioOutputDevice? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return nil }

        var nameRef: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let nameStatus = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameRef)
        let name = nameStatus == noErr ? (nameRef?.takeRetainedValue() as String?) ?? "" : ""

        var transport = UInt32(0)
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &transportSize, &transport)

        return AudioOutputDevice(id: deviceID, name: name, transport: transport)
    }
}
