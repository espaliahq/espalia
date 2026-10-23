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
  # @param indent [Boolean] true for any reply — a single level of visual
  #   indent. Depth beyond one is conveyed by the reply chip, not by
  #   deeper nesting, so replies-of-replies share this same indent.
  # @param reply_to [PersonDevelopmentComment, nil] the comment this one
  #   answers, when it should be surfaced (i.e. the parent isn't the line
  #   rendered directly above — see Thread#render_thread_tree). nil hides
  #   the "↳ replying to" affordance.
  def initialize(comment:, assessment_id:, can_edit: false, can_delete: false,
                 can_reply: false, indent: false, reply_to: nil)
    @comment = comment
    @assessment_id = assessment_id
    @can_edit = can_edit
    @can_delete = can_delete
    # Display is flat beyond one level — any comment on the cell can be replied to.
    @can_reply = can_reply
    @indent = indent
    @reply_to = reply_to
  end

  def view_template
    li(
      id: "comment-#{@comment.id}",
      class: [ "group relative flex gap-2 py-1.5 text-xs",
               "text-muted",
               @indent ? "pl-5" : "" ].join(" ")
    ) do
      avatar_dot
      div(class: "min-w-0 flex-1") do
        if @comment.deleted?
          deleted_body
        else
          reply_context_chip if @reply_to
          header_line
          body_line
          reply_form if @can_reply
        end
      end
      actions_menu if !@comment.deleted? && (@can_edit || @can_delete || @can_reply)
    end
  end

  private

  # Small "↳ replying to <author>" link shown when the answered comment
  # isn't the one directly above. Clicking scrolls to and briefly
  # highlights the parent so the reader can find it in the flat stream.
  def reply_context_chip
    a(
      href: "#comment-#{@reply_to.id}",
      class: "inline-flex items-center gap-1 text-[10px] text-muted",
      title: "Replying to #{reply_to_author_name}",
      data: {
        action: "click->comments-thread#scrollToComment",
        comments_thread_comment_id_param: @reply_to.id
      }
    ) do
      plain "↳ replying to #{reply_to_author_name}"
    end
  end

  def reply_to_author_name
    return "a deleted comment" if @reply_to.deleted?

    @reply_to.author&.name.to_s.strip.presence || "Unknown"
  end

  def avatar_dot
    span(
      class: "mt-1 w-2 h-2 rounded-full shrink-0 bg-activity-discussion",
      title: "Comment"
    ) { }
  end

  def header_line
    div(class: "flex flex-wrap items-center gap-x-2 text-[11px]") do
      span(class: "font-medium text-default") do
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
          class: "inline-flex items-center gap-1 text-muted " \
                 "underline decoration-dotted decoration-(--gos-border-emphasized) " \
                 "underline-offset-2 hover:decoration-solid",
          title: "Link to this comment · posted #{@comment.posted_at.utc.iso8601}",
          # The card can render inside the evidence-linkage thread frame;
          # the permalink is a full-page navigation and must escape it.
          data: { turbo_frame: "_top" }
        ) do
          permalink_icon
          plain "#{time_ago_in_words(@comment.posted_at)} ago"
        end
      else
        span(class: "text-muted") { "—" }
      end
      if @comment.edited_at.present?
        span(
          class: "text-muted italic",
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
    # full body.
    render Components::Kit::Prose.new(@comment.body, class: "mt-0.5 text-muted",
                                                     data: { comments_thread_target: "displayBody" })
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
      # Replies inherit the parent's anchor — for an evidence-linkage
      # comment that includes the evidence_id, so the reply lands on the
      # same linkage thread.
      if @comment.evidence_id.present?
        input(type: "hidden", name: "comment[evidence_id]", value: @comment.evidence_id)
      end
      input(type: "hidden", name: "comment[parent_id]", value: @comment.id)
      textarea(
        name: "comment[body]",
        rows: 2,
        required: true,
        placeholder: "Reply…",
        aria: { label: "Reply to comment" },
        class: Components::Kit::Field::INLINE,
        data: {
          comments_thread_target: "replyBody",
          action: "keydown->comments-thread#submitOnModEnter"
        }
      ) { "" }
      div(class: "mt-1 flex items-center gap-2") do
        render Components::Kit::Button.new(tone: :brand, size: :xs, compact: true, type: :submit) { "Reply" }
        render Components::Kit::Button.new(variant: :ghost, size: :xs, compact: true,
                                           data: { action: "click->comments-thread#cancelReply" }) { "Cancel" }
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
        aria: { label: "Edit comment" },
        class: Components::Kit::Field::INLINE,
        data: { action: "keydown->comments-thread#submitOnModEnter" }
      ) { @comment.body }
      div(class: "mt-1 flex items-center gap-2") do
        render Components::Kit::Button.new(tone: :brand, size: :xs, compact: true, type: :submit) { "Save" }
        render Components::Kit::Button.new(variant: :ghost, size: :xs, compact: true,
                                           data: { action: "click->comments-thread#cancelEdit" }) { "Cancel" }
      end
    end
  end

  def deleted_body
    div(class: "italic text-muted") do
      plain "[deleted]"
      if @comment.deletion_reason.present?
        plain " — #{@comment.deletion_reason}"
      end
    end
  end

  def actions_menu
    # Kebab stays visible at all times — the opacity-0/hover pattern
    # hid Reply on touch devices entirely and was hard to discover on
    # desktop.
    div(class: "absolute top-1 right-1") do
      render Components::Kit::Dropdown.new do |dropdown|
        dropdown.trigger(label: "Comment actions", button: { variant: :ghost, size: :xs, icon: true }) do
          icon("kebab", class: "size-4")
        end
        dropdown.menu(width: "w-32") do
          reply_menu_item(dropdown) if @can_reply
          edit_menu_item(dropdown) if @can_edit
          delete_menu_item if @can_delete
        end
      end
    end
  end

  def reply_menu_item(dropdown)
    dropdown.item(size: :xs, data: {
      action: "click->dropdown#close click->comments-thread#startReply",
      comments_thread_comment_id_param: @comment.id
    }) { "Reply" }
  end

  def edit_menu_item(dropdown)
    dropdown.item(size: :xs, data: {
      action: "click->dropdown#close click->comments-thread#startEdit",
      comments_thread_comment_id_param: @comment.id
    }) { "Edit" }
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
      class: Components::Kit::Dropdown.item_classes(tone: :danger, size: :xs),
      role: "menuitem",
      data: { turbo_confirm: "Delete this comment? Replies will stay visible." }
    ) { "Delete" }
  end
end
