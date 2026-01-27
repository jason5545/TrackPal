import Foundation
import IOKit
import IOKit.hid

/// Manages input devices (trackpad, mouse, etc.)
@MainActor
final class DeviceManager {

    static let shared = DeviceManager()

    // MARK: - Device Types

    enum DeviceType: Sendable {
        case trackpad
        case magicMouse
        case regularMouse
        case unknown
    }

    struct InputDevice: Sendable {
        let id: Int
        let name: String
        let type: DeviceType
        let vendorID: Int
        let productID: Int
    }

    // MARK: - Properties

    private(set) var connectedDevices: [InputDevice] = []
    private var hidManager: IOHIDManager?

    var onDeviceConnected: (@MainActor (InputDevice) -> Void)?
    var onDeviceDisconnected: (@MainActor (InputDevice) -> Void)?

    // MARK: - Init

    private init() {}

    // MARK: - Public Methods

    func startMonitoring() {
        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let manager = hidManager else {
            print("TrackPal: Failed to create HID manager")
            return
        }

        let matchingDict: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer]
        ]

        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingDict as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context = context else { return }
            let manager = Unmanaged<DeviceManager>.fromOpaque(context).takeUnretainedValue()
            let inputDevice = manager.createInputDevice(from: device)

            Task { @MainActor in
                manager.deviceConnected(inputDevice)
            }
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context = context else { return }
            let manager = Unmanaged<DeviceManager>.fromOpaque(context).takeUnretainedValue()
            let inputDevice = manager.createInputDevice(from: device)

            Task { @MainActor in
                manager.deviceDisconnected(inputDevice)
            }
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        print("TrackPal: Device monitoring started")
    }

    func stopMonitoring() {
        guard let manager = hidManager else { return }

        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = nil

        print("TrackPal: Device monitoring stopped")
    }

    // MARK: - Private Methods

    private func deviceConnected(_ device: InputDevice) {
        connectedDevices.append(device)
        onDeviceConnected?(device)
        print("TrackPal: Device connected - \(device.name) (\(device.type))")
    }

    private func deviceDisconnected(_ device: InputDevice) {
        connectedDevices.removeAll { $0.id == device.id }
        onDeviceDisconnected?(device)
        print("TrackPal: Device disconnected - \(device.name)")
    }

    nonisolated private func createInputDevice(from device: IOHIDDevice) -> InputDevice {
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
        let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let locationID = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int ?? 0

        let type = determineDeviceType(name: name, vendorID: vendorID, productID: productID)

        return InputDevice(
            id: locationID,
            name: name,
            type: type,
            vendorID: vendorID,
            productID: productID
        )
    }

    nonisolated private func determineDeviceType(name: String, vendorID: Int, productID: Int) -> DeviceType {
        let lowercaseName = name.lowercased()

        // Apple vendor ID
        if vendorID == 0x05AC {
            if lowercaseName.contains("trackpad") {
                return .trackpad
            } else if lowercaseName.contains("magic mouse") {
                return .magicMouse
            }
        }

        if lowercaseName.contains("trackpad") {
            return .trackpad
        } else if lowercaseName.contains("mouse") {
            return .regularMouse
        }

        return .unknown
    }
}
