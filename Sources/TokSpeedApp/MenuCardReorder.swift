import AppKit

// No NSMenu items, card frames, or menu windows are moved during menu tracking.
// A lightweight image follows the pointer; only a successful drop changes order.
enum MenuCardReorder {
    struct Destination: Equatable {
        let index: Int
        let slot: Int
    }

    static func destination(at point: NSPoint, frames: [NSRect], from index: Int, vertical: Bool = false) -> Destination? {
        guard frames.count > 1, frames.indices.contains(index),
              frames.dropFirst().reduce(frames[0], { $0.union($1) }).contains(point) else { return nil }
        // Screen Y increases upwards; vertical slots run top to bottom.
        let slot = frames.firstIndex { vertical ? point.y >= $0.midY : point.x < $0.midX } ?? frames.count
        let destination = slot > index ? slot - 1 : slot
        return destination == index ? nil : Destination(index: destination, slot: slot)
    }

    static func trackClick(_ card: SummaryMenuView, event: NSEvent,
                           onTrackingChange: ((Bool) -> Void)? = nil,
                           onClick: () -> Void) {
        guard let window = card.window else { return }
        onTrackingChange?(true)
        defer { onTrackingChange?(false) }
        while card.window === window && window.isVisible {
            guard let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                until: Date(timeIntervalSinceNow: 0.1), inMode: .eventTracking, dequeue: true) else { continue }
            if next.type == .keyDown {
                if next.keyCode == 53 { continue }
                NSApp.sendEvent(next)
                continue
            }
            if next.type == .leftMouseUp {
                let local = card.convert(next.locationInWindow, from: nil)
                if next.window === window && card.bounds.contains(local) {
                    onClick()
                }
                return
            }
        }
    }

    static func track(_ card: SummaryMenuView, event: NSEvent, cards: [SummaryMenuView], vertical: Bool,
                      onTrackingChange: ((Bool) -> Void)? = nil,
                      onClick: (() -> Void)? = nil,
                      onDrop: (Int) -> Void) {
        guard cards.count > 1, let from = cards.firstIndex(where: { $0 === card }),
              let window = card.window, let root = window.contentView,
              cards.allSatisfy({ $0.window === window }) else { return }
        onTrackingChange?(true)
        let frames = cards.map { window.convertToScreen($0.convert($0.bounds, to: nil)) }
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
            card.isDragging = false
            if pushedCursor { NSCursor.pop() }
            onTrackingChange?(false)
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
                    card.isDragging = false
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
            if !dragging && next.type == .leftMouseDragged &&
                abs(vertical ? point.y - start.y : point.x - start.x) >= 5 {
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
            let target = dragging ? destination(at: point, frames: frames, from: from, vertical: vertical) : nil
            insertionLine?.isHidden = target == nil
            if let target {
                let adjacent = cards[min(target.slot, cards.count - 1)]
                let frame = adjacent.convert(adjacent.bounds, to: root)
                if vertical {
                    let atBottom = target.slot == cards.count
                    let y = root.isFlipped == atBottom ? frame.maxY - 2 : frame.minY
                    insertionLine?.frame = NSRect(x: frame.minX, y: y, width: frame.width, height: 2)
                } else {
                    let x = target.slot == cards.count ? frame.maxX - 2 : frame.minX
                    insertionLine?.frame = NSRect(x: x, y: frame.minY + 8, width: 2, height: frame.height - 16)
                }
            }
            if let preview {
                preview.setFrameOrigin(NSPoint(x: originalFrame.minX + (vertical ? 0 : point.x - start.x),
                    y: originalFrame.minY + (vertical ? (root.isFlipped ? -1 : 1) * (point.y - start.y) : 0)))
            }
            if next.type == .leftMouseUp {
                if !dragging {
                    let local = card.convert(next.locationInWindow, from: nil)
                    if next.window === window && card.bounds.contains(local) {
                        onClick?()
                    }
                } else if let target {
                    onDrop(target.index)
                }
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
        preview.alphaValue = 0.5
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
