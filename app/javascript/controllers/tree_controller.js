// Role tree controller for hierarchical checkbox selection with solo mode.
//
// Manages the role tree in the Framework Explorer left pane.
// Dispatches "tree:changed" events when selection changes,
// which the matrix controller listens to for Turbo Frame updates.
//
// <aside data-controller="tree">
//   <button data-action="tree#filterTrack" data-track="ic">IC</button>
//   <div data-tree-target="group" data-family-id="rf1">
//     <input type="checkbox" data-action="tree#toggleFamily" data-family-id="rf1">
//     <div data-tree-target="role" data-role-id="r1" data-track="ic">
//       <input type="checkbox" data-role-id="r1">
//       <button data-action="tree#solo" data-role-id="r1">solo</button>
//     </div>
//   </div>
// </aside>

import { Controller } from "@hotwired/stimulus"

// localStorage key remembering that the user dismissed the "solo" discovery tip.
const SOLO_HINT_KEY = "growthos:explorer:soloHintDismissed"

export default class extends Controller {
  static targets = ["role", "group", "familyCheckbox", "trackButton", "childList", "hint"]
  static values = {
    track: { type: String, default: "both" },
    soloId: { type: String, default: "" }
  }

  connect() {
    this.preSoloState = null
    this.#initSoloHint()
  }

  // ── Actions ──

  toggleRole(event) {
    // Exit solo mode on any manual toggle
    if (this.soloIdValue) {
      this.soloIdValue = ""
      this.preSoloState = null
    }
    this.#updateFamilyCheckbox(event.currentTarget.closest("[data-family-id]"))
    this.#dispatchChanged()
  }

  toggleFamily(event) {
    const group = event.currentTarget.closest("[data-tree-target='group']") ||
                  event.currentTarget.closest("[data-family-id]")
    if (!group) return

    const familyId = group.dataset.familyId
    const checkboxes = this.#visibleRoleCheckboxes(familyId)
    const allChecked = checkboxes.every(cb => cb.checked)

    // Toggle: if all checked, uncheck all; otherwise check all
    checkboxes.forEach(cb => { cb.checked = !allChecked })
    this.#updateFamilyCheckbox(group)

    if (this.soloIdValue) {
      this.soloIdValue = ""
      this.preSoloState = null
    }

    this.#dispatchChanged()
  }

  toggleGroup(event) {
    const familyId = event.currentTarget.dataset.familyId || event.params?.familyId
    if (!familyId) return

    const childList = this.childListTargets.find(el => el.dataset.familyId === familyId)
    if (!childList) return

    childList.classList.toggle("hidden")

    // Rotate chevron
    const chevron = event.currentTarget.querySelector("svg")
    if (chevron) {
      chevron.classList.toggle("rotate-90")
    }

    // Update aria
    event.currentTarget.setAttribute(
      "aria-expanded",
      !childList.classList.contains("hidden")
    )
  }

  solo(event) {
    event.stopPropagation()
    const roleId = event.currentTarget.dataset.roleId
    if (!roleId) return

    if (this.soloIdValue === roleId) {
      // Un-solo: restore previous state
      this.soloIdValue = ""
      if (this.preSoloState) {
        this.#restoreCheckboxState(this.preSoloState)
        this.preSoloState = null
      }
    } else {
      // Enter solo mode
      if (!this.soloIdValue) {
        this.preSoloState = this.#saveCheckboxState()
      }
      this.soloIdValue = roleId

      // Uncheck all, check only the solo'd role
      this.#allRoleCheckboxes().forEach(cb => { cb.checked = false })
      const soloCb = this.#findRoleCheckbox(roleId)
      if (soloCb) soloCb.checked = true

      this.#updateAllFamilyCheckboxes()
    }

    this.#dispatchChanged()
  }

  showAll(event) {
    event.preventDefault()

    if (this.soloIdValue && this.preSoloState) {
      this.#restoreCheckboxState(this.preSoloState)
      this.soloIdValue = ""
      this.preSoloState = null
    } else {
      // Check all visible roles
      this.#allVisibleRoleCheckboxes().forEach(cb => { cb.checked = true })
    }

    this.#updateAllFamilyCheckboxes()
    this.#dispatchChanged()
  }

