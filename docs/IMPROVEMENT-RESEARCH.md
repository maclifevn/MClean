# MClean Improvement Research

> Multi-agent deep research (CleanMyMac UX, SwiftUI motion, feature gaps, icon/Launchpad cache). Generated for the v2.7.0 polish pass.

Deployment target is macOS 13.0 (constrains some APIs). I have everything needed to write the report.

# MClean -> CleanMyMac-Grade: Engineering Report

**Constraint baseline:** Deployment target is `MACOSX_DEPLOYMENT_TARGET = 13.0` (confirmed in `.pbxproj`). This gates several premium APIs. `PhaseAnimator`/`KeyframeAnimator`/`.symbolEffect`/`.contentTransition(.numericText)`/`SectorMark` selection require macOS 14+; `.scrollTransition`/`.visualEffect` are macOS 14+; `TextRenderer`/zoom transitions are macOS 15+. **Recommendation: raise the floor to macOS 14.0** — it unlocks ~80% of the premium toolkit (Swift Charts `SectorMark`, symbol effects, numeric text, phase/keyframe animators) at minimal user-base cost given macOS 14 shipped 2023. Where I list a 14+ API, a macOS 13 fallback is noted. Existing confetti, dashboard, and onboarding files are at `MClean/Views/{DashboardView.swift, OnboardingView.swift, Components/ConfettiView.swift}`.

---

## 1. UI/UX Direction — SwiftUI Changes for CleanMyMac-Grade Polish

CleanMyMac's premium feel is not one trick; it is five stacked systems — organic geometry, a warm gradient color language, sensory layering (parallax + translucency + sound), tight micro-interaction timing, and glassmorphic depth [cleanmymac-ux ^1][^3]. Translate each into the existing SwiftUI surfaces.

### 1.1 Dashboard — tile-based information architecture
Replace any list-first dashboard with a `LazyVGrid` of 2-3 module tiles (Cleanup, Apps, Orphans, Storage, Large/Old, Schedule), each a summary stat + "Review"/"Clean" actions — progressive disclosure removes the wall-of-text intimidation factor [cleanmymac-ux ^10]. Edit `MClean/Views/DashboardView.swift`.

- Each tile gets its **own gradient pair** for wayfinding without labels (Cleanup pink→blue, Storage blue→purple, Apps pink→lavender) [cleanmymac-ux ^1].
- Tile container: `.background(.ultraThinMaterial)` + `.overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.18), lineWidth: 1))`, placed above a `LinearGradient` window backdrop. Glassmorphism only shines over vibrant saturated backgrounds — not flat gray [cleanmymac-ux ^7][^8].
- Hover elevation per tile: `.scaleEffect(isHovered ? 1.03 : 1.0)` + `.shadow(radius: isHovered ? 30 : 10)` + `.animation(.smooth(duration: 0.22), value: isHovered)`. Tap feedback `.scaleEffect(0.92)` with `.snappy(duration: 0.18)` [cleanmymac-ux ^4][^6].

### 1.2 Geometry — organic, not mechanical
Standardize on 16pt corner radius minimum; avoid perfect circles and hard corners. CleanMyMac deliberately uses superellipse/squircle shapes because "sterile, perfect objects repel people" [cleanmymac-ux ^2][^3]. SwiftUI: `RoundedRectangle(cornerRadius: 16, style: .continuous)` (the `.continuous` style is the system squircle — use it everywhere, it is the single cheapest organic-feel win).

### 1.3 Scan reveal — sequential, masked, motion-designed
The existing radial gauges are the right foundation. Upgrade the reveal:
- **Gauge fill**: keep `Circle().trim(from:0,to:progress).stroke(gradient, lineWidth:)` with `.rotationEffect(.degrees(-90))` and `.animation(.linear, value: progress)` for the live sweep [swiftui-motion].
- **Results stagger**: as categories resolve, reveal tiles sequentially (not simultaneously) — `.transition(.scale.combined(with:.opacity))` with per-tile `.animation(.spring(duration:0.5, bounce:0.2).delay(index * 0.06))`. Sequential timing is what reads as "designed" vs. a dump [cleanmymac-ux ^11].
- **Freed-space counter**: animate the GB number with `.contentTransition(.numericText(value:))` (macOS 14+; on 13 fall back to a `TimelineView`-driven interpolated `Text`) [swiftui-motion].
- **Completion**: spring settle on the gauge + `withAnimation(...) { } completion: { Haptics.success(); confetti }` using the completion-handler API so haptic/confetti fire exactly when the animation settles, not on a guessed timer [swiftui-motion].

