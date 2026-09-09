# Design QA — Home forecast and insights

## Evidence

- Source visual truth: `/var/folders/xp/rywx8z4s1d331273fq23fjv00000gn/T/TemporaryItems/NSIRD_screencaptureui_YOyPTV/Screenshot 2026-09-15 at 21.39.46.png`
- Implementation screenshot: `/tmp/moneva-home-equal-cards.png`
- Viewport: iPhone 17 Pro, 402 × 874 points, light appearance
- Source pixels: 1210 × 1702, including a photographed device frame
- Implementation pixels: 1206 × 2622 at 3× native Simulator density
- Normalization: compared at a common rendered width; device chrome and unrelated article/finance content were excluded from fidelity judgments
- State: Home, Personal scope, populated budget, forecast without enough history, no significant insight signals

## Full-view comparison

The requested two-column editorial composition is present: both cards have equal height, while Smart Insights begins 38 points lower and therefore ends lower. Rounded white cards, narrow columns, strong title hierarchy, short preview copy, and generous whitespace remain consistent with the reference. Moneva's existing warm background, semantic colors, shadows, corner radii, and floating actions remain intact.

## Focused card comparison

The full screenshots render both card regions large enough to assess typography, spacing, radii, icons, copy, and actions without a separate crop. The source's article photography is intentionally not reproduced because the requested cards contain financial data, not media.

## Findings

- No actionable P0, P1, or P2 differences.
- Typography intentionally keeps Moneva's system and serif hierarchy instead of adopting the reference app's font wholesale.
- Spacing and layout preserve the reference's equal-height, staggered two-column rhythm while fitting Moneva's existing Home margins.
- Colors use the existing `Palette` tokens in light/dark mode; no new color or gradient was introduced.
- SF Symbols remain sharp at native scale. No image assets are required for these finance previews.
- Copy is finance-specific and both cards expose a clear `View` affordance.

## Open Questions

- The existing scan and microphone controls overlap the right-hand card, similar to the floating compose control in the source. Their global placement is outside this scoped change, and the `View` action remains unobstructed.

## Interaction verification

- Financial Forecast preview opens its detailed forecast screen and returns through the system Back action.
- Smart Insights preview opens its detailed insights screen and returns through the system Back action.
- DEBUG app launch completed and ran the existing self-check path.

## Comparison history

- Pass 1: P2 — Financial Forecast was taller than Smart Insights and their lower edges aligned, which lost the reference's staggered rhythm.
- Fix: constrained both preview contents to the same 246-point height while retaining the existing 38-point top offset on Smart Insights.
- Pass 2 evidence: `/tmp/moneva-home-equal-cards.png` shows equal card heights with the right card beginning and ending lower; no actionable P0/P1/P2 findings remain.

## Implementation checklist

- [x] Preserve Moneva theme, fonts, and colors
- [x] Replace full Home sections with staggered preview cards
- [x] Keep both preview cards the same height
- [x] Add working detail navigation for both cards
- [x] Verify build, launch, visual state, and both routes

final result: passed
