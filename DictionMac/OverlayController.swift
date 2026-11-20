import AppKit
import SwiftUI

/// The small floating pill near the bottom of the screen while you dictate.
/// It never takes focus, so the text still lands in the app you were using.
@MainActor
final class OverlayController {
    private let panel: NSPanel
    private static let size = NSSize(width: 240, height: 44)

    init(controller: AppController) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: PillView().environmentObject(controller))
    }

    func show() {
        positionOnActiveScreen()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + 24)
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: true)
    }
}

private struct PillView: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Capsule().fill(.black.opacity(0.85)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .recording(let handsFree):
            if handsFree {
                Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
            }
            LevelBars(levels: controller.levels)
        case .transcribing:
            ProgressView().controlSize(.small).tint(.white)
            Text("Transcribing").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
        case .loadingModel:
            ProgressView().controlSize(.small).tint(.white)
            Text("Loading model").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
        case .error(let message):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).font(.system(size: 11)).foregroundStyle(.white).lineLimit(1).truncationMode(.tail)
        case .idle:
            EmptyView()
        }
    }
}

private struct LevelBars: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: 4 + CGFloat(levels[index]) * 18)
            }
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}
