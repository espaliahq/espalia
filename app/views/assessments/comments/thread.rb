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

  # @param comments [Array<PersonDevelopmentComment>] chronological, top-level + replies
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
      class: "mt-3 pt-2 border-t border-gray-200 dark:border-gray-700",
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

  def dom_id
    "comments-thread-#{@capability_stable_id}-#{@level_ordinal}"
  end

  # Header pairs the section label with a small `+` affordance that
  # toggles the composer. Composer is hidden by default to reclaim
  # vertical space — the textarea no longer sits empty under every
  # focused cell.
  def header
    div(class: "flex items-center gap-1 text-[10px] uppercase tracking-wide " \
               "text-gray-500 dark:text-gray-400 mb-1") do
      span { "Comments" }
      span(class: "font-mono") { "(#{visible_count})" } if visible_count.positive?
      add_icon if @can_create
    end
  end

  def add_icon
    button(
      type: "button",
      class: "ml-auto rounded p-0.5 text-gray-400 hover:text-gray-700 hover:bg-gray-100 " \
             "dark:hover:bg-gray-700 dark:hover:text-gray-200",
      aria: { label: "Add a comment" },
      data: { action: "click->comments-thread#toggleComposer" }
    ) do
      span(class: "block text-sm leading-none", aria_hidden: "true") { "+" }
    end
  end

  # Count non-deleted comments. Deleted ones still render as tombstones
  # but don't get counted in the (N) badge.
  def visible_count
    @visible_count ||= @comments.count { |c| !c.deleted? }
  end

  # Renders comments top-level-first, with replies grouped under their
  # parent. V1 supports a single level of replies — replies-of-replies
  # are flattened to the first reply level.
  #
  # Deleted-comment visibility rule: a tombstone stays only when it is
  # load-bearing for thread structure — i.e. when its presence is the
  # only reason a still-visible reply makes sense. Concretely:
  # - Deleted REPLIES are always hidden (they are leaves; nothing depends
  #   on them).
  # - Deleted TOP-LEVELS are hidden when they have no non-deleted
  #   replies, and kept (as a "[deleted]" tombstone) when active
  #   replies still hang off them.
  # This preserves conversational continuity for active threads without
  # accumulating dead-comment clutter indefinitely. The cell's
  # `comment_count` badge already counts only active comments, so
  # tombstone visibility here doesn't bleed into the count.
  def render_thread_tree
    by_parent = @comments.group_by(&:parent_id)
    top_level = by_parent[nil] || []
    top_level.sort_by(&:posted_at).each do |comment|
      replies = (by_parent[comment.id] || []).reject(&:deleted?).sort_by(&:posted_at)
      next if comment.deleted? && replies.empty?

      render_card(comment, indent: false)
      replies.each { |reply| render_card(reply, indent: true) }
    end
  end

  def render_card(comment, indent:)
    render Views::Assessments::Comments::Card.new(
      comment: comment,
      assessment_id: @assessment_id,
      can_edit: can_edit?(comment),
      can_delete: can_delete?(comment),
      # Reply rights match comment-creation rights — anyone who can
      # post a top-level comment can reply to one. Card-side guard
      # then narrows further (only top-level comments expose Reply,
      # to preserve the one-level threading invariant).
      can_reply: @can_create,
      indent: indent
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
        class: "w-full rounded-md border border-gray-300 dark:border-gray-600 " \
               "bg-white dark:bg-gray-800 px-2 py-1 text-xs text-gray-900 dark:text-white " \
               "focus:outline-none focus:ring-2 focus:ring-primary",
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
        span(class: "text-[10px] text-gray-400 dark:text-gray-500") do
          plain "⌘/Ctrl+Enter to post"
        end
        button(
          type: "submit",
          class: "px-2 py-1 text-[11px] rounded-md bg-primary text-white hover:bg-primary/90"
        ) { "Post" }
      end
    end
  end
end
