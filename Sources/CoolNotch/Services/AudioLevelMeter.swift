import Accelerate
import AppKit
import AudioToolbox
import CoreAudio
import Foundation

/// Громкость пяти полос (басы → верха) того, что сейчас играет на Маке, — для эквалайзера.
///
/// macOS 14.2+: системный «отвод» звука (Core Audio process tap). Звук не записывается и никуда
/// не уходит: в памяти считаются только громкости полос, ~30 раз в секунду, и только пока
/// эквалайзер виден и музыка играет. Без разрешения, на старой macOS или в тишине `isLive == false` —
/// тогда эквалайзер показывает спокойную анимацию.
@MainActor
final class AudioLevelMeter {
    static let shared = AudioLevelMeter()
    static let bandCount = 5

    private(set) var levels = [Float](repeating: 0, count: bandCount)
    private(set) var isLive = false

    private var subscribers: [ObjectIdentifier: ([Float], Bool) -> Void] = [:]
    private var engine: AnyObject?
    private var stopTask: Task<Void, Never>?
    /// Отвод не дал ни звука (скорее всего, нет разрешения) — не пробуем снова какое-то время.
    private var cooldownUntil = Date.distantPast
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultsObserver: NSObjectProtocol?
    private var lastEnabled = Pref.bool(Pref.liveEqualizer)

    /// Отвод звука сейчас работает. Если приложение завершилось аварийно, пока он работал,
    /// при следующем запуске «настоящий звук» выключается сам — чтобы не вылетать снова и снова.
    private static let runningKey = "audioTapRunning"
    static let disabledAfterCrashKey = "liveEqualizerDisabledAfterCrash"

    /// При запуске: прошлый раз закончился сбоем во время отвода — выключаем «настоящий звук».
    static func recoverAfterCrash() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: runningKey) else { return }
        defaults.set(false, forKey: runningKey)
        defaults.set(false, forKey: Pref.liveEqualizer)
        defaults.set(true, forKey: disabledAfterCrashKey)
    }

    /// При обычном выходе отвод не считается сбоем.
    static func markStopped() {
        UserDefaults.standard.set(false, forKey: runningKey)
    }
    private static var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private init() {
        // Сменилось устройство вывода (AirPods, колонка) — перестраиваем отвод под него.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.restartIfRunning() }
            }
        }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, DispatchQueue.main, block)
        // Переключили «Волна / Под настоящий звук» в настройках — применяем сразу.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferenceChanged() }
        }
    }

    private func preferenceChanged() {
        // Реагируем только на сам переключатель: UserDefaults меняются по сотне поводов, и раньше
        // каждый такой повод снова запускал отвод звука (даже после неудачи).
        let enabled = Pref.bool(Pref.liveEqualizer)
        guard enabled != lastEnabled else { return }
        lastEnabled = enabled
        if enabled { UserDefaults.standard.removeObject(forKey: Self.disabledAfterCrashKey) }
        if !enabled, engine != nil {
            stop()
        } else if enabled, engine == nil, !subscribers.isEmpty {
            cooldownUntil = .distantPast
            startIfNeeded()
        }
    }

    func subscribe(_ owner: AnyObject, _ handler: @escaping ([Float], Bool) -> Void) {
        subscribers[ObjectIdentifier(owner)] = handler
        stopTask?.cancel()
        stopTask = nil
        startIfNeeded()
        handler(levels, isLive)
    }

    func unsubscribe(_ owner: AnyObject) {
        guard subscribers.removeValue(forKey: ObjectIdentifier(owner)) != nil, subscribers.isEmpty else { return }
        // Чёлка то свёрнута, то раскрыта — не пересоздаём отвод на каждое переключение.
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.subscribers.isEmpty else { return }
            self.stop()
        }
    }

    private func startIfNeeded() {
        guard engine == nil, Pref.bool(Pref.liveEqualizer), Date() >= cooldownUntil else { return }
        guard #available(macOS 14.2, *) else { return }
        if AudioCapturePermission.status == .denied { return }
        let tap = SystemAudioTap { [weak self] levels, live, silentSinceStart in
            self?.deliver(levels, live: live, silentSinceStart: silentSinceStart)
        }
        UserDefaults.standard.set(true, forKey: Self.runningKey)
        if tap.start() {
            engine = tap
        } else {
            tap.stop()
            Self.markStopped()
            cooldownUntil = Date().addingTimeInterval(60)
        }
    }

    private func stop() {
        if #available(macOS 14.2, *), let tap = engine as? SystemAudioTap { tap.stop() }
        if engine != nil { Self.markStopped() }
        engine = nil
        if isLive {
            isLive = false
            notify()
        }
    }

    private func restartIfRunning() {
        guard engine != nil else { return }
        stop()
        startIfNeeded()
    }

    private func deliver(_ newLevels: [Float], live: Bool, silentSinceStart: TimeInterval?) {
        levels = newLevels
        isLive = live
        notify()
        // Восемь секунд «музыка играет», а в отводе ни звука — значит, нет разрешения. Не держим его зря.
        if let silent = silentSinceStart, silent > 8 {
            stop()
            cooldownUntil = Date().addingTimeInterval(60)
        }
    }

    private func notify() {
        for handler in subscribers.values { handler(levels, isLive) }
    }
}

