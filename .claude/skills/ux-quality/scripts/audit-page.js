/**
 * In-page visual audit for the deterministic checks in references/visual.md.
 * Inject this file via script evaluation, then call:
 *
 *   __uxAudit({ spacingScale: [0,4,8,12,16,24,32,40], fontScale: [12,14,16,18,24,32], minTarget: 24 })
 *
 * Scales come from host discovery; without one, values are tallied but
 * never classified off-scale — internal consistency is the only check
 * a host-less run can make. Returns
 * JSON-safe data: tallies plus capped example selectors. Results are
 * evidence — WCAG 2.5.8 exceptions and severity stay with the reviewer.
 */
;(function () {
  if (window.__uxAudit) return

  const MAX_EXAMPLES = 10

  const px = (v) => Math.round(parseFloat(v) * 10) / 10

  const onScale = (value, scale) =>
    scale.some((s) => Math.abs(s - value) <= 0.1)

  /** A human-readable pointer, not a unique locator — pair with the values. */
  const describe = (el) => {
    const tag = el.tagName.toLowerCase()
    if (el.id) return `${tag}#${el.id}`
    const cls = (typeof el.className === 'string' ? el.className : '')
      .split(/\s+/)
      .filter(Boolean)
      .slice(0, 2)
      .join('.')
    const text = (el.textContent || '').trim().slice(0, 24)
    return cls ? `${tag}.${cls}` : text ? `${tag} "${text}"` : tag
  }

  const visible = (el) => {
    if (
      el.checkVisibility &&
      !el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })
    )
      return false
    const r = el.getBoundingClientRect()
    return r.width > 0 && r.height > 0
  }

  /** Operable-but-possibly-transparent: opacity-0 styled-input overlays are
   *  real hit targets and must reach the target-size check. */
  const operable = (el) => {
    if (el.checkVisibility && !el.checkVisibility({ checkVisibilityCSS: true }))
      return false
    const r = el.getBoundingClientRect()
    return r.width > 0 && r.height > 0
  }

  const tally = (map, key) => {
    map[key] = (map[key] || 0) + 1
  }

  const push = (list, item) => {
    if (list.length < MAX_EXAMPLES) list.push(item)
  }

  window.__uxAudit = function (opts) {
    opts = opts || {}
    const out = {}
    const all = Array.from(document.querySelectorAll('*')).filter(visible)

    const check = (name, fn) => {
      try {
        out[name] = fn()
      } catch (e) {
        out[name] = { error: String(e) }
      }
    }

    check('fontSizes', () => {
      const sizes = Object.create(null)
      const offScale = []
      for (const el of all) {
        if (!el.childNodes.length) continue
        const hasText = Array.from(el.childNodes).some(
          (n) => n.nodeType === 3 && n.textContent.trim(),
        )
        if (!hasText) continue
        const size = px(getComputedStyle(el).fontSize)
        tally(sizes, size)
        if (opts.fontScale?.length && !onScale(size, opts.fontScale))
          push(offScale, { description: describe(el), size })
      }
      return { tally: sizes, offScale }
    })

    check('spacing', () => {
      const values = Object.create(null)
      const offScale = []
      const props = [
        'marginTop',
        'marginBottom',
        'marginLeft',
        'marginRight',
        'paddingTop',
        'paddingBottom',
        'paddingLeft',
        'paddingRight',
        'rowGap',
        'columnGap',
      ]
      for (const el of all) {
        const cs = getComputedStyle(el)
        for (const p of props) {
          const v = px(cs[p])
          if (!v || Number.isNaN(v)) continue
          tally(values, v)
          if (
            opts.spacingScale?.length &&
            !onScale(Math.abs(v), opts.spacingScale)
          )
            push(offScale, { description: describe(el), prop: p, value: v })
        }
      }
      return { tally: values, offScale }
    })

    check('smallTargets', () => {
      const min = opts.minTarget || 24
      const result = []
      const targets = document.querySelectorAll(
        'a[href], button, input, select, textarea, details > summary:first-of-type, [role="button"], [role="link"], [role="checkbox"], [role="radio"], [role="tab"], [role="menuitem"], [tabindex]:not([tabindex="-1"])',
      )
      for (const el of targets) {
        if (!operable(el)) continue
        const r = el.getBoundingClientRect()
        /** ≤2px native inputs are visually-hidden proxies (styled
         *  checkbox/radio/file pattern) — their styled control is the real
         *  target. Anything else that tiny is reportable evidence. */
        if (
          r.width <= 2 &&
          r.height <= 2 &&
          el.matches(
            'input[type="checkbox"], input[type="radio"], input[type="file"]',
          )
        )
          continue
        if (r.width < min || r.height < min)
          push(result, {
            description: describe(el),
            width: Math.round(r.width),
            height: Math.round(r.height),
          })
      }
      return result
    })

    check('overflow', () => {
      const doc = document.documentElement
      const wide = []
      const sx = window.scrollX
      let overflowCount = 0
      for (const el of all) {
        const r = el.getBoundingClientRect()
        if (r.right + sx > doc.clientWidth + 1) {
          overflowCount++
          push(wide, {
            description: describe(el),
            left: Math.round(r.left + sx),
            right: Math.round(r.right + sx),
          })
        }
      }
      return {
        horizontalPageScroll: doc.scrollWidth > doc.clientWidth,
        viewportWidth: doc.clientWidth,
        overflowCount,
        elementsPastViewport: wide,
      }
    })

    check('radii', () => {
      const values = Object.create(null)
      for (const el of all) {
        const v = getComputedStyle(el).borderRadius
        if (v && v !== '0px') tally(values, v)
      }
      return values
    })

    check('duplicateIds', () => {
      const seen = Object.create(null)
      for (const el of document.querySelectorAll('[id]'))
        if (el.id) tally(seen, el.id)
      return Object.keys(seen)
        .filter((id) => seen[id] > 1)
        .slice(0, MAX_EXAMPLES)
    })

    return out
  }
})()
