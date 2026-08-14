//
//  USBProbe.swift
//  HPRT Utility
//
//  Talks to IOKit directly rather than parsing system_profiler: on macOS 26 the
//  SPUSBDataType text output no longer lists this printer reliably, and IOKit
//  also gives us live attach / detach notifications.
//

import Foundation
import IOKit
import IOKit.usb

final class USBProbe: ObservableObject {

    @Published private(set) var devices: [USBDeviceInfo] = []
    @Published private(set) var allDevices: [USBDeviceInfo] = []
    var onChange: (() -> Void)?

    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    init() {
        refresh()
        startWatching()
    }

    deinit {
        if addedIterator != 0 { IOObjectRelease(addedIterator) }
        if removedIterator != 0 { IOObjectRelease(removedIterator) }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
    }

    // MARK: Enumeration

    func refresh() {
        let classesByLocation = interfaceClassesByLocation()
        var found: [USBDeviceInfo] = []

        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            let vendorName = string(service, "USB Vendor Name") ?? ""
            let productName = string(service, "USB Product Name") ?? ""
            let location = int(service, "locationID") ?? 0
            let locationHex = String(format: "0x%08X", location)

            found.append(USBDeviceInfo(
                vendorName: vendorName.isEmpty ? "Unknown vendor" : vendorName,
                productName: productName.isEmpty ? "Unknown product" : productName,
                serial: string(service, "USB Serial Number"),
                vendorID: int(service, "idVendor") ?? 0,
                productID: int(service, "idProduct") ?? 0,
                locationID: locationHex,
                speed: speedLabel(int(service, "Device Speed")),
                interfaceClasses: classesByLocation[locationHex] ?? []
            ))

            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        let sorted = found.sorted { $0.productName < $1.productName }
        let hprt = sorted.filter { $0.looksLikeHPRT }

        if Thread.isMainThread {
            allDevices = sorted
            devices = hprt
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.allDevices = sorted
                self?.devices = hprt
            }
        }
    }

    /// Interface classes live on IOUSBHostInterface nodes, one level below the
    /// device. Class 7 is the USB printer class — its presence is what tells us
    /// macOS can speak to the device without a vendor driver.
    private func interfaceClassesByLocation() -> [String: [Int]] {
        var map: [String: [Int]] = [:]
        guard let matching = IOServiceMatching("IOUSBHostInterface") else { return map }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return map }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let interfaceClass = int(service, "bInterfaceClass") {
                var location = int(service, "locationID")
                if location == nil {
                    var parent: io_object_t = 0
                    if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
                        location = int(parent, "locationID")
                        IOObjectRelease(parent)
                    }
                }
                if let location {
                    map[String(format: "0x%08X", location), default: []].append(interfaceClass)
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return map
    }

    // MARK: Live notifications

    private func startWatching() {
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notifyPort else { return }
        IONotificationPortSetDispatchQueue(notifyPort, DispatchQueue.main)

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            // The iterator must be drained or no further notifications arrive.
            var object = IOIteratorNext(iterator)
            while object != 0 {
                IOObjectRelease(object)
                object = IOIteratorNext(iterator)
            }
            guard let refcon else { return }
            let probe = Unmanaged<USBProbe>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async {
                probe.refresh()
                probe.onChange?()
            }
        }

        func subscribe(_ type: String, into iterator: inout io_iterator_t) {
            guard let matching = IOServiceMatching("IOUSBHostDevice") else { return }
            let result = IOServiceAddMatchingNotification(notifyPort, type, matching,
                                                          callback, context, &iterator)
            guard result == KERN_SUCCESS else { return }
            var object = IOIteratorNext(iterator)     // arm the notification
            while object != 0 {
                IOObjectRelease(object)
                object = IOIteratorNext(iterator)
            }
        }

        subscribe(kIOMatchedNotification, into: &addedIterator)
        subscribe(kIOTerminatedNotification, into: &removedIterator)
    }

    // MARK: Property helpers

    private func property(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private func string(_ service: io_object_t, _ key: String) -> String? {
        property(service, key) as? String
    }

    private func int(_ service: io_object_t, _ key: String) -> Int? {
        (property(service, key) as? NSNumber)?.intValue
    }

    private func speedLabel(_ raw: Int?) -> String {
        switch raw {
        case 0: return "Low (1.5 Mb/s)"
        case 1: return "Full (12 Mb/s)"
        case 2: return "High (480 Mb/s)"
        case 3: return "Super (5 Gb/s)"
        case 4: return "Super+ (10 Gb/s)"
        default: return "Unknown"
        }
    }

    // MARK: Checks

    static func checks(devices: [USBDeviceInfo], cupsDevices: [String]) -> [Check] {
        var out: [Check] = []

        if let device = devices.first {
            // The MT800 enumerates without vendor/product strings, so fall back
            // to the authoritative model CUPS reads from the 1284 device ID.
            let cupsModel = cupsDevices.first?.firstMatch("usb://[^/]+/([^?]+)")
            let name = device.displayName.hasPrefix("HPRT printer")
                ? (cupsModel.map { "HPRT \($0)" } ?? device.displayName)
                : device.displayName
            out.append(.ok("Printer on USB", name))
            out.append(.info("Vendor / Product ID", device.idPair))
            out.append(.info("Location ID", device.locationID))
            out.append(.info("Link speed", device.speed))
            if let serial = device.serial {
                out.append(.info("Serial", serial))
            }
            if device.isPrinterClass {
                out.append(.ok("USB interface class", "7 (Printer)", "macOS can talk to it natively."))
            } else if device.interfaceClasses.isEmpty {
                out.append(.info("USB interface class", "Not reported"))
            } else {
                out.append(.warn("USB interface class",
                                 device.interfaceClasses.map(String.init).joined(separator: ", "),
                                 "Class 7 (Printer) was expected. Direct libusb access would be required."))
            }
        } else {
            out.append(.fail("Printer on USB", "Not detected",
                             "Check that the cable carries data rather than power only, that the printer is powered on, and that it is not asleep."))
        }

        if let discovered = cupsDevices.first {
            let uri = discovered.split(separator: " ").last.map(String.init) ?? discovered
            out.append(.ok("Enumerated by CUPS", uri))
            if let model = uri.firstMatch("usb://[^/]+/([^?]+)") {
                out.append(.info("Model reported by firmware", model,
                                 "This is the authoritative model name — it can differ from the one printed on the box."))
            }
        } else if !devices.isEmpty {
            out.append(.warn("Enumerated by CUPS", "No",
                             "The device is on the bus but CUPS does not list it. Try again with administrator rights."))
        }
        return out
    }
}
