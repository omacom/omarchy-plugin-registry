import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["front", "back", "toggle"]

  connect() {
    this.beforeCache = () => this.flip(false)
    document.addEventListener("turbo:before-cache", this.beforeCache)
    this.overflowElements = [...this.element.querySelectorAll("[data-card-flip-overflow]")]
    this.resizeObserver = new ResizeObserver(() => this.scheduleOverflowCheck())
    this.overflowElements.forEach((element) => this.resizeObserver.observe(element))
    this.flip(false)
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.beforeCache)
    this.resizeObserver.disconnect()
    cancelAnimationFrame(this.overflowFrame)
  }

  toggle(event) {
    if (event.target.closest("a, button")) return
    this.flip(!this.element.classList.contains("is-flipped"))
  }

  toggleButton() {
    const state = !this.element.classList.contains("is-flipped")
    this.flip(state)
    queueMicrotask(() => {
      if (!this.element.isConnected) return
      if (state) {
        const target = this.backTarget.querySelector("[data-card-flip-autofocus]") ||
          this.backTarget.querySelector("a, button")
        target?.focus({ preventScroll: true })
      } else {
        this.toggleTarget.focus({ preventScroll: true })
      }
    })
  }

  keydown(event) {
    if (event.key !== "Escape" || !this.element.classList.contains("is-flipped")) return
    event.preventDefault()
    this.flip(false)
    this.toggleTarget.focus({ preventScroll: true })
  }

  flip(state) {
    this.element.classList.toggle("is-flipped", state)
    this.toggleTarget.setAttribute("aria-expanded", state)
    this.frontTarget.toggleAttribute("inert", state)
    this.frontTarget.setAttribute("aria-hidden", state)
    this.backTarget.toggleAttribute("inert", !state)
    this.backTarget.setAttribute("aria-hidden", !state)
    this.scheduleOverflowCheck()
  }

  scheduleOverflowCheck() {
    cancelAnimationFrame(this.overflowFrame)
    this.overflowFrame = requestAnimationFrame(() => {
      this.overflowElements.forEach((element) => {
        const content = element.querySelector(":scope > span:last-child")
        const range = document.createRange()
        if (content) range.selectNodeContents(content)
        const contentHeight = content ? Math.max(content.scrollHeight, range.getBoundingClientRect().height) : 0
        element.classList.toggle("is-overflowing", contentHeight > (content?.clientHeight || 0) + 1)
      })
    })
  }
}
