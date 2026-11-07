import SwiftUI
import QuickLook
import UIKit

// MARK: - Cards

struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label(title, systemImage: systemImage ?? "circle")
                    .labelStyle(.titleAndIcon)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct QuotaBar: View {
    var fraction: Double
    var height: CGFloat = 8

    var color: Color { fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .accentColor }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(color).frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(L("Storage used"))
        .accessibilityValue(Fmt.percent(fraction))
    }
}

struct ProviderBadge: View {
    let kind: ProviderKind
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(kind == .googleDrive ? Color.green.gradient : Color.blue.gradient)
            Image(systemName: kind.symbol).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(kind.title)
    }
}

struct StatusDot: View {
    let status: ConnectionStatus
    var body: some View {
        let color: Color = switch status {
        case .connected: .green
        case .experimental: .orange
        case .expired: .yellow
        case .error: .red
        }
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

struct AccountRow: View {
    let account: CloudAccount

    var body: some View {
        HStack(spacing: 12) {
            ProviderBadge(kind: account.provider)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(account.displayName).font(.body.weight(.medium)).lineLimit(1)
                    if account.isActive { Text(L("Active")).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.accentColor.opacity(0.15), in: Capsule()) }
                    if account.role != .normal { Text(account.role.title).font(.caption2).foregroundStyle(.secondary) }
                }
                Text(account.email.isEmpty ? account.provider.title : account.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let total = account.quotaTotal, let used = account.quotaUsed {
                    QuotaBar(fraction: account.usageFraction, height: 5)
                    Text(LF("%@ of %@ used", Fmt.bytes(used), Fmt.bytes(total))).font(.caption2).foregroundStyle(.secondary)
                } else if let used = account.quotaUsed {
                    Text(LF("%@ used (no fixed limit reported)", Fmt.bytes(used))).font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    StatusDot(status: account.status)
                    Text(account.status.title).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct FileIcon: View {
    let item: RemoteItem
    var size: CGFloat = 32

    var tint: Color {
        switch item.category {
        case .folder: return .accentColor
        case .photo: return .pink
        case .video: return .purple
        case .audio: return .orange
        case .pdf: return .red
        case .document: return .blue
        case .spreadsheet: return .green
        case .presentation: return .orange
        case .archive: return .brown
        case .app: return .indigo
        default: return .gray
        }
    }

    var body: some View {
        Image(systemName: item.name.hasSuffix(".\(FileEncryptor.encryptedExtension)") ? "lock.doc.fill" : item.category.symbol)
            .font(.system(size: size * 0.6))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var message: String?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        }
    }
}

struct ErrorBanner: View {
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark").font(.footnote.weight(.semibold)) }.buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - QuickLook & Share

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let ql = QLPreviewController()
        ql.dataSource = context.coordinator
        return UINavigationController(rootViewController: ql)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Identifiable wrapper so local URLs can drive `.sheet(item:)`.
struct LocalFile: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }
}

// MARK: - Lock screen

struct LockScreenView: View {
    @EnvironmentObject var lock: AppLockManager

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.icloud.fill").font(.system(size: 64)).foregroundStyle(.tint)
            Text("iCloud IPA").font(.largeTitle.bold())
            Text(L("Locked")).foregroundStyle(.secondary)
            Button {
                Task { await lock.unlock() }
            } label: {
                Label(LF("Unlock with %@", lock.authenticator.biometryName), systemImage: "faceid")
                    .frame(maxWidth: 280)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if let e = lock.lastError { Text(e).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThickMaterial)
        .task { await lock.unlock() }
    }
}

extension View {
    /// Presents an alert for an optional error string.
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert(L("Something went wrong"), isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
            Button(L("OK"), role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
