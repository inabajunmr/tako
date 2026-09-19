import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import ScreenCaptureKit

enum WindowPermissionManager {
    private static var isStartupPermissionSequenceRunning = false
    private static var didResetPrivacyPermissionsForMissingGrant = false
    private static var permissionPollTimer: Timer?

    static func requestStartupPermissions() {
        guard !isStartupPermissionSequenceRunning else {
            return
        }

        let missingScreenRecording = !isScreenRecordingGranted
        let missingAccessibility = !isAccessibilityGranted

        guard missingScreenRecording || missingAccessibility else {
            return
        }

        resetPrivacyPermissionsIfNeeded(
            missingScreenRecording: missingScreenRecording,
            missingAccessibility: missingAccessibility
        )

        isStartupPermissionSequenceRunning = true
        requestScreenRecordingPermission {
            requestAccessibilityPermission {
                isStartupPermissionSequenceRunning = false
            }
        }
    }

    static func requestAccessibilityPermission() {
        requestAccessibilityPermission(onGranted: nil)
    }

    private static func requestAccessibilityPermission(onGranted: (() -> Void)?) {
        guard !isAccessibilityGranted else {
            onGranted?()
            return
        }

        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary

        AXIsProcessTrustedWithOptions(options)

        if let onGranted {
            waitUntil({ isAccessibilityGranted }, then: onGranted)
        }
    }

    private static func requestScreenRecordingPermission(onGranted: (() -> Void)?) {
        guard !isScreenRecordingGranted else {
            onGranted?()
            return
        }

        NSApp.activate(ignoringOtherApps: true)

        Task {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )

                await MainActor.run {
                    onGranted?()
                }
            } catch {
                await MainActor.run {
                    if let onGranted {
                        waitUntil({ isScreenRecordingGranted }, then: onGranted)
                    }
                }
            }
        }
    }

    private static func waitUntil(_ isGranted: @escaping () -> Bool, then onGranted: @escaping () -> Void) {
        guard !isGranted() else {
            onGranted()
            return
        }

        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            guard isGranted() else {
                return
            }

            timer.invalidate()
            permissionPollTimer = nil
            onGranted()
        }
    }

    private static func resetPrivacyPermissionsIfNeeded(
        missingScreenRecording: Bool,
        missingAccessibility: Bool
    ) {
        guard !didResetPrivacyPermissionsForMissingGrant else {
            return
        }

        didResetPrivacyPermissionsForMissingGrant = true

        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            AppLog.write("privacy_permissions_reset_skipped", [
                "reason": "missing_bundle_identifier",
                "missing_screen_recording": missingScreenRecording,
                "missing_accessibility": missingAccessibility
            ])
            return
        }

        let buildFingerprint = currentBuildFingerprint()
        let services = resettablePrivacyServices(
            missingScreenRecording: missingScreenRecording,
            missingAccessibility: missingAccessibility,
            buildFingerprint: buildFingerprint
        )

        guard !services.isEmpty else {
            AppLog.write("privacy_permissions_reset_skipped", [
                "reason": "already_reset_for_this_build",
                "bundle_id": bundleIdentifier,
                "build_fingerprint": buildFingerprint,
                "missing_screen_recording": missingScreenRecording,
                "missing_accessibility": missingAccessibility
            ])
            return
        }

        let results = services.map { service in
            let result = resetPrivacyPermission(
                service: service,
                bundleIdentifier: bundleIdentifier
            )
            markPrivacyPermissionResetAttempted(
                service: service,
                buildFingerprint: buildFingerprint
            )
            return result.logPayload(service: service)
        }

        AppLog.write("privacy_permissions_reset", [
            "bundle_id": bundleIdentifier,
            "build_fingerprint": buildFingerprint,
            "missing_screen_recording": missingScreenRecording,
            "missing_accessibility": missingAccessibility,
            "services": results
        ])
    }

    private static func resettablePrivacyServices(
        missingScreenRecording: Bool,
        missingAccessibility: Bool,
        buildFingerprint: String
    ) -> [String] {
        [
            (missingScreenRecording, "ScreenCapture"),
            (missingAccessibility, "Accessibility")
        ]
            .filter { isMissing, service in
                isMissing && !hasResetPrivacyPermission(
                    service: service,
                    buildFingerprint: buildFingerprint
                )
            }
            .map(\.1)
    }

    private static func hasResetPrivacyPermission(
        service: String,
        buildFingerprint: String
    ) -> Bool {
        UserDefaults.standard.string(forKey: privacyResetUserDefaultsKey(for: service)) == buildFingerprint
    }

    private static func markPrivacyPermissionResetAttempted(
        service: String,
        buildFingerprint: String
    ) {
        UserDefaults.standard.set(buildFingerprint, forKey: privacyResetUserDefaultsKey(for: service))
    }

    private static func privacyResetUserDefaultsKey(for service: String) -> String {
        "privacyResetBuildFingerprint.\(service)"
    }

    private static func resetPrivacyPermission(
        service: String,
        bundleIdentifier: String
    ) -> ProcessResult {
        let process = Process()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleIdentifier]
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProcessResult(
                terminationStatus: -1,
                standardOutput: "",
                standardError: error.localizedDescription
            )
        }

        return ProcessResult(
            terminationStatus: process.terminationStatus,
            standardOutput: readString(from: standardOutputPipe),
            standardError: readString(from: standardErrorPipe)
        )
    }

    private static func currentBuildFingerprint() -> String {
        guard
            let executableURL = Bundle.main.executableURL,
            let data = try? Data(contentsOf: executableURL)
        else {
            return [
                Bundle.main.bundleIdentifier ?? "unknown-bundle",
                Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown-version",
                Bundle.main.executableURL?.path ?? "unknown-executable"
            ]
                .compactMap { $0 }
                .joined(separator: ":")
        }

        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func readString(from pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    private static var isScreenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    private struct ProcessResult {
        let terminationStatus: Int32
        let standardOutput: String
        let standardError: String

        var isSuccess: Bool {
            terminationStatus == 0
        }

        func logPayload(service: String) -> [String: Any] {
            [
                "service": service,
                "success": isSuccess,
                "termination_status": terminationStatus,
                "stdout": standardOutput,
                "stderr": standardError
            ]
        }
    }
}
