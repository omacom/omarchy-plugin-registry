import { Controller } from "@hotwired/stimulus"

const MOVE_MS = 420
const EASE = "cubic-bezier(0.33, 1, 0.68, 1)"
const COMPACT_QUERY = "(max-width: 1100px)"
const FULL_WIDTH_QUERY = "(min-width: 1920px)"

export default class extends Controller {
  static targets = ["row", "stack", "card", "status"]
  static values = { label: { type: String, default: "Most Wanted" } }

  connect() {
    this.motionQuery = window.matchMedia("(prefers-reduced-motion: reduce)")
    this.compactQuery = window.matchMedia(COMPACT_QUERY)
    this.fullWidthQuery = window.matchMedia(FULL_WIDTH_QUERY)
    this.reducedMotion = this.motionQuery.matches

    this.onMotionChange = (event) => {
      this.reducedMotion = event.matches
      this.cancelAnimations()
    }
    this.onLayoutChange = () => {
      this.cancelAnimations()
      this.placeCards([...this.cardTargets])
    }
    this.motionQuery.addEventListener("change", this.onMotionChange)
    this.compactQuery.addEventListener("change", this.onLayoutChange)
    this.fullWidthQuery.addEventListener("change", this.onLayoutChange)

    this.beforeCache = () => this.cancelAnimations()
    document.addEventListener("turbo:before-cache", this.beforeCache)
    this.placeCards([...this.cardTargets])
  }

  disconnect() {
    this.cancelAnimations()
    this.motionQuery?.removeEventListener("change", this.onMotionChange)
    this.compactQuery?.removeEventListener("change", this.onLayoutChange)
    this.fullWidthQuery?.removeEventListener("change", this.onLayoutChange)
    document.removeEventListener("turbo:before-cache", this.beforeCache)
  }

  previous(event) {
    event?.preventDefault()
    this.rotate(-1)
  }

  next(event) {
    event?.preventDefault()
    this.rotate(1)
  }

  keydown(event) {
    if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return
    if (event.target.closest("input, textarea, select, [contenteditable]")) return
    if (event.key === "ArrowLeft") {
      event.preventDefault()
      this.rotate(-1)
    } else if (event.key === "ArrowRight") {
      event.preventDefault()
      this.rotate(1)
    }
  }

  rotate(direction = 1) {
    if (!this.hasStackTarget || this.cardTargets.length < 2) return

    const cards = [...this.cardTargets]
    this.cancelAnimations()
    const before = this.reducedMotion ? null : new Map(cards.map((card) => [card, card.getBoundingClientRect()]))
    cards.forEach((card) => { card.style.animation = "none" })

    if (direction > 0) cards.push(cards.shift())
    else cards.unshift(cards.pop())
    this.placeCards(cards)

    if (before) {
      cards.forEach((card) => {
        const from = before.get(card)
        const to = card.getBoundingClientRect()
        const dx = from.left - to.left
        const dy = from.top - to.top
        const sx = to.width ? from.width / to.width : 1
        const sy = to.height ? from.height / to.height : 1
        if (Math.abs(dx) < 1 && Math.abs(dy) < 1 && Math.abs(sx - 1) < 0.01 && Math.abs(sy - 1) < 0.01) return
        card.style.transformOrigin = "top left"
        card.animate(
          [{ transform: `translate(${dx}px, ${dy}px) scale(${sx}, ${sy})` }, { transform: "none" }],
          { duration: MOVE_MS, easing: EASE }
        )
      })
    }

    if (this.hasStatusTarget) {
      const name = cards[0].querySelector(".recent-card__name")?.textContent.trim() || "plugin"
      this.statusTarget.textContent = `Showing ${this.labelValue} plugin ${name}`
    }
  }

  placeCards(cards) {
    if (!this.hasRowTarget || !this.hasStackTarget) return
    const focusedCard = document.activeElement?.closest?.(".recent-card")
    const masterCount = Math.min(this.masterCount, cards.length)
    cards.forEach((card, index) => {
      const master = index < masterCount
      if (card.classList.contains("is-flipped")) {
        this.application.getControllerForElementAndIdentifier(card, "card-flip")?.flip(false)
      }
      card.classList.toggle("recent-card--master", master)
      if (master) this.rowTarget.insertBefore(card, this.stackTarget)
      else this.stackTarget.append(card)
    })
    const withoutStack = cards.length <= masterCount
    this.stackTarget.hidden = withoutStack
    this.rowTarget.classList.toggle("recent-row--without-stack", withoutStack)
    this.rowTarget.style.setProperty("--recent-master-count", masterCount)

    if (focusedCard?.isConnected) {
      const focusTarget = focusedCard.classList.contains("recent-card--master") ?
        focusedCard.querySelector(".recent-card__badge--toggle") : focusedCard.querySelector(".recent-card__open")
      focusTarget?.focus({ preventScroll: true })
    }
  }

  get masterCount() {
    if (this.compactQuery.matches) return 1
    if (this.fullWidthQuery.matches) return 3
    return 2
  }

  cancelAnimations() {
    this.cardTargets.forEach((card) => card.getAnimations().forEach((animation) => animation.cancel()))
  }
}
