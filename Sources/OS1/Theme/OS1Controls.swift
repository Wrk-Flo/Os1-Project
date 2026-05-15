import SwiftUI

// MARK: - Button styles

/// The canonical OS1 button — glass capsule on the coral surface with
/// white smallCaps text. Use for primary actions (Save, Connect, Verify).
struct OS1PrimaryButtonStyle: ButtonStyle {
    @Environment(\.os1Theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .os1Style(theme.typography.smallCaps)
            .foregroundStyle(theme.palette.onCoralPrimary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(configuration.isPressed
                          ? theme.palette.glassFillHover
                          : theme.palette.glassFill)
            )
            .overlay {
                Capsule()
                    .strokeBorder(configuration.isPressed
                                  ? theme.palette.glassBorderHover
                                  : theme.palette.glassBorder,
                                  lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Outline button for less-prominent actions (Cancel, Skip, Dismiss).
/// Borderless on the coral surface with white text.
struct OS1SecondaryButtonStyle: ButtonStyle {
    @Environment(\.os1Theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .os1Style(theme.typography.smallCaps)
            .foregroundStyle(configuration.isPressed
                             ? theme.palette.onCoralPrimary
                             : theme.palette.onCoralSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Subtle borderless icon button (close X, refresh circle, expand caret).
/// Tinted with onCoralSecondary, brightens on press.
struct OS1IconButtonStyle: ButtonStyle {
    @Environment(\.os1Theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed
                             ? theme.palette.onCoralPrimary
                             : theme.palette.onCoralSecondary)
            .padding(6)
            .background(
                Circle()
                    .fill(configuration.isPressed
                          ? theme.palette.glassFill
                          : Color.clear)
            )
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == OS1PrimaryButtonStyle {
    static var os1Primary: OS1PrimaryButtonStyle { OS1PrimaryButtonStyle() }
}

extension ButtonStyle where Self == OS1SecondaryButtonStyle {
    static var os1Secondary: OS1SecondaryButtonStyle { OS1SecondaryButtonStyle() }
}

extension ButtonStyle where Self == OS1IconButtonStyle {
    static var os1Icon: OS1IconButtonStyle { OS1IconButtonStyle() }
}

// MARK: - Text input

/// OS-1's `.text-input` pattern: transparent fill, single hairline at the
/// bottom, white-on-coral text. Border brightens on focus. Apply with
/// `.os1Underlined()` on any `TextField` / `SecureField`.
extension View {
    func os1Underlined() -> some View {
        modifier(OS1UnderlinedFieldModifier())
    }
}

private struct OS1UnderlinedFieldModifier: ViewModifier {
    @Environment(\.os1Theme) private var theme
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused($isFocused)
            .os1Style(theme.typography.body)
            .foregroundStyle(theme.palette.onCoralPrimary)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isFocused
                          ? theme.palette.glassBorderHover
                          : theme.palette.glassBorder)
                    .frame(height: 1)
            }
    }
}

// MARK: - Glass surface modifier (for one-off chrome)

/// Quick glass surface — translucent white fill + hairline border on
/// the current shape. Use inline for picker rows, drop targets, etc.
extension View {
    func os1GlassSurface(cornerRadius: CGFloat = 8, hover: Bool = false) -> some View {
        modifier(OS1GlassSurfaceModifier(cornerRadius: cornerRadius, hover: hover))
    }
}

private struct OS1GlassSurfaceModifier: ViewModifier {
    @Environment(\.os1Theme) private var theme

    let cornerRadius: CGFloat
    let hover: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(hover ? theme.palette.glassFillHover : theme.palette.glassFill)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(hover ? theme.palette.glassBorderHover : theme.palette.glassBorder,
                                  lineWidth: 1)
            }
    }
}
