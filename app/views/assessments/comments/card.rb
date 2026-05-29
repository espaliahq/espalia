# frozen_string_literal: true

# Renders a single comment inside the focused assessment cell's
# comment thread.
#
# Shows author + relative timestamp, body, and (if author or admin)
# edit/delete affordances. Deleted comments render in a tombstone style.
#
class Views::Assessments::Comments::Card < Views::Base
  include Phlex::Rails::Helpers::TimeAgoInWords
  include Phlex::Rails::Helpers::ButtonTo

  # @param comment [PersonDevelopmentComment]
  # @param assessment_id [String]
  # @param can_edit [Boolean]
  # @param can_delete [Boolean]
  # @param can_reply [Boolean] whether the viewer may post a reply on this thread
  # @param indent [Boolean] true when rendering as a reply (visual indent)
  def initialize(comment:, assessment_id:, can_edit: false, can_delete: false,
                 can_reply: false, indent: false)
    @comment = comment
    @assessment_id = assessment_id
    @can_edit = can_edit
    @can_delete = can_delete
    # V1 thread depth is one level — replies-of-replies render as same-
    # level replies (see Thread#render_thread_tree). To keep that
    # invariant, only top-level comments expose a Reply affordance.
    @can_reply = can_reply && @comment.parent_id.nil?
    @indent = indent
  end

  def view_template
    li(
      id: "comment-#{@comment.id}",
      class: [ "group relative flex gap-2 py-1.5 text-xs",
               "text-gray-700 dark:text-gray-200",
               @indent ? "pl-5" : "" ].join(" ")
    ) do
      avatar_dot
      div(class: "min-w-0 flex-1") do
        if @comment.deleted?
          deleted_body
        else
          header_line
          body_line
          reply_form if @can_reply
        end
      end
      actions_menu if !@comment.deleted? && (@can_edit || @can_delete || @can_reply)
    end
  end

  private

  def avatar_dot
    span(
      class: "mt-1 w-2 h-2 rounded-full shrink-0 bg-sky-500",
      title: "Comment"
    ) { }
  end

  def header_line
    div(class: "flex flex-wrap items-center gap-x-2 text-[11px]") do
      span(class: "font-medium text-gray-900 dark:text-gray-100") do
        @comment.author&.name || "Unknown"
      end
      # Timestamp doubles as the comment's permalink — comments are
      # individually addressable and the "time ago" line is the most
      # natural anchor for that, freeing the footer for actions that
      # actually need their own row. Affordance is two-layered: a small
      # chain-link icon next to the time, plus an always-on dotted
      # underline that solidifies on hover (Wikipedia-style "this is a
      # link" cue). The plain hover-only underline tested poorly — users
      # didn't realise the time was clickable.
      if @comment.posted_at
        a(
          href: comment_path(@comment),
          class: "inline-flex items-center gap-1 text-gray-400 dark:text-gray-500 " \
                 "underline decoration-dotted decoration-gray-300 dark:decoration-gray-600 " \
                 "underline-offset-2 hover:decoration-solid hover:text-gray-600 " \
                 "dark:hover:text-gray-300",
          title: "Link to this comment · posted #{@comment.posted_at.utc.iso8601}"
        ) do
          permalink_icon
          plain "#{time_ago_in_words(@comment.posted_at)} ago"
        end
      else
        span(class: "text-gray-400 dark:text-gray-500") { "—" }
      end
      if @comment.edited_at.present?
        span(
          class: "text-gray-400 dark:text-gray-500 italic",
          title: "Last edited #{@comment.edited_at.utc.iso8601}"
        ) { "(edited)" }
      end
    end
  end

  # Tiny chain-link icon used inside the timestamp permalink. Heroicons
  # "link" outline path, sized to sit on the 11px text baseline.
  def permalink_icon
    svg(
      class: "w-3 h-3 shrink-0",
      fill: "none",
      viewBox: "0 0 24 24",
      stroke: "currentColor",
      stroke_width: "2",
      aria_hidden: "true"
    ) do |s|
      s.path(
        stroke_linecap: "round",
        stroke_linejoin: "round",
        d: "M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101" \
           "m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1"
      )
    end
  end

  def body_line
    # The card only renders inside the focused expanded cell — render the
    # full body. `whitespace-pre-wrap` preserves line breaks the author
    # entered; `break-words` keeps long URLs from blowing out the column.
    div(
      class: "mt-0.5 text-gray-700 dark:text-gray-300 whitespace-pre-wrap break-words",
      data: { comments_thread_target: "displayBody" }
    ) { @comment.body }
    edit_form if @can_edit
  end

  # Inline reply composer that hides under the comment until the
  # viewer clicks the kebab's "Reply" action. Posts a NEW comment
  # scoped to this card's cell with `parent_id` set so the projection
  # threads it under this comment.
  def reply_form
    form(
      action: assessment_comments_path(@assessment_id),
      method: "post",
      class: "hidden mt-1",
      data: {
        comments_thread_target: "replyForm",
        action: "turbo:submit-end->comments-thread#submitted"
      }
    ) do
      input(type: "hidden", name: "authenticity_token",
            value: view_context.form_authenticity_token)
      input(type: "hidden", name: "comment[capability_stable_id]",
            value: @comment.capability_stable_id)
      input(type: "hidden", name: "comment[level_ordinal]",
            value: @comment.level_ordinal)
      input(type: "hidden", name: "comment[parent_id]", value: @comment.id)
      textarea(
        name: "comment[body]",
        rows: 2,
        required: true,
        placeholder: "Reply…",
        class: "w-full rounded-md border border-gray-300 dark:border-gray-600 " \
               "bg-white dark:bg-gray-800 px-2 py-1 text-xs text-gray-900 dark:text-white " \
               "focus:outline-none focus:ring-2 focus:ring-primary",
        data: {
          comments_thread_target: "replyBody",
          action: "keydown->comments-thread#submitOnModEnter"
        }
      ) { "" }
      div(class: "mt-1 flex items-center gap-2") do
        button(
          type: "submit",
          class: "px-2 py-1 text-[11px] rounded-md bg-primary text-white hover:bg-primary/90"
        ) { "Reply" }
        button(
          type: "button",
          class: "px-2 py-1 text-[11px] rounded-md text-gray-600 dark:text-gray-300 hover:underline",
          data: { action: "click->comments-thread#cancelReply" }
        ) { "Cancel" }
      end
    end
  end

  def edit_form
    form(
      action: assessment_comment_path(@assessment_id, @comment.id),
      method: "post",
      class: "hidden mt-1",
      data: {
        comments_thread_target: "editForm",
        action: "turbo:submit-end->comments-thread#submitted"
      }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "_method", value: "patch")
      textarea(
        name: "comment[body]",
        rows: 3,
        required: true,
        class: "w-full rounded-md border border-gray-300 dark:border-gray-600 " \
               "bg-white dark:bg-gray-800 px-2 py-1 text-xs text-gray-900 dark:text-white " \
               "focus:outline-none focus:ring-2 focus:ring-primary",
        data: { action: "keydown->comments-thread#submitOnModEnter" }
      ) { @comment.body }
      div(class: "mt-1 flex items-center gap-2") do
        button(
          type: "submit",
          class: "px-2 py-1 text-[11px] rounded-md bg-primary text-white hover:bg-primary/90"
        ) { "Save" }
        button(
          type: "button",
          class: "px-2 py-1 text-[11px] rounded-md text-gray-600 dark:text-gray-300 hover:underline",
          data: { action: "click->comments-thread#cancelEdit" }
        ) { "Cancel" }
      end
    end
  end

  def deleted_body
    div(class: "italic text-gray-400 dark:text-gray-500") do
      plain "[deleted]"
      if @comment.deletion_reason.present?
        plain " — #{@comment.deletion_reason}"
      end
    end
  end

  def actions_menu
    # Kebab stays visible at all times — the opacity-0/hover pattern
    # hid Reply on touch devices entirely and was hard to discover on
    # desktop. On mobile a muted-by-default trigger is more discoverable
    # than no trigger; the kebab subdues itself with text-gray-400 so
    # it stays decorative rather than fighting the comment body.
    div(
      class: "absolute top-1 right-1",
      data: { controller: "dropdown",
              action: "keydown.esc@window->dropdown#close" }
    ) do
      kebab_trigger
      kebab_menu
    end
  end

  def kebab_trigger
    button(
      type: "button",
      class: "rounded p-1 text-gray-400 hover:text-gray-700 hover:bg-gray-100 " \
             "dark:hover:bg-gray-700 dark:hover:text-gray-200",
      data: { dropdown_target: "trigger", action: "dropdown#toggle" },
      aria: { label: "Comment actions", haspopup: "menu", expanded: "false" }
    ) do
      span(class: "block leading-none -mt-1 text-base", aria_hidden: "true") { "⋮" }
    end
  end

  def kebab_menu
    div(
      class: "hidden absolute right-0 mt-1 w-32 rounded-md border border-gray-200 " \
             "dark:border-gray-700 bg-white dark:bg-gray-900 shadow-lg z-10 " \
             "py-1 text-xs",
      role: "menu",
      data: { dropdown_target: "menu" }
    ) do
      reply_menu_item if @can_reply
      edit_menu_item if @can_edit
      delete_menu_item if @can_delete
    end
  end

  def reply_menu_item
    button(
      type: "button",
      class: "block w-full text-left px-3 py-1.5 text-gray-700 dark:text-gray-200 " \
             "hover:bg-gray-100 dark:hover:bg-gray-700",
      role: "menuitem",
      data: {
        action: "click->dropdown#close click->comments-thread#startReply",
        comments_thread_comment_id_param: @comment.id
      }
    ) { "Reply" }
  end

  def edit_menu_item
    button(
      type: "button",
      class: "block w-full text-left px-3 py-1.5 text-gray-700 dark:text-gray-200 " \
             "hover:bg-gray-100 dark:hover:bg-gray-700",
      role: "menuitem",
      data: {
        action: "click->dropdown#close click->comments-thread#startEdit",
        comments_thread_comment_id_param: @comment.id
      }
    ) { "Edit" }
  end

  def delete_menu_item
    # `data-turbo-confirm` goes on the submit BUTTON, not the wrapping
    # form. Turbo's form-submit interceptor checks the button first;
    # placing it on the form via `form: { data: ... }` is documented to
    # work but is less reliable in practice (some Turbo versions only
    # look at the submitter). Keeping it on the button is unambiguous.
    button_to(
      assessment_comment_path(@assessment_id, @comment.id),
      method: :delete,
      class: "block w-full text-left px-3 py-1.5 text-red-700 dark:text-red-300 " \
             "hover:bg-red-50 dark:hover:bg-red-900/30",
      role: "menuitem",
      data: { turbo_confirm: "Delete this comment? Replies will stay visible." }
    ) { "Delete" }
  end
end
