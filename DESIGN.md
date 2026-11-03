# InFocus Drive Design

Drive's web UI uses the **Blackletter** structure with **InFocus Green** as its one accent color: a true-black canvas, off-white ink, depth built from luminance steps and translucent hairlines, Geist for the interface, Geist Serif for big display type, and Geist Mono for data. The InFocus wordmark stays as the logo. The native Mac and iOS apps still follow the InFocus Design System 2026 (Portal [DESIGN.md](https://github.com/neelsatyavolu/infocus-portal/blob/master/DESIGN.md)).

Tokens live at the top of `app/static/app.css`. Updated November 2, 2026.

## Color

| Role | Token | Dark / light | Use |
| --- | --- | --- | --- |
| Canvas | `--background` | `#000000` / `#FCFCFD` | Page and sidebar background (`--sb-bg`). |
| Card | `--card` | `#0A0A0C` / `#FFFFFF` | Cards, inputs, list surfaces. |
| Elevated | `--popover`, `--secondary`, `--muted` | `#111114` / `#F4F5F7` | Menus, modals, toasts, the upload tray, ghost buttons, hover fills. |
| Ink | `--foreground` | `#FCFDFF` / `#0A0A0C` | Primary text. The primary button is an ink fill with canvas text. |
| Body | `--mist` | ink at 86% | Secondary text and long prose. |
| Mute | `--muted-foreground` | `#A1A4A5` / `#5F6366` | Meta, captions, labels. |
| Hairlines | `--line`, `--line-2` (`--border` is the opaque `--line-2`) | white 6% and 14% / black 6% and 12% | Row dividers; card, input and popover borders. |
| Field border | `--input` | 3:1 against the canvas | Text inputs. |
| Accent | `--brand-green` | `#2BB36E` / `#0B6E3E` | Links, focus, selected and active marks, icons. |
| Accent fill | `--brand-fill`, `--brand-fill-hover`, `--on-brand` | `#0B6E3E` | `.btn--accent` and progress bars only. |
| Accent tint | `--accent`, `--brand-green-a10…a30`, `--focus-ring` | | Selected rows, active nav items, focus rings, inline code. |
| Danger | `--danger`, `--danger-text`, `--danger-tint`, `--danger-a12/-a18/-a40` | | Errors and destructive actions. A solid fill only on a final confirm. |
| Warn | `--brand-amber` | | Warnings. |
| Record Red | `--brand-red` | `#EE3A2A` | A tiny rec/live dot only. |

Keep green under about 3% of any screen. Selected and active states are a green tint with ink or green text, not solid green bands. The semantic HSL triplets (`--background`, `--border`, …) are defined under `:root` for the dark theme and under `.light` for the light theme, and the sidebar has its own `--sb-*` tokens in each theme. When adding a color, use these tokens instead of new literals.

## Type

- **Geist** (`--font-sans`, `--font-display`) for everything people read. Body weight is 400 and headings are 500. Emphasis is a color step (body to ink), not weight. Labels are 12px sentence case in the mute color, with no all-caps tracking.
- **Geist Serif** (`--font-serif`) only for display text at 40px and larger (the sign-in headline), weight 400, line-height 1.0, `-0.02em`. It isn't on Google Fonts, so it is self-hosted as `geist-serif.woff2` (SIL OFL) and preloaded from `index.html`. The CLI sign-in page's CSP only allows Google Fonts, so it doesn't use the serif.
- **Geist Mono** (`--font-mono`) only for data: sizes, dates in columns, durations, progress, speeds, IDs. Numbers in columns use `tabular-nums`.
- Geist and Geist Mono load from Google Fonts via `<link>` in each HTML page. There are no italics in the UI, except rendered Markdown.

## Shape, depth, motion

- Radii: `--radius` (8px) for buttons, inputs, rows and menu items; `--radius-lg` (12px) for cards, panels, modals, menus, toasts and the upload tray; `--radius-sm` (6px) for small chips and thumbnails; full for pills, dots, avatars and toggles.
- Depth comes from luminance steps (canvas, card, elevated) plus a 1px `--line-2` border. There are no box-shadows (except focus rings), gradients, glass or blur. Scrims over media are flat translucent black.
- Code blocks are dark wells (`#06060A`) in both themes.
- Motion uses `--ease-out` (`cubic-bezier(0.2, 0, 0, 1)`): 150ms for hover and focus, 250ms for enter, and enter animations are an 8px rise with a fade.

## Brand assets

All in `app/static/`, served from `/assets/`:

| File | Use |
| --- | --- |
| `infocus-wordmark.png` | Wordmark with light letters, for the dark theme |
| `infocus-wordmark-light.png` | Wordmark with ink letters and deep green, for the light theme |
| `favicon-32.png` | Browser tab icon (the "o" mark on a rounded ink tile) |
| `apple-touch-icon.png` | Home-screen icon (the "o" mark on a square ink tile) |
| `geist-serif.woff2` | Geist Serif variable font |

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

`/assets/*` is served with `Cache-Control: immutable` for a year. When a CSS, JS, font or image file changes, bump its `?v=` on every reference (`index.html`, `share.html`, `cli-authorize.html`, `app.css` for the font, and module imports) or browsers keep the old file.
