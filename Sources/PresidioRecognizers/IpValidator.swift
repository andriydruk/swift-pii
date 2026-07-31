/// IP address validation matching Python's `ipaddress.ip_interface`.
///
/// `IpRecognizer.invalidate_result` simply calls `ipaddress.ip_interface` and
/// treats a `ValueError` as invalid, so the recognizer's real acceptance rule is
/// CPython's parser — not the regex, which is deliberately loose.
///
/// The gap matters: the IPv4 pattern `[01]?[0-9][0-9]?` happily matches `010`,
/// but `ipaddress` rejects leading zeros (CPython 3.9.5+, after the octal
/// ambiguity CVE). Without that check the recognizer emits addresses upstream
/// discards.
public enum IpValidator {

    /// True when the text parses as an IPv4/IPv6 address or interface.
    public static func isValidInterface(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        let address = String(parts[0])

        // A scope-zone suffix (`fe80::1%eth0`) is accepted on IPv6 and rejected
        // on IPv4, and the zone must be non-empty. Verified against CPython
        // 3.10: `fe80::1%eth0` parses, `192.168.1.1%eth0` and `fe80::1%` do not.
        var host = address
        var hasZone = false
        if let percent = address.firstIndex(of: "%") {
            host = String(address[address.startIndex..<percent])
            let zone = address[address.index(after: percent)...]
            guard !zone.isEmpty else { return false }
            hasZone = true
        }

        let isV4 = !hasZone && parseIPv4(host) != nil
        let isV6 = isV4 ? false : isValidIPv6(host)
        guard isV4 || isV6 else { return false }

        if parts.count == 2 {
            let prefixText = String(parts[1])
            guard !prefixText.isEmpty else { return false }
            // ip_interface also accepts a dotted netmask for IPv4, but the
            // recognizer's patterns only ever produce a numeric prefix.
            guard prefixText.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let prefix = Int(prefixText)
            else { return false }
            return prefix >= 0 && prefix <= (isV4 ? 32 : 128)
        }
        return true
    }

    /// Four dotted decimal octets, 0-255, no leading zeros.
    static func parseIPv4(_ text: String) -> [UInt8]? {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var out: [UInt8] = []
        for octet in octets {
            guard !octet.isEmpty, octet.count <= 3,
                  octet.allSatisfy({ $0.isASCII && $0.isNumber })
            else { return nil }
            // "01" and "010" are rejected; "0" alone is fine.
            if octet.count > 1 && octet.first == "0" { return nil }
            guard let value = Int(octet), value <= 255 else { return nil }
            out.append(UInt8(value))
        }
        return out
    }

    /// RFC 4291 textual IPv6, including `::` compression and a trailing
    /// embedded IPv4 form.
    static func isValidIPv6(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 45 else { return false }

        // Split on the (at most one) "::" compression marker.
        let compressedParts = text.components(separatedBy: "::")
        guard compressedParts.count <= 2 else { return false }
        let compressed = compressedParts.count == 2

        func groups(_ segment: String) -> [String]? {
            if segment.isEmpty { return [] }
            let pieces = segment.split(separator: ":", omittingEmptySubsequences: false)
            return pieces.contains(where: \.isEmpty) ? nil : pieces.map(String.init)
        }

        guard var head = groups(compressedParts[0]) else { return false }
        var tail = compressed ? groups(compressedParts[1]) : []
        guard var tailGroups = tail else { return false }

        // A trailing embedded IPv4 consumes two 16-bit groups.
        var embeddedIPv4 = 0
        if let last = (tailGroups.last ?? head.last), last.contains(".") {
            guard parseIPv4(last) != nil else { return false }
            embeddedIPv4 = 2
            if !tailGroups.isEmpty { tailGroups.removeLast() } else { head.removeLast() }
        }

        for group in head + tailGroups {
            guard !group.isEmpty, group.count <= 4,
                  group.allSatisfy({ $0.isHexDigit && $0.isASCII })
            else { return false }
        }

        let total = head.count + tailGroups.count + embeddedIPv4
        tail = tailGroups
        return compressed ? total < 8 : total == 8
    }

    public static func invalidate(_ text: String) -> Bool {
        !isValidInterface(text)
    }
}