  clearAll(event) {
    event.preventDefault()

    // Clearing always wins over solo mode: drop solo without restoring the
    // pre-solo selection, since the intent is an empty starting point.
    this.soloIdValue = ""
    this.preSoloState = null

    this.#allVisibleRoleCheckboxes().forEach(cb => { cb.checked = false })

    this.#updateAllFamilyCheckboxes()
    this.#dispatchChanged()
  }

  dismissHint(event) {
    if (event) event.preventDefault()
    this.#setSoloHintDismissed()
    if (this.hasHintTarget) this.hintTarget.remove()
  }

  filterTrack(event) {
    const track = event.currentTarget.dataset.track
    if (!track) return

    this.trackValue = track

    this.trackButtonTargets.forEach(btn => {
      btn.setAttribute("aria-pressed", String(btn.dataset.track === track))
    })

    // Show/hide roles by track
    this.roleTargets.forEach(roleEl => {
      const roleTrack = roleEl.dataset.track
      const visible = track === "both" || roleTrack === track
      roleEl.classList.toggle("hidden", !visible)
    })

    this.#updateAllFamilyCheckboxes()
    this.#dispatchChanged()
  }

  // ── Private ──

  // Hide the solo discovery tip if the user has dismissed it before.
  // localStorage may throw (private mode, blocked storage) — fail open and
  // just show the tip rather than break the controller.
  #initSoloHint() {
    if (!this.hasHintTarget) return
    if (this.#soloHintDismissed()) this.hintTarget.remove()
  }

  #soloHintDismissed() {
    try {
      return localStorage.getItem(SOLO_HINT_KEY) === "1"
    } catch {
      return false
    }
  }

  #setSoloHintDismissed() {
    try {
      localStorage.setItem(SOLO_HINT_KEY, "1")
    } catch {
      // Storage unavailable — tip will reappear next load, which is acceptable.
    }
  }

  #dispatchChanged() {
    const roleIds = this.#getSelectedRoleIds()
    this.dispatch("changed", {
      detail: { roleIds, track: this.trackValue },
      bubbles: true
    })
  }

  #getSelectedRoleIds() {
    return this.#allVisibleRoleCheckboxes()
      .filter(cb => cb.checked)
      .map(cb => cb.dataset.roleId)
  }

  #allRoleCheckboxes() {
    return Array.from(
      this.element.querySelectorAll("input[type='checkbox'][data-role-id]")
    )
  }

  #allVisibleRoleCheckboxes() {
    return this.#allRoleCheckboxes().filter(cb => {
      // Check if the role's container div (not the whole tree) is hidden
      const roleDiv = cb.closest("[data-tree-target='role']")
      return roleDiv && !roleDiv.classList.contains("hidden")
    })
  }

  #visibleRoleCheckboxes(familyId) {
    const group = this.groupTargets.find(g => g.dataset.familyId === familyId)
    if (!group) return []
    return Array.from(
      group.querySelectorAll("input[type='checkbox'][data-role-id]")
    ).filter(cb => !cb.closest("[data-tree-target='role'].hidden"))
  }

  #findRoleCheckbox(roleId) {
    return this.element.querySelector(
      `input[type='checkbox'][data-role-id='${roleId}']`
    )
  }

  #updateFamilyCheckbox(group) {
    if (!group) return
    const familyCb = group.querySelector("[data-tree-target='familyCheckbox']")
    if (!familyCb) return

    const checkboxes = this.#visibleRoleCheckboxes(group.dataset.familyId)
    const allChecked = checkboxes.length > 0 && checkboxes.every(cb => cb.checked)
    const someChecked = checkboxes.some(cb => cb.checked)

    familyCb.checked = allChecked
    familyCb.indeterminate = someChecked && !allChecked
  }

  #updateAllFamilyCheckboxes() {
    this.groupTargets.forEach(group => this.#updateFamilyCheckbox(group))
  }

  #saveCheckboxState() {
    const state = {}
    this.#allRoleCheckboxes().forEach(cb => {
      state[cb.dataset.roleId] = cb.checked
    })
    return state
  }

  #restoreCheckboxState(state) {
    this.#allRoleCheckboxes().forEach(cb => {
      if (cb.dataset.roleId in state) {
        cb.checked = state[cb.dataset.roleId]
      }
    })
  }
}
