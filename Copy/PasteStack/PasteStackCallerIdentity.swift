import AppKit
import CopyCore
import CryptoKit
import Security

func pasteStackCaller(from event: NSAppleEventDescriptor) -> PasteStackCaller? {
    guard let token = event.attributeDescriptor(forKeyword: AEKeyword(keyActualSenderAuditToken)),
          token.descriptorType == DescType(typeAuditToken),
          token.data.count == MemoryLayout<audit_token_t>.size else { return nil }
    var code: SecCode?
    let attributes = [kSecGuestAttributeAudit: token.data] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
          let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
          let staticCode else { return nil }
    var codeURL: CFURL?
    guard SecCodeCopyPath(staticCode, [], &codeURL) == errSecSuccess,
          let codeURL else { return nil }
    let actualURL = (codeURL as URL).standardizedFileURL.resolvingSymlinksInPath()
    var bundleURL = actualURL
    while bundleURL.pathExtension.lowercased() != "app" && bundleURL.path != "/" {
        bundleURL.deleteLastPathComponent()
    }
    guard bundleURL.pathExtension.lowercased() == "app", let bundle = Bundle(url: bundleURL),
          let bundleID = bundle.bundleIdentifier, !bundleID.isEmpty,
          let executable = bundle.executableURL?.standardizedFileURL.resolvingSymlinksInPath(),
          actualURL == bundleURL || actualURL == executable else { return nil }
    var caller = PasteStackCaller(bundleID: bundleID, canonicalPath: bundleURL.path)
    guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return caller }
    var rawInfo: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInfo) == errSecSuccess,
          let info = rawInfo as? [CFString: Any], let signingID = info[kSecCodeInfoIdentifier] as? String,
          !signingID.isEmpty, let certificates = info[kSecCodeInfoCertificates] as? [SecCertificate],
          let certificate = certificates.first else { return caller }
    let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
        .map { String(format: "%02x", $0) }.joined()
    caller.signingID = signingID
    caller.certificateSHA256 = fingerprint
    return caller
}
