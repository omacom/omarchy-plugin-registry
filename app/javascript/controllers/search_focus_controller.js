import { Controller } from "@hotwired/stimulus"

// Ctrl+K (or Cmd+K) jumps to the directory search box from anywhere on the
// page; Escape blurs it again. Also serves the header search button (which
// lives outside the form): focusing works whether this controller wraps the
// search form or the button calls focus() directly.
export default class extends Controller {
  static targets = ["input"]

  connect() {
    this.shortcut = (event) => {
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k") {
        event.preventDefault()
        this.focusInput()
      }
    }
    document.addEventListener("keydown", this.shortcut)
  }

  disconnect() {
    document.removeEventListener("keydown", this.shortcut)
  }

  // Header search button action: jump to the directory search wherever it is.
  focus(event) {
    event?.preventDefault()
    if (this.hasInputTarget) {
      this.focusInput()
      return
    }
    const input = document.querySelector('input[type="search"][name="q"]')
    if (input) {
      input.focus()
      input.select()
      // In-page affordance only: the page itself never smooth-scrolls
      // (see application.css), so this explicit smooth jump is safe here.
      input.scrollIntoView({ block: "center", behavior: "smooth" })
    } else {
      window.location.href = "/"
    }
  }

  focusInput() {
    this.inputTarget.focus()
    this.inputTarget.select()
  }
}
