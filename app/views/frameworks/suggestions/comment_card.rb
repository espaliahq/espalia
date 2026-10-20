# frozen_string_literal: true

# One comment inside a suggestion's discussion thread. Mirrors the
# assessment comment card (Views::Assessments::Comments::Card): author +
# relative timestamp, body, kebab with reply / edit / delete, tombstone
# style for deleted comments, and the "↳ replying to" chip when the
# answered comment isn't the line directly above.
#
class Views::Frameworks::Suggestions::CommentCard < Views::Base
  include Phlex::Rails::Helpers::TimeAgoInWords
  include Phlex::Rails::Helpers::ButtonTo

  # @param comment [FrameworkState::SuggestionComment]
  # @param framework_id [String]
  # @param suggestion_id [String]
  # @param can_edit [Boolean]
  # @param can_delete [Boolean]
  # @param can_reply [Boolean]
  # @param indent [Boolean] true for any reply — one visual level only;
  #   replies-of-replies share the same indent (depth rides the chip)
  # @param reply_to [FrameworkState::SuggestionComment, nil]
  # @param return_to [String] "panel" | "detail"
  def initialize(comment:, framework_id:, suggestion_id:, can_edit: false,
                 can_delete: false, can_reply: false, indent: false,
                 reply_to: nil, return_to: "panel")
    @comment = comment
    @framework_id = framework_id
    @suggestion_id = suggestion_id
    @can_edit = can_edit
    @can_delete = can_delete
    @can_reply = can_reply
    @indent = indent
    @reply_to = reply_to
    @return_to = return_to
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
    span(class: "mt-1 w-2 h-2 rounded-full shrink-0 bg-activity-discussion", title: "Comment") { }
  end

  def header_line
    div(class: "flex flex-wrap items-center gap-x-2 text-[11px]") do
      span(class: "font-medium text-default") do
        @comment.author&.name || "Unknown"
      end
      if @comment.posted_at
        span(
          class: "text-muted",
          title: "Posted #{@comment.posted_at.utc.iso8601}"
        ) { "#{time_ago_in_words(@comment.posted_at)} ago" }
      end
      if @comment.edited_at.present?
        span(
          class: "text-muted italic",
          title: "Last edited #{@comment.edited_at.utc.iso8601}"
        ) { "(edited)" }
      end
    end
  end

  def body_line
    render Components::Kit::Prose.new(@comment.body, class: "mt-0.5 text-muted",
                                                     data: { comments_thread_target: "displayBody" })
    edit_form if @can_edit
  end

  # Inline reply composer, hidden until the kebab's "Reply" opens it. Posts
  # a NEW comment on the same suggestion with parent_id set.
  def reply_form
    form(
      action: framework_suggestion_comments_path(@framework_id, @suggestion_id),
      method: "post",
      class: "hidden mt-1",
      data: {
        comments_thread_target: "replyForm",
        action: "turbo:submit-end->comments-thread#submitted"
      }
    ) do
      input(type: "hidden", name: "authenticity_token",
            value: view_context.form_authenticity_token)
      input(type: "hidden", name: "return_to", value: @return_to)
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
        render Components::Kit::Button.new(tone: :brand, size: :xs, type: :submit) { "Reply" }
        render Components::Kit::Button.new(variant: :ghost, size: :xs,
                                           data: { action: "click->comments-thread#cancelReply" }) { "Cancel" }
      end
    end
  end

  def edit_form
    form(
      action: framework_suggestion_comment_path(@framework_id, @suggestion_id, @comment.id),
      method: "post",
      class: "hidden mt-1",
      data: {
        comments_thread_target: "editForm",
        action: "turbo:submit-end->comments-thread#submitted"
      }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "_method", value: "patch")
      input(type: "hidden", name: "return_to", value: @return_to)
      textarea(
        name: "comment[body]",
        rows: 3,
        required: true,
        aria: { label: "Edit comment" },
        class: Components::Kit::Field::INLINE,
        data: { action: "keydown->comments-thread#submitOnModEnter" }
      ) { @comment.body }
      div(class: "mt-1 flex items-center gap-2") do
        render Components::Kit::Button.new(tone: :brand, size: :xs, type: :submit) { "Save" }
        render Components::Kit::Button.new(variant: :ghost, size: :xs,
                                           data: { action: "click->comments-thread#cancelEdit" }) { "Cancel" }
      end
    end
  end

  def deleted_body
    div(class: "italic text-muted") do
      plain "[deleted]"
      plain " — #{@comment.deletion_reason}" if @comment.deletion_reason.present?
    end
  end

  # Kebab stays visible at all times — the opacity-0/hover pattern hides
  # Reply on touch devices (see the assessment card for the full rationale).
  def actions_menu
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
    # `data-turbo-confirm` goes on the submit BUTTON (see the assessment
    # card for why the wrapping form is less reliable).
    button_to(
      framework_suggestion_comment_path(@framework_id, @suggestion_id, @comment.id,
                                        return_to: @return_to),
      method: :delete,
      class: Components::Kit::Dropdown.item_classes(tone: :danger, size: :xs),
      role: "menuitem",
      data: { turbo_confirm: "Delete this comment? Replies will stay visible." }
    ) { "Delete" }
  end
end
