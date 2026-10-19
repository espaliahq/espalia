# Assessments — Hard-Won Lessons

> Part of the [assessments.md](../assessments.md) guide set. Read this when: a lesson in the core guide's index names what you are about to touch. The numbers are cited elsewhere; never renumber.

## Hard-Won Lessons

### 1. Separate view hierarchies over multi-mode components

A parallel `app/views/assessments/` hierarchy with its own card/strip/chip components was cleaner than adding mode parameters to the framework explorer's view. Assessment components need frequency selectors, secondary bars, contribution badges, and color-tiered chip backgrounds that don't belong in the read-only explorer.

### 2. Context threading must be end-to-end

The `:self` / `:manager` / `:alignment` context flows from controller detection through the builder, into every view component, and into form action URLs. Missing the context at any layer — especially `FrequencyPill#form_action` — routes ratings to the wrong endpoint silently.

### 3. Perspective scoring returns nil, not empty

`build_perspective_scoring` returns `nil` (not an empty hash) when no ratings exist for a perspective. `HeroSummary` falls back to effective scoring when its preferred perspective is nil. Returning an empty hash would display misleading zero scores.

### 4. The middle band must point at the *next* milestone, not one already cleared

An early state machine fired a separate `:progressing_to_next` state whenever the next-level ratio cleared the underperforming floor — pointing at promotion before the person had consolidated their own level. The mental model is *always-the-next-gate*: `:performing` owns the band from meeting to the mastery waypoint and is framed as progress toward the next level, using next-level contributions so the gap values actually mean something (capabilities at `+0.0` current would show `-1.0` at L+1 — the real signal). With the level-independent scale (ADR-21) the number itself says how far along that band the person is, so the headline carries it ("38% of the way to E4") instead of a separate state.

### 5. CSS scroll-driven animation needs `grid-template-rows`, not `max-height`

The original hero collapse animated `max-height` + `padding-block`. That caused a re-layout feedback loop mid-scroll — visible as a flicker between hidden and visible — because the unified sticky header height was changing every frame, which `category_nav_controller`'s ResizeObserver published as `--sticky-header-h`, which cascaded layout, which …

`grid-template-rows: 1fr → 0fr` owns the row's height locally. Two-layer wrapper (grid item with no padding, padded child inside) lets the row shrink to 0 without padding contributing to a minimum height.

### 6. Sub-pixel rounding leaves a 1px gap under the sticky header

`element.offsetHeight` returns an integer. When the real sticky-header height is fractional (Hi-DPI displays, mid-animation), `--sticky-header-h` lands 0.5–1px short of the actual bottom edge, and the category section's `top: var(--sticky-header-h)` ends up a hair below the unified header — revealing a thin strip of scrolling content. Use `Math.ceil(getBoundingClientRect().height)` instead.

### 7. Active-chip detection must be locked during programmatic scroll

The smooth-scroll animation's final scroll event can fire while the target section's top is still a few pixels short of the active-detection threshold. Without a lock, the active marker reverts to the previous chip — the clicked chip appears to mismatch the visible section. `category_nav_controller` locks the active state for ~900ms after a chip click and suppresses scroll-based detection during that window.

### 8. Capability contribution must render as a signed delta, never hidden when negative

The original card had `return if @contribution.negative?` and rendered the contribution as a percentage. That silently dropped the most informative signal (under-performance) and showed even `+0.0` as `0%` — meaningless. Render as `±N.N` always; color-tier by magnitude.

### 9. Auto-focus removes the "no level focused" state — drop the close button with it

The original card had a `×` close button on the expansion panel that returned to "no level focused" — strip visible, panel hidden. Auto-focusing every card on the person's level makes that state meaningless (there's nothing to close *to*). Re-focusing means clicking a different chip; that's the only interaction the strip needs.

### 10. Rating Turbo Streams must re-render with the right mode + context

Inline rating responses use `turbo_stream.replace` on the rated cell or expansion. The replacement must carry both `context:` and `frozen:` / `alignment_locked:` from the parent view, otherwise the re-rendered fragment loses the read-only treatment in `aligning` / `aligned` states.

### 11. IntersectionObserver's connect-time callback isn't a user scroll

`new IntersectionObserver(cb).observe(el)` triggers `cb` once with the current intersection state — not in response to a user scroll, but as a one-shot bootstrap. Acting on that callback to update capability focus made every page load auto-narrow the activity feed to whichever card happened to sit in the visible band, silently overriding URL-driven (`?capability=`) and click-driven initial focus. Fix: gate `#updateFocusedCapabilityFromScroll` on `_sawUserScroll`, which only flips after a real `scroll` event has fired. Real users always trip the flag with their first scroll; the bootstrap callback no-ops.

