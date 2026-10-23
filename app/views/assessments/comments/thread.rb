# frozen_string_literal: true

# Stack of comment cards inside the focused assessment cell, plus an
# inline "Add a comment" textarea.
#
# Rendered only when the viewer has a Person (anonymous viewers can't
# comment, and never see the comment thread). The comment thread is
# anchored to (capability_stable_id, level_ordinal) and survives role
# transitions and framework version drift the same way ratings and
# evidence do.
#
class Views::Assessments::Comments::Thread < Views::Base
  include Phlex::Rails::Helpers::TimeAgoInWords

  # @param comments [Array<PersonDevelopmentComment>] all comments on the cell (any depth)
  # @param assessment_id [String]
  # @param viewer_person_id [String]
  # @param can_create [Boolean]
  # @param tenant_admin [Boolean] tenant admins can delete (but not edit) others' comments
  # @param capability_stable_id [String]
  # @param level_ordinal [Integer]
  def initialize(comments:, assessment_id:, viewer_person_id:, can_create:,
                 capability_stable_id:, level_ordinal:, tenant_admin: false)
    @comments = comments
    @assessment_id = assessment_id
    @viewer_person_id = viewer_person_id
    @can_create = can_create
    @tenant_admin = tenant_admin
    @capability_stable_id = capability_stable_id
    @level_ordinal = level_ordinal
  end

  def view_template
    div(
      id: dom_id,
      class: "mt-4 pt-3 border-t border-default",
      data: { controller: "comments-thread" }
    ) do
      header
      if @comments.any?
        ul(class: "space-y-0.5") do
          render_thread_tree
        end
      end
      composer if @can_create
    end
  end

  private

  def composer_hint_id
    "comment-hint-#{@capability_stable_id}-#{@level_ordinal}"
  end

  def dom_id
    "comments-thread-#{@capability_stable_id}-#{@level_ordinal}"
  end

  # Header pairs the section label with a `+` affordance that toggles
  # the composer. When the viewer can create, the whole header line is
  # the click target — a 1px-tall row of microtype was a hard-to-hit
  # affordance on touch.
  def header
    if @can_create
      add_button
    else
      div(class: header_label_classes) do
        header_label_content
      end
    end
  end

  def add_button
    button(
      type: "button",
      class: "#{header_label_classes} w-full min-h-6 text-left cursor-pointer rounded px-1 -mx-1 py-1 " \
             "hover:bg-default-hover hover:text-default transition-colors",
      aria: { label: "Add a comment" },
      data: { action: "click->comments-thread#toggleComposer" }
    ) do
      header_label_content
      span(class: "ml-auto block text-sm leading-none", aria_hidden: "true") { "+" }
    end
  end

  def header_label_classes
    "flex items-center gap-1 text-[10px] uppercase tracking-wide " \
      "text-muted mb-2"
  end

  # When the thread is empty AND the viewer can comment, lean the label
  # into the affordance ("Add a comment") rather than describing an
  # empty section ("Comments"). With comments present, switch back to
  # the section label + count. When the viewer can't comment (read-only
  # peer view), don't dangle an affordance they can't act on — render
  # the plain "Comments" label.
  def header_label_content
    if visible_count.positive?
      span { "Comments" }
      span(class: "font-mono") { "(#{visible_count})" }
    elsif @can_create
      span { "Add a comment" }
    else
      span { "Comments" }
    end
  end

  # Count non-deleted comments. Deleted ones still render as tombstones
  # but don't get counted in the (N) badge.
  def visible_count
    @visible_count ||= @comments.count { |c| !c.deleted? }
  end

  # Renders every comment on the cell as a flat, chronological stream.
  # Threading is conveyed not by nesting but by a small "↳ replying to
  # <author>" affordance on any comment whose parent isn't the line
  # directly above it — when a reply follows the comment it answers, the
  # relationship is self-evident and the chip is omitted.
  #
  # Deleted-comment visibility rule: a tombstone stays only when it is
  # load-bearing — i.e. some still-visible comment replied to it, so a
  # "↳ replying to …" link would otherwise dangle. Deleted comments that
  # nothing points at are dropped entirely. This preserves conversational
  # continuity without accumulating dead-comment clutter. The cell's
  # `comment_count` badge already counts only active comments, so
  # tombstone visibility here doesn't bleed into the count.
  def render_thread_tree
    ordered = @comments.sort_by(&:posted_at)
    referenced_parent_ids = ordered.reject(&:deleted?).filter_map(&:parent_id).to_set
    by_id = ordered.index_by(&:id)
    visible = ordered.reject { |c| c.deleted? && !referenced_parent_ids.include?(c.id) }

    previous_id = nil
    visible.each do |comment|
      parent = comment.parent_id && by_id[comment.parent_id]
      # Show the "replying to" chip only when the answered comment isn't
      # the one rendered immediately above — otherwise the link is noise.
      reply_to = (parent if parent && comment.parent_id != previous_id)
      # Any reply gets a single level of indent. Depth beyond one is
      # conveyed by the chip, not deeper nesting — so a reply-to-a-reply
      # sits at the same indent as a reply, never further right.
      render_card(comment, indent: comment.parent_id.present?, reply_to: reply_to)
      previous_id = comment.id
    end
  end

  def render_card(comment, indent:, reply_to:)
    render Views::Assessments::Comments::Card.new(
      comment: comment,
      assessment_id: @assessment_id,
      can_edit: can_edit?(comment),
      can_delete: can_delete?(comment),
      # Reply rights match comment-creation rights — anyone who can post
      # a comment can reply to any comment on the cell.
      can_reply: @can_create,
      indent: indent,
      reply_to: reply_to
    )
  end

  def can_edit?(comment)
    !comment.deleted? && comment.author_id == @viewer_person_id
  end

  def can_delete?(comment)
    return false if comment.deleted?

    comment.author_id == @viewer_person_id || @tenant_admin
  end

  # Inline composer at the bottom of the thread. Hidden by default;
  # the `+` icon in the header toggles it open. Once posted the
  # `submitted` Stimulus action clears the textarea and re-hides the
  # composer so the next interaction returns to the compact state.
  def composer
    form(
      action: assessment_comments_path(@assessment_id),
      method: "post",
      class: "hidden mt-2",
      data: {
        comments_thread_target: "composer",
        action: "turbo:submit-end->comments-thread#submitted"
      }
    ) do
      input(type: "hidden", name: "authenticity_token",
            value: view_context.form_authenticity_token)
      input(type: "hidden", name: "comment[capability_stable_id]",
            value: @capability_stable_id)
      input(type: "hidden", name: "comment[level_ordinal]", value: @level_ordinal)

      textarea(
        name: "comment[body]",
        rows: 2,
        required: true,
        placeholder: "Add a comment…",
        aria: { label: "Add a comment", describedby: composer_hint_id },
        class: Components::Kit::Field::INLINE,
        data: {
          comments_thread_target: "composerBody",
          action: "keydown->comments-thread#submitOnModEnter"
        }
      ) { "" }

      div(class: "mt-1 flex items-center justify-between gap-2") do
        # OS-agnostic hint — the Stimulus controller treats both metaKey
        # and ctrlKey as the submit modifier so we don't need to detect
        # the platform server-side. Mac users read this as "⌘+Enter",
        # PC/Linux users read it as "Ctrl+Enter".
        span(id: composer_hint_id, class: "text-[10px] text-muted") do
          plain "#{Prose::COMPOSER_HINT} · ⌘/Ctrl+Enter to post"
        end
        render Components::Kit::Button.new(tone: :brand, size: :xs, compact: true, type: :submit) { "Post" }
      end
    end
  end
end
