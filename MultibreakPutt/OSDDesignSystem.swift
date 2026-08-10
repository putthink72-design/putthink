import SwiftUI
import UIKit

// MARK: - Design tokens (레인지파인더 앰버)

enum OSDPalette {
    static let accent = Color(red: 1.0, green: 176 / 255, blue: 32 / 255)
    static let accentInk = Color(red: 26 / 255, green: 18 / 255, blue: 4 / 255)
    static let accentSoft = Color(red: 1.0, green: 176 / 255, blue: 32 / 255).opacity(0.16)
    static let accentMid = Color(red: 1.0, green: 176 / 255, blue: 32 / 255).opacity(0.38)
    static let status = Color(red: 62 / 255, green: 213 / 255, blue: 152 / 255)
    static let textPrimary = Color(red: 245 / 255, green: 242 / 255, blue: 232 / 255)
    static let textSecondary = Color(red: 170 / 255, green: 179 / 255, blue: 166 / 255)
    static let textTertiary = Color(red: 111 / 255, green: 121 / 255, blue: 112 / 255)
    static let glass = Color(red: 9 / 255, green: 13 / 255, blue: 10 / 255).opacity(0.66)
    static let glassStrong = Color(red: 7 / 255, green: 10 / 255, blue: 8 / 255).opacity(0.82)
    static let glassBorder = Color.white.opacity(0.09)
    static let glassHair = Color.white.opacity(0.06)
}

// MARK: - Top chrome

struct OSDHeaderBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            leading()
            Spacer(minLength: 8)
            trailing()
        }
    }
}

struct OSDStatusPill: View {
    let isHealthy: Bool
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isHealthy ? OSDPalette.status : Color.orange)
                .frame(width: 6, height: 6)
                .shadow(color: (isHealthy ? OSDPalette.status : Color.orange).opacity(0.8), radius: 4)
            HStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(OSDPalette.textPrimary)
                if let subtitle, !subtitle.isEmpty {
                    Text(" · \(subtitle)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(OSDPalette.textSecondary)
                        .monospacedDigit()
                }
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .fixedSize(horizontal: true, vertical: false)
        .background(OSDPalette.glass, in: Capsule())
        .overlay(Capsule().strokeBorder(OSDPalette.glassBorder, lineWidth: 1))
    }
}

struct OSDGearButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(OSDPalette.textSecondary)
                .frame(width: 36, height: 36)
                .background(OSDPalette.glass, in: Circle())
                .overlay(Circle().strokeBorder(OSDPalette.glassBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("설정")
    }
}

/// 상단 크롬 — safe area 아래 최소 여백.
enum OSDTopChromeMetrics {
    static let horizontalPadding: CGFloat = 14
    static let topPadding: CGFloat = 6
    static let floatingCardHorizontalPadding: CGFloat = 14
    static let floatingCardBottomPadding: CGFloat = 26
}

// MARK: - Bottom panel

struct OSDBottomPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            OSDPalette.glassStrong
                .background(.ultraThinMaterial.opacity(0.35))
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(OSDPalette.glassBorder)
                .frame(height: 1)
        }
        .clipShape(RoundedCornerShape(radius: 22, corners: [.topLeft, .topRight]))
    }
}

/// OSD 패널 내 섹션 구분선.
struct OSDSectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(OSDPalette.glassBorder)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

struct OSDStepHeader: View {
    let step: String?
    let title: String
    let bodyText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let step {
                Text(step)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(OSDPalette.accent)
                    .tracking(0.5)
            }
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(OSDPalette.textPrimary)
            if let bodyText {
                Text(bodyText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(OSDPalette.textSecondary)
                    .lineSpacing(2)
            }
        }
    }
}