/// Разрешение «Запись системного звука» (Конфиденциальность → Запись экрана и системного звука).
/// Публичного способа узнать его состояние нет, поэтому — как в примере Apple AudioCap — через TCC.
enum AudioCapturePermission {
    enum Status { case authorized, denied, unknown }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @convention(block) (Bool) -> Void) -> Void
    private static let service = "kTCCServiceAudioCapture" as CFString

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW) else { return nil }
        return dlsym(handle, name)
    }

    static var status: Status {
        guard let pointer = symbol("TCCAccessPreflight") else { return .unknown }
        let preflight = unsafeBitCast(pointer, to: Preflight.self)
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Показывает системный запрос; если не вышло — открывает нужный раздел настроек.
    static func request(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard let pointer = symbol("TCCAccessRequest") else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    openSettings()
                    completion(false)
                }
            }
            return
        }
        let request = unsafeBitCast(pointer, to: Request.self)
        request(service, nil) { granted in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(granted) }
            }
        }
    }

    @MainActor
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Отвод звука

@available(macOS 14.2, *)
private final class SystemAudioTap: @unchecked Sendable {
    /// levels 0…1, есть ли сейчас звук, сколько секунд с запуска не было ни звука (nil — звук уже был).
    private let onLevels: @MainActor ([Float], Bool, TimeInterval?) -> Void
    private let queue = DispatchQueue(label: "halo.audio-levels", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var channels = 2
    private var interleaved = true
    private var analyzer = SpectrumAnalyzer(sampleRate: 48_000)
    private var mono: [Float] = []

    init(onLevels: @escaping @MainActor ([Float], Bool, TimeInterval?) -> Void) {
        self.onLevels = onLevels
    }

    func start() -> Bool {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { return false }
        tapID = tap

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else { return false }
        channels = max(1, Int(format.mChannelsPerFrame))
        interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        analyzer = SpectrumAnalyzer(sampleRate: format.mSampleRate > 0 ? format.mSampleRate : 48_000)

        guard let outputUID = Self.defaultOutputUID() else { return false }
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Halo Levels",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate) == noErr else { return false }
        aggregateID = aggregate

        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { [weak self] _, input, _, _, _ in
            self?.process(input)
        }
        guard status == noErr, let proc else { return false }
        procID = proc
        return AudioDeviceStart(aggregate, proc) == noErr
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// На очереди отвода: смешиваем каналы в моно и отдаём анализатору.
    private func process(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        mono.removeAll(keepingCapacity: true)
        if interleaved, let buffer = buffers.first, let data = buffer.mData {
            let samples = data.assumingMemoryBound(to: Float.self)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += samples[frame * channels + channel] }
                mono.append(sum / Float(channels))
            }
        } else if let first = buffers.first {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            mono = [Float](repeating: 0, count: frames)
            let count = Float(max(1, buffers.count))
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) {
                    mono[frame] += samples[frame] / count
                }
            }
        }
        guard let result = analyzer.push(mono) else { return }
        let onLevels = self.onLevels
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onLevels(result.levels, result.live, result.silentSinceStart) }
        }
    }

    private static func defaultOutputUID() -> String? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &uidSize, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}

