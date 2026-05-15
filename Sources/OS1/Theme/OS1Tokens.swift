import SwiftUI

/// Static-shorthand accessors for the standard OS1 palette and typography.
///
/// `@Environment(\.os1Theme)` remains the canonical way to read tokens —
/// it's how shared components in `HermesUI.swift` and `OS1Controls.swift`
/// pick them up. But for view-level styling sweeps, threading `theme.*`
/// into every Swift struct adds a lot of boilerplate. Since we only ship
/// one theme today (and likely tomorrow), these statics let view code
/// write `.foregroundStyle(.os1OnCoralSecondary)` and `.font(.os1Body)`
/// without an Environment hop. The values are pulled from
/// `OS1Theme.standard`, so a future theme swap would still flip every
/// site that uses the Environment, and these statics can be migrated
/// then.
extension Color {
    private static let _palette = OS1Palette.standard

    static var os1Coral: Color           { _palette.coral }
    static var os1Coral500: Color        { _palette.coral500 }
    static var os1Coral400: Color        { _palette.coral400 }
    static var os1Coral300: Color        { _palette.coral300 }
    static var os1Coral600: Color        { _palette.coral600 }

    static var os1BgCream: Color         { _palette.bgCream }
    static var os1BgBeige: Color         { _palette.bgBeige }

    static var os1OnCoralPrimary: Color   { _palette.onCoralPrimary }
    static var os1OnCoralSecondary: Color { _palette.onCoralSecondary }
    static var os1OnCoralMuted: Color     { _palette.onCoralMuted }

    static var os1OnCreamPrimary: Color   { _palette.onCreamPrimary }
    static var os1OnCreamSecondary: Color { _palette.onCreamSecondary }
    static var os1OnCreamMuted: Color     { _palette.onCreamMuted }

    static var os1GlassFill: Color        { _palette.glassFill }
    static var os1GlassBorder: Color      { _palette.glassBorder }
    static var os1GlassFillHover: Color   { _palette.glassFillHover }
    static var os1GlassBorderHover: Color { _palette.glassBorderHover }

    static var os1DarkOverlay: Color      { _palette.darkOverlay }

    static var os1IconWarm: Color         { _palette.iconWarm }
    static var os1IconTan: Color          { _palette.iconTan }
}

extension Font {
    private static let _typography = OS1Typography.standard

    static var os1TitleHero: Font     { _typography.titleHero.font }
    static var os1TitleSection: Font  { _typography.titleSection.font }
    static var os1TitlePanel: Font    { _typography.titlePanel.font }
    static var os1Body: Font          { _typography.body.font }
    static var os1BodyEmphasis: Font  { _typography.bodyEmphasis.font }
    static var os1Label: Font         { _typography.label.font }
    static var os1SmallCaps: Font     { _typography.smallCaps.font }
}

/// Mirror the Color statics on ShapeStyle so `.foregroundStyle(.os1...)`
/// dot syntax resolves correctly. SwiftUI looks up the dot-prefix on the
/// expected ShapeStyle type, not Color, so without these extensions
/// `.foregroundStyle(.os1OnCoralPrimary)` fails to compile.
extension ShapeStyle where Self == Color {
    static var os1Coral: Color           { .os1Coral }
    static var os1Coral500: Color        { .os1Coral500 }
    static var os1Coral400: Color        { .os1Coral400 }
    static var os1Coral300: Color        { .os1Coral300 }
    static var os1Coral600: Color        { .os1Coral600 }

    static var os1BgCream: Color         { .os1BgCream }
    static var os1BgBeige: Color         { .os1BgBeige }

    static var os1OnCoralPrimary: Color   { .os1OnCoralPrimary }
    static var os1OnCoralSecondary: Color { .os1OnCoralSecondary }
    static var os1OnCoralMuted: Color     { .os1OnCoralMuted }

    static var os1OnCreamPrimary: Color   { .os1OnCreamPrimary }
    static var os1OnCreamSecondary: Color { .os1OnCreamSecondary }
    static var os1OnCreamMuted: Color     { .os1OnCreamMuted }

    static var os1GlassFill: Color        { .os1GlassFill }
    static var os1GlassBorder: Color      { .os1GlassBorder }
    static var os1GlassFillHover: Color   { .os1GlassFillHover }
    static var os1GlassBorderHover: Color { .os1GlassBorderHover }

    static var os1DarkOverlay: Color      { .os1DarkOverlay }

    static var os1IconWarm: Color         { .os1IconWarm }
    static var os1IconTan: Color          { .os1IconTan }
}
