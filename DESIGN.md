# InFocus Drive Design

Drive follows the **InFocus Design System 2026**, the same system as InFocus Portal. The full brand rules (logo, color, type, shape, motion, and the web guidance) are in the Portal's [DESIGN.md](https://github.com/neelsatyavolu/infocus-portal/blob/master/DESIGN.md), especially §10 (web and interfaces) and §13 (token reference). This file covers how Drive implements them: tokens, the light theme, the wordmark swap, and cache-busting.

Tokens live at the top of `app/static/app.css`. Updated September 26, 2026.

## Color

| Brand color | Token | Use |
| --- | --- | --- |
| Ink `#0F110F` | `--background` (dark), `--ink` (flips), `--sb-bg` | Page and sidebar canvas. `--card` / `--secondary` / `--muted` are slightly raised Ink. |
| InFocus Green `#0B6E3E` | `--brand-fill` (`--primary`) | Primary buttons, active and selected states, header bands. Always white text (`--on-brand`). Hover `--brand-fill-hover`. |
| Green on Dark `#2BB36E` | `--brand-green` (flips to `#0B6E3E` in light) | Text, links, icons, small marks. Tints `--brand-green-a10…a30` are fine; never a solid large fill. |
| Record Red `#EE3A2A` | `--brand-red` | A tiny rec/live dot only. Never text, buttons, or errors. |
| Mist `#DCE2DE` | `--mist` | Secondary text on dark. |
| Danger `#C21F3A` | `--danger` | Destructive fills with white text, only on a final confirm. |
| Danger on Dark `#FF7A8A` | `--danger-text` (flips to `#C21F3A`) | Error text, icons, borders; quiet destructive buttons. |
| Danger tints | `--danger-tint`, `--danger-a12/-a18/-a40` | Error banners and hover tints. |

Semantic HSL triplets (`--background`, `--primary`, `--border`, …) are defined under `:root` for the dark theme and under `.light` for the light theme. Both use the same values as InFocus Portal. The sidebar has its own `--sb-*` tokens in each theme. When adding a color, use these tokens instead of new literals.

## Type, shape, motion

- **Lexend** (`--font-sans`, `--font-display`) for everything people read: headings in SemiBold with tight tracking, body in Regular, labels in ALL CAPS Medium with wide tracking. **Geist Mono** (`--font-mono`) is only for data: sizes, dates in columns, durations, progress, speeds, IDs. Both load from Google Fonts via `<link>` in each HTML page.
- There are no italics in the UI, except rendered Markdown.
- One small radius, `--radius` (6px; `--radius-sm` is 4px), is used everywhere. Circles are only for avatars, dots, spinners, and toggles.
- The arc corner (`--arc`, 24px on phones and 32px from 640px) is one curved top corner with the others square. It appears on just a few plate pieces and on the active sidebar item.
- Everything is flat: no gradients, drop shadows, glass, or blur.
- Transitions run 150–300ms on `--ease-out`.

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
