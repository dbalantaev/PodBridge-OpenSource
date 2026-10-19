// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation
#if targetEnvironment(macCatalyst)
import Darwin
import IOKit
#endif

extension ClassicDatabase {
    /// Reads and validates the 16-hex-digit FireWire ID from iPod metadata.
    static func firewireID(at root: URL) throws -> Data {
#if targetEnvironment(macCatalyst)
        // The mounted disk's hardware identity is authoritative on macOS. Prefer it
        // over copied/stale SysInfo data and over PodBridge's per-volume cache.
        if let id = MacIPodIdentity.firewireID(for: root) {
            cacheFirewireID(id, root: root)
            AppLogger.database("Read FireWire GUID automatically from the iPod USB device", level: .info)
            return id
        }
#endif
        let device = root.appendingPathComponent("iPod_Control/Device", isDirectory: true)
        var candidates = ["SysInfo", "SysInfoExtended", "ExtendedSysInfoXml.xml"].map {
            device.appendingPathComponent($0)
        }
        if let discovered = try? FileManager.default.contentsOfDirectory(
            at: device,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            let additional = discovered.filter { url in
                guard !candidates.contains(url) else { return false }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true, (values?.fileSize ?? Int.max) <= 1_048_576 else { return false }
                return ["", "xml", "plist", "txt"].contains(url.pathExtension.lowercased())
            }
            candidates.append(contentsOf: additional.prefix(64))
        }

        for url in candidates {
            guard let data = try? Data(contentsOf: url), data.count <= 1_048_576 else { continue }
            if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
               let id = firewireID(inPropertyList: plist) {
                cacheFirewireID(id, root: root)
                AppLogger.database("Found FireWire GUID in \(url.lastPathComponent)", level: .info)
                return id
            }
            if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16),
               let id = firewireID(inText: text) {
                cacheFirewireID(id, root: root)
                AppLogger.database("Found FireWire GUID in \(url.lastPathComponent)", level: .info)
                return id
            }
        }
        let cache = UserDefaults.standard.dictionary(forKey: "PodBridge.cachedFirewireIDs") as? [String: String]
        if let value = cache?[root.lastPathComponent], let id = decodeFirewireID(value) {
            AppLogger.database("Using cached FireWire GUID for destination=\(root.lastPathComponent)", level: .info)
            return id
        }
        throw PodBridgeError.missingFirewireID
    }

    private static func firewireID(inPropertyList value: Any) -> Data? {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                let normalized = key.lowercased().filter(\.isLetter)
                if normalized == "firewireguid" {
                    if let string = child as? String, let id = decodeFirewireID(string) { return id }
                    if let data = child as? Data, data.count == 8 { return data }
                    if let number = child as? NSNumber,
                       let id = decodeFirewireID(String(format: "%016llx", number.uint64Value)) { return id }
                }
                if let id = firewireID(inPropertyList: child) { return id }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let id = firewireID(inPropertyList: child) { return id }
            }
        }
        return nil
    }

    private static func firewireID(inText text: String) -> Data? {
        for line in text.split(whereSeparator: \.isNewline) {
            let lower = line.lowercased()
            guard lower.contains("firewireguid") || lower.contains("firewire guid") else { continue }
            for token in line.split(whereSeparator: { !$0.isHexDigit && $0 != "x" && $0 != "X" }) {
                if let id = decodeFirewireID(String(token)) { return id }
            }
        }

        // Some exported device-info XML omits the key but retains Apple's iPod GUID prefix.
        let compact = text.filter(\.isHexDigit)
        let prefix = "000A2700"
        var searchStart = compact.startIndex
        while let range = compact.range(of: prefix, options: .caseInsensitive, range: searchStart..<compact.endIndex) {
            let end = compact.index(range.lowerBound, offsetBy: 16, limitedBy: compact.endIndex) ?? compact.endIndex
            if compact.distance(from: range.lowerBound, to: end) == 16,
               let id = decodeFirewireID(String(compact[range.lowerBound..<end])) { return id }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func cacheFirewireID(_ id: Data, root: URL) {
        let key = "PodBridge.cachedFirewireIDs"
        var cache = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        cache[root.lastPathComponent] = id.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(cache, forKey: key)
    }

    /// Stores a validated FireWire ID in the destination's SysInfo file.
    static func storeFirewireID(_ value: String, root: URL) throws {
        guard let id = decodeFirewireID(value) else { throw PodBridgeError.invalidFirewireID }
        cacheFirewireID(id, root: root)
        let sysInfo = root.appendingPathComponent("iPod_Control/Device/SysInfo")
        let existing = (try? String(contentsOf: sysInfo, encoding: .utf8)) ?? ""
        let preservedLines = existing.split(whereSeparator: \.isNewline).filter {
            !$0.lowercased().hasPrefix("firewireguid:")
        }.map(String.init)
        let hexID = id.map { String(format: "%02x", $0) }.joined()
        let updated = (preservedLines + ["FirewireGuid: 0x\(hexID)"]).joined(separator: "\n") + "\n"
        do {
            try updated.write(to: sysInfo, atomically: true, encoding: .utf8)
            AppLogger.database("Persisted FireWire GUID in SysInfo", level: .info)
        } catch {
            // The local cache still lets this iPhone write safely when a file
            // provider does not allow updating SysInfo itself.
            AppLogger.database(
                "Could not persist FireWire GUID in SysInfo error=\(error.localizedDescription)",
                level: .error
            )
        }
    }

    /// Removes the signing ID from readable iPod metadata and the local cache.
    /// Every changed file is restored if the final absence check fails.
    static func removeFirewireIDForTesting(at root: URL, expectedID: Data) throws {
        guard expectedID.count == 8 else { throw PodBridgeError.invalidFirewireID }
        let device = root.appendingPathComponent("iPod_Control/Device", isDirectory: true)
        let candidates = firewireMetadataCandidates(in: device)
        let expectedHex = expectedID.map { String(format: "%02x", $0) }.joined()
        var originals: [URL: Data] = [:]
        let cacheKey = "PodBridge.cachedFirewireIDs"
        let originalCache = UserDefaults.standard.dictionary(forKey: cacheKey)

        do {
            for url in candidates {
                let original = try Data(contentsOf: url)
                let updated = try scrubbedFirewireMetadata(
                    original,
                    expectedID: expectedID,
                    expectedHex: expectedHex
                )
                guard let updated else { continue }
                originals[url] = original
                try updated.write(to: url, options: .atomic)
                guard try Data(contentsOf: url) == updated else { throw PodBridgeError.databaseVerificationFailed }
            }

            var cache = originalCache as? [String: String] ?? [:]
            cache.removeValue(forKey: root.lastPathComponent)
            UserDefaults.standard.set(cache, forKey: cacheKey)
            if (try? firewireID(at: root)) != nil { throw PodBridgeError.databaseVerificationFailed }
            AppLogger.database("Removed FireWire GUID from iPod metadata for recovery test", level: .info)
        } catch {
            restoreFirewireMetadata(originals, cache: originalCache, cacheKey: cacheKey)
            throw error
        }
    }

    private static func firewireMetadataCandidates(in device: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: device,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.filter { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            let isKnownFile = ["SysInfo", "SysInfoExtended", "ExtendedSysInfoXml.xml"]
                .contains(url.lastPathComponent)
            let isReadableMetadata = ["", "xml", "plist", "txt"]
                .contains(url.pathExtension.lowercased())
            return values?.isRegularFile == true
                && (values?.fileSize ?? Int.max) <= 1_048_576
                && (isKnownFile || isReadableMetadata)
        }
    }

    private static func scrubbedFirewireMetadata(
        _ original: Data,
        expectedID: Data,
        expectedHex: String
    ) throws -> Data? {
        var format = PropertyListSerialization.PropertyListFormat.xml
        let propertyList = try? PropertyListSerialization.propertyList(
            from: original,
            options: [],
            format: &format
        )
        if let propertyList, firewireID(inPropertyList: propertyList) == expectedID {
            let scrubbed = removingFirewireID(from: propertyList, expectedHex: expectedHex)
            let encoded = try PropertyListSerialization.data(
                fromPropertyList: scrubbed,
                format: format,
                options: 0
            )
            return encoded == original ? nil : encoded
        }

        guard let text = String(data: original, encoding: .utf8),
              firewireID(inText: text) == expectedID else {
            return nil
        }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let lower = String(line).lowercased()
            let compact = lower.filter(\.isHexDigit)
            return !lower.contains("firewireguid")
                && !lower.contains("firewire guid")
                && !compact.contains(expectedHex)
        }
        let scrubbed = kept.joined(separator: "\n")
        return scrubbed == text ? nil : Data(scrubbed.utf8)
    }

    private static func restoreFirewireMetadata(
        _ originals: [URL: Data],
        cache: [String: Any]?,
        cacheKey: String
    ) {
        for (url, data) in originals {
            try? data.write(to: url, options: .atomic)
        }
        if let cache {
            UserDefaults.standard.set(cache, forKey: cacheKey)
        } else {
            UserDefaults.standard.removeObject(forKey: cacheKey)
        }
    }

    private static func removingFirewireID(from value: Any, expectedHex: String) -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, child) in dictionary {
                let normalized = key.lowercased().filter(\.isLetter)
                guard normalized != "firewireguid" else { continue }
                result[key] = removingFirewireID(from: child, expectedHex: expectedHex)
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { removingFirewireID(from: $0, expectedHex: expectedHex) }
        }
        if let string = value as? String,
           string.lowercased().filter(\.isHexDigit).contains(expectedHex) {
            return ""
        }
        return value
    }

    private static func decodeFirewireID(_ value: String) -> Data? {
        let hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
        guard hex.count == 16 else { return nil }
        var result = Data()
        var index = hex.startIndex
        for _ in 0..<8 {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

}

#if targetEnvironment(macCatalyst)
/// Resolves the USB serial belonging to the exact mounted iPod volume selected by the user.
/// Classic/nano/mini devices expose their 16-hex FireWire GUID as this USB serial.
enum MacIPodIdentity {
    static func firewireID(for root: URL) -> Data? {
        guard let bsdName = mountedBSDName(for: root),
              let service = bsdService(named: bsdName) else {
            AppLogger.database("Could not associate the selected iPod volume with an IORegistry disk", level: .error)
            return nil
        }
        defer { IOObjectRelease(service) }

        for key in ["USB Serial Number", "Serial Number", "iSerialNumber"] {
            guard let property = IORegistryEntrySearchCFProperty(
                service,
                kIOServicePlane,
                key as CFString,
                kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            ) else { continue }
            if let id = decode(property) { return id }
        }
        AppLogger.database("The selected iPod disk has no readable 16-digit USB serial in IORegistry", level: .error)
        return nil
    }

    private static func mountedBSDName(for root: URL) -> String? {
        var information = statfs()
        let result = root.path.withCString { statfs($0, &information) }
        guard result == 0 else { return nil }
        let source = withUnsafePointer(to: &information.f_mntfromname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) {
                String(cString: $0)
            }
        }
        guard source.hasPrefix("/dev/") else { return nil }
        return String(source.dropFirst(5))
    }

    private static func bsdService(named name: String) -> io_registry_entry_t? {
        let service = name.withCString { pointer in
            IOServiceGetMatchingService(
                kIOMainPortDefault,
                IOBSDNameMatching(kIOMainPortDefault, 0, pointer)
            )
        }
        return service == IO_OBJECT_NULL ? nil : service
    }

    private static func decode(_ property: CFTypeRef) -> Data? {
        let value: String
        if CFGetTypeID(property) == CFStringGetTypeID() {
            guard let string = property as? String else { return nil }
            value = string
        } else if CFGetTypeID(property) == CFDataGetTypeID() {
            guard let data = property as? Data,
                  let string = String(data: data, encoding: .utf8) else { return nil }
            value = string
        } else {
            return nil
        }
        let hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
        guard hex.count == 16 else { return nil }
        var output = Data(capacity: 8)
        var index = hex.startIndex
        for _ in 0..<8 {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            output.append(byte)
            index = next
        }
        return output
    }
}
#endif
