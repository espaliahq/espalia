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

  KIND_LABELS = { "edit" => "Edit", "create" => "New", "delete" => "Archive" }.freeze

  STATUS_STYLES = {
    "pending"   => "bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-300",
    "approved"  => "bg-green-100 text-green-800 dark:bg-green-900/40 dark:text-green-300",
    "rejected"  => "bg-gray-100 text-gray-700 dark:bg-gray-700 dark:text-gray-300",
    "withdrawn" => "bg-gray-100 text-gray-700 dark:bg-gray-700 dark:text-gray-300"
  }.freeze

  # @param framework [FrameworkState::Framework]
  # @param suggestion [FrameworkState::SuggestedEdit]
  # @param comments [Array<FrameworkState::SuggestionComment>]
  # @param author_name [String, nil]
  # @param clear_path [String] URL back to the framework-wide feed
  # @param approval_authority [Frameworks::SuggestionApprovalAuthority]
  # @param viewer_person_id [String, nil]
  # @param can_comment [Boolean]
  # @param tenant_admin [Boolean]
  def initialize(framework:, suggestion:, comments:, author_name:, clear_path:,
                 approval_authority:, viewer_person_id:, can_comment:, tenant_admin: false,
                 alert: nil)
    @framework = framework
    @suggestion = suggestion
    @comments = comments
    @alert = alert
    @author_name = author_name
    @clear_path = clear_path
    @approval_authority = approval_authority
    @viewer_person_id = viewer_person_id
    @can_comment = can_comment
    @tenant_admin = tenant_admin
  end

  def view_template
    turbo_frame_tag("suggestion-panel") do
      div(class: "h-full flex flex-col") do
        header
        div(class: "flex-1 overflow-y-auto p-4") do
          alert_banner if @alert.present?
          proposal_block
          action_row if actionable?
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
      a(
        href: @clear_path,
        class: "text-xs text-gray-600 dark:text-gray-300 hover:text-primary inline-block",
        data: {
          turbo_frame: "suggestion-panel",
          action: "click->context-pane#clearFocus"
        }
      ) { "← Back to activity" }
      div(class: "mt-1 flex items-center justify-between gap-2") do
        h2(class: "text-sm font-semibold text-gray-900 dark:text-white truncate") do
          "#{kind_label} · #{entity_label}"
        end
        status_pill
      end
    end
  end

  def kind_label
    KIND_LABELS[@suggestion.kind] || @suggestion.kind.to_s.humanize
  end

  def entity_label
    ENTITY_TYPE_LABELS[@suggestion.target_entity_type] ||
      @suggestion.target_entity_type.to_s.humanize
  end

  def status_pill
    span(
      class: "inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-medium shrink-0 " \
             "#{STATUS_STYLES[@suggestion.status] || STATUS_STYLES['rejected']}"
    ) { @suggestion.status.to_s.capitalize }
  end

  def proposal_block
    div(class: "rounded-lg border border-gray-200 dark:border-gray-700 p-3 text-xs") do
      if @suggestion.field.present?
        p(class: "text-[10px] font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400") do
          "#{entity_label} #{@suggestion.field}"
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
    if @suggestion.kind == "delete"
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
    # human-readable keys over ids (mirrors PanelFrame#creation_preview).
    attrs = @suggestion.proposed_attributes || {}
    %w[name title description].filter_map { |k| attrs[k].presence }.first ||
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
    @suggestion.status == "pending" &&
      @approval_authority.can_approve?(@suggestion.target_entity_type)
  end

  def resolved?
    %w[approved rejected withdrawn].include?(@suggestion.status)
  end

  def action_row
    div(
      class: "mt-3 flex items-center gap-2",
      data: {
        controller: "suggestion-action",
        suggestion_action_approve_url_value:
          approve_framework_suggestion_path(@framework.framework_id, @suggestion.suggestion_id, inline: 1)
      }
    ) do
      button(
        type: "button",
        class: "inline-flex items-center rounded px-2 py-0.5 text-[11px] font-medium " \
               "bg-green-600 text-white hover:bg-green-700 transition-colors " \
               "disabled:opacity-50 disabled:cursor-not-allowed",
        data: { action: "suggestion-action#approve" }
      ) { "Approve" }
      button(
        type: "button",
        class: "inline-flex items-center rounded px-2 py-0.5 text-[11px] font-medium " \
               "border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-200 " \
               "hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors",
        data: {
          action: "click->modal#open",
          modal_target_id: "reject-suggestion-modal",
          reject_suggestion_id: @suggestion.suggestion_id,
          reject_framework_id: @framework.framework_id,
          reject_entity_label: entity_label,
          reject_preview: @suggestion.suggested_value.to_s.strip.presence
        }
      ) { "Reject" }
    end
  end

  def resolution_block
    div(class: "mt-3 rounded-lg bg-gray-50 dark:bg-gray-800/60 p-3 text-[11px] " \
               "text-gray-600 dark:text-gray-300") do
      plain resolution_sentence
      if @suggestion.reviewer_comment.present?
        p(class: "mt-1 italic") { "“#{@suggestion.reviewer_comment}”" }
      end
    end
  end

  def resolution_sentence
    when_bit = @suggestion.reviewed_at ? " #{time_ago_in_words(@suggestion.reviewed_at)} ago" : ""
    case @suggestion.status
    when "approved"  then "Approved#{when_bit}."
    when "rejected"  then "Rejected#{when_bit}."
    when "withdrawn" then "Withdrawn by the author."
    end
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