// MARK: - Анализ

/// БПФ на 1024 отсчёта (окно Ханна) ~30 раз в секунду → энергия пяти полос → 0…1.
/// Громкость нормируется по недавнему максимуму каждой полосы, поэтому эквалайзер «живой»
/// и на тихой, и на громкой музыке; подъём быстрый, спад плавный.
private final class SpectrumAnalyzer {
    struct Result {
        var levels: [Float]
        var live: Bool
        var silentSinceStart: TimeInterval?
    }

    private static let size = 1024
    private static let log2n = vDSP_Length(10)
    /// Полосы, Гц: басы, низкая середина, середина, верхняя середина, верха.
    private static let edges: [Double] = [40, 150, 400, 1200, 3500, 11_000]

    private let sampleRate: Double
    private let setup: FFTSetup?
    private var window = [Float](repeating: 0, count: size)
    private var ring = [Float](repeating: 0, count: size)
    private var ringIndex = 0
    private var ceilings = [Float](repeating: -30, count: AudioLevelMeter.bandCount)
    private var smoothed = [Float](repeating: 0, count: AudioLevelMeter.bandCount)
    private var lastAnalysis: TimeInterval = 0
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var lastSound: TimeInterval = -.infinity
    private var heardAnything = false

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    func push(_ samples: [Float]) -> Result? {
        for sample in samples {
            ring[ringIndex] = sample
            ringIndex = (ringIndex + 1) % Self.size
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAnalysis >= 1.0 / 30, let setup else { return nil }
        lastAnalysis = now

        // Последние 1024 отсчёта по порядку, с окном.
        var frame = [Float](repeating: 0, count: Self.size)
        for i in 0..<Self.size { frame[i] = ring[(ringIndex + i) % Self.size] }
        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(Self.size))
        if rms > 0.0005 {
            lastSound = now
            heardAnything = true
        }
        vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(Self.size))

        let half = Self.size / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                frame.withUnsafeBufferPointer { framePointer in
                    framePointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        // Чувствительность из настроек (0,5…2): выше — столбики выше и отзывчивее к тихому звуку.
        let stored = UserDefaults.standard.double(forKey: Pref.eqSensitivity)
        let sensitivity = Float(stored > 0 ? min(max(stored, 0.5), 2) : 1)
        let range = min(80, max(18, 42 / sensitivity))
        let gain = 0.75 + 0.25 * sensitivity
        let binWidth = sampleRate / Double(Self.size)
        for band in 0..<AudioLevelMeter.bandCount {
            let low = max(1, Int(Self.edges[band] / binWidth))
            let high = min(half - 1, max(low + 1, Int(Self.edges[band + 1] / binWidth)))
            var sum: Float = 0
            for bin in low..<high { sum += magnitudes[bin] }
            let energy = sum / Float(high - low)
            let db = 10 * log10f(energy + 1e-12)
            // Потолок полосы: сразу поднимается к громкому, медленно (~6 дБ за секунду) опускается.
            ceilings[band] = max(db, ceilings[band] - 0.2)
            let floor = ceilings[band] - range
            let target = max(0, min(1, (db - floor) / range * gain))
            let current = smoothed[band]
            smoothed[band] = target > current ? current + (target - current) * 0.65 : current + (target - current) * 0.22
        }

        let live = heardAnything && now - lastSound < 2.5
        let silentSinceStart: TimeInterval? = heardAnything ? nil : now - startedAt
        return Result(levels: live ? smoothed : [Float](repeating: 0, count: AudioLevelMeter.bandCount),
                      live: live, silentSinceStart: silentSinceStart)
    }
}
