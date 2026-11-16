// Is a modal or a menu open on top of a pane? Both own their dismissal, so a
// pane must not act on an Escape or an outside click while one is up.
// `:not([hidden])` matters for the menu: a `Kit::Dropdown` renders its menu
// closed-but-present, so a bare `[role='menu']` matches on every edit-mode
// page and disarms the guard entirely (framework explorer, Hard-Won Lesson 37).
export function somethingElseIsOpen() {
  return Boolean(
    document.querySelector("[data-modal-target='overlay']:not(.hidden)") ||
    document.querySelector("[role='menu']:not([hidden])")
  )
}
