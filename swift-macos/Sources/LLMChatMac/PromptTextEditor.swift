import AppKit
import SwiftUI

struct PromptTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var dynamicHeight: CGFloat
    var isEnabled: Bool
    var onSubmit: () -> Void
    var minLines: Int = 3
    var maxLines: Int = 20

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, dynamicHeight: $dynamicHeight, minLines: minLines, maxLines: maxLines)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = KeyHandlingTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.isEditable = isEnabled
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = text

        let scrollView = PromptScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.onLayout = { [weak textView, weak scrollView, coordinator = context.coordinator] in
            guard let textView, let scrollView else { return }
            coordinator.updateHeight(for: textView, in: scrollView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? KeyHandlingTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = isEnabled
        textView.onSubmit = onSubmit
        textView.frame.size.width = scrollView.contentSize.width
        context.coordinator.updateHeight(for: textView, in: scrollView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        @Binding private var dynamicHeight: CGFloat
        private let minLines: Int
        private let maxLines: Int

        init(text: Binding<String>, dynamicHeight: Binding<CGFloat>, minLines: Int, maxLines: Int) {
            _text = text
            _dynamicHeight = dynamicHeight
            self.minLines = minLines
            self.maxLines = maxLines
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            if let scrollView = textView.enclosingScrollView {
                updateHeight(for: textView, in: scrollView)
            }
        }

        func updateHeight(for textView: NSTextView, in scrollView: NSScrollView) {
            let availableWidth = scrollView.contentSize.width
            guard availableWidth > 0 else { return }
            guard let font = textView.font else { return }
            guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }

            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.frame.size.width = availableWidth
            textContainer.containerSize = NSSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: textContainer)

            let lineHeight = layoutManager.defaultLineHeight(for: font)
            let verticalInset = textView.textContainerInset.height * 2
            let horizontalInset = (textView.textContainerInset.width * 2) + (textContainer.lineFragmentPadding * 2)
            let textWidth = max(availableWidth - horizontalInset, 1)
            let measurementText = textView.string.isEmpty ? " " : textView.string
            let measuredRect = NSString(string: measurementText).boundingRect(
                with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            )
            let usedHeight = ceil(measuredRect.height) + verticalInset
            let minHeight = ceil(lineHeight * CGFloat(minLines)) + verticalInset
            let maxHeight = ceil(lineHeight * CGFloat(maxLines)) + verticalInset
            let resolvedHeight = min(max(usedHeight, minHeight), maxHeight)

            scrollView.hasVerticalScroller = usedHeight > maxHeight
            if abs(dynamicHeight - resolvedHeight) > 0.5 {
                dynamicHeight = resolvedHeight
            }
        }
    }
}

private final class PromptScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

private final class KeyHandlingTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isEnter = event.keyCode == 36 || event.keyCode == 76
        let sendsMessage = isEnter && !event.modifierFlags.contains(.shift)
        if sendsMessage {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }
}