struct OSDPrimaryButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5, weight: .heavy))
                .foregroundStyle(OSDPalette.accentInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background {
                    LinearGradient(
                        colors: [OSDPalette.accent, Color(red: 229 / 255, green: 150 / 255, blue: 15 / 255)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: OSDPalette.accent.opacity(0.45), radius: 9, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

struct OSDOnboardCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 16) {
            content()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .background(OSDPalette.glassStrong, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(OSDPalette.glassBorder, lineWidth: 1))
    }
}

/// 스캔·조준 플로팅 카드 — 스크롤 가능, 스크롤바 비표시.
struct OSDFloatingScrollCard<Content: View>: View {
    var maxHeight: CGFloat = 320
    var scrollToID: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                OSDOnboardCard {
                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .scrollDismissesKeyboard(.never)
            .frame(maxHeight: maxHeight)
            .onChange(of: scrollToID) { _, id in
                guard let id else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Keyboard inset (하단 OSD가 키패드에 가리지 않도록)

private enum OSDKeyboardMetrics {
    static var bottomSafeArea: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
    }

    static func overlapPadding(for keyboardFrame: CGRect) -> CGFloat {
        let screenHeight = UIScreen.main.bounds.height
        let overlap = screenHeight - keyboardFrame.origin.y
        guard overlap > 0 else { return 0 }
        return max(0, overlap - bottomSafeArea)
    }
}

struct OSDKeyboardAdaptive: ViewModifier {
    @State private var keyboardPadding: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.bottom, keyboardPadding)
            .animation(.easeOut(duration: 0.22), value: keyboardPadding)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                guard
                    let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                else { return }
                keyboardPadding = OSDKeyboardMetrics.overlapPadding(for: frame)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard
                    let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                else { return }
                keyboardPadding = OSDKeyboardMetrics.overlapPadding(for: frame)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardPadding = 0
            }
    }
}

extension View {
    func osdKeyboardAdaptive() -> some View {
        modifier(OSDKeyboardAdaptive())
    }
}

// MARK: - Inline number pad (SwiftUI — UIKit inputView 지연 없음)

struct OSDCentimeterInput: View {
    @Binding var digits: String
    var isEnabled: Bool
    var isActive: Bool
    var onActivate: () -> Void

    var body: some View {
        Button(action: onActivate) {
            Group {
                if digits.isEmpty {
                    Text("cm")
                        .foregroundStyle(OSDPalette.textTertiary)
                } else {
                    (Text(digits) + Text("cm"))
                        .foregroundStyle(OSDPalette.textPrimary)
                }
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(minWidth: 56, minHeight: 32)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isActive ? OSDPalette.accent : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
    }
}

struct OSDInlineNumberPad: View {
    let onDigit: (String) -> Void
    let onDelete: () -> Void
    let onDone: () -> Void

    static let height: CGFloat = 248

    private let padBackground = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    private let keyBackground = Color(red: 58 / 255, green: 58 / 255, blue: 60 / 255)

    var body: some View {
        VStack(spacing: 7) {
            keyRow(["1", "2", "3"])
            keyRow(["4", "5", "6"])
            keyRow(["7", "8", "9"])
            HStack(spacing: 7) {
                padButton(title: "완료", accent: true, action: onDone)
                padButton(title: "0", action: { onDigit("0") })
                deleteButton(action: onDelete)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(padBackground)
    }

    private func keyRow(_ labels: [String]) -> some View {
        HStack(spacing: 7) {
            ForEach(labels, id: \.self) { label in
                padButton(title: label, action: { onDigit(label) })
            }
        }
    }

    private func padButton(title: String, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: accent ? 17 : 24, weight: accent ? .semibold : .regular))
                .foregroundStyle(accent ? OSDPalette.accent : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(keyBackground, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    private func deleteButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "delete.left.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(keyBackground, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Custom number pad (0 왼쪽 「완료」)

/// 시스템 numberPad 대체 — 하단 `[완료 | 0 | ⌫]`.
/// inputView는 텍스트필드마다 별도 인스턴스 필요(공유 시 키패드 미표시).
final class OSDNumberPadKeyboard: UIInputView {
    weak var targetField: UITextField?

    private let accentUIColor = UIColor(red: 1.0, green: 176 / 255, blue: 32 / 255, alpha: 1)
    private let padBackground = UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
    private let keyBackground = UIColor(red: 58 / 255, green: 58 / 255, blue: 60 / 255, alpha: 1)

    init() {
        let width = UIScreen.main.bounds.width
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 248), inputViewStyle: .keyboard)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if #available(iOS 17.0, *) {
            allowsSelfSizing = true
        }
        backgroundColor = padBackground
        buildKeys()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIScreen.main.bounds.width, height: 248)
    }

    /// 레이아웃·오토레이아웃 워밍업(첫 포커스 지연 완화). X/Y/run_id 필드 3개 + 여유 1.
    private static var retainedPads: [OSDNumberPadKeyboard] = []
    private static let poolCapacity = 4

    static func prewarm() {
        guard retainedPads.count < poolCapacity else { return }
        while retainedPads.count < poolCapacity {
            let pad = OSDNumberPadKeyboard()
            pad.setNeedsLayout()
            pad.layoutIfNeeded()
            retainedPads.append(pad)
        }
    }

    static func acquire() -> OSDNumberPadKeyboard {
        prewarm()
        if let pad = retainedPads.popLast() {
            pad.targetField = nil
            return pad
        }
        let pad = OSDNumberPadKeyboard()
        pad.setNeedsLayout()
        pad.layoutIfNeeded()
        return pad
    }

    private static var presentationPrewarmed = false

    /// UIKit inputView 첫 표시 지연 완화 — 윈도우가 있을 때 1회만 실행.
    static func prewarmPresentationIfNeeded() {
        guard !presentationPrewarmed else { return }
        presentationPrewarmed = true

        guard
            let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
        else { return }

        let field = UITextField(frame: CGRect(x: -200, y: -200, width: 1, height: 1))
        field.alpha = 0.01
        field.isUserInteractionEnabled = false
        let pad = acquire()
        pad.targetField = field
        field.inputView = pad
        window.addSubview(field)

        UIView.performWithoutAnimation {
            field.becomeFirstResponder()
            field.reloadInputViews()
            field.resignFirstResponder()
        }
        field.removeFromSuperview()
        retainedPads.append(pad)
    }

    private func buildKeys() {
        let root = UIStackView()
        root.axis = .vertical
        root.spacing = 7
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        let side: CGFloat = 12
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: side),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -side),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            root.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -6),
        ])

        let rows: [[PadKey]] = [
            [.digit("1"), .digit("2"), .digit("3")],
            [.digit("4"), .digit("5"), .digit("6")],
            [.digit("7"), .digit("8"), .digit("9")],
            [.done, .digit("0"), .delete],
        ]

        for row in rows {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 7
            rowStack.distribution = .fillEqually
            for key in row {
                rowStack.addArrangedSubview(makeButton(for: key))
            }
            rowStack.heightAnchor.constraint(equalToConstant: 46).isActive = true
            root.addArrangedSubview(rowStack)
        }
    }

    private enum PadKey {
        case digit(String)
        case done
        case delete
    }

    private func makeButton(for key: PadKey) -> UIButton {
        let button = UIButton(type: .system)
        button.backgroundColor = keyBackground
        button.layer.cornerRadius = 5
        button.titleLabel?.font = .systemFont(ofSize: 24, weight: .regular)

        switch key {
        case .digit(let value):
            button.setTitle(value, for: .normal)
            button.setTitleColor(.white, for: .normal)
            button.addTarget(self, action: #selector(digitTapped(_:)), for: .touchUpInside)
        case .done:
            button.setTitle("완료", for: .normal)
            button.setTitleColor(accentUIColor, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
            button.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        case .delete:
            button.setImage(UIImage(systemName: "delete.left.fill"), for: .normal)
            button.tintColor = .white
            button.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        }
        return button
    }

    @objc private func digitTapped(_ sender: UIButton) {
        guard let field = targetField, let digit = sender.title(for: .normal) else { return }
        field.insertText(digit)
        field.sendActions(for: .editingChanged)
    }

    @objc private func doneTapped() {
        targetField?.resignFirstResponder()
    }

    @objc private func deleteTapped() {
        guard let field = targetField else { return }
        field.deleteBackward()
        field.sendActions(for: .editingChanged)
    }
}

// MARK: - Keyboard fields

/// UIKit TextField. digitsOnly=true면 커스텀 숫자패드(0 왼쪽 완료), 아니면 시스템 키보드+좌측 완료 bar.
struct OSDDoneTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var keyboardType: UIKeyboardType = .numberPad
    var digitsOnly: Bool = false
    var isEnabled: Bool = true
    var textAlignment: NSTextAlignment = .right
    var onBeginEditing: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, digitsOnly: digitsOnly, onBeginEditing: onBeginEditing)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(frame: .zero)
        field.delegate = context.coordinator
        field.textAlignment = textAlignment
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        field.textColor = UIColor(OSDPalette.textPrimary)
        field.tintColor = UIColor(OSDPalette.accent)
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.returnKeyType = .done
        field.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        field.layer.cornerRadius = 6
        field.clipsToBounds = true
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)

        if digitsOnly {
            let pad = OSDNumberPadKeyboard.acquire()
            pad.targetField = field
            context.coordinator.numberPad = pad
            field.inputView = pad
        } else {
            field.keyboardType = keyboardType
            field.inputAccessoryView = Self.makeDoneAccessory(
                target: context.coordinator,
                action: #selector(Coordinator.doneTapped)
            )
        }

        context.coordinator.field = field
        context.coordinator.applyPlaceholder(placeholder, to: field)
        field.isEnabled = isEnabled
        field.isUserInteractionEnabled = isEnabled
        field.alpha = isEnabled ? 1 : 0.35
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.onBeginEditing = onBeginEditing
        context.coordinator.applyPlaceholder(placeholder, to: uiView)
        if uiView.text != text {
            uiView.text = text
        }
        let enabled = isEnabled
        if uiView.isEnabled != enabled {
            uiView.isEnabled = enabled
            uiView.isUserInteractionEnabled = enabled
            uiView.alpha = enabled ? 1 : 0.35
        }
    }

    private static var prewarmedDoneAccessory: UIToolbar?

    private static func makeDoneAccessory(target: Any, action: Selector) -> UIToolbar {
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44))
        toolbar.barStyle = .black
        toolbar.isTranslucent = true
        let done = UIBarButtonItem(
            title: "완료",
            style: .done,
            target: target,
            action: action
        )
        done.tintColor = UIColor(OSDPalette.accent)
        toolbar.items = [done, UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)]
        return toolbar
    }

    static func prewarmAccessoryBar() {
        guard prewarmedDoneAccessory == nil else { return }
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44))
        toolbar.barStyle = .black
        toolbar.isTranslucent = true
        toolbar.items = [
            UIBarButtonItem(title: "완료", style: .done, target: nil, action: nil),
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
        ]
        prewarmedDoneAccessory = toolbar
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var text: String
        let digitsOnly: Bool
        var onBeginEditing: (() -> Void)?
        weak var field: UITextField?
        var numberPad: OSDNumberPadKeyboard?

        init(text: Binding<String>, digitsOnly: Bool, onBeginEditing: (() -> Void)?) {
            _text = text
            self.digitsOnly = digitsOnly
            self.onBeginEditing = onBeginEditing
        }

        func applyPlaceholder(_ placeholder: String, to field: UITextField) {
            field.attributedPlaceholder = NSAttributedString(
                string: placeholder,
                attributes: [.foregroundColor: UIColor(OSDPalette.textTertiary)]
            )
        }

        func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
            textField.isUserInteractionEnabled
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if digitsOnly {
                numberPad?.targetField = textField
                textField.reloadInputViews()
            }
            onBeginEditing?()
        }

        @objc func doneTapped() {
            field?.resignFirstResponder()
        }

        @objc func editingChanged(_ sender: UITextField) {
            text = sender.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            guard digitsOnly else { return true }
            if string.isEmpty { return true }
            return string.allSatisfy(\.isNumber)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            text = textField.text ?? ""
            if digitsOnly {
                numberPad?.targetField = nil
            }
        }
    }
}

