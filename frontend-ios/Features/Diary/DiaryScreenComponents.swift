import SwiftUI
func macroColor(_ kind: DiaryMacroKind) -> Color {
    switch kind {
    case .protein: return .pink
    case .carbs: return .blue
    case .fat: return .yellow
    }
}

// Pairs a compact horizontal row with a full-width vertical fallback. At
// accessibility text sizes the vertical branch is always used so labels stay
// readable as whole words; otherwise ViewThatFits keeps the original horizontal
// row whenever its intrinsic text fits, leaving the default layout untouched.
//
// Each horizontal-branch child is pinned to its one-line intrinsic width with
// .fixedSize(horizontal: true, vertical: false). Without that, wrapping/compressing
// text lets the HStack "fit" at any width, so ViewThatFits would never reach the
// vertical fallback at narrow widths, long locales or large non-AX text. The
// Spacer still expands to fill the row when the horizontal branch is chosen,
// so the default side-by-side layout is unchanged.
/// Passive native progress styling: a thick rounded track and fill instead of
/// the platform's ~2pt linear bar. `ProgressView` keeps its value/label
/// accessibility; the style only draws the geometry, with no interaction.
struct BriefCapsuleProgressStyle: ProgressViewStyle {
    let fraction: Double
    let color: Color
    let height: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { proxy in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * clamped)
            }
        }
        .frame(height: height)
    }
}

struct AdaptiveLabeledRow<Horizontal: View, Vertical: View>: View {
    let accessibilityLayout: Bool
    let horizontal: Horizontal
    let vertical: Vertical

    init(
        _ accessibilityLayout: Bool,
        @ViewBuilder horizontal: () -> Horizontal,
        @ViewBuilder vertical: () -> Vertical
    ) {
        self.accessibilityLayout = accessibilityLayout
        self.horizontal = horizontal()
        self.vertical = vertical()
    }

    var body: some View {
        if accessibilityLayout {
            vertical
        } else {
            ViewThatFits(in: .horizontal) {
                horizontal
                vertical
            }
        }
    }
}

struct MealArtHeader: View {
    let slot: MealSlot
    let title: String
    let calories: Double

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var usesAccessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    private var assetName: String {
        switch slot {
        case .breakfast: return "breakfast"
        case .lunch: return "lunch"
        case .dinner: return "dinner"
        case .snack: return "snacks"
        case .lateNightSnack: return "late-night-snack"
        }
    }

    private var imageAspect: CGFloat {
        switch slot {
        case .breakfast: return 3432.0 / 364.0
        case .lunch: return 3432.0 / 382.0
        case .dinner: return 3432.0 / 380.0
        case .snack: return 3434.0 / 374.0
        case .lateNightSnack: return 3432.0 / 382.0
        }
    }

    private var focusX: CGFloat {
        switch slot {
        case .breakfast: return 0.13
        case .lunch: return 0.50
        case .dinner: return 0.47
        case .snack: return 0.82
        case .lateNightSnack: return 0.73
        }
    }

    private var caloriesText: String {
        "\(DiaryValueFormat.amount(calories)) kcal"
    }

    var body: some View {
        AdaptiveLabeledRow(
            usesAccessibilityLayout,
            horizontal: {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    Text(caloriesText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)
                }
            },
            vertical: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(caloriesText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        )
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 80)
        .background {
            artBackground
        }
        .clipped()
    }

    // One continuous, clipped artwork surface covering the entire header,
    // sized at the asset's true aspect ratio and large enough to cover BOTH
    // container axes: on wide iPad columns width dominates, on accessibility-
    // tall headers height dominates. No letterboxing, stretching or tiling.
    private var artBackground: some View {
        GeometryReader { geo in
            let containerWidth = geo.size.width
            let containerHeight = geo.size.height
            let renderedWidth = max(containerWidth, containerHeight * imageAspect)
            let renderedHeight = renderedWidth / imageAspect
            // Bring the web focus point toward the horizontal centre, then pin
            // the leading edge into [containerWidth - renderedWidth, 0] so the
            // art always spans the full width with no uncovered band.
            let focusedLeading = containerWidth / 2 - focusX * renderedWidth
            let leadingOffset = min(0, max(focusedLeading, containerWidth - renderedWidth))
            let verticalOffset = (containerHeight - renderedHeight) / 2

            Image(assetName)
                .resizable()
                .scaledToFill()
                .frame(width: renderedWidth, height: renderedHeight)
                .offset(x: leadingOffset, y: verticalOffset)
                .frame(width: containerWidth, height: containerHeight, alignment: .topLeading)
                .clipped()
                .overlay {
                    // The white title/total are vertically centred in the
                    // header, above the old bottom-only scrim (~0.27 opacity at
                    // the text, fading to 0 at the top). On bright breakfast /
                    // lunch skies that leaves white-on-light text with weak
                    // contrast, and the full-width cover can place the total
                    // over open sky. Keep a continuous gradient with a ~0.35
                    // floor so the whole text band is legible while the art
                    // (sun, clouds, hills) stays clearly identifiable: no
                    // faux panel, no band, no extra rounding.
                    LinearGradient(
                        colors: [.black.opacity(0.55), .black.opacity(0.35)],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                    .allowsHitTesting(false)
                }
        }
    }
}
