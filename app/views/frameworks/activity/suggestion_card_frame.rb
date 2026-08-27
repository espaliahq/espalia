# frozen_string_literal: true

# The context pane's SUGGESTION FOCUS view — one suggestion's consolidated
# card: the proposal, its resolution state, the inline Approve / Reject
# affordances (the same §12 machinery the feed entries use), and the
# discussion thread with composer. Rendered into the same
# `suggestion-panel` Turbo Frame as the feed, swapped in when
# `focus=suggestion&suggestion_id=` is set — so suggestion management
# happens in the pane, next to the matrix context, not on a separate page.
#
class Views::Frameworks::Activity::SuggestionCardFrame < Views::Base
  include Phlex::Rails::Helpers::TurboFrameTag
  include Phlex::Rails::Helpers::TimeAgoInWords

  ENTITY_TYPE_LABELS = Views::Frameworks::Suggestions::IndexView::ENTITY_TYPE_LABELS

  # @param framework [FrameworkState::Framework]
  # @param suggestion [FrameworkState::SuggestedEdit]
  # @param comments [Array<FrameworkState::SuggestionComment>]
  # @param author_name [String, nil]
  # @param clear_path [String] URL back to the framework-wide feed
  # @param permalink [String, nil] absolute, shareable link to this discussion
  # @param approval_authority [Frameworks::SuggestionApprovalAuthority]
  # @param viewer_person_id [String, nil]
  # @param can_comment [Boolean]
  # @param tenant_admin [Boolean]
  def initialize(framework:, suggestion:, comments:, author_name:, clear_path:,
                 approval_authority:, viewer_person_id:, can_comment:, tenant_admin: false,
                 alert: nil, permalink: nil)
    @framework = framework
    @suggestion = suggestion
    @comments = comments
    @alert = alert
    @author_name = author_name
    @clear_path = clear_path
    @permalink = permalink
    @approval_authority = approval_authority
    @viewer_person_id = viewer_person_id
    @can_comment = can_comment
    @tenant_admin = tenant_admin
  end

  def view_template
    turbo_frame_tag("suggestion-panel") do
      div(class: "h-full flex flex-col") do
        header
        # scroller target: broadcast reloads of the card (e.g. a fresh thread
        # comment) preserve the reader's position in a long discussion, same
        # as the feed (see PanelFrame#body).
        div(class: "flex-1 overflow-y-auto p-4", data: { context_pane_target: "scroller" }) do
          alert_banner if @alert.present?
          proposal_block
          action_row if actionable?
          resolve_action_row if resolvable?
          resolution_block if resolved?
          thread
        end
      end
    end
  end

  private

  # Submission errors redirected back into this frame (no layout, so no
  # global flash) — e.g. replying to a just-deleted comment.
  def alert_banner
    div(
      class: "mb-3 rounded-md border border-red-200 dark:border-red-900/50 " \
             "bg-red-50 dark:bg-red-900/20 px-3 py-2 text-[11px] " \
             "text-red-800 dark:text-red-300",
      role: "alert"
    ) { @alert }
  end

  def header
    div(class: "px-4 py-3 border-b border-gray-200 dark:border-gray-700") do
      # Copy link rides the back-link row, which is otherwise empty — putting it
      # beside the title stole enough width to truncate the card's own identity
      # ("Clarify · Expect…"), and a utility control shouldn't cost the heading.
      div(class: "flex items-center justify-between gap-2") do
        a(
          href: @clear_path,
          class: "text-xs text-gray-600 dark:text-gray-300 hover:text-primary inline-block",
          data: {
            turbo_frame: "suggestion-panel",
            action: "click->context-pane#clearFocus"
          }
        ) { "← Back to activity" }
        copy_link_control
      end
      div(class: "mt-1 flex items-center justify-between gap-2") do
        h2(class: "text-sm font-semibold text-gray-900 dark:text-white truncate") do
          "#{kind_label} · #{entity_label}"
        end
        status_pill
      end
    end
  end

  # "Copy link" — the discussion's shareable URL. Sharing the link is how a
  # question reaches the person who should answer it (there are no
  # notifications for discussions yet), so the link needs to be visible rather
  # than something you know to lift out of the address bar.
  #
  # The URL rides in a visually-hidden span because the shared `clipboard`
  # controller copies its source target's text.
  def copy_link_control
    return if @permalink.blank?

    # label_value belongs on the controller ROOT — a Stimulus value read off a
    # child is silently ignored, and the button's rest label would degrade to
    # the class default ("Copy") the first time it restores.
    div(class: "flex items-center",
        data: { controller: "clipboard", clipboard_label_value: "Copy link" }) do
      # aria-hidden: this span exists only to carry the URL for the clipboard
      # controller to read; without it a screen reader announces the whole
      # UUID link before reaching the button. Copy is unaffected — it reads
      # textContent, not the accessibility tree.
      span(class: "sr-only", aria: { hidden: "true" },
           data: { clipboard_target: "source" }) { @permalink }
      button(
        type: "button",
        class: "inline-flex items-center rounded px-1.5 py-0.5 text-[11px] font-medium " \
               "text-gray-600 dark:text-gray-300 hover:text-primary hover:bg-primary/10 " \
               "transition-colors cursor-pointer",
        title: "Copy a link to this discussion",
        data: { action: "clipboard#copy", clipboard_target: "button" }
      ) { "Copy link" }
    end
  end

  def kind_label
    Views::Frameworks::Suggestions::IndexView::KIND_BADGE_LABELS
      .fetch(@suggestion.kind, @suggestion.kind.to_s.humanize)
  end

  def entity_label
    ENTITY_TYPE_LABELS[@suggestion.target_entity_type] ||
      @suggestion.target_entity_type.to_s.humanize
  end

  # The same Kit::Badge + variant map the suggestion index uses, so the
  # same suggestion never shows differently-toned status pills per surface.
  def status_pill
    render Components::Kit::Badge.new(
      @suggestion.status.to_s.capitalize,
      variant: Views::Frameworks::Suggestions::IndexView::STATUS_VARIANTS.fetch(@suggestion.status, :default)
    )
  end

  def proposal_block
    div(class: "rounded-lg border border-gray-200 dark:border-gray-700 p-3 text-xs") do
      if @suggestion.field.present?
        p(class: "text-[10px] font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400") do
          "#{entity_label} #{@suggestion.field}"
        end
      elsif @suggestion.clarification? && clarification_level.present?
        p(class: "text-[10px] font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400") do
          "#{entity_label} · L#{clarification_level}"
        end
      end
      current_and_proposed
      if @suggestion.rationale.present?
        p(class: "mt-2 text-[11px] text-gray-600 dark:text-gray-300 italic") do
          "“#{@suggestion.rationale}”"
        end
      end
      footer_line
    end
  end

  def current_and_proposed
    if @suggestion.clarification?
      # Nothing is proposed — the question (rationale, rendered below) is the
      # content; the anchored text shows plain, never struck through.
      if @suggestion.current_value.present?
        p(class: "mt-1 text-gray-700 dark:text-gray-300 whitespace-pre-wrap break-words") do
          @suggestion.current_value
        end
      end
    elsif @suggestion.kind == "delete"
      p(class: "mt-1 text-gray-700 dark:text-gray-300 line-through") do
        @suggestion.current_value.presence || "(this #{entity_label.downcase})"
      end
    else
      if @suggestion.current_value.present?
        p(class: "mt-1 text-gray-500 dark:text-gray-400 line-through") { @suggestion.current_value }
      end
      p(class: "mt-1 text-gray-900 dark:text-gray-100 whitespace-pre-wrap break-words") do
        proposed_text
      end
    end
  end

  def proposed_text
    return @suggestion.suggested_value if @suggestion.suggested_value.present?

    # Creation proposals carry their content in proposed_attributes — prefer
    # human-readable keys over ids, using the same preferred-key order as
    # the index/panel previews (CONTENT_KEYS) so surfaces can't diverge.
    attrs = @suggestion.proposed_attributes || {}
    Views::Frameworks::Suggestions::IndexView::CONTENT_KEYS
      .filter_map { |k| attrs[k].presence }.first ||
      attrs.values.map(&:to_s).find(&:present?).to_s
  end

  def footer_line
    div(class: "mt-2 text-[10px] text-gray-500 dark:text-gray-400") do
      bits = [ @author_name.presence,
               (@suggestion.created_at && "#{time_ago_in_words(@suggestion.created_at)} ago") ].compact
      span { bits.join(" · ") }
    end
  end

  # The same inline approve + modal reject the feed entries carry (§12) —
  # deciding from the card keeps the read-thread-then-act flow in one place.
  def actionable?
    @suggestion.proposal? &&
      @suggestion.status == "pending" &&
      @approval_authority.can_approve?(@suggestion.target_entity_type)
  end

  # A pending clarification carries "Resolve…" instead of Approve/Reject —
  # expectation-tier authority, matching FrameworkSuggestionPolicy#resolve?.
  def resolvable?
    @suggestion.clarification? &&
      @suggestion.status == "pending" &&
      @approval_authority.can_resolve_clarifications?
  end

  def resolved?
    %w[approved rejected withdrawn resolved].include?(@suggestion.status)
  end

  def action_row
    div(class: "mt-1.5") do
      render Views::Frameworks::Activity::SuggestionActions.new(
        framework_id: @framework.framework_id,
        suggestion_id: @suggestion.suggestion_id,
        entity_label: entity_label,
        reject_preview: @suggestion.suggested_value.to_s.strip.presence
      )
    end
  end

  def resolve_action_row
    render Views::Frameworks::Activity::ClarificationActions.new(
      framework_id: @framework.framework_id,
      suggestion_id: @suggestion.suggestion_id,
      question_preview: @suggestion.rationale.to_s.strip.presence
    )
  end

  def resolution_block
    div(class: "mt-3 rounded-lg bg-gray-50 dark:bg-gray-800/60 p-3 text-[11px] " \
               "text-gray-600 dark:text-gray-300") do
      plain resolution_sentence
      if @suggestion.reviewer_comment.present?
        p(class: "mt-1 italic") { "“#{@suggestion.reviewer_comment}”" }
      end
      resulting_suggestion_link if @suggestion.resulting_suggestion_id.present?
    end
  end

  # A resolved clarification can name the concrete change it spawned — link
  # its detail page (full-page escape hatch, so break out of the frame).
  def resulting_suggestion_link
    p(class: "mt-1") do
      a(
        href: framework_suggestion_path(@framework.framework_id, @suggestion.resulting_suggestion_id),
        class: "text-primary hover:underline",
        data: { turbo_frame: "_top" }
      ) { "View the resulting suggestion →" }
    end
  end

  def resolution_sentence
    when_bit = @suggestion.reviewed_at ? " #{time_ago_in_words(@suggestion.reviewed_at)} ago" : ""
    case @suggestion.status
    when "approved"  then "Approved#{when_bit}."
    when "rejected"  then "Rejected#{when_bit}."
    when "resolved"  then "Resolved#{when_bit}."
    when "withdrawn" then "Withdrawn by the author."
    end
  end

  # A capability-anchored clarification carries its level in
  # proposed_attributes; an expectation anchor implies it (shown via the
  # snapshot text instead).
  def clarification_level
    (@suggestion.proposed_attributes || {})["level_ordinal"]
  end

  def thread
    render Views::Frameworks::Suggestions::Thread.new(
      comments: @comments,
      framework_id: @framework.framework_id,
      suggestion_id: @suggestion.suggestion_id,
      viewer_person_id: @viewer_person_id,
      can_comment: @can_comment,
      tenant_admin: @tenant_admin,
      return_to: "panel"
    )
  end
end