// MARK: - Reticle (기존 44pt 유지, 목업 형태)

struct OSDAmberReticle: View {
    var dashedRing: Bool = false

    private let size: CGFloat = 44
    private let accent = OSDPalette.accent
    private let outline = Color.black

    var body: some View {
        ZStack {
            ringStroke(lineWidth: 3.0, color: outline, dashed: dashedRing)
            ringStroke(lineWidth: 1.4, color: accent.opacity(0.95), dashed: dashedRing)

            outlinedBar(width: 1.4, height: size * 0.32)
            outlinedBar(width: size * 0.32, height: 1.4)

            ZStack {
                Circle()
                    .stroke(outline, lineWidth: 2.2)
                    .frame(width: 8, height: 8)
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
            }
            .shadow(color: OSDPalette.accent.opacity(0.55), radius: 6)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.35), radius: 2)
    }

    @ViewBuilder
    private func ringStroke(lineWidth: CGFloat, color: Color, dashed: Bool) -> some View {
        if dashed {
            Circle()
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: lineWidth, dash: [4, 5])
                )
                .frame(width: size * 0.64, height: size * 0.64)
        } else {
            Circle()
                .stroke(color, lineWidth: lineWidth)
                .frame(width: size * 0.64, height: size * 0.64)
        }
    }

    @ViewBuilder
    private func outlinedBar(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(outline)
                .frame(width: width + 1.6, height: height + 1.6)
            Rectangle()
                .fill(accent)
                .frame(width: width, height: height)
        }
    }
}

