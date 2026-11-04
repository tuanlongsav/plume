import Foundation

/// Which main-frame navigation, if any, is an attachment fetch.
///
/// An attachment (fbsbx.com) loads in the main frame so its response can be
/// turned into a download; a redirect off the CDN to something renderable
/// must then be cancelled, not committed over the live inbox. That needs the
/// attachment's own navigation, and WebKit only names it at
/// `didStartProvisionalNavigation`, after the policy decision that knew it
/// was an attachment. Neither a flag (cleared by the failure of a superseded
/// fetch) nor the provisional URL (an ordering detail of WebKit) proved
/// reliable; the order of the callbacks is: a main-frame navigation's policy
/// decision is followed by that navigation's start.
///
/// Navigations are compared by identity only, so tests can use any object.
struct AttachmentNavTracker {
    /// The last allowed main-frame decision was for an attachment.
    private var expecting = false
    /// The attachment navigation whose response is still to be decided.
    private var tagged: ObjectIdentifier?

    /// Every allowed main-frame navigation action. Overwrites what came
    /// before, so an expectation cannot outlive the next decision.
    mutating func decided(isAttachment: Bool) {
        expecting = isAttachment
    }

    /// A load Plume started itself (`window.open` of an attachment), whose
    /// navigation object is known at once.
    mutating func loadedDirectly(_ navigation: ObjectIdentifier) {
        tagged = navigation
    }

    /// A main-frame navigation started. True when it is the attachment
    /// fetch, which should not flash the loading pill. Any other one
    /// supersedes whatever attachment was in flight.
    mutating func started(_ navigation: ObjectIdentifier) -> Bool {
        if navigation == tagged { expecting = false; return true }
        if expecting {
            expecting = false
            tagged = navigation
            return true
        }
        tagged = nil
        return false
    }

    /// A main-frame response arrived; it belongs to the latest navigation.
    /// True when that is an attachment fetch. Consumes the tag.
    mutating func responseForMainFrame() -> Bool {
        defer { tagged = nil }
        return tagged != nil
    }

    /// A navigation failed. Only its own state ends with it: clicking a
    /// second attachment cancels the first, and that failure is reported
    /// after the second has already been tagged.
    mutating func failed(_ navigation: ObjectIdentifier) {
        if navigation == tagged { tagged = nil }
    }
}