### 11a. "Deepest card past the sticky chrome" is symmetric in mechanism but asymmetric in perception

First version of `#updateFocusedCapabilityFromScroll` picked the deepest card whose top had scrolled past `stickyH + 16` — same heuristic `category_nav_controller#updateActiveCategory` uses for category sections. Worked great scrolling down (the new card appears at the chrome line, focus switches naturally). Broke scrolling up: when the current card's top crossed back below the threshold, the "next" card in the set was the one ABOVE the chrome, often far above with only its bottom edge visible. Focus jumped to a card the user couldn't yet see.

The cause: with downward scrolling the threshold-crossing card is also the one growing visibly in the band; with upward scrolling the same crossing dismisses the visible card while crowning one that's mostly off-screen. Fix: switch to a most-visible-area picker. The card with the most pixels in the content band (viewport strip below sticky chrome) wins regardless of scroll direction. Both directions converge on "what the user has the most of on screen", which is what they're reading.

### 12. Activity feed reconnect on lazy-frame load needs a DOM signal for capability focus

`activity_feed_controller#readMatrixFocusFromDom` runs on every `connect()`. The activity sidebar lives in a `loading: "lazy"` turbo-frame, so its first connect (when the pane opens) happens AFTER the user may have already clicked a card. Without a DOM signal for "capability focus is active on card X", the reconnect would default to category-level focus and silently undo the click. The signal is `data-focused="true"` on the matching card — server stamps it from `?capability=`, JS toggles it on focus changes, feed reads it on reconnect.

### 13. Renew-on-scroll suppression beats a fixed time window

The first version of the explicit-click suppression was time-only: `_capabilityFocusSuppressUntil = Date.now() + 900`. On slow CI runners the smooth scroll that an explicit click triggers routinely outlasted 900ms — even after bumping to 1800ms the picker could fire mid-animation and overwrite the user's focus with whichever card was the area-winner at that frame. Fix: pair the time-based window with a `_suppressionScrollRenew` flag plus a `_scrollSettleTimer` that every scroll event resets. The flag stays true until scroll events have been quiet for 2000ms, so the suppression naturally tracks the actual animation duration regardless of CI speed. Time-based covers the click itself; renew-on-scroll covers the scroll animation. Both are needed — neither alone survives the full range of CI timing.

### 14. IntersectionObserver callbacks aren't load-bearing for the picker

The original picker iterated `_intersectingCards`, a `Set` maintained by the `IntersectionObserver` callback. On slow CI the IO callback fires arbitrarily late — the picker would run with a stale or empty set when the test asserted. Fix: iterate `cardTargets` directly inside the picker and compute visible area via `getBoundingClientRect()` for each card. The IO is still useful as the scroll-event flusher (it triggers `#scheduleCapabilityScrollUpdate` from the callback) but it's no longer the source of truth for *which* cards the picker considers. Genuine user scrolls drive the picker via `_onCapabilityScroll`; the IO callback only renews suppression for layout-shift-driven re-fires.

### 15. External category focus must be sticky against the scroll picker

The picker's "don't override" check originally only honoured `cell` / `capability` focus on the same card — `category` always fell through and got rewritten to `capability` focus on whatever card was the area winner. That meant a deliberate chip click would persist for the suppression window, then silently downgrade the moment a single scroll event landed past the renew timer. Fix: track external category dispatches with a `_categoryFocusFromExternal` sticky flag (set in `#onExternalFocusChange` when `detail.level === "category"`, cleared in `#setFocus` whenever the new level is anything else). The picker checks the flag the same way it checks for same-card cell/capability focus. Initial default category focus from `#dispatchInitialFocus` doesn't set the flag, so the first user scroll on a fresh page still narrows to capability focus as expected — only chip-set category focus is sticky.

### 16. A scroll-driven animation that resizes an in-flow element shakes — two couplings, two fixes

The hero middle band collapses via `animation-timeline: scroll(root)`, and the band sits inside the **unified sticky header, which is in normal document flow** at the top of the page. So as the band collapses, the header's flow box shrinks *above the fold* — and that couples scroll position back into the scroll-linked animation in **two independent ways**, each producing a visible "shake" of the band when the resting scroll lands inside the 0–240px collapse range ("close to full visibility but not quite"):

1. **Scroll anchoring** (fires on *any* page during active scroll). The browser, by default, nudges `scrollTop` to keep below-fold content visually stable when content above it resizes. The header shrinking triggers that nudge → re-drives the animation → resizes the header → … Fix: `overflow-anchor: none` on the page's scroll-root subtree, so the band collapses purely as a function of genuine user scroll.