// MARK: - Readout (조준 화면)

struct OSDAimReadout: View {
    let horizontalDistance: Double
    let flatEquivalentDistance: Double
    let distanceAdjustment: Double
    let elevationDelta: Double
    let directionDegrees: Double
    let strokeGuidance: String
    var detailLines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.1fm 볼·홀 실거리", horizontalDistance))
                        .font(.system(size: 12.5))
                        .foregroundStyle(OSDPalette.textSecondary)
                        .monospacedDigit()
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(String(format: "%.1f", flatEquivalentDistance))
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(OSDPalette.accent)
                            .monospacedDigit()
                            .shadow(color: OSDPalette.accentMid, radius: 11)
                        Text("m")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(OSDPalette.textSecondary)
                    }
                    Text(adjustmentText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(OSDPalette.textSecondary)
                        .monospacedDigit()
                    Text(elevationText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(OSDPalette.textSecondary.opacity(0.7))
                }
                Spacer(minLength: 0)
                OSDAimCompass(degrees: directionDegrees)
            }

            Text(strokeGuidance)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(OSDPalette.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(OSDPalette.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(OSDPalette.accentMid, lineWidth: 1)
                )

            if !detailLines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(detailLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10.5))
                            .foregroundStyle(OSDPalette.textTertiary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private var adjustmentText: String {
        let direction = distanceAdjustment >= 0 ? "오르막 보정" : "내리막 보정"
        return String(format: "%+.1fm %@", distanceAdjustment, direction)
    }

    private var elevationText: String {
        if abs(elevationDelta) < 0.005 {
            return "볼과 홀이 같은 높이"
        }
        return elevationDelta > 0
            ? String(format: "홀이 볼보다 %.2fm 높음", elevationDelta)
            : String(format: "홀이 볼보다 %.2fm 낮음", abs(elevationDelta))
    }
}

