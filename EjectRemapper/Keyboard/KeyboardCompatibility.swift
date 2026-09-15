//
//  KeyboardCompatibility.swift
//  EjectRemapper
//

import Foundation
import IOKit
import IOKit.hid

/// What sits where the Eject key used to be on a given Apple keyboard.
enum EjectKeyVariant: String, Sendable {
    /// A real Eject key — the app can remap it.
    case eject
    /// The padlock key on 2021-and-later Magic Keyboards. Handled inside macOS; never reaches apps.
    case lock
    /// The Touch ID button. Also handled inside macOS.
    case touchID
    /// No key in that position at all (built-in MacBook keyboards).
    case none
    /// An Apple product ID the app does not recognise, or a third-party keyboard.
    case unknown
}

/// One connected keyboard, described well enough to explain itself to the user.
struct HIDKeyboardInfo: Hashable, Sendable {
    /// The name the device reports, e.g. "MagicKeyboard".
    let name: String
    let vendorID: Int
    let productID: Int
    /// "Bluetooth", "USB", "SPI"…
    let transport: String
    /// What the app believes is in the Eject position.
    let variant: EjectKeyVariant
    /// Whether the device's own HID report descriptor declares Consumer page Eject. This is the
    /// authoritative signal; `variant` is only there to phrase a helpful message.
    let declaresEjectUsage: Bool
}

/// The verdict shown to the user.
enum CompatibilityAssessment: Equatable, Sendable {
    /// At least one connected keyboard declares an Eject key.
    case supported(HIDKeyboardInfo)
    /// Keyboards are connected, but none of them has an Eject key.
    case unsupported(reason: String, keyboards: [HIDKeyboardInfo])
    /// No keyboard was found at all.
    case noKeyboardFound
    /// The check has not run, or could not run.
    case unknown
}

/// Works out whether the attached keyboard has a key this app can remap.
///
/// ## Why it is done this way
///
/// The check reads each device's own HID *report descriptor* — the block of bytes in which a device
/// declares what it can report — and looks for Consumer page `0x0C`, usage `0xB8` (Eject). That is
/// the same declaration macOS itself reads, so a keyboard either has the key or it does not; there
/// is no guesswork and third-party keyboards are covered automatically.
///
/// Crucially, this needs **no permission whatsoever**. The devices are enumerated but never opened
/// and never scheduled on a run loop, so no Input Monitoring prompt appears and the app's TCC state
/// is untouched — verified on macOS 26.5 with Input Monitoring denied
/// (`docs/TECHNICAL_INVESTIGATION.md` §11).
///
/// Two tempting alternatives were rejected: `IOHIDDeviceCopyMatchingElements` returns nothing for a
/// keyboard without Input Monitoring, and the device's `Elements` property is truncated for
/// ordinary apps. Product IDs alone would miss third-party keyboards, so they are used only to
/// phrase a specific message about *why* a particular Apple keyboard is unsupported.
enum KeyboardCompatibility {

    /// Apple's vendor IDs: `0x05AC` over USB, `0x004C` over Bluetooth.
    static let appleVendorIDs: Set<Int> = [0x05AC, 0x004C]

    /// HID Consumer usage page.
    static let consumerUsagePage = 0x0C
    /// HID Consumer usage "Eject".
    static let ejectUsage = 0xB8

