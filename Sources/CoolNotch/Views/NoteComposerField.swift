import AppKit
import SwiftUI

/// Поле новой заметки. Своё (NSTextView), а не системное многострочное TextField: то прокручивалось
/// «на полстроки» — сверху торчал обрезанный кусок текста, а подложка поля подпрыгивала.
/// Здесь поле ровно растёт от одной до трёх строк, дальше прокручивается по целым строкам.
/// Enter — отправить, Shift/Option + Enter — новая строка.
struct NoteComposerField: NSViewRepresentable {
    @Binding var text: String
    /// Высота текста (1…3 строки) — по ней SwiftUI плавно меняет высоту поля.
    @Binding var height: CGFloat
    /// Увеличь, чтобы вернуть курсор в поле (например, после отправки).
    var focusRequest: Int
    var maxLines = 3
    var onSubmit: () -> Void
    var onFocusChange: (Bool) -> Void

    static let font = NSFont.systemFont(ofSize: 13)

    /// Высота одной строки — для начального размера поля.
    static var lineHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(for: font).rounded(.up)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none

        // TextKit 1: ровный расчёт высоты строк.
        let textView = ComposerTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.onWidthChange = {
            DispatchQueue.main.async { context.coordinator.recalculate() }
        }
        textView.onFocusChange = { focused in
            // Не меняем состояние SwiftUI посреди его же обновления.
            DispatchQueue.main.async { context.coordinator.parent.onFocusChange(focused) }
        }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.typingAttributes = [.font: Self.font, .foregroundColor: NSColor.white]
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.string = text

        scroll.documentView = textView
        context.coordinator.textView = textView
        DispatchQueue.main.async { context.coordinator.recalculate() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            DispatchQueue.main.async { context.coordinator.recalculate() }
        }
        if focusRequest != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteComposerField
        weak var textView: NSTextView?
        var lastFocusRequest: Int

        init(_ parent: NoteComposerField) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            recalculate()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Пока набирается составной символ (метод ввода), Enter его подтверждает, а не отправляет.
            guard selector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }

        /// Высота = строки текста, но не больше maxLines; дальше — прокрутка к курсору.
        func recalculate() {
            guard let textView, let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let line = layout.defaultLineHeight(for: NoteComposerField.font)
            let used = max(layout.usedRect(for: container).height, line)
            let target = min(used, line * CGFloat(parent.maxLines)).rounded(.up)
            if abs(parent.height - target) > 0.5 { parent.height = target }
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }
}

/// Сообщает, когда поле получает и теряет фокус (для подсветки и «не сворачивать, пока печатаю»).
final class ComposerTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
    /// Ширина поменялась — строки переносятся иначе, пересчитываем высоту.
    var onWidthChange: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { onWidthChange?() }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }
}
