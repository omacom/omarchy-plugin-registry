// The sticky bar, ported from omarchy-site's SiteHeader paint logic at the
// fidelity a server-rendered page needs: the bar carries the section's own
// color only while wholly inside that section (real background-color, not a
// translucent wash), so a section edge passes through in the open with no
// seam. Past the hero it keeps a 90%-over-blur surface like the main site.
import { Controller } from "@hotwired/stimulus"
import { THEME_EVENT, OPEN_PICKER_EVENT } from "lib/omarchy-theme"

export default class extends Controller {
  connect() {
    this.bar = this.element.querySelector(".omarchy-bar")
    this.beforeCache = () => {
      this.setMenu(false)
      this.closeLanguages()
    }
    document.addEventListener("turbo:before-cache", this.beforeCache)
    this.onScroll = () => this.paint()
    this.onResize = () => {
      if (window.matchMedia("(min-width: 900px)").matches) this.setMenu(false)
      this.survey()
    }
    this.onTheme = () => this.survey()
    this.onKey = (e) => {
      if (e.key !== "Escape") return
      if (this.languageTrigger) this.closeLanguages(true)
      else if (this.menuOpen()) {
        this.setMenu(false)
        this.toggleTarget.focus()
      }
    }
    this.toggleTarget?.addEventListener("click", this.toggle)
    this.toggleCloseTarget?.addEventListener("click", this.toggle)
    this.onScrim = () => this.setMenu(false)
    this.scrimTarget?.addEventListener("click", this.onScrim)
    this.onOutside = (event) => {
      if (!event.target.closest("[data-lang-pop], [data-language-toggle]")) this.closeLanguages()
    }
    document.addEventListener("click", this.onOutside)
    window.addEventListener("scroll", this.onScroll, { passive: true })
    window.addEventListener("resize", this.onResize)
    window.addEventListener(THEME_EVENT, this.onTheme)
    window.addEventListener("keydown", this.onKey)
    // Sections grow as images land; re-survey once the current task is done
    // and whenever the DOM under <main> is swapped (Turbo navigation).
    this.settled = window.setTimeout(() => this.survey(), 0)
    this.sizes = new ResizeObserver(() => this.survey())
    const main = document.querySelector("main")
    if (main) this.sizes.observe(main)
    this.arrivals = new MutationObserver(() => this.survey())
    this.arrivals.observe(document.documentElement, {
      childList: true,
      subtree: true,
    })
    this.survey()
  }

  disconnect() {
    window.removeEventListener("scroll", this.onScroll)
    window.removeEventListener("resize", this.onResize)
    window.removeEventListener(THEME_EVENT, this.onTheme)
    window.removeEventListener("keydown", this.onKey)
    window.clearTimeout(this.settled)
    this.sizes?.disconnect()
    this.arrivals?.disconnect()
    this.toggleTarget?.removeEventListener("click", this.toggle)
    this.toggleCloseTarget?.removeEventListener("click", this.toggle)
    this.scrimTarget?.removeEventListener("click", this.onScrim)
    document.removeEventListener("click", this.onOutside)
    document.removeEventListener("turbo:before-cache", this.beforeCache)
    delete document.documentElement.dataset.navMenu
  }

  // -- theme picker (one deck for the whole page) ---------------------------

  openPicker(event) {
    event?.preventDefault()
    this.setMenu(false)
    this.closeLanguages()
    window.dispatchEvent(new CustomEvent(OPEN_PICKER_EVENT))
  }

  // The directory is English; these links open Omarchy's translated sites.
  openLanguages(event) {
    event.preventDefault()
    const pop = this.element.querySelector("[data-lang-pop]")
    const open = pop.hidden
    this.closeLanguages()
    if (!open) return
    this.setMenu(false)
    this.languageTrigger = event.currentTarget
    this.languageTrigger.setAttribute("aria-expanded", "true")
    pop.hidden = false
    pop.querySelector("a").focus()
  }

  closeLanguages(restoreFocus = false) {
    this.element.querySelector("[data-lang-pop]").hidden = true
    this.languageTrigger?.setAttribute("aria-expanded", "false")
    if (restoreFocus) this.languageTrigger?.focus()
    this.languageTrigger = null
  }

  closeMenu() {
    this.setMenu(false)
  }

  // -- responsive menu (omarchy-site's sheet, plus account actions) -----------------

  toggle = () => this.setMenu(!this.menuOpen())

  menuOpen() {
    return this.bar.dataset.menu === "open"
  }

