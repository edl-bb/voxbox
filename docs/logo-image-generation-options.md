# VoxBox app icon — image-creation options (researched August 2026)

Four vector concept drafts live in `branding/logo-concepts/` (open
`preview.html`). This note covers the tooling options for producing the final
mark and macOS icon.

## 1. Vector / logo-specialised AI generators

- **Recraft (V3/V4)** — the standout: the only mainstream model producing
  true editable SVG paths (not traced raster), with a style/brand-kit system.
  Free tier 50 daily credits; $10/mo for private images + commercial rights;
  API ~$0.08/SVG. SVGs can be messy and want cleanup in Figma/Illustrator.
- **Ideogram 3.0** — best-in-class text/wordmark rendering (~95% accuracy on
  short copy), fast iteration; raster-only. API $0.03–0.09/image.
- **Looka** — template-driven; quick but generic. $65 Premium for SVG/EPS +
  commercial rights. Fine for a wordmark, weak for a distinctive icon.

Note: an app icon is ultimately raster (1024 px master) anyway — true vector
matters more for the brand logo than the icon itself.

## 2. General image models

- **OpenAI GPT Image** ($0.005–0.21/image): you own outputs, commercial use
  allowed, but no exclusivity/copyright registration. Excellent flat
  iconography.
- **Adobe Firefly**: trained on licensed content, IP-indemnified — safest
  legally; bundled with Creative Cloud.
- **Midjourney** ($10–60/mo): great aesthetics, but ongoing litigation and no
  indemnity make it the riskiest base for a mark you'll trademark.
- **Google Imagen 4**: being sunset on the Gemini API (Aug 2026); not a
  stable pick.

Caveat: purely AI-generated images can't be copyright-registered; trademark
protection via use in commerce still applies.

## 3. Local on Apple Silicon (free, private)

- **Draw Things** (native Mac app): runs Flux.1/Flux.2 and SDXL, fastest
  Apple-Silicon path; 24 GB+ RAM comfortable for Flux.
- **ComfyUI + Flux**: more control (LoRAs, icon-style fine-tunes) but DIY.
- Cons: weaker text rendering than Ideogram; icon-grade polish takes many
  iterations + manual cleanup.

## 4. Human designers (baseline)

- 99designs contests $299–$1,299; Fiverr icons $10–500; Dribbble direct-hire
  $500–2,000+. The only route to guaranteed-original, trademark-clean,
  Liquid-Glass-native layered artwork.

## 5. macOS icon requirements (macOS 26 "Liquid Glass")

- macOS 26 introduced the Liquid Glass icon style and a layered `.icon`
  format. Apple's free **Icon Composer** (ships with Xcode 26) assembles
  layered SVG/PNG artwork into a `.icon` with glass/translucency/dynamic
  lighting for light/dark/tinted modes.
- Still need a 1024×1024 master and a legacy .icns/asset-catalog fallback for
  older macOS. Design flat, layered, simple shapes (glyph + background) — the
  system applies the glass.

## Recommendation

Fastest high-quality path (~$20–30, one afternoon):

1. Ideate in Ideogram 3.0 or GPT Image (flat, layered macOS-style icon —
   rounded box + soundwave/mic glyph for "VoxBox"), iterating cheaply.
2. Recraft ($10/mo) to regenerate the winning concept as SVG with commercial
   rights — clean vector layers for both logo and icon.
3. Clean up in Figma/Illustrator, separate glyph and background layers, run
   through Icon Composer for the Liquid Glass `.icon` + rendered 1024 px PNG
   → .icns fallback.
4. If VoxBox becomes a serious commercial brand, commission a designer
   ($500–900) later to refine the mark for trademark cleanliness — or use
   Firefly now if legal indemnity matters.

Skip local Flux unless privacy/zero-cost is the priority; skip Midjourney for
anything you plan to trademark.
