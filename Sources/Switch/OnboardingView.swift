import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 56, height: 56)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Switch")
                        .font(.system(size: 16, weight: .semibold))
                    Text(L10n.string(model.requiresScreenCapture ? "Two permissions before you can switch windows." : "One permission before you can switch windows."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(spacing: 8) {
                row(
                    name: "Accessibility",
                    detail: "Lets Switch intercept ⌘-Tab and ⌥-`.",
                    granted: model.accessibility,
                    open: model.openAccessibility
                )
                row(
                    name: "Screen Recording",
                    detail: model.requiresScreenCapture ? "Captures live thumbnails of your windows." : "Optional while thumbnails are disabled.",
                    granted: model.screenCapture,
                    open: model.openScreenCapture
                )
            }

            HStack {
                if model.allGranted {
                    Label("Ready. Hold ⌘-Tab to switch windows.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12, weight: .medium))
                } else {
                    Text("Click Open Settings, then toggle Switch on. This window updates automatically.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.accessibility && model.requiresScreenCapture && !model.screenCapture {
                    Button("Continue without thumbnails") {
                        SwitchPreferences.shared.showThumbnails = false
                        model.refresh()
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    private func row(name: String, detail: String, granted: Bool, open: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 18))
                .foregroundStyle(granted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.string(name)).font(.system(size: 13, weight: .medium))
                Text(L10n.string(detail)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.string(granted ? "Granted" : "Open Settings"), action: open)
                .disabled(granted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
