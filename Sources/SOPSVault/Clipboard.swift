import AppKit

@MainActor final class Clipboard {
    static let shared = Clipboard()
    private var expiry: DispatchWorkItem?
    private var ownedChange: Int?
    func copy(_ value: String, duration: TimeInterval = 30) {
        clear()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
                                  NSPasteboard.PasteboardType("org.nspasteboard.TransientType")], owner: nil)
        pasteboard.setString(value, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        ownedChange = pasteboard.changeCount
        let task = DispatchWorkItem { [weak self] in self?.clear() }
        expiry = task
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }
    func clear() {
        expiry?.cancel(); expiry = nil
        if let ownedChange, NSPasteboard.general.changeCount == ownedChange { NSPasteboard.general.clearContents() }
        ownedChange = nil
    }
}
