// Whether the dictation app has the mic open right now, asked of CoreAudio (`micbtn --button`).
//
// The button toggles hands-free dictation, and a toggle that only remembers its own clicks is wrong the
// moment dictation ends some other way: Escape, the app's own stop, a click in its window. CoreAudio
// knows which processes are reading an input, so the button asks instead of remembering. Granola opens
// the mic ~250 ms after dictation starts (up to ~700 ms measured) and closes it ~100 ms after it ends.
//
// It reads nothing from the mic and needs no permission: this is the same fact the orange dot shows.

import CoreAudio
import Foundation

enum DictationMic {
    /// True while a process of the dictation app (its bundle id starts with `dictationApp`) reads an input.
    /// A click reads this and asks CoreAudio nothing: asking every audio process costs ~30 ms, and ~130 ms when
    /// CoreAudio has sat idle, all of it before a click can press a key (measured). It is kept current instead,
    /// on the main queue, from what CoreAudio does announce: the process list changing, and a device starting or
    /// stopping for anyone. A process's own IsRunningInput announces nothing (measured: never heard while the
    /// app had the mic open), so each announcement asks the app's few processes directly, ~2 ms.
    static var open: Bool { isOpen }
    private static var isOpen = false
    private static var known: [AudioObjectID] = [], app: [AudioObjectID] = [], heardDevices = Set<AudioObjectID>()

    /// Starts listening. False when CoreAudio refuses: the answer would never change, so the caller says so.
    static func start() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var processList = address(kAudioHardwarePropertyProcessObjectList), deviceList = address(kAudioHardwarePropertyDevices)
        guard AudioObjectAddPropertyListenerBlock(system, &processList, .main, { _, _ in refresh() }) == noErr,
              AudioObjectAddPropertyListenerBlock(system, &deviceList, .main, { _, _ in listenToDevices() }) == noErr else { return false }
        listenToDevices()
        refresh()
        return true
    }

    private static func listenToDevices() {
        for device in objects(kAudioHardwarePropertyDevices) where !heardDevices.contains(device) {
            var at = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            if AudioObjectAddPropertyListenerBlock(device, &at, .main, { _, _ in update() }) == noErr { heardDevices.insert(device) }
        }
        update()
    }

    private static func refresh() {
        let now = processes()
        if now != known {
            known = now
            app = now.filter { bundle($0).hasPrefix(dictationApp) }
        }
        update()
    }

    private static func update() { isOpen = asked() }

    /// The answer asked of CoreAudio now: the app's processes only.
    static func asked() -> Bool { app.contains { running($0) } }

    /// Bundle ids of everything reading an input right now. Asks every audio process (30 to 130 ms): never
    /// on the path of a click.
    static func everyone() -> [String] {
        processes().filter { running($0) }.map { bundle($0) }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func processes() -> [AudioObjectID] { objects(kAudioHardwarePropertyProcessObjectList) }

    private static func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var at = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &at, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &at, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func running(_ process: AudioObjectID) -> Bool {
        var at = address(kAudioProcessPropertyIsRunningInput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &at, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func bundle(_ process: AudioObjectID) -> String {
        var at = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &at, 0, nil, &size, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }
}