### 1.4 Motion timing table (apply globally)
| Interaction | Duration | Curve | Effect |
|---|---|---|---|
| Tap | 180ms | `.snappy` | scale 1.0→0.92 |
| Hover | 220ms | `.smooth` | scale 1.0→1.03, shadow 10→30 |
| Reveal/context change | 400-600ms | spring bounce 0.2 | tile/scale-in |
| Idle pulse (CTA) | 1200ms loop | `.repeatForever(autoreverses:)` | scale 1.0→1.08 |

Keep bounce ≤ 0.30 for UI; never exceed 0.40 [cleanmymac-ux ^4][^6][swiftui-motion]. CTAs and category icons get SF Symbol feedback via `.symbolEffect(.bounce, value:)` on completion and `.symbolEffect(.pulse)` while scanning (macOS 14+; free + accessible) [swiftui-motion].

### 1.5 Graphs / charts — the biggest visible gap
Adopt **Swift Charts** (macOS 14+) for storage breakdown — this is the single feature that most reads as "premium graphical tool":
- **Donut** via `SectorMark(angle:.value(...), innerRadius:.ratio(0.618), angularInset:1.5).cornerRadius(5).foregroundStyle(by:)`, with `.chartBackground` centering total-storage text in the hole [swiftui-motion].
- **Segmented usage bar** for the dashboard header via `BarMark` stacked by file-type category.
- **Interactivity**: `.chartAngleSelection` to dim non-selected sectors to 0.3 opacity on hover/click [swiftui-motion].
- macOS 13 fallback: `Canvas` arc drawing (hardware-accelerated) for the donut — pattern in [swiftui-motion]. Existing gauges already prove the team can do `Canvas`/`trim`.

### 1.6 Color & depth
Define 3 module gradient pairs as `Theme` tokens (extend `MClean/Extensions/Theme.swift`); test all over light/dark via `NSColor` dynamic providers. Use `.ultraThinMaterial` for floating panels, vibrant gradient for window background — layered planes are what flat design cannot reproduce [cleanmymac-ux ^1][^7][^8]. Add a subtle parallax: a low-opacity (0.6-0.8) gradient layer with a 2-3s offset loop behind the hero gauge for atmospheric depth [cleanmymac-ux ^1].

### 1.7 Sound + accessibility (mandatory)
- Success chime `NSSound(named: "Glass")?.play()`, error `NSSound(named: "Basso")` — fire in sync with the visual, not after [cleanmymac-ux ^3][^9]. macOS has no Taptic Engine; the existing `Haptics.swift` likely uses `NSHapticFeedbackManager` for trackpad — keep that paired with sound.
- **Gate every animation** on `@Environment(\.accessibilityReduceMotion)`: `.animation(reduceMotion ? nil : .spring, value:)`. When motion conveys status, swap for a dissolve/color-fade, don't just drop it. App Store reduced-motion criteria require this [swiftui-motion].

---

## 2. Confetti Redesign

Current `ConfettiView.swift` is a `CAEmitterLayer` line emitter dropping 6 rounded-rect colors straight down with `yAcceleration: 240`, `spin: 4`, `scale: 0.35`. It reads "horrible" because: (a) gravity-only fall with no upward burst looks like falling debris, not celebration; (b) flat 2D rectangles with no 3D tumble; (c) saturated primary palette clashes with a premium muted aesthetic [cleanmymac-ux ^3 — "muted, timeless palette, not neon acid tones"]; (d) uniform scale and a single rectangle shape.

**Tasteful replacement — two viable paths:**

**Option A (recommended, on-brand, low risk): refine the existing emitter.** Keep `CAEmitterLayer` (it correctly stays off the SwiftUI render thread — that part is right) but redesign the physics and look:
- **Center-burst, not top-drop**: `emitterShape = .point`, `emitterPosition` at the gauge center, `emissionRange = .pi * 2` (full radial), high initial `velocity` (~300) with negative-then-positive arc via `yAcceleration` — particles shoot up/out then gently fall. This is celebratory, not raining.
- **3D tumble**: drive `emissionLongitude` variation + higher `spinRange`, and ship 2-3 particle shapes (thin rectangle, small circle, tiny streamer) instead of one rounded rect.
- **Muted premium palette**: desaturate the current colors ~20-30% and add the module gradient hues (soft pink, periwinkle, mint, peach) — drop the pure-orange/pure-yellow neon [cleanmymac-ux ^3][^5].
- **Density & decay**: fewer particles (lower `birthRate`), faster `alphaSpeed` fade, total life ≤ 2s. Restraint reads premium.

