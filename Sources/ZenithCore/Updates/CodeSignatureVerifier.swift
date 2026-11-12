import Foundation
import Security

/// How the running copy of Zenith is signed, as far as updating it is concerned.
public enum RunningAppSigning: Equatable, Sendable {
    /// Signed with a certificate. `requirement` is the designated requirement's text, for the log.
    case stable(requirement: String)
    /// Ad hoc (including the linker's signature on a `swift build` binary): the designated requirement is only the
    /// code's own hash, which no other build can satisfy, so no update can be verified.
    case adHoc
    case unsigned
    /// The signature could not be read.
    case unreadable(String)

    public var isStable: Bool {
        if case .stable = self { return true }
        return false
    }
}

/// The answer to "is this candidate signed by the same signer as me?".
public enum CandidateSignatureCheck: Equatable, Sendable {
    case satisfiesRunningRequirement
    case rejected(String)
}

/// The one place that decides whether downloaded code is trusted. Tests inject the answers.
public protocol CodeSignatureVerifying: Sendable {
    func runningAppSigning() -> RunningAppSigning
    /// Whether the bundle at `candidate` is valid as a whole (every architecture, nested code, strict) and satisfies
    /// the running app's own designated requirement.
    func checkCandidate(at candidate: URL) -> CandidateSignatureCheck
}

/// The real verifier, on the Security framework (no parsing of `codesign` output).
public struct SecurityFrameworkSignatureVerifier: CodeSignatureVerifying {
    /// `SecStaticCodeCheckValidityWithErrors` flags for a candidate: all architectures, nested code (the Now Playing
    /// adapter in Contents/Frameworks), strict validation, and no symbolic link pointing out of the bundle.
    public static let candidateFlags = SecCSFlags(rawValue:
        kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate | kSecCSRestrictSymlinks)

    /// The static code to compare against; nil means "this process" (`SecCodeCopySelf`). Tests and the opt-in E2E
    /// pass a bundle path to stand in for the running app.
    private let referencePath: URL?

    public init(referencePath: URL? = nil) {
        self.referencePath = referencePath
    }

    private struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private func referenceStaticCode() -> Result<SecStaticCode, Failure> {
        var staticCode: SecStaticCode?
        if let referencePath {
            let status = SecStaticCodeCreateWithPath(referencePath as CFURL, SecCSFlags(), &staticCode)
            guard status == errSecSuccess, let staticCode else { return .failure(Failure("SecStaticCodeCreateWithPath: \(status)")) }
            return .success(staticCode)
        }
        var code: SecCode?
        let selfStatus = SecCodeCopySelf(SecCSFlags(), &code)
        guard selfStatus == errSecSuccess, let code else { return .failure(Failure("SecCodeCopySelf: \(selfStatus)")) }
        let staticStatus = SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else { return .failure(Failure("SecCodeCopyStaticCode: \(staticStatus)")) }
        return .success(staticCode)
    }

    public func runningAppSigning() -> RunningAppSigning {
        switch referenceStaticCode() {
        case .failure(let failure):
            return .unreadable(failure.message)
        case .success(let staticCode):
            return Self.classify(staticCode)
        }
    }

    /// Ad hoc when the signature says so, or when it carries no certificate chain; stable only with a certificate and
    /// a designated requirement that names one.
    static func classify(_ staticCode: SecStaticCode) -> RunningAppSigning {
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard status == errSecSuccess, let dictionary = info as? [String: Any] else {
            return .unreadable("SecCodeCopySigningInformation: \(status)")
        }
        guard dictionary[kSecCodeInfoIdentifier as String] != nil else { return .unsigned }
        let flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let certificates = dictionary[kSecCodeInfoCertificates as String] as? [Any] ?? []
        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 || certificates.isEmpty {
            return .adHoc
        }
        guard let text = designatedRequirementText(staticCode) else {
            return .unreadable("SecCodeCopyDesignatedRequirement failed")
        }
        // A certificate-signed app's requirement pins its certificate (`certificate leaf = H"…"`, or an Apple anchor
        // for a Developer ID). Anything else (a bare cdhash, an explicit `always`) cannot stand for "same signer".
        guard text.contains("certificate") || text.contains("anchor apple"), !text.contains("always") else {
            return .unreadable("unexpected designated requirement: \(text)")
        }
        return .stable(requirement: text)
    }

    private static func designatedRequirement(_ staticCode: SecStaticCode) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, SecCSFlags(), &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    private static func designatedRequirementText(_ staticCode: SecStaticCode) -> String? {
        guard let requirement = designatedRequirement(staticCode) else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, SecCSFlags(), &text) == errSecSuccess, let text else { return nil }
        return text as String
    }

    public func checkCandidate(at candidate: URL) -> CandidateSignatureCheck {
        let reference: SecStaticCode
        switch referenceStaticCode() {
        case .failure(let failure): return .rejected(failure.message)
        case .success(let code): reference = code
        }
        // Never compare against a requirement that only an identical build satisfies, or one that is not ours.
        guard case .stable = Self.classify(reference), let requirement = Self.designatedRequirement(reference) else {
            return .rejected("the running app is not signed with a stable identity")
        }
        var candidateCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(candidate as CFURL, SecCSFlags(), &candidateCode)
        guard createStatus == errSecSuccess, let candidateCode else {
            return .rejected("SecStaticCodeCreateWithPath: \(createStatus)")
        }
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(candidateCode, Self.candidateFlags, requirement, &error)
        guard status == errSecSuccess else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "OSStatus \(status)"
            return .rejected(detail)
        }
        return .satisfiesRunningRequirement
    }
}
