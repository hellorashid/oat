import SwiftUI

struct OatGlassContainer<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder
    func oatGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func oatGlass() -> some View {
        oatGlass(in: Capsule())
    }

    @ViewBuilder
    func oatGlass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// Frosted window fill. Liquid Glass is for floating chrome/controls, not a sibling behind content —
    /// that samples empty space and renders black. A window material is the system-supported backdrop.
    @ViewBuilder
    func oatWindowGlass() -> some View {
        if #available(macOS 15.0, *) {
            containerBackground(.thickMaterial, for: .window)
        } else {
            background(.thickMaterial)
        }
    }
}