**Option B (most premium, macOS 14+): native SwiftUI particle burst** using `KeyframeAnimator` over a `Canvas`. Spawn ~40 particles each with `(position, rotation3D, scale, opacity)` as an `Animatable`/`VectorArithmetic` struct; keyframe an arc (SpringKeyframe up, CubicKeyframe down) with independent rotation tracks for tumble [swiftui-motion]. Fully deterministic, GPU-cheap via `Canvas`, and matches the rest of the motion system. More work than A; do it as a follow-up.

Either way: fire on the animation **completion handler** (§1.3), respect `reduceMotion` (suppress confetti entirely, keep the sound), and trigger only on a genuine cleanup-complete with non-trivial space freed — celebration inflation cheapens it.

---

## 3. Missing Features — Prioritized

| Feature | User value | Effort | How |
|---|---|---|---|
| **Menu bar widget** | HIGH — discoverability, always-visible CTA, 1-click scan; no OSS cleaner has it [feature-gaps] | LOW (3-4d) | `NSStatusBar` item + `NSPopover` (or `MenuBarExtra` scene, macOS 13+). Show storage used/free %, "Run Scan", last-cleanup date. |
| **Disk-space visualization (sunburst/treemap)** | HIGH — the DaisyDisk/Space-Lens insight users pay $30 for; "see what eats space" without a list [feature-gaps] | MED-HIGH (2-3w) | `Canvas`/Core Graphics sunburst, click-to-drill-down, color by file type, exclude system by default. macOS 13-safe via Canvas. |
| **Duplicate file finder** | HIGH — 2-10 GB typical recovery [feature-gaps] | MED (2-3w) | Size-bucket → partial hash → full SHA fingerprint; xattr-cache hashes; filetype-aware (EXIF/MP3 tags); reference-dir safety (keep originals, delete only from chosen dirs). |
| **Large/Old files filter presets** | MED-HIGH — reuses existing scanner; power-user control [feature-gaps] | LOW (3-5d) | Add size slider + date picker + location scope to existing "Large & Old"; ship presets (Old Backups >5y, Bulky Media >1GB, Installers >500MB matching `.dmg/.pkg`); persist custom presets to `UserDefaults`. |
| **Login items / launch agents manager** | MED — boot-time bloat, no good OSS tool [feature-gaps] | MED-HIGH (1-2w) | Parse `~/Library/LaunchAgents`, `/Library/LaunchAgents`, daemons; PropertyList parse via Foundation; table (App/Label/Executable/toggle/delete); warn on Apple system agents; cross-ref `launchctl list`. |
| **Finder right-click "Uninstall with MClean"** | MED-HIGH — removes drag/launch friction [feature-gaps] | MED (5-7d) | App Extension (Finder/Action extension) registered for `.app` bundles; launch host with bundle URL arg → pre-populate the existing uninstaller (`AppPathFinder`). |
| **Real-time monitoring (CPU/RAM/disk)** | LOW-MED — Sensei-style, mostly background value [feature-gaps] | MED (1-2w) | Defer to Phase 3. |
| **Malware/security scan** | MED (FUD-driven) [feature-gaps] | LOW value/HIGH cost (2-4w) | Defer; signature DB upkeep is a long-term liability. |

Engine is already ahead of AppCleaner/Pearcleaner; the entire gap to CleanMyMac is UX + visualization + these secondary features, not core capability [feature-gaps].

---

## 4. App Icon + Launchpad Cache Fix

### 4.1 Why the icon renders "abnormal" / dull
A near-white icon (≥ `#F5F5F5`) has insufficient contrast for macOS's Liquid-Glass specular/translucency layer, rendering dull/blank — worst in the Dock when the app is running [icon-launchpad]. Fix the asset, not just the cache.

