import AppKit
import ApplicationServices

/// Works out what's under the pointer, through the Accessibility API (the same one VoiceOver uses), so the highlight
/// can box just that: a button or link on its own, the paragraph a bit of text belongs to, or the container you
/// pointed at. Needs Accessibility access.
enum ElementFinder {
    /// Things you'd click or type in: boxed on their own, even when the pointer is on the text inside them.
    private static let controls: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXComboBox",
        "AXTextField", "AXSearchField", "AXSlider", "AXIncrementor", "AXDisclosureTriangle", "AXTab",
        "AXMenuItem", "AXMenuBarItem", "AXSegmentedControl", "AXColorWell", "AXDateField", "AXImage",
    ]
    /// Bits of text, which read better boxed as the paragraph (or heading, or list item) they're part of.
    private static let text: Set<String> = ["AXStaticText", "AXTextArea", "AXHeading"]
    /// What a bit of text belongs to.
    private static let blocks: Set<String> = ["AXGroup", "AXHeading", "AXListItem", "AXCell", "AXRow", "AXParagraph"]
    /// Never boxed: they're the whole window or app, not a part of it.
    private static let tooBig: Set<String> = ["AXWindow", "AXApplication", "AXSheet", "AXDrawer", "AXWebArea", "AXSplitGroup"]

    /// The frame (global, top-left origin, in points) of the thing at `point`, or nil if there's nothing sensible.
    static func frame(at point: CGPoint) -> CGRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }

        // Chrome and Electron apps only describe their web content to apps that ask for it.
        var pid: pid_t = 0
        if AXUIElementGetPid(hit, &pid) == .success {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        // From what's under the pointer up to its window.
        var chain: [(role: String, frame: CGRect)] = []
        var window = CGRect.null
        var element: AXUIElement? = hit
        while let e = element, chain.count < 30 {
            let role = string(e, kAXRoleAttribute) ?? ""
            if role == "AXWindow" { window = frame(of: e) ?? .null; break }
            if let f = frame(of: e), f.width >= 4, f.height >= 4 { chain.append((role, f)) }
            element = parent(of: e)
        }
        let limit = window.isNull ? (NSScreen.screens.first?.frame ?? .infinite) : window
        func sensible(_ f: CGRect) -> Bool {
            f.contains(point) && f.width * f.height < limit.width * limit.height * 0.7
        }
        let candidates = chain.filter { !tooBig.contains($0.role) && sensible($0.frame) }
        guard let first = candidates.first else { return nil }

        // A control near the pointer (a link's text, a button's label) wins.
        if let control = candidates.prefix(4).first(where: { controls.contains($0.role) }) { return control.frame }
        // Text: its paragraph, as long as that's still a modest block and not the whole page.
        if text.contains(first.role) {
            let block = candidates.dropFirst().prefix(3).first {
                blocks.contains($0.role) && $0.frame.height < max(limit.height * 0.5, first.frame.height * 2)
            }
            return block?.frame ?? first.frame
        }
        // Anything else is the container you pointed at.
        return first.frame
    }

    private static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func parent(of e: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func frame(of e: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
}
