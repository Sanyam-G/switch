import AppKit
import SwiftUI

struct PermissionsTabView: View {
    let accent: Color
    @StateObject private var perms = OnboardingModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Switch needs Accessibility for the ⌘-Tab hotkey. Screen Recording is only needed when thumbnails are enabled.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                permRow(
                    title: "Accessibility",
                    detail: "Intercept ⌘-Tab and ⌥-` system-wide.",
                    granted: perms.accessibility,
                    action: { perms.openAccessibility() }
                )
                permRow(
                    title: "Screen Recording",
                    detail: SwitchPreferences.shared.showThumbnails ? "Capture live thumbnails of every window." : "Optional while thumbnails are disabled.",
                    granted: perms.screenCapture,
                    action: { perms.openScreenCapture() }
                )
            }
            .padding(24)
        }
        .onAppear { perms.startPolling() }
        .onDisappear { perms.stopPolling() }
    }

    private func permRow(title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open in System Settings", action: action)
                    .controlSize(.small)
            } else {
                Text("Granted").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(SettingsRowBackground())
    }
}