2. **Scroll-range clamping** (the "sometimes" / short-page case). On a marginally-scrollable page the collapse shrinks the document below `scrollTop`, so the browser **hard-clamps** the scroll down, which re-expands the band, which restores the scroll length — a sustained ~1px limit cycle. Clamping is a hard constraint `overflow-anchor` can't suppress. Fix: a `min-height` floor (collapse range + band-height headroom, on top of the viewport) on the same scroll-root — on a short page the collapse is absorbed by the floor instead of shrinking the document, so the scroll length stays constant and never clamps; on a normal (tall) matrix it's a no-op.

Both live on `.assessment-scroll-root` (the `assessment-sync` wrapper in `show_view.rb` / `manager_show_view.rb`), gated inside `@supports (animation-timeline: scroll())` so they only apply where the collapse — and thus the loop — actually runs. The trap is assuming `overflow-anchor: none` alone fixes it: it kills the anchor loop but not the clamp loop, which is the one the bug report ("shakes near full visibility, sometimes") actually describes. Verified in-browser: before, a held scroll position oscillates the band through several heights; after, every position holds a single stable height. Regression-guarded by `assessments_system_test.rb` → "apply the anti-shake CSS to the assessment scroll root".

### 17. Toggling Tailwind `hidden` on an element that already has a `display` utility doesn't hide it

The request modal hides a suggestion chip once it's been added to the recipient list. The first cut toggled the `hidden` class — and the chip stayed visible. Cause: the chip carries `inline-flex` (a `display` utility), and `.hidden { display:none }` ties it on specificity (both single-class selectors), so **source order decides** — Tailwind emits `inline-flex` after `hidden`, so `inline-flex` wins and `.hidden` is a no-op. The class *is* present in the DOM (so a `classList.contains("hidden")` check misleads you into thinking it worked); it just has no visual effect. Fix: toggle an **inline** `el.style.display = "none" / ""` (inline style beats any class), or render the element without a competing display utility. See `request_evidence_controller.js#toggleSuggestion`. The general rule: never rely on `hidden` to override another `display-*` utility on the *same* element — gate visibility from a parent, or use inline style.

### 18. Per-card selected level needs its own *rendering* axis, separate from the single *focus* axis

The selected level a card's expansion shows was originally carried by the **same** `?capability=` + `?level_ordinal=` pair that drives cell focus (ring + activity narrowing). Because that pair holds exactly ONE capability, only one card could ever show a non-default level: selecting a level on a second capability reloaded the whole matrix frame and re-rendered every other card at `@person_level` (the URL named only the new one), and the scroll-driven picker — which rewrites that pair as you scroll — *dropped* `level_ordinal` entirely, so the selection silently vanished on the next broadcast reload. The two concerns look identical (both are "a capability + a level") but have different cardinalities: **focus is singular and transient; rendered level is plural and sticky.** Conflating them caps persistence at one card and couples it to scroll. The fix is a second, additive URL axis — `levels[<stable_id>]=<ordinal>`, an accumulating map the server renders each card from (`selected_levels[stable_id] || person_level`) and that the scroll picker never touches. Lesson: when one piece of UI state is per-entity-and-sticky and another is one-at-a-time-and-transient, give them separate URL params even if each value is "a capability and a level" — don't overload one slot for both.

### 19. A sticky pane under a moving header can't be sized by CSS alone

The activity sidebar is sticky at `top: --sticky-header-h + 1rem` and was capped at `100vh - 2rem`, which ignored the header and left the pane's bottom, and the feed's last entries, several hundred pixels below the viewport ([#470](https://github.com/mr-yum/growth-os/issues/470)). Subtracting the header (`100dvh - --sticky-header-h - 2rem`) is right only once the pane has stuck. Before that, at the top of the page, the navbar above the header pushes the pane lower than its sticky offset, and the bottom is still off screen. `overscroll-contain` makes that worse, since the wheel can no longer move the page to reveal it. So `activity_pane_controller` measures the pane's own top and sets `max-height` to what is left below it. The CSS cap stays as the pre-JS fallback, and both offsets are `lg:`-only: an inline `top` also overrode the phone overlay's `inset-y-0`, so it opened a rem below the top of the screen.

### 20. A swapped card is a new node — never remember a card by its element

`#applyCardFocus` used to remember the focused card as a DOM node and clear only that node on the next focus change. Once a chip click swapped a card in place ([#488](https://github.com/mr-yum/growth-os/issues/488)), the replacement was a different node that the server had already stamped `data-focused="true"`; the remembered node was detached, so scrolling to another card left two rings. It now clears by attribute across `cardTargets`. Anything else that holds a card element across an interaction has the same problem: re-find it by `data-capability-stable-id`.
