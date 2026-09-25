# InFocus Drive Design

Colors and brand assets for InFocus Drive. Drive shares the InFocus design system with InFocus Portal; typography, spacing, and component recipes are in the Portal's [DESIGN.md](https://github.com/neelsatyavolu/infocus-portal/blob/master/DESIGN.md). This file covers the palette and what is specific to Drive: the light theme, the wordmark swap, and cache-busting.

Tokens live in `app/static/app.css`. Updated September 25, 2026 for the new InFocus logo.

## Logo palette

Exact colors from the logo files. Every other brand color is derived from them.

| Name | Hex | Where it appears in the logo |
| --- | --- | --- |
| Logo green | `#2BB36E` | "in" and the "o" ring on dark backgrounds |
| Logo deep green | `#0B6E3E` | "in" and the "o" ring on light backgrounds |
| Logo red | `#EE3A2A` | The dot over the "i" (always red) |
| Logo ink | `#0F110F` | "focus" and the signal arcs on light backgrounds; the app-icon tile |
| White | `#FFFFFF` | "focus" and the signal arcs on dark backgrounds |

| Background | Green | Letters and arcs | Dot |
| --- | --- | --- | --- |
| Dark theme | `#2BB36E` | `#FFFFFF` | `#EE3A2A` |
| Light theme | `#0B6E3E` | `#0F110F` | `#EE3A2A` |

## Contrast

| Pair | Ratio | Use |
| --- | --- | --- |
| Ink `#0A0A0A` on logo green `#2BB36E` | 7.3:1 | Green buttons in the dark theme. Dark text on green. |
| White on logo green | 2.7:1 | Avoid for text. |
| Logo green on ink | 7.3:1 | Green text and icons in the dark theme. |
| Logo red `#EE3A2A` on ink | 5.0:1 | Red text and icons in the dark theme. |
| White on deep red `#C92B1D` | 5.5:1 | Filled red controls. White on logo red is only 4.0:1. |
| Logo deep green `#0B6E3E` on white | 6.3:1 | Green text on light backgrounds. |
| Logo green on white | 2.7:1 | Avoid for text on light backgrounds. |

## Tokens

| Token | Value | Use |
| --- | --- | --- |
| `--brand-green` | `#2bb36e` | Logo green |
| `--brand-green-deep` | `#23955c` | Hover and pressed green |
| `--brand-red` | `#ee3a2a` | Logo red |
| `--brand-red-deep` | `#c92b1d` | Red fills with white text |
| `--brand-amber` | `#f2a516` | Warnings |
| `--brand-green-a10` … `-a30` | `rgb(43 179 110 / α)` | Green tints |
| `--brand-red-a12` … `-a40` | `rgb(238 58 42 / α)` | Red tints |

Semantic HSL triplets (`--background`, `--primary`, `--border`, …) are defined twice: under `:root` for the dark theme and under `.light` for the light theme. The dark values match InFocus Portal exactly. `--primary` is `150 61% 43.5%` (the logo green) in both themes.

Neutrals carry a faint green tint from the logo ink instead of the old blue-gray. Dark-theme tokens use the Portal's values (hue 120, 4–6% saturation). Light-theme tokens, sidebar `--sb-*` tokens, and literal grays use half that tint, because green reads more strongly than blue at mid and light grays.

When adding a color, derive it from the logo palette. Use the RGB tints above for translucent fills and borders rather than new literals.

## Brand assets

All in `app/static/`, served from `/assets/`:

| File | Use |
| --- | --- |
| `infocus-wordmark.png` | Wordmark with white letters, for the dark theme |
| `infocus-wordmark-light.png` | Wordmark with ink letters and deep green, for the light theme |
| `favicon-32.png` | Browser tab icon (the "o" mark on a rounded ink tile) |
| `apple-touch-icon.png` | Home-screen icon (the "o" mark on a square ink tile) |

Both wordmarks share one 480×206 canvas, so the `width`/`height` attributes on the `<img>` tags stay the same.

Pages that support the light theme render both wordmarks and let CSS pick one:

```html
<img class="wm-dark" src="/assets/infocus-wordmark.png?v=…" alt="InFocus" width="70" height="30" decoding="async" />
<img class="wm-light" src="/assets/infocus-wordmark-light.png?v=…" alt="InFocus" width="70" height="30" loading="lazy" decoding="async" />
```

```css
html:not(.light) .wm-light,
html.light .wm-dark {
  display: none;
}
```

`loading="lazy"` keeps the hidden light wordmark from downloading in the dark theme.

Do not recolor, stretch, or recreate the logo with text.

## Cache-busting

`/assets/*` is served with `Cache-Control: immutable` for a year. When a CSS, JS, or image file changes, bump its `?v=` on every reference (`index.html`, `share.html`, `cli-authorize.html`, and module imports) or browsers keep the old file.