struct OSDAimCompass: View {
    let degrees: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.35))
            Circle()
                .strokeBorder(OSDPalette.glassBorder, lineWidth: 1)
            Rectangle()
                .fill(Color.white)
                .frame(width: 2.4, height: 20)
                .offset(y: -10)
                .rotationEffect(.degrees(degrees))
                .shadow(color: Color.white.opacity(0.45), radius: 6)
            Text("H")
                .font(.system(size: 7))
                .foregroundStyle(OSDPalette.textSecondary)
                .offset(y: -22)
            Text(String(format: "%+.1f°", degrees))
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(OSDPalette.accent)
                .monospacedDigit()
                .offset(y: 18)
        }
        .frame(width: 56, height: 56)
    }
}

struct OSDSpeedCorridorSection: View {
    let corridorIndex: Int
    let corridorCount: Int
    let overrunDistance: Double?
    let isComputing: Bool
    let isApplying: Bool
    let statusMessage: String
    let onSelectIndex: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("스피드 코리도")
                    .font(.system(size: 13.5, weight: .heavy))
                    .foregroundStyle(OSDPalette.textPrimary)
                Spacer()
                if corridorCount >= 1, let overrunDistance {
                    Text(
                        String(
                            format: "오버런 %.2fm · %d/%d",
                            overrunDistance,
                            min(corridorIndex + 1, corridorCount),
                            corridorCount
                        )
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(OSDPalette.textSecondary)
                    .monospacedDigit()
                }
            }

