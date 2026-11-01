import AudioToolbox
import CoreAudio
import Observation

/// Громкость Мака — того устройства, куда сейчас идёт звук (динамики, AirPods, колонка).
/// Слушает изменения от системы (клавиши громкости, другие приложения) без опроса.
@MainActor
@Observable
final class SystemVolume {
    /// 0…1.
    private(set) var level: Float = 0.5
    private(set) var isMuted = false
    /// У устройства есть регулировка громкости (у некоторых HDMI и цифровых выходов её нет).
    private(set) var isAvailable = false

    @ObservationIgnored private var device = AudioDeviceID(0)
    @ObservationIgnored private var deviceListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var valueListener: AudioObjectPropertyListenerBlock?

    private static var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    init() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.attachToDefaultDevice() }
            }
        }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, DispatchQueue.main, block)
        attachToDefaultDevice()
    }

    /// Выставить громкость. Если звук был выключен, а громкость прибавили — включаем.
    func set(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        level = clamped
        guard isAvailable else { return }
        var volume = Float32(clamped)
        AudioObjectSetPropertyData(device, &Self.volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
        if isMuted, clamped > 0 { setMuted(false) }
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    private func setMuted(_ muted: Bool) {
        var address = Self.muteAddress
        guard AudioObjectHasProperty(device, &address) else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        isMuted = muted
    }

    // MARK: - Устройство

    private func attachToDefaultDevice() {
        let newDevice = Self.defaultOutputDevice()
        if newDevice != device {
            if let valueListener, device != 0 {
                AudioObjectRemovePropertyListenerBlock(device, &Self.volumeAddress, DispatchQueue.main, valueListener)
                AudioObjectRemovePropertyListenerBlock(device, &Self.muteAddress, DispatchQueue.main, valueListener)
            }
            device = newDevice
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.read() }
                }
            }
            valueListener = block
            if device != 0 {
                AudioObjectAddPropertyListenerBlock(device, &Self.volumeAddress, DispatchQueue.main, block)
                AudioObjectAddPropertyListenerBlock(device, &Self.muteAddress, DispatchQueue.main, block)
            }
        }
        read()
    }

    private func read() {
        var volumeAddress = Self.volumeAddress
        let available = device != 0 && AudioObjectHasProperty(device, &volumeAddress)
        if available != isAvailable { isAvailable = available }
        if available {
            var volume = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &volume) == noErr, abs(volume - level) > 0.001 {
                level = volume
            }
        }
        var muteAddress = Self.muteAddress
        if device != 0, AudioObjectHasProperty(device, &muteAddress) {
            var muted = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &muted) == noErr, (muted != 0) != isMuted {
                isMuted = muted != 0
            }
        }
    }

    private static func defaultOutputDevice() -> AudioDeviceID {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, 0, nil, &size, &device)
        return status == noErr ? device : 0
    }
}
