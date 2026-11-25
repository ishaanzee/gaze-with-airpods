// A button that arrives over HID: the receiver of a wireless mic (DJI Mic Mini) reports each press of the
// transmitter's linking button as a Volume Up click, key down and key up a millisecond apart. Nothing here
// reads audio.
//
// The device is seized, so the press is ours alone and macOS no longer turns the volume up on every one.
// Each click carries the time the report reached the Mac, not the time this process got round to it, so a
// busy moment never stretches the gap between two clicks.

import Foundation
import IOKit.hid

final class HIDButton {
    var onClick: (_ time: Double) -> Void = { _ in }
    var onAttach: (_ name: String) -> Void = { _ in }
    var onDetach: (_ name: String) -> Void = { _ in }
    var onOther: (_ what: String) -> Void = { _ in }  // a report that is not the click, for the log
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private(set) var attached = 0

    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    /// Seconds on the clock the reports are stamped with.
    static func now() -> Double { Double(mach_absolute_time()) * timebase }

    /// Whether macOS lets this app read the device at all (Input Monitoring). Asking shows the prompt once.
    static func allowed(asking: Bool) -> Bool {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted { return true }
        return asking && IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Starts watching on the main run loop, in every mode, so an open menu never holds a click back.
    /// Returns the error when a receiver that is plugged in could not be seized.
    func open() -> IOReturn {
        // --raw: every HID interface the receiver has, unseized, and every report on it logged, so a press
        // that never comes out as Volume Up (a fast repeat the transmitter turns into something else) shows.
        let match: [String: Any] = rawHID ? [kIOHIDVendorIDKey: buttonVendor] : [
            kIOHIDVendorIDKey: buttonVendor, kIOHIDDeviceUsagePageKey: kHIDPage_Consumer, kIOHIDDeviceUsageKey: kHIDUsage_Csmr_ConsumerControl,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let this = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            let button = Unmanaged<HIDButton>.fromOpaque(context!).takeUnretainedValue()
            button.attached += 1
            button.onAttach(HIDButton.name(device))
        }, this)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            let button = Unmanaged<HIDButton>.fromOpaque(context!).takeUnretainedValue()
            button.attached -= 1
            button.onDetach(HIDButton.name(device))
        }, this)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            let button = Unmanaged<HIDButton>.fromOpaque(context!).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            let page = Int(IOHIDElementGetUsagePage(element)), usage = Int(IOHIDElementGetUsage(element))
            if rawHID {
                log(String(format: "raw: page 0x%x usage 0x%x value %ld at %.3f", page, usage, IOHIDValueGetIntegerValue(value),
                           Double(IOHIDValueGetTimeStamp(value)) * HIDButton.timebase))
            }
            guard page == kHIDPage_Consumer || page == kHIDPage_Telephony else { return }  // the vendor pages are the receiver's own chatter
            let down = IOHIDValueGetIntegerValue(value) != 0
            if page == kHIDPage_Consumer, usage == kHIDUsage_Csmr_VolumeIncrement {
                if down { button.onClick(Double(IOHIDValueGetTimeStamp(value)) * HIDButton.timebase) }
            } else if down {
                button.onOther(String(format: "usage 0x%x on page 0x%x", usage, page))
            }
        }, this)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        return IOHIDManagerOpen(manager, IOOptionBits(rawHID ? kIOHIDOptionsTypeNone : kIOHIDOptionsTypeSeizeDevice))
    }

    private static func name(_ device: IOHIDDevice) -> String {
        IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "button"
    }
}
