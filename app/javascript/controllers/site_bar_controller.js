import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.hero = document.querySelector(".hero")
    if (!this.hero) return

    this.frame = null
    this.handleViewportChange = this.scheduleUpdate.bind(this)
    window.addEventListener("scroll", this.handleViewportChange, { passive: true })
    window.addEventListener("resize", this.handleViewportChange, { passive: true })
    this.scheduleUpdate()
  }

  disconnect() {
    window.removeEventListener("scroll", this.handleViewportChange)
    window.removeEventListener("resize", this.handleViewportChange)
    cancelAnimationFrame(this.frame)
    this.element.classList.remove("site-bar--wide")
  }

  scheduleUpdate() {
    if (this.frame !== null) return

    this.frame = requestAnimationFrame(() => {
      this.frame = null
      this.updateWidth()
    })
  }

  updateWidth() {
    if (!this.hero?.isConnected) {
      this.element.classList.remove("site-bar--wide")
      return
    }

    const heroHasPassedBar = this.hero.getBoundingClientRect().bottom <=
      this.element.getBoundingClientRect().bottom
    this.element.classList.toggle("site-bar--wide", heroHasPassedBar)
  }
}
