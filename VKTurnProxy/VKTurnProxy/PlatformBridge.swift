// SPDX-License-Identifier: MIT
//
// The macOS port's seam. Everything the app takes from UIKit is small — a
// view wrapper, the pasteboard, a text field hint — and each has an AppKit
// twin with a different name. This file gives the two ONE name, so the views
// stay a single source instead of forking per platform.
//
// 🚨 KEEP THIS FILE THE ONLY PLACE THAT SPELLS BOTH. A second `#if os(macOS)`
// with its own NSPasteboard call is a second place to get the Mac wrong.

import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - View wrapping

#if os(iOS)
/// The UIKit-flavoured spelling the three WKWebView wrappers and the log view
/// were written in. On iOS it IS UIViewRepresentable.
typealias PlatformViewRepresentable = UIViewRepresentable
typealias PlatformView = UIView
#else
typealias PlatformView = NSView

/// On macOS the same spelling is forwarded to NSViewRepresentable, so a
/// wrapper written as `makeUIView` / `updateUIView` / `dismantleUIView`
/// compiles unchanged. `dismantleUIView` has a default so wrappers that do not
/// need teardown need not declare it.
protocol PlatformViewRepresentable: NSViewRepresentable where NSViewType == PlatformViewType {
    associatedtype PlatformViewType: NSView
    func makeUIView(context: Context) -> PlatformViewType
    func updateUIView(_ view: PlatformViewType, context: Context)
    static func dismantleUIView(_ view: PlatformViewType, coordinator: Coordinator)
}

extension PlatformViewRepresentable {
    func makeNSView(context: Context) -> PlatformViewType { makeUIView(context: context) }
    func updateNSView(_ nsView: PlatformViewType, context: Context) { updateUIView(nsView, context: context) }
    static func dismantleNSView(_ nsView: PlatformViewType, coordinator: Coordinator) {
        dismantleUIView(nsView, coordinator: coordinator)
    }
    static func dismantleUIView(_ view: PlatformViewType, coordinator: Coordinator) {}
}
#endif

// MARK: - Pasteboard

enum PlatformPasteboard {
    /// The general pasteboard's text, or nil when it holds none.
    static var string: String? {
        #if os(iOS)
        return UIPasteboard.general.string
        #else
        return NSPasteboard.general.string(forType: .string)
        #endif
    }

    static func set(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        #endif
    }
}

// MARK: - Text-field hints that only a touch keyboard has

extension View {
    /// `.autocapitalization(.none)` on iOS; a Mac keyboard does not capitalize
    /// on its own, so nothing on macOS.
    @ViewBuilder
    func noAutocapitalization() -> some View {
        #if os(iOS)
        self.autocapitalization(.none)
        #else
        self
        #endif
    }

    /// The numbers-and-punctuation keyboard for port fields; a Mac has one
    /// keyboard.
    @ViewBuilder
    func numericKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.numbersAndPunctuation)
        #else
        self
        #endif
    }

    /// `.navigationBarTitleDisplayMode(.inline)` — a UINavigationBar setting
    /// with no macOS counterpart (the Mac title bar has one mode).
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

// MARK: - System colours the two toolkits name differently

extension Color {
    /// `UIColor.systemBackground` / `NSColor.windowBackgroundColor`.
    static var platformBackground: Color {
        #if os(iOS)
        Color(.systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// `UIColor.systemGray6` — the light fill behind a grouped row. AppKit's
    /// nearest named colour is the control background.
    static var platformGroupedFill: Color {
        #if os(iOS)
        Color(.systemGray6)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
}

// MARK: - Navigation container

/// `NavigationView` on iOS (the app's floor is iOS 15, where NavigationStack
/// does not exist); `NavigationStack` on macOS, where NavigationView is a
/// split view and a push-style NavigationLink needs a stack to push onto.
struct PlatformNavigation<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(iOS)
        NavigationView { content() }
        #else
        NavigationStack { content() }
        #endif
    }
}

// MARK: - Sheet sizing

extension View {
    /// A macOS sheet is sized by its content, and a WKWebView has no intrinsic
    /// size — without this the three web sheets (VK login, VK ID, captcha)
    /// open as a sliver. iOS sheets fill the screen; nothing to do there.
    @ViewBuilder
    func webSheetSized() -> some View {
        #if os(macOS)
        self.frame(minWidth: 520, idealWidth: 560, minHeight: 720, idealHeight: 800)
        #else
        self
        #endif
    }
}
