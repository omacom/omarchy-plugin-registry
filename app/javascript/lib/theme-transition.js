// Split-wipe from omacom/omarchy-site src/lib/theme-transition.ts.
// Keep the picker sharp while the frosted page opens along the same slit.
export function runThemeViewTransition(update, { frosted = false } = {}) {
  if (!document.startViewTransition || matchMedia("(prefers-reduced-motion: reduce)").matches) {
    update()
    return
  }

  const root = document.documentElement
  const done = () => root.classList.remove("theme-wipe-frosted")
  if (frosted) root.classList.add("theme-wipe-frosted")
  try {
    const transition = document.startViewTransition(update)
    transition.finished.then(done, done)
  } catch {
    update()
    done()
  }
}
