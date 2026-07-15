import SwiftUI

extension View {
    /// Marks a mock layout as a loading placeholder: redacts the content and
    /// takes it out of hit-testing and VoiceOver. Put `.pulsePlaceholder(delay:)`
    /// on the individual rows so they fade one after another.
    func placeholderContainer() -> some View {
        redacted(reason: .placeholder)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// A gentle repeating opacity fade so a placeholder reads as "loading".
    /// `delay` staggers the start so a stack of rows fades element by element.
    func pulsePlaceholder(delay: Double = 0) -> some View {
        modifier(PulsePlaceholder(delay: delay))
    }
}

/// Placeholder rows (avatar dot + name bar) shown while a list of entities
/// loads — shared by the entity list and the child/reference tables so they
/// look identical. Plain grey bars (no fabricated text), fading row by row.
struct EntityRowsPlaceholder: View {
    var count = 6
    var avatarSize: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: 12) {
                    Circle()
                        .fill(.fill.secondary)
                        .frame(width: avatarSize, height: avatarSize)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.fill.secondary)
                        .frame(width: 150 - CGFloat(index % 3) * 34, height: 11)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .pulsePlaceholder(delay: Double(index) * 0.12)
            }
            Spacer()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Grouped-form placeholder (label bar + value bar per rounded row) shown
/// while a `.formStyle(.grouped)` sheet loads. Fades row by row.
struct FormPlaceholder: View {
    var rows = 5

    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<rows, id: \.self) { index in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.fill.secondary)
                        .frame(width: 90, height: 11)
                    Spacer()
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.fill.secondary)
                        .frame(width: 150 - CGFloat(index % 3) * 34, height: 11)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 15)
                .background(RoundedRectangle(cornerRadius: 10).fill(.fill.quaternary))
                .pulsePlaceholder(delay: Double(index) * 0.1)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Dashboard usage-stats placeholder — four stat-tile skeletons in the same
/// adaptive grid as the real tiles. Fades tile by tile.
struct StatsPlaceholder: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], spacing: 10) {
            ForEach(0..<4, id: \.self) { index in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.fill.secondary)
                        .frame(width: 60, height: 10)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.fill.secondary)
                        .frame(width: 90, height: 22)
                    Capsule()
                        .fill(.fill.secondary)
                        .frame(height: 4)
                        .padding(.top, 8)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.fill.secondary)
                        .frame(width: 80, height: 9)
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .background(Color("CardBackground"), in: RoundedRectangle(cornerRadius: 16))
                .pulsePlaceholder(delay: Double(index) * 0.12)
            }
        }
        .frame(maxWidth: 640)
        .padding(32)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PulsePlaceholder: ViewModifier {
    let delay: Double
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.35 : 0.9)
            .animation(
                .easeInOut(duration: 0.8).delay(delay).repeatForever(autoreverses: true),
                value: dim
            )
            .onAppear { dim = true }
    }
}