### 4.2 Design guidance (asset fixes)
Edit the source art behind `MClean/Assets.xcassets/AppIcon.appiconset`:
- **Do NOT bake rounded corners** — the OS applies the squircle/superellipse mask (~22.37% width radius, ~60% smoothing). Provide square layers [icon-launchpad].
- **512×512 canvas, 50px transparent padding all sides; primary content within the centered 412×412** — edge-to-edge fill makes the icon look 20-30% oversized in Dock/Launchpad [icon-launchpad].
- **Contrast ≥ 3:1** vs. background (prefer 4.5:1+ in grids); avoid solid light grays ≥ `#D0D0D0` as the primary color; **test light + dark mode** [icon-launchpad]. Give the near-white mark a saturated/dark backplate or gradient so Liquid Glass has something to catch.
- Vector (SVG/PDF) foreground; PNG only for raster/gradient layers [icon-launchpad].

### 4.3 Exact cache remediation (post-Homebrew-cask reinstall)
```bash
# 1. Kill UI processes
killall Dock
killall Finder

# 2. Clear icon caches
sudo rm -rfv /Library/Caches/com.apple.iconservices.store
sudo find /private/var/folders/ \( -name com.apple.dock.iconcache -or -name com.apple.iconservices \) -exec rm -rfv {} \;

# 3. Rebuild LaunchServices (maps app bundles -> icons; critical after a cask relocation)
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -kill -r -domain local -domain user -domain system -v

# 4. Restart Dock/Finder
sleep 3
killall Dock
killall Finder
```
Allow 2-5 min for the LaunchServices DB to re-seed (system runs slower during rebuild); open MClean once to force re-registration. If still stale, Safe Mode restart (Shut down → power on holding **Shift** through login → wait 5 min → restart normally) forces a rebuild with no third-party interference [icon-launchpad].

Faster user-domain-only LaunchServices variant for dev iteration: append `-apps u` instead of the `-domain` flags [icon-launchpad].

---

## 5. Ship THIS Release vs. Follow-Ups

### Ship now (low effort, high visible impact, macOS 13-safe)
1. **Confetti Option A** — refine the existing emitter (center burst, 3D tumble, muted palette, completion-handler trigger, reduce-motion gate). Hours, not days; directly fixes the "looks horrible" complaint. §2.
2. **`.continuous` corner radius + glass + hover/tap micro-interactions** across dashboard tiles — the cheapest premium-feel uplift, no new APIs. §1.1-1.4.
3. **Sound + `accessibilityReduceMotion` gating** on all existing animations — mandatory polish + App Store compliance, ~1 day. §1.7.
4. **Sequential staggered scan-reveal** using existing transitions/springs. §1.3.
5. **Large/Old files filter presets** (3-5d, reuses scanner). §3.
6. **App icon contrast/padding fix + documented cache-reset script** shipped in the README/troubleshooting. §4.

### Follow-up release (raise floor to macOS 14 first)
7. **Menu bar widget** (`MenuBarExtra`) — highest-ROI new feature, 3-4d. §3.
8. **Swift Charts donut + segmented storage bar** with selection. §1.5.
9. **Numeric-text freed-space counter** + `.symbolEffect` icon feedback. §1.3-1.4.
10. **Confetti Option B** (native Canvas/KeyframeAnimator particles). §2.

### Later phases
11. Disk-space sunburst visualization (2-3w). 12. Duplicate finder (2-3w). 13. Login-items manager (1-2w). 14. Finder context-menu extension (5-7d). Defer real-time monitoring + malware scan. §3.

---

**Files to touch:** `MClean/Views/DashboardView.swift` (tiles, charts, reveal), `MClean/Views/Components/ConfettiView.swift` (redesign), `MClean/Extensions/Theme.swift` (gradient/color tokens), `MClean/Services/Haptics.swift` (sound+haptic pairing), `MClean/Assets.xcassets/AppIcon.appiconset` (icon art), and the `.pbxproj` `MACOSX_DEPLOYMENT_TARGET` (13.0 → 14.0 for the follow-up wave). New: a `MenuBarExtra` scene in `MClean/MCleanApp.swift`, a `StorageChartView`, and an `AppExtension` target for Finder integration.

**Citation key:** [cleanmymac-ux] = CleanMyMac UX brief (Behance/Novikov ^1-3, micro-interactions ^4/^6, color ^5, glass ^7/^8, audio-haptic ^9, Smart Care ^10, reveal ^11); [swiftui-motion] = SwiftUI/macOS 2026 motion brief (Apple WWDC23-25 docs); [feature-gaps] = competitive feature brief (CleanMyMac X, DaisyDisk, Sensei, dupeGuru, Pearcleaner); [icon-launchpad] = icon/cache brief (Apple HIG, Eclectic Light, squircle.js.org, ithy.com Sequoia guide).