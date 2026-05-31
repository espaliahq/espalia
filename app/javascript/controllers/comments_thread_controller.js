// Example usage:
// <div data-controller="comments-thread">
//   <textarea data-comments-thread-target="composerBody"></textarea>
//   <li id="comment-:id">
//     <div data-comments-thread-target="displayBody">Body</div>
//     <form class="hidden" data-comments-thread-target="editForm">…</form>
//     <button data-action="comments-thread#startEdit"
//             data-comments-thread-comment-id-param=":id">Edit</button>
//   </li>
// </div>
//
// Manages the inline edit toggle and clears the composer textarea on
// successful submit so the form is ready for the next comment without a
// full page reload.

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["composer", "composerBody", "displayBody", "editForm", "replyForm", "replyBody"]

  // Toggles the comment composer's visibility. The composer starts
  // hidden so the focused cell isn't dominated by an empty textarea —
  // the `+` icon next to the COMMENTS header opens it on demand.
  toggleComposer() {
    if (!this.hasComposerTarget) return
    const form = this.composerTarget
    const willOpen = form.classList.contains("hidden")
    form.classList.toggle("hidden")
    if (willOpen && this.hasComposerBodyTarget) {
      this.composerBodyTarget.focus()
    }
  }

  // Cmd/Ctrl+Enter submits the nearest form. Bound on textarea
  // keydown so it works for both the composer and the inline edit
  // textareas without each needing its own per-target action.
  submitOnModEnter(event) {
    if (event.key !== "Enter") return
    if (!(event.metaKey || event.ctrlKey)) return

    const form = event.target.closest("form")
    if (!form) return

    event.preventDefault()
    if (typeof form.requestSubmit === "function") {
      form.requestSubmit()
    } else {
      form.submit()
    }
  }

  // Toggles the matching comment's display ↔ edit-form view. The
  // comment's display body and edit form sit inside the same <li>, so
  // we scope the toggle by the supplied comment_id.
  startEdit(event) {
    const id = event.params.commentId
    if (!id) return
    const li = this.element.querySelector(`#comment-${CSS.escape(id)}`)
    if (!li) return
    const display = li.querySelector("[data-comments-thread-target='displayBody']")
    const form = li.querySelector("[data-comments-thread-target='editForm']")
    if (display) display.classList.add("hidden")
    if (form) {
      form.classList.remove("hidden")
      const textarea = form.querySelector("textarea[name='comment[body]']")
      if (textarea) {
        textarea.focus()
        const len = textarea.value.length
        textarea.setSelectionRange(len, len)
      }
    }
  }

  // Opens the inline reply form attached to the targeted comment.
  // Scoped by comment_id so siblings stay closed. Closes any other
  // reply form first — only one reply composer open at a time keeps
  // the thread from sprawling.
  startReply(event) {
    const id = event.params.commentId
    if (!id) return
    this.replyFormTargets.forEach(f => f.classList.add("hidden"))
    const li = this.element.querySelector(`#comment-${CSS.escape(id)}`)
    if (!li) return
    const form = li.querySelector("[data-comments-thread-target='replyForm']")
    if (!form) return
    form.classList.remove("hidden")
    const textarea = form.querySelector("textarea[name='comment[body]']")
    if (textarea) textarea.focus()
  }

  // Scrolls to and briefly highlights the comment a "↳ replying to"
  // chip points at, so the reader can jump to the answered comment in
  // the flat thread without losing their place.
  scrollToComment(event) {
    const id = event.params.commentId
    if (!id) return
    const li = this.element.querySelector(`#comment-${CSS.escape(id)}`)
    if (!li) return
    event.preventDefault()
    li.scrollIntoView({ behavior: "smooth", block: "center" })
    li.classList.add("comment-flash")
    setTimeout(() => li.classList.remove("comment-flash"), 1200)
  }

  cancelReply(event) {
    const form = event.target.closest("[data-comments-thread-target='replyForm']")
    if (!form) return
    form.classList.add("hidden")
    const textarea = form.querySelector("textarea[name='comment[body]']")
    if (textarea) textarea.value = ""
  }

  cancelEdit(event) {
    const form = event.target.closest("[data-comments-thread-target='editForm']")
    if (!form) return
    form.classList.add("hidden")
    const li = form.closest("li[id^='comment-']")
    const display = li?.querySelector("[data-comments-thread-target='displayBody']")
    if (display) display.classList.remove("hidden")
    // Restore the textarea contents in case the user changed it before cancelling.
    const textarea = form.querySelector("textarea[name='comment[body]']")
    if (textarea) textarea.value = textarea.defaultValue
  }

  // On successful submit, blank the composer textarea so the form is
  // ready for the next comment. The Turbo Drive redirect+frame reload
  // brings in the just-posted card; without clearing the textarea the
  // user's just-submitted text would still be sitting there.
  submitted(event) {
    if (!event.detail?.success) return
    if (this.hasComposerBodyTarget) {
      this.composerBodyTarget.value = ""
    }
    // Re-hide the composer after a successful post so the cell returns
    // to its compact state. Users open it again via the `+` icon when
    // they want to add another comment.
    if (this.hasComposerTarget) {
      this.composerTarget.classList.add("hidden")
    }
  }
}
