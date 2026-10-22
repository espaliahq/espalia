# frozen_string_literal: true

# The discussion thread on one framework suggestion — a stack of comment
# cards plus an inline composer. Mirrors the assessment cell's comment
# thread (Views::Assessments::Comments::Thread): display is chronological
# and flat with ONE level of indent for any reply; depth beyond one is
# conveyed by the "↳ replying to" chip, never deeper nesting. Deleted
# comments render as tombstones only while a live reply references them.
#
# Rendered on both thread surfaces — the context pane's suggestion card
# and the suggestion detail page — differentiated by `return_to`, which
# rides the forms so the controller redirects back to the right surface.
#
class Views::Frameworks::Suggestions::Thread < Views::Base
  # @param comments [Array<FrameworkState::SuggestionComment>] all comments
  #   on the suggestion (any depth, incl. deleted)
  # @param framework_id [String]
  # @param suggestion_id [String]
  # @param viewer_person_id [String, nil]
  # @param can_comment [Boolean]
  # @param tenant_admin [Boolean] tenant admins can delete (but not edit) others' comments
  # @param return_to [String] "panel" | "detail" — which surface hosts the thread
  def initialize(comments:, framework_id:, suggestion_id:, viewer_person_id:,
                 can_comment:, tenant_admin: false, return_to: "panel")
    @comments = comments
    @framework_id = framework_id
    @suggestion_id = suggestion_id
    @viewer_person_id = viewer_person_id
    @can_comment = can_comment
    @tenant_admin = tenant_admin
    @return_to = return_to
  end

  def view_template
    div(
      id: "suggestion-thread-#{@suggestion_id}",
      class: "mt-3 pt-3 border-t border-default",
      data: { controller: "comments-thread" }
    ) do
      header
      if @comments.any?
        ul(class: "space-y-0.5") do
          render_thread_tree
        end
      end
      composer if @can_comment
    end
  end

  private

  def composer_hint_id
    "suggestion-comment-hint-#{@suggestion_id}"
  end

  def header
    div(class: header_label_classes) do
      span { "Discussion" }
      if visible_count.positive?
        span(class: "text-muted") { visible_count.to_s }
      end
    end
  end

  def header_label_classes
    "flex items-center gap-2 text-[10px] font-semibold uppercase tracking-wide " \
      "text-muted mb-1"
  end

  def visible_count
    @comments.count { |c| !c.deleted? }
  end

  # Chronological flat render with one indent level — the same algorithm as
  # the assessment thread: deleted comments show only while a live reply
  # references them; the "replying to" chip appears only when the answered
  # comment isn't the line directly above.
  def render_thread_tree
    ordered = @comments.sort_by(&:posted_at)
    referenced_parent_ids = ordered.reject(&:deleted?).filter_map(&:parent_id).to_set
    by_id = ordered.index_by(&:id)
    visible = ordered.reject { |c| c.deleted? && !referenced_parent_ids.include?(c.id) }

    previous_id = nil
    visible.each do |comment|
      parent = comment.parent_id && by_id[comment.parent_id]
      reply_to = (parent if parent && comment.parent_id != previous_id)
      render Views::Frameworks::Suggestions::CommentCard.new(
        comment: comment,
        framework_id: @framework_id,
        suggestion_id: @suggestion_id,
        can_edit: can_edit?(comment),
        can_delete: can_delete?(comment),
        # Reply rights match comment rights — anyone who can post can reply
        # to any non-deleted comment on the suggestion.
        can_reply: @can_comment,
        indent: comment.parent_id.present?,
        reply_to: reply_to,
        return_to: @return_to
      )
      previous_id = comment.id
    end
  end

  def can_edit?(comment)
    @viewer_person_id.present? && comment.author_id == @viewer_person_id
  end

  def can_delete?(comment)
    @tenant_admin || can_edit?(comment)
  end

  def composer
    form(
      action: framework_suggestion_comments_path(@framework_id, @suggestion_id),
      method: "post",
      class: "mt-2",
      data: {
        comments_thread_target: "composer",
        action: "turbo:submit-end->comments-thread#submitted"
      }
    ) do
      input(type: "hidden", name: "authenticity_token",
            value: view_context.form_authenticity_token)
      input(type: "hidden", name: "return_to", value: @return_to)
      textarea(
        name: "comment[body]",
        rows: 2,
        required: true,
        placeholder: "Add to the discussion…",
        aria: { label: "Comment on this suggestion", describedby: composer_hint_id },
        class: Components::Kit::Field::INLINE,
        data: {
          comments_thread_target: "composerBody",
          action: "keydown->comments-thread#submitOnModEnter"
        }
      ) { "" }
      div(class: "mt-1 flex items-center justify-between gap-2") do
        span(id: composer_hint_id, class: "text-[10px] text-muted") { Prose::COMPOSER_HINT }
        render Components::Kit::Button.new(tone: :brand, size: :xs, type: :submit) { "Comment" }
      end
    end
  end
end