    /// Apple keyboards whose top-right key is known. Sources are listed in
    /// `docs/TECHNICAL_INVESTIGATION.md` §11.
    static let knownAppleKeyboards: [Int: (model: String, variant: EjectKeyVariant)] = [
        0x0220: ("Apple Keyboard (A1243)", .eject),
        0x0221: ("Apple Keyboard (A1243)", .eject),
        0x0222: ("Apple Keyboard (A1243)", .eject),
        0x022C: ("Apple Wireless Keyboard", .eject),
        0x022D: ("Apple Wireless Keyboard", .eject),
        0x022E: ("Apple Wireless Keyboard", .eject),
        0x0239: ("Apple Wireless Keyboard (2009)", .eject),
        0x023A: ("Apple Wireless Keyboard (2009)", .eject),
        0x023B: ("Apple Wireless Keyboard (2009)", .eject),
        0x0255: ("Apple Wireless Keyboard (2011)", .eject),
        0x0256: ("Apple Wireless Keyboard (2011)", .eject),
        0x0257: ("Apple Wireless Keyboard (2011)", .eject),
        0x0267: ("Magic Keyboard (2015, A1644)", .eject),
        0x026C: ("Magic Keyboard with Numeric Keypad (2017, A1843)", .eject),
        0x029A: ("Magic Keyboard with Touch ID (2021, A2449)", .touchID),
        0x029C: ("Magic Keyboard (2021, A2450)", .lock),
        0x029F: ("Magic Keyboard with Touch ID and Numeric Keypad (2021, A2520)", .touchID),
        0x0320: ("Magic Keyboard (2024, A3203)", .lock),
        0x0321: ("Magic Keyboard with Touch ID (2024, A3118)", .touchID),
        0x0322: ("Magic Keyboard with Touch ID and Numeric Keypad (2024, A3119)", .touchID),
    ]

    // MARK: - Assessment

    /// Runs the check and turns it into a verdict with a sentence the user can act on.
    static func assess(keyboards: [HIDKeyboardInfo]? = nil) -> CompatibilityAssessment {
        let found = keyboards ?? connectedKeyboards()

        if let supported = found.first(where: \.declaresEjectUsage) {
            return .supported(supported)
        }
        guard !found.isEmpty else {
            return .noKeyboardFound
        }
        return .unsupported(reason: reason(for: found), keyboards: found)
    }

    /// The most specific explanation the evidence supports.
    static func reason(for keyboards: [HIDKeyboardInfo]) -> String {
        if keyboards.contains(where: { $0.variant == .lock }) {
            return String(localized: "This Magic Keyboard has a Lock key where the Eject key used to be. macOS handles that key itself and never passes it to apps, so it can't be remapped.")
        }
        if keyboards.contains(where: { $0.variant == .touchID }) {
            return String(localized: "This Magic Keyboard has Touch ID where the Eject key used to be. macOS handles that button itself, so there's nothing to remap.")
        }
        if keyboards.allSatisfy({ $0.variant == .none }) {
            return String(localized: "Built-in Mac keyboards don't have an Eject key.")
        }
        return String(localized: "No connected keyboard has an Eject ⏏ key. This app works with Apple keyboards that have one, such as the Magic Keyboard from 2015 or 2017.")
    }

    // MARK: - Enumeration

    /// Every connected keyboard, described.
    ///
    /// Devices are enumerated and their properties read. **No device is opened and none is
    /// scheduled on a run loop** — doing either would ask the user for Input Monitoring, which this
    /// app does not need and should never request.
    static func connectedKeyboards() -> [HIDKeyboardInfo] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }

        return devices.compactMap(keyboardInfo(for:))
            .sorted { ($0.declaresEjectUsage ? 0 : 1, $0.name) < ($1.declaresEjectUsage ? 0 : 1, $1.name) }
    }

    /// Describes one device, or returns `nil` if it is not a keyboard.
    static func keyboardInfo(for device: IOHIDDevice) -> HIDKeyboardInfo? {
        guard isKeyboard(device) else { return nil }

        let name = string(device, kIOHIDProductKey) ?? String(localized: "Keyboard")
        let vendorID = int(device, kIOHIDVendorIDKey) ?? 0
        let productID = int(device, kIOHIDProductIDKey) ?? 0
        let transport = string(device, kIOHIDTransportKey) ?? ""

        var declaresEject = false
        if let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data {
            declaresEject = descriptorDeclaresEject([UInt8](descriptor))
        }

        let variant: EjectKeyVariant
        if let known = knownAppleKeyboards[productID], appleVendorIDs.contains(vendorID) {
            variant = known.variant
        } else {
            variant = declaresEject ? .eject : .unknown
        }

        return HIDKeyboardInfo(
            name: name,
            vendorID: vendorID,
            productID: productID,
            transport: transport,
            variant: variant,
            declaresEjectUsage: declaresEject
        )
    }

    /// A device counts as a keyboard when it declares Generic Desktop (page 1) usage 6.
    ///
    /// `IOHIDDeviceConformsTo` is deliberately avoided: it returned false for the Magic Keyboard in
    /// a process without Input Monitoring, whereas reading the usage-pair property works.
    static func isKeyboard(_ device: IOHIDDevice) -> Bool {
        if let page = int(device, kIOHIDPrimaryUsagePageKey), let usage = int(device, kIOHIDPrimaryUsageKey),
           page == kHIDPage_GenericDesktop, usage == kHIDUsage_GD_Keyboard {
            return true
        }
        guard let pairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] else {
            return false
        }
        return pairs.contains { pair in
            (pair[kIOHIDDeviceUsagePageKey] as? Int) == kHIDPage_GenericDesktop
                && (pair[kIOHIDDeviceUsageKey] as? Int) == kHIDUsage_GD_Keyboard
        }
    }

    // MARK: - Report descriptor parsing

    /// Walks a HID report descriptor looking for Consumer page usage `0xB8` (Eject).
    ///
    /// Pure and separable from IOKit so it can be unit-tested against the real bytes of a Magic
    /// Keyboard A1644 and against a synthetic descriptor with no Eject usage.
    ///
    /// A descriptor is a flat list of items. Each starts with a prefix byte whose low two bits give
    /// the payload size (with `3` meaning four bytes, not three) and whose upper six bits give the
    /// tag. Only two tags matter here:
    ///
    /// - `0x04` Usage Page (global) — sets the page that later usages belong to.
    /// - `0x08` Usage (local), `0x18` Usage Minimum, `0x28` Usage Maximum — name a usage.
    ///
    /// A usage item may carry the page in its own high bytes when it is four bytes wide, in which
    /// case it overrides the current page for that item alone. Both forms are handled.
    ///
    /// Long items (prefix `0xFE`) are skipped; no Apple keyboard uses them.
    static func descriptorDeclaresEject(_ bytes: [UInt8]) -> Bool {
        var index = 0
        var currentPage = 0
        /// A Usage Minimum on the Consumer page, waiting for its matching Maximum.
        var pendingMinimum: Int?

        while index < bytes.count {
            let prefix = bytes[index]
            index += 1

            // Long item: [0xFE][dataSize][tag][data...]
            if prefix == 0xFE {
                guard index < bytes.count else { return false }
                let dataSize = Int(bytes[index])
                index += 1 + 1 + dataSize
                continue
            }

            let tag = prefix & 0xFC
            let sizeCode = Int(prefix & 0x03)
            let size = sizeCode == 3 ? 4 : sizeCode

            guard index + size <= bytes.count else { return false }

            var value = 0
            for offset in 0..<size {
                value |= Int(bytes[index + offset]) << (8 * offset)
            }
            index += size

            switch tag {
            case 0x04:                                   // Usage Page (global)
                currentPage = value & 0xFFFF

            case 0x08, 0x18, 0x28:                       // Usage, Usage Minimum, Usage Maximum
                // A four-byte usage carries its own page in the high half.
                let page = size == 4 ? (value >> 16) & 0xFFFF : currentPage
                let usage = value & 0xFFFF

                if page == consumerUsagePage {
                    if tag == 0x08, usage == ejectUsage { return true }
                    // A min/max range that spans 0xB8 also declares the key.
                    if tag == 0x18, usage <= ejectUsage { pendingMinimum = usage }
                    if tag == 0x28, let minimum = pendingMinimum, minimum <= ejectUsage, usage >= ejectUsage {
                        return true
                    }
                }

            default:
                break
            }
        }

        return false
    }

    // MARK: - Property helpers

    private static func string(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private static func int(_ device: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }
}
