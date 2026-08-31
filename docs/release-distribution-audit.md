# macOS Release / Distribution Compliance Audit

Audit date: 2026-08-31  
Scope: repository configuration, local signing identities, the installed 2.0.0 app, and the current public GitHub Release asset. No Apple Developer account, secret value, or notarization submission was inspected.

Terms used below: Developer Identifier (Developer ID, 开发者标识；Apple 用于识别独立开发者签名身份), Continuous Integration (CI, 持续集成；自动构建与验证改动), Application Programming Interface (API, 应用程序编程接口；程序之间约定的调用方式), and Secure Hash Algorithm 256-bit (SHA-256, 256 位安全散列算法；用于核对文件是否被改动).

## Executive conclusion

The repository currently publishes an explicitly **unsigned preview**, not a Developer ID-signed and notarized production distribution. The workflow is internally consistent with that label, but it does not satisfy the Apple direct-distribution path for a Gatekeeper-friendly release. No credential or Apple submission status is asserted here.

## Evidence-based status

| Area | Current evidence | Audit status |
|---|---|---|
| Build architecture/version | `scripts/package-release.sh:29-44` builds Release, universal `arm64 x86_64`; `:56-68` checks macOS 13.0 and version | **Completed for preview packaging**; not evidence of signing compliance |
| Code signing | `scripts/package-release.sh:34-36` sets `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`, empty identity; `:55` removes the executable signature | **Missing for production**. Apple requires a valid Developer ID Application signature for distributed app code |
| Hardened Runtime | Release target has `ENABLE_HARDENED_RUNTIME = YES` in `ProxySentry.xcodeproj/project.pbxproj:344-357` | **Configured**, but cannot compensate for an unsigned artifact |
| Secure timestamp / entitlements | No production `codesign --timestamp` or entitlement verification is present in the release path | **Unverified/missing evidence** |
| Notarization | No `xcrun notarytool submit`, status/log check, or notarization result is present | **Missing** |
| Stapling | No `xcrun stapler staple` or `stapler validate` is present | **Missing** |
| Distribution container | `:73-78` creates a ZIP containing the app and a SHA-256 sidecar; Apple says a ZIP cannot be stapled directly, so the app inside must be stapled before recreating the ZIP | **Preview packaging completed; production notarized ZIP not demonstrated** |
| GitHub Release | `.github/workflows/release.yml` reserves `preview-v*` tags for unsigned packages, marks them as prereleases, grants only `contents: write`, and uploads the package plus checksum | **Preview automation present**; ordinary production-looking `v*` tags no longer publish unsigned assets |
| Published v0.1.0 asset | The public `ProxySentry-v0.1.0-macOS-universal-unsigned.zip` was downloaded and inspected: `codesign` reports no signature, Gatekeeper rejects it with `source=no usable signature`, and no stapled ticket validates | **Not production compliant**; this matches its unsigned-preview label |
| Published 2.0.0 preview | The public `preview-v2.0.0` asset was downloaded after publication: its checksum passes, the app reports version 2.0.0 with `x86_64 arm64`, `codesign` reports no signature, and Gatekeeper rejects it with `source=no usable signature` | **Published and verified as an unsigned prerelease**, not a production-compliant build |
| Installed 2.0.0 app | The local `/Applications/ProxySentry.app` has only an ad hoc signature, no Team Identifier, no stapled ticket, and Gatekeeper rejects it | **Local development build only** |
| Credentials | No signing identity is available locally; GitHub reports no Actions secret or variable names for this repository. No signing, App Store Connect key, or keychain profile is present in tracked files | **Needs protected CI credentials**; metadata absence is not proof about Apple account state |

## Apple requirements and minimum production gate

For direct distribution outside the Mac App Store, Apple’s current guidance requires a Developer ID certificate, valid code signatures for distributed executables, Hardened Runtime, and a secure timestamp; the `com.apple.security.get-task-allow` entitlement must not be enabled for distribution. Submit the exact outer distribution container to Apple’s notary service, review the notary log, staple the ticket where supported, and test the final artifact on a clean Mac. For a ZIP, staple the app before rebuilding the ZIP; stapling only an earlier intermediate artifact is insufficient.

Authoritative sources:

- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple: Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
- [Apple: Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Apple: Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
- [Apple: Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)

Before calling a production Release compliant, CI should be able to retain auditable evidence (without printing secrets): selected Developer ID identity, signed-app verification, notarization submission ID and `Accepted` result/log, stapler validation on the final distributed artifact, and an independent Gatekeeper assessment. The required signing identity and notarization credential material must be supplied through protected CI secrets/keychain profiles; do not commit certificates, private keys, passwords, or API-key contents.

## GitHub Release / download practice

GitHub Releases are an appropriate place to publish release notes and downloadable binary assets. Keep the release asset names/version/tag aligned, publish the checksum alongside the exact asset, and document how users verify it. The current workflow uses the automatically issued `GITHUB_TOKEN`; GitHub documents that its permissions are repository-scoped and recommends granting only the permissions needed by the job. The current `contents: write` is required for creating a Release, but the workflow should remain limited to the release job and should not be treated as evidence of Apple signing.

Authoritative sources:

- [GitHub Docs: Releasing projects on GitHub](https://docs.github.com/en/repositories/releasing-projects-on-github)
- [GitHub Docs: GITHUB_TOKEN](https://docs.github.com/en/actions/concepts/security/github_token)
- [GitHub Docs: Workflow syntax — permissions](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#permissions)

## Actionable disposition

- **Current / completed:** reproducible unsigned universal ZIP preview, SHA-256 sidecar, preview-tag-triggered GitHub Release, prerelease marking, and explicit unsigned labeling.
- **Missing:** production Developer ID signing, secure timestamp/entitlement evidence, notarization acceptance/log, stapling and validation of the final distributed artifact, and clean-machine Gatekeeper verification.
- **Needs credentials / operator evidence:** Developer ID Application certificate/private key and Apple notary authentication (Apple Account app-specific password or App Store Connect API key/profile), stored only in protected CI/keychain mechanisms. The repository audit intentionally does not inspect or expose them.

Until those gates are evidenced for the exact uploaded asset, classify releases as **unsigned preview / not verified for notarized direct distribution**.
