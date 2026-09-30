---
name: antora-image-styling
description: >-
  Documents how Antora supplemental UI adds borders, shadows, and padding to
  images and videos so they pop against white backgrounds. Use when adding
  images, editing CSS, modifying supplemental-ui partials, or updating
  site.yml UI styling.
---

# Antora Image & Video Styling

## How It Works

All `image::` blocks in Asciidoc automatically get border styling via CSS
injected through Antora's supplemental UI system. No per-image roles or
classes (like `[.border]`) are needed.

## The CSS

Applied globally to every block image (`.doc .imageblock img`):

```css
.doc .imageblock img {
  border: 1px solid #c0c4ca;
  border-radius: 6px;
  box-shadow: 0 2px 6px rgba(0, 0, 0, 0.15);
  background-color: #f0f1f3;
  padding: 8px;
  width: auto !important;
  max-width: 100%;
  height: auto;
}
```

What each property does:
- **`border`** — subtle gray outline separates the image from the page
- **`border-radius`** — softly rounded corners
- **`box-shadow`** — light drop shadow for depth
- **`background-color`** — light gray pad behind the image so white-background screenshots don't bleed into the page
- **`padding`** — breathing room between image content and the border
- **`width/max-width/height`** — responsive sizing

Videos get a stronger treatment:

```css
video {
  border: solid 1px black;
  box-shadow: 0 4px 8px 0 rgba(0, 0, 0, 0.2),
              0 6px 20px 0 rgba(0, 0, 0, 0.19);
}
```

## Where the CSS Lives (3 places)

The same rules are defined in multiple locations for redundancy:

| File | Role |
|------|------|
| `site.yml` (inline `partials/head-styles.hbs`) | **Primary** — minified rules injected at build time; only place with responsive `width`/`max-width`/`height` |
| `content/supplemental-ui/partials/head-styles.hbs` | Supplemental partial (overridden by `site.yml` inline) |
| `content/supplemental-ui/partials/head-meta.hbs` | Inline `<style>` block in `<head>` |
| `content/supplemental-ui/css/site-extra.css` | Standalone stylesheet (same rules) |

**When editing styles, update `site.yml` first** — its inline `partials/head-styles.hbs` block takes precedence since Antora merges supplemental files with last-defined-wins. Then update the other files to keep them consistent.

## Adding Images in Asciidoc

No special roles or attributes are needed for styling. Just use standard Asciidoc:

```asciidoc
image::my-screenshot.png[align="center", width=600, link=self, window=blank]
```

Common attributes used in this repo:
- `align="center"` — centers the image block
- `width=600` — constrains width (CSS `max-width: 100%` keeps it responsive)
- `link=self` — clicking the image opens it full-size
- `window=blank` or `window=_blank` — opens link in new tab

Imageblock alignment is also set globally:

```css
.doc .imageblock {
  align-items: flex-start;
}
```

## Reusing in Other Antora Projects

To add this styling to another Antora site:

1. Add the CSS to `site.yml` under `ui.supplemental_files` as an inline `partials/head-styles.hbs`
2. Optionally create `content/supplemental-ui/css/site-extra.css` as a standalone backup
3. No changes needed to individual `.adoc` pages
