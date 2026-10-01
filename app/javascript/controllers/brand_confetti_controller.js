// The navbar brand's easter egg: hovering shows the tagline, which follows the
// pointer within a small zone under the top-left of the nav, and rains
// heart-hands across the screen; clicking bounces the brand and rains harder.
//
// Usage:
//   <div data-controller="brand-confetti">
//     <button data-brand-confetti-target="brand"
//             data-action="mouseenter->brand-confetti#enter focus->brand-confetti#focus
//                          blur->brand-confetti#blur click->brand-confetti#celebrate
//                          turbo:before-cache@document->brand-confetti#beforeCache">…</button>
//     <div data-brand-confetti-target="tagline" role="tooltip">…</div>
//   </div>

import BaseController from "controllers/base_controller"

const EMOJI = "🫶"
const ZONE_RIGHT_OF_BRAND = 180
const ZONE_BELOW_NAV = 70
const EDGE = 8

export default class extends BaseController {
  static targets = ["brand", "tagline"]
  static values = {
    hoverCount: { type: Number, default: 24 },
    clickCount: { type: Number, default: 50 },
    hoverCooldown: { type: Number, default: 3000 },
    clickCooldown: { type: Number, default: 600 }
  }

  connect() {
    super.connect()
    this.lastHover = 0
    this.lastClick = 0
    this.onPointerMove = this.onPointerMove.bind(this)
    this.onPointerOut = this.onPointerOut.bind(this)
  }

  disconnect() {
    this.hide()
    this.layer?.remove()
    this.layer = null
    super.disconnect()
  }

  enter(event) {
    this.show()
    this.follow(event.clientX, event.clientY)
    window.addEventListener("mousemove", this.onPointerMove)
    document.addEventListener("mouseout", this.onPointerOut)
    this.rain(this.hoverCountValue, 900, "lastHover", this.hoverCooldownValue)
  }

  // Keyboard focus only — a mouse click also focuses the button, and the
  // tagline should then keep following the pointer rather than pin itself.
  focus() {
    if (!this.keyboardFocused()) return

    const brand = this.brandTarget.getBoundingClientRect()
    this.show()
    this.follow(brand.left, brand.bottom - EDGE)
    this.rain(this.hoverCountValue, 900, "lastHover", this.hoverCooldownValue)
  }

  blur() {
    this.hide()
  }

  // Turbo snapshots the page before this controller disconnects, so an open
  // tagline would otherwise be restored open, and dead, on Back.
  beforeCache() {
    this.hide()
  }

  celebrate() {
    if (!this.rain(this.clickCountValue, 1200, "lastClick", this.clickCooldownValue)) return

    this.brandTarget.animate(
      [
        { transform: "scale(1)" },
        { transform: "scale(0.9)", offset: 0.25 },
        { transform: "scale(1.12)", offset: 0.6 },
        { transform: "scale(1)" }
      ],
      { duration: 450, easing: "ease-out" }
    )
  }

  // private

  onPointerMove(event) {
    const zone = this.zone()
    const inside = event.clientX >= zone.left && event.clientX <= zone.right &&
      event.clientY >= zone.top && event.clientY <= zone.bottom

    if (inside || this.keyboardFocused()) {
      this.follow(event.clientX, event.clientY)
    } else {
      this.hide()
    }
  }

  onPointerOut(event) {
    if (!event.relatedTarget) this.hide()
  }

  keyboardFocused() {
    return this.brandTarget.matches(":focus-visible")
  }

  show() {
    this.taglineTarget.dataset.open = ""
  }

  hide() {
    delete this.taglineTarget.dataset.open
    window.removeEventListener("mousemove", this.onPointerMove)
    document.removeEventListener("mouseout", this.onPointerOut)
  }

  zone() {
    const brand = this.brandTarget.getBoundingClientRect()
    const nav = this.navRect()
    return {
      left: nav.left,
      top: nav.top,
      right: brand.right + ZONE_RIGHT_OF_BRAND,
      bottom: nav.bottom + ZONE_BELOW_NAV,
      navBottom: nav.bottom
    }
  }

  follow(x, y) {
    const zone = this.zone()
    const tagline = this.taglineTarget
    const maxLeft = Math.min(zone.right, window.innerWidth - tagline.offsetWidth - EDGE)
    const left = Math.max(Math.min(x + 12, maxLeft), zone.left + EDGE)
    const top = Math.min(Math.max(y + 18, zone.navBottom + EDGE), zone.bottom - EDGE)

    tagline.style.left = `${left}px`
    tagline.style.top = `${top}px`
  }

  navRect() {
    return (this.element.closest("nav") || this.element).getBoundingClientRect()
  }

  // Returns whether it rained, so a click inside its cooldown skips the bounce too.
  rain(count, maxDelay, clock, cooldown) {
    const now = Date.now()
    if (now - this[clock] < cooldown) return false
    this[clock] = now

    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return false

    const layer = this.confettiLayer()
    const width = layer.clientWidth
    const height = layer.clientHeight

    for (let i = 0; i < count; i++) {
      const size = 32 + Math.random() * 32
      const heart = document.createElement("span")
      heart.textContent = EMOJI
      heart.dataset.brandConfettiHeart = ""
      Object.assign(heart.style, {
        position: "absolute",
        top: "0",
        left: "0",
        fontSize: `${size}px`,
        lineHeight: "1",
        willChange: "transform, opacity"
      })
      layer.appendChild(heart)

      const x0 = Math.random() * width - size / 2
      const drift = (Math.random() - 0.5) * 160
      const sway = (Math.random() - 0.5) * 60
      const rotation = (Math.random() - 0.5) * 300
      const y0 = -size - 10
      const y1 = height + 20

      heart.animate(
        [
          { transform: `translate(${x0}px, ${y0}px) rotate(0deg)`, opacity: 0 },
          { transform: `translate(${x0 + sway}px, ${y0 + (y1 - y0) * 0.12}px) rotate(${rotation * 0.15}deg)`, opacity: 1, offset: 0.1 },
          { transform: `translate(${x0 - sway + drift * 0.5}px, ${y0 + (y1 - y0) * 0.55}px) rotate(${rotation * 0.6}deg)`, opacity: 1, offset: 0.55 },
          { transform: `translate(${x0 + drift}px, ${y1}px) rotate(${rotation}deg)`, opacity: 0.2 }
        ],
        {
          duration: 3200 + Math.random() * 1600,
          delay: Math.random() * maxDelay,
          easing: "cubic-bezier(.45, .05, .55, .95)",
          fill: "backwards"
        }
      ).onfinish = () => heart.remove()
    }
    return true
  }

  // Starts at the nav's bottom edge so the hearts appear to fall out from under
  // it. Sits below the modals (z-40) and never takes a click.
  confettiLayer() {
    if (!this.layer?.isConnected) {
      this.layer = document.createElement("div")
      this.layer.setAttribute("aria-hidden", "true")
      this.layer.dataset.brandConfettiLayer = ""
      this.layer.dataset.turboTemporary = ""
      Object.assign(this.layer.style, {
        position: "fixed",
        left: "0",
        right: "0",
        bottom: "0",
        overflow: "hidden",
        pointerEvents: "none",
        zIndex: "30"
      })
      document.body.appendChild(this.layer)
    }
    this.layer.style.top = `${Math.max(0, this.navRect().bottom)}px`
    return this.layer
  }
}
