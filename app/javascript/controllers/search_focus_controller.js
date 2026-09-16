import { Controller } from "@hotwired/stimulus"

// One global shortcut owner in the header, including after Turbo navigation.
export default class extends Controller {
  connect() {
    this.shortcut = (event) => {
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k") this.focus(event)
    }
    this.onLoad = () => {
      if (location.hash === "#directory-search") this.focus()
    }
    document.addEventListener("keydown", this.shortcut)
    document.addEventListener("turbo:load", this.onLoad)
    this.onLoad()
  }

  disconnect() {
    document.removeEventListener("keydown", this.shortcut)
    document.removeEventListener("turbo:load", this.onLoad)
  }

  focus(event) {
    // The brand remains a normal home link for modified and middle clicks.
    if (event?.type === "click" && (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)) return
    event?.preventDefault()
    this.application.getControllerForElementAndIdentifier(this.element, "site-header")?.closeMenu()
    const input = document.querySelector('input[type="search"][name="q"]')
    if (input) {
      input.focus({ preventScroll: true })
      input.select()
      input.scrollIntoView({ block: "center" })
    } else {
      window.location.href = "/#directory-search"
    }
  }
}
