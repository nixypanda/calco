// Deliberate, user-triggered clipboard copy for a one-time API-key secret.
//
// The receipt is the pasteboard change count at copy time. Lifecycle cleanup
// clears only when that count is still current, so copying something else
// after the secret is never erased by this feature. Tests inject a fake; no
// test touches the system pasteboard.

import Foundation

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

public struct APIKeyClipboardReceipt: Equatable, Sendable {
    public let changeCount: Int

    public init(changeCount: Int) {
        self.changeCount = changeCount
    }
}

@MainActor
public protocol APIKeySecretCopying {
    /// Returns nil when the pasteboard rejected the write.
    func copySecretToClipboard(_ secret: String) -> APIKeyClipboardReceipt?
    /// Clears only when the receipt still owns the current pasteboard item.
    func clearSecretFromClipboard(_ receipt: APIKeyClipboardReceipt)
}

public struct SystemAPIKeySecretClipboard: APIKeySecretCopying {
    nonisolated public init() {}

    @MainActor
    public func copySecretToClipboard(_ secret: String) -> APIKeyClipboardReceipt? {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        pasteboard.clearContents()
        guard pasteboard.declareTypes([.string, concealed, transient], owner: nil) != 0
        else { return nil }
        guard pasteboard.setString(secret, forType: .string) else { return nil }
        // Best-effort hints for clipboard managers; NSPasteboard has no
        // iOS-style local-only or expiry option.
        _ = pasteboard.setString("", forType: concealed)
        _ = pasteboard.setString("", forType: transient)
        return APIKeyClipboardReceipt(changeCount: pasteboard.changeCount)
        #elseif canImport(UIKit)
        let pasteboard = UIPasteboard.general
        let options: [UIPasteboard.OptionsKey: Any] = [
            .localOnly: true,
            .expirationDate: Date().addingTimeInterval(5 * 60),
        ]
        pasteboard.setItems(
            [[UTType.utf8PlainText.identifier: secret]],
            options: options
        )
        return APIKeyClipboardReceipt(changeCount: pasteboard.changeCount)
        #else
        return nil
        #endif
    }

    @MainActor
    public func clearSecretFromClipboard(_ receipt: APIKeyClipboardReceipt) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == receipt.changeCount else { return }
        pasteboard.clearContents()
        #elseif canImport(UIKit)
        let pasteboard = UIPasteboard.general
        guard pasteboard.changeCount == receipt.changeCount else { return }
        pasteboard.items = []
        #endif
    }
}