  setMenu(open) {
    if (open) {
      this.closeLanguages()
      this.element.dataset.menu = "open"
      this.bar.dataset.menu = "open"
      document.documentElement.dataset.navMenu = "open"
      this.menuTarget.hidden = false
      this.scrimTarget.hidden = false
      this.toggleTarget?.setAttribute("aria-expanded", "true")
      this.toggleTarget?.setAttribute("aria-label", "Close menu")
      this.toggleTarget.hidden = true
      if (this.toggleCloseTarget) this.toggleCloseTarget.hidden = false
    } else {
      delete this.element.dataset.menu
      delete this.bar.dataset.menu
      delete document.documentElement.dataset.navMenu
      this.menuTarget.hidden = true
      this.scrimTarget.hidden = true
      this.toggleTarget?.setAttribute("aria-expanded", "false")
      this.toggleTarget?.setAttribute("aria-label", "Menu")
      this.toggleTarget.hidden = false
      if (this.toggleCloseTarget) this.toggleCloseTarget.hidden = true
    }
    this.paint()
  }

  get menuTarget() {
    return this.element.querySelector("#site-menu")
  }

  get scrimTarget() {
    return this.element.querySelector("[data-menu-scrim]")
  }

  get toggleTarget() {
    return this.element.querySelector(".omarchy-toggle--menu")
  }

  get toggleCloseTarget() {
    return this.element.querySelector(".omarchy-toggle--close")
  }

  // -- surface -------------------------------------------------------------

  survey() {
    const hero = document.querySelector("[data-hero-sentinel]")
    const main = document.querySelector("main")
    this.heroUp = hero !== null
    const barH = this.bar.getBoundingClientRect().height || 56
    this.height = barH
    this.heroBottom = hero
      ? hero.getBoundingClientRect().bottom + window.scrollY
      : 0
    const sections = document.querySelectorAll("main > section, main [data-ground]")
    const nodes = sections.length ? [...sections] : main ? [main] : []
    const footer = document.querySelector("footer")
    if (footer) nodes.push(footer)
    this.grounds = nodes
      .filter((n) => !n.hasAttribute("data-hero-sentinel"))
      .map((node) => ({
        top: node.getBoundingClientRect().top + window.scrollY,
        bottom: node.getBoundingClientRect().bottom + window.scrollY,
        colour: this.groundOf(node) || "var(--color-bg)",
      }))

    this.paint()
  }

  groundOf(node) {
    // Canvas resolves rgb, oklch and color-mix to the same sRGB value.
    const context = this.colourContext ||= document.createElement("canvas").getContext("2d", { willReadFrequently: true })
    for (let el = node; el; el = el.parentElement) {
      context.clearRect(0, 0, 1, 1)
      context.fillStyle = getComputedStyle(el).backgroundColor
      context.fillRect(0, 0, 1, 1)
      const [r, g, b, alpha] = context.getImageData(0, 0, 1, 1).data
      if (alpha >= 250) return `rgb(${r}, ${g}, ${b})`
    }
    return null
  }

  groundAt(y) {
    let found = null
    for (const g of this.grounds || []) {
      if (y >= g.top && y < g.bottom) found = g
    }
    return found
  }

  paint() {
    if (!this.bar) return
    const y = window.scrollY
    const top = this.groundAt(y)
    const bottom = this.groundAt(y + (this.height || 56))
    const whole = top && top === bottom ? top : null
    const phone = window.matchMedia("(max-width: 639.98px)").matches
    const sheet = this.menuOpen()
    if (sheet) {
      this.bar.style.backgroundImage = ""
      this.bar.classList.add("omarchy-bar--sheet")
    } else {
      this.bar.classList.remove("omarchy-bar--sheet")
      // On a phone the bar never goes bare past the hero: while an edge is
      // crossing it, paint the split edge itself so nothing leaks through.
      if (phone && top !== bottom) {
        const edge =
          top && bottom
            ? Math.min(top.bottom, bottom.top > y ? bottom.top : Infinity)
            : top
              ? top.bottom
              : bottom.top
        const split = Math.round(edge - y)
        const wash = (c) =>
          `color-mix(in srgb, ${c} 90%, transparent)`
        const above = top ? wash(top.colour) : "transparent"
        const below = bottom ? wash(bottom.colour) : "transparent"
        this.bar.style.backgroundImage = `linear-gradient(to bottom, ${above} ${split}px, ${below} ${split}px)`
        this.bar.style.setProperty("--nav-fill", "0")
      } else {
        this.bar.style.backgroundImage = ""
        this.bar.style.setProperty("--nav-fill", "1")
      }
      const here = phone ? top ?? bottom : whole
      if (here) this.bar.style.setProperty("--nav-ground", here.colour)
      else if (!this.heroUp)
        this.bar.style.setProperty("--nav-ground", "var(--color-bg)")
      this.bar.style.setProperty(
        "--nav-surface",
        here || !this.heroUp ? "1" : "0"
      )
    }
    this.bar.toggleAttribute(
      "data-nav-past-hero",
      !this.heroUp || (phone ? y + this.height : y) >= this.heroBottom
    )
  }
}
