import CryptoKit
import Foundation
import Security

/// Conditions under which macOS silently drops or withholds privacy grants: a quarantined or translocated bundle
/// (opened from a disk image, Downloads, or a randomized path), and a changed code-signing identity.
struct InstallationCheck {
    let bundlePath: String
    let isQuarantined: Bool
    let isTranslocated: Bool
    let signingIdentity: String?
    let previousSigningIdentity: String?

    var signingIdentityChanged: Bool {
        guard let signingIdentity, let previousSigningIdentity else { return false }
        return signingIdentity != previousSigningIdentity
    }

    /// Warnings for the user: at most one about the bundle's location (translocation takes precedence over quarantine)
    /// and one about a changed signing identity. Empty when neither applies.
    var warnings: [String] {
        var warnings: [String] = []
        if isTranslocated {
            warnings.append("Local Dictation is running from a temporary location macOS assigned to a downloaded app. Move it to Applications and open it from there.")
        } else if isQuarantined {
            warnings.append("Local Dictation is marked as downloaded from the internet. Move it to Applications and open it once from there.")
        }
        if signingIdentityChanged {
            warnings.append("This build is signed differently from the last one, so macOS may have reset Microphone and Accessibility. Check the permissions below.")
        }
        return warnings
    }

    var doctorChecks: [DoctorReport.Check] {
        [
            DoctorReport.Check(
                name: "Installation", status: isQuarantined || isTranslocated ? .warning : .ok,
                detail: isTranslocated ? "Translocated: \(bundlePath)" : isQuarantined ? "Quarantined: \(bundlePath)" : bundlePath),
            DoctorReport.Check(
                name: "Signing identity", status: signingIdentityChanged ? .warning : signingIdentity == nil ? .warning : .ok,
                detail: signingIdentity.map { "Certificate SHA-1 \($0)" + (signingIdentityChanged ? ", changed since the last launch" : "") }
                    ?? "Ad hoc or unsigned; permissions will not survive rebuilds"),
        ]
    }

    private static var recordURL: URL { ApplicationFiles.supportDirectory.appendingPathComponent("signing-identity.txt") }

    static func current() -> InstallationCheck {
        let bundleURL = Bundle.main.bundleURL
        let identity = signingCertificateDigest(of: bundleURL)
        return InstallationCheck(
            bundlePath: bundleURL.path, isQuarantined: hasQuarantineAttribute(bundleURL),
            isTranslocated: bundleURL.path.contains("/AppTranslocation/"), signingIdentity: identity,
            previousSigningIdentity: try? String(contentsOf: recordURL, encoding: .utf8))
    }

    /// Records this launch's identity, so the next launch can tell whether it changed.
    func recordLaunch() {
        guard let signingIdentity else { return }
        try? FileManager.default.createDirectory(at: ApplicationFiles.supportDirectory, withIntermediateDirectories: true)
        try? signingIdentity.write(to: Self.recordURL, atomically: true, encoding: .utf8)
    }

    private static func hasQuarantineAttribute(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    /// SHA-1 of the leaf signing certificate, the same value `codesign -dvv` and `security find-identity` show.
    private static func signingCertificateDigest(of bundleURL: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
            let dictionary = information as? [String: Any],
            let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
            let leaf = certificates.first
        else { return nil }
        let data = SecCertificateCopyData(leaf) as Data
        return Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}