            HStack(spacing: 8) {
                Text("안전")
                    .font(.system(size: 10.5))
                    .foregroundStyle(OSDPalette.textSecondary)
                if corridorCount <= 1 {
                    Slider(value: .constant(0), in: 0...1)
                        .tint(OSDPalette.accent)
                        .disabled(true)
                        .opacity(0.45)
                } else {
                    Slider(
                        value: Binding(
                            get: { Double(corridorIndex) },
                            set: { onSelectIndex(Int($0.rounded())) }
                        ),
                        in: 0...Double(max(corridorCount - 1, 0)),
                        step: 1
                    )
                    .tint(OSDPalette.accent)
                    .disabled(isComputing || isApplying)
                }
                Text("공격적")
                    .font(.system(size: 10.5))
                    .foregroundStyle(OSDPalette.textSecondary)
            }

            if corridorCount <= 1 {
                Text(corridorCount == 0 ? "후보 없음" : "이 그린은 후보가 1개뿐")
                    .font(.system(size: 10.5))
                    .foregroundStyle(OSDPalette.accent.opacity(0.85))
            }

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(OSDPalette.textTertiary)
            }
        }
    }
}

// MARK: - Settings sheet controls

struct OSDSegmentedRow<Option: Hashable>: View {
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = selection == option
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.system(size: 11, weight: selected ? .heavy : .regular))
                        .foregroundStyle(selected ? OSDPalette.accentInk : OSDPalette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(selected ? OSDPalette.accent : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OSDPalette.glassBorder, lineWidth: 1))
    }
}

struct OSDPillRow: View {
    let labels: [String]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                let selected = index == selectedIndex
                Button {
                    onSelect(index)
                } label: {
                    Text(label)
                        .font(.system(size: 10.8, weight: selected ? .heavy : .regular))
                        .foregroundStyle(selected ? OSDPalette.accentInk : OSDPalette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(selected ? OSDPalette.accent : Color.clear, in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(selected ? Color.clear : OSDPalette.glassBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct OSDSettingsSectionGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(OSDPalette.textPrimary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(OSDPalette.glassBorder, lineWidth: 1)
        )
    }
}

struct OSDSettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(OSDPalette.textPrimary)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(OSDPalette.accent)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(OSDPalette.glassHair).frame(height: 1)
        }
    }
}

struct OSDSettingsKVRow: View {
    let title: String
    let value: String
    var valueColor: Color = OSDPalette.accent
    var showsMenuIndicator: Bool = false

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(OSDPalette.textPrimary)
            Spacer()
            HStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(valueColor)
                    .monospacedDigit()
                if showsMenuIndicator {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(OSDPalette.textTertiary)
                }
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(OSDPalette.glassHair).frame(height: 1)
        }
    }
}

struct OSDSettingsMenuRow<Option: Hashable>: View {
    let title: String
    let options: [Option]
    let optionLabel: (Option) -> String
    @Binding var selection: Option
    var disabled: Bool = false

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(optionLabel(option), systemImage: "checkmark")
                    } else {
                        Text(optionLabel(option))
                    }
                }
            }
        } label: {
            OSDSettingsKVRow(
                title: title,
                value: optionLabel(selection),
                showsMenuIndicator: true
            )
        }
        .disabled(disabled)
    }
}

struct OSDGreenSpeedStepper: View {
    let value: Double
    let onDecrement: () -> Void
    let onIncrement: () -> Void
    let canDecrement: Bool
    let canIncrement: Bool

    var body: some View {
        HStack {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(String(format: "%.1f", value))
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(OSDPalette.accent)
                    .monospacedDigit()
                Text("m")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OSDPalette.textSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("0.1m 단위")
                    .font(.system(size: 9.5))
                    .foregroundStyle(OSDPalette.textTertiary)
                HStack(spacing: 0) {
                    Button(action: onDecrement) {
                        Text("−")
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundStyle(OSDPalette.accent)
                            .frame(width: 32, height: 32)
                    }
                    .disabled(!canDecrement)
                    Rectangle().fill(OSDPalette.glassBorder).frame(width: 1, height: 32)
                    Button(action: onIncrement) {
                        Text("+")
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundStyle(OSDPalette.accent)
                            .frame(width: 32, height: 32)
                    }
                    .disabled(!canIncrement)
                }
                .background(Color.white.opacity(0.05), in: Capsule())
                .overlay(Capsule().strokeBorder(OSDPalette.glassBorder, lineWidth: 1))
            }
        }
    }
}

// MARK: - Helpers

private struct RoundedCornerShape: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
