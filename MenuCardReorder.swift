import AppKit

// No NSMenu items, card frames, or menu windows are moved during menu tracking.
// A lightweight image follows the pointer; only a successful drop changes order.
enum MenuCardReorder {
    enum Edge { case top, bottom }

    struct Destination: Equatable {
        let index: Int
        let slot: Int
    }

    static func destination(at point: NSPoint, frames: [NSRect], from index: Int) -> Destination? {
        guard frames.count > 1, frames.indices.contains(index),
              frames.dropFirst().reduce(frames[0], { $0.union($1) }).contains(point) else { return nil }
        // Frames are in screen coordinates, in visual top-to-bottom order.
        let slot = frames.firstIndex { point.y >= $0.midY } ?? frames.count
        let destination = slot > index ? slot - 1 : slot
        return destination == index ? nil : Destination(index: destination, slot: slot)
    }

    static func track(_ card: SummaryMenuView, event: NSEvent, rows: [SummaryMenuView],
                      onDrop: (Int) -> Void) {
        guard rows.count > 1, let from = rows.firstIndex(where: { $0 === card }),
              let window = card.window, let root = window.contentView,
              rows.allSatisfy({ $0.window === window }) else { return }
        let frames = rows.map { window.convertToScreen($0.convert($0.bounds, to: nil)) }
        let start = window.convertPoint(toScreen: event.locationInWindow)
        let originalFrame = card.convert(card.bounds, to: root)
        var preview: NSImageView?
        var insertionLine: NSView?
        var dragging = false
        var cancelled = false
        var pushedCursor = false
        defer {
            preview?.removeFromSuperview()
            insertionLine?.removeFromSuperview()
            rows.forEach { $0.insertionEdge = nil; $0.isDragging = false }
            if pushedCursor { NSCursor.pop() }
        }

        while card.window === window && window.isVisible {
            guard let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                until: Date(timeIntervalSinceNow: 0.1), inMode: .eventTracking, dequeue: true) else { continue }
            if next.type == .keyDown {
                if next.keyCode == 53 {
                    cancelled = true
                    preview?.removeFromSuperview()
                    preview = nil
                    insertionLine?.removeFromSuperview()
                    insertionLine = nil
                    rows.forEach { $0.insertionEdge = nil; $0.isDragging = false }
                    if pushedCursor { NSCursor.pop(); pushedCursor = false }
                    // Consume the eventual release too; otherwise NSMenu treats it as a menu click.
                    continue
                }
                NSApp.sendEvent(next)
                continue
            }
            if cancelled {
                if next.type == .leftMouseUp { return }
                continue
            }
            let point = next.window.map { $0.convertPoint(toScreen: next.locationInWindow) } ?? NSEvent.mouseLocation
            if !dragging && next.type == .leftMouseDragged && hypot(point.x - start.x, point.y - start.y) >= 5 {
                dragging = true
                preview = makePreview(card, in: root, frame: originalFrame)
                let line = NSView()
                line.wantsLayer = true
                line.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                line.layer?.cornerRadius = 1
                // Keep the insertion line above the floating card, not hidden behind it.
                root.addSubview(line)
                insertionLine = line
                card.isDragging = true
                NSCursor.closedHand.push()
                pushedCursor = true
            }
            let target = dragging ? destination(at: point, frames: frames, from: from) : nil
            rows.forEach { $0.insertionEdge = nil }
            insertionLine?.isHidden = target == nil
            if let target {
                if target.slot == rows.count { rows.last?.insertionEdge = .bottom }
                else { rows[target.slot].insertionEdge = .top }
                let row = rows[min(target.slot, rows.count - 1)]
                let frame = row.convert(row.bounds, to: root)
                let atBottom = target.slot == rows.count
                let y = root.isFlipped
                    ? (atBottom ? frame.maxY - 2 : frame.minY)
                    : (atBottom ? frame.minY : frame.maxY - 2)
                insertionLine?.frame = NSRect(x: frame.minX + 12, y: y, width: frame.width - 24, height: 2)
            }
            if let preview {
                let direction: CGFloat = root.isFlipped ? -1 : 1
                preview.setFrameOrigin(NSPoint(x: originalFrame.minX,
                    y: originalFrame.minY + direction * (point.y - start.y)))
            }
            if next.type == .leftMouseUp {
                if let target { onDrop(target.index) }
                return
            }
        }
    }

    private static func makePreview(_ card: NSView, in root: NSView, frame: NSRect) -> NSImageView? {
        guard let bitmap = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { return nil }
        card.cacheDisplay(in: card.bounds, to: bitmap)
        let image = NSImage(size: card.bounds.size)
        image.addRepresentation(bitmap)
        let preview = NSImageView(frame: frame)
        preview.image = image
        preview.imageScaling = .scaleNone
        preview.alphaValue = 0.95
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        preview.layer?.cornerRadius = 6
        preview.layer?.shadowColor = NSColor.black.cgColor
        preview.layer?.shadowOpacity = 0.15
        preview.layer?.shadowRadius = 5
        preview.layer?.shadowOffset = NSSize(width: 0, height: -2)
        root.addSubview(preview)
        return preview
    }
}
