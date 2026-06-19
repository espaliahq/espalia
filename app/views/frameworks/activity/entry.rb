# frozen_string_literal: true

# Renders a single framework activity feed entry.
#
# Each entry kind has a short summary line, an optional where-in-the-framework
# context line (never truncated — see framework-explorer.md §9), and a footer
# (actor · timestamp). Capability/category-anchored entries are clickable —
# they navigate the explorer matrix to the entity, reusing the context pane's
# `focusSuggestion` handler.
#
# Internal categorisations (review tiers, entity-type codes) are never
# surfaced — they serve the system, not the user.
#
class Views::Frameworks::Activity::Entry < Views::Base
  include Phlex::Rails::Helpers::TimeAgoInWords

  ENTITY_TYPE_LABELS = Views::Frameworks::Suggestions::IndexView::ENTITY_TYPE_LABELS

  KIND_DOT = {
    "suggestion_edit"           => "bg-sky-500",
    "suggestion_create"         => "bg-sky-500",
    "suggestion_delete"         => "bg-sky-500",
    "suggestion_amended"        => "bg-sky-500",
    "suggestion_approved"       => "bg-green-600",
    "suggestion_rejected"       => "bg-gray-400",
    "suggestion_withdrawn"      => "bg-gray-400",
    "capability_added"          => "bg-emerald-500",
    "capability_archived"       => "bg-amber-500",
    "capability_updated"        => "bg-indigo-500",
    "category_added"            => "bg-emerald-500",
    "category_archived"         => "bg-amber-500",
    "category_updated"          => "bg-indigo-500",
    "binding_added"             => "bg-emerald-500",
    "binding_updated"           => "bg-indigo-500",
    "binding_removed"           => "bg-gray-400",
    "expectation_added"         => "bg-emerald-500",
    "expectation_updated"       => "bg-indigo-500",
    "illustration_added"        => "bg-indigo-500",
    "illustration_updated"      => "bg-indigo-500",
    "illustration_removed"      => "bg-gray-400",
    "draft_opened"              => "bg-purple-500",
    "version_published"         => "bg-green-600",
    "migration_mapping_defined" => "bg-purple-500",
    "collaborator_added"        => "bg-indigo-500",
    "collaborator_role_changed" => "bg-indigo-500",
    "collaborator_removed"      => "bg-gray-400"
  }.freeze

  # Maps each kind to one of the five filter-chip groups.
  KIND_GROUP = {
    "suggestion_edit"           => "suggestions",
    "suggestion_create"         => "suggestions",
    "suggestion_delete"         => "suggestions",
    "suggestion_amended"        => "suggestions",
    "suggestion_approved"       => "suggestions",
    "suggestion_rejected"       => "suggestions",
    "suggestion_withdrawn"      => "suggestions",
    "capability_updated"        => "edits",
    "category_updated"          => "edits",
    "expectation_updated"       => "edits",
    "illustration_added"        => "edits",
    "illustration_updated"      => "edits",
    "illustration_removed"      => "edits",
    "capability_added"          => "structural",
    "capability_archived"       => "structural",
    "category_added"            => "structural",
    "category_archived"         => "structural",
    "binding_added"             => "structural",
    "binding_updated"           => "structural",
    "binding_removed"           => "structural",
    "expectation_added"         => "structural",
    "draft_opened"              => "lifecycle",
    "version_published"         => "lifecycle",
    "migration_mapping_defined" => "lifecycle",
    "collaborator_added"        => "collaborators",
    "collaborator_role_changed" => "collaborators",
    "collaborator_removed"      => "collaborators"
  }.freeze

  # @param entry [Frameworks::ActivityFeedQuery::Entry]
  # @param framework_id [String, nil] needed by inline action affordances
  # @param approval_authority [Frameworks::SuggestionApprovalAuthority] per-viewer
  #   authority; an entry is actionable only when its suggestion is pending AND
  #   the viewer can approve its tier
  def initialize(entry:, framework_id: nil, approval_authority: Frameworks::SuggestionApprovalAuthority.none)
    @entry = entry
    @framework_id = framework_id
    @approval_authority = approval_authority
  end

  def view_template
    li(
      id: "framework-activity-#{dom_safe_id}",
      class: "flex gap-2 text-xs text-gray-700 dark:text-gray-300 rounded -mx-2 px-2 py-1.5 " \
             "transition-colors data-[hidden=true]:hidden " \
             "#{navigable_classes if navigable?}",
      tabindex: (navigable? ? "0" : nil),
      role: (navigable? ? "button" : nil),
      data: entry_data
    ) do
      span(class: "mt-1 w-2 h-2 rounded-full shrink-0 #{dot_class}") { }
      div(class: "min-w-0 flex-1") do
        p(class: "font-medium text-gray-900 dark:text-gray-100") { summary_text }
        context_line if context_text
        secondary_line if secondary_text
        footer
        action_row if actionable?
      end
    end
  end

  private

  # Suggestion kinds whose entry can carry the approve/reject action. The
  # original edit AND each amendment qualify — but the query flags all but the
  # most recent proposal per suggestion as `superseded`, so exactly one entry
  # (the latest, showing the up-to-date value) is actionable. approved /
  # rejected / withdrawn are narrative only.
  ACTIONABLE_KINDS = %w[suggestion_edit suggestion_amended suggestion_create suggestion_delete].freeze

  # An entry is actionable when its suggestion is still pending, this is the
  # latest proposal on it (not superseded by a newer amendment), AND the
  # viewer's precomputed authority clears the suggestion's review tier. Computed
  # server-side — an unauthorised viewer never receives the controls.
  def actionable?
    @framework_id.present? &&
      ACTIONABLE_KINDS.include?(@entry.kind) &&
      !@entry.superseded &&
      @entry.suggestion_status == "pending" &&
      @entry.suggestion_entity_type.present? &&
      @approval_authority.can_approve?(@entry.suggestion_entity_type)
  end

  # Inline approve + modal reject for every actionable suggestion kind — edits
  # and amendments (shape-preserving, apply live) AND create/delete proposals
  # (shape-changing: approval stages the add/archive into a draft, deferred
  # until the separate publish gate). All four route through the same approve
  # endpoint + reject modal, so a deletion proposal is as visible and one-click
  # to action as an edit — no muted "Review" link to miss. The else branch is a
  # defensive fallback for any future actionable kind without an inline form.
  def action_row
    if @entry.suggestion_id.present?
      div(
        class: "mt-1.5 flex items-center gap-2",
        data: {
          controller: "suggestion-action",
          suggestion_action_approve_url_value:
            approve_framework_suggestion_path(@framework_id, @entry.suggestion_id, inline: 1)
        }
      ) do
        approve_button
        reject_button
      end
    else
      div(class: "mt-1.5") { review_link }
    end
  end

  def approve_button
    button(
      type: "button",
      class: "inline-flex items-center rounded px-2 py-0.5 text-[11px] font-medium " \
             "bg-green-600 text-white hover:bg-green-700 transition-colors " \
             "disabled:opacity-50 disabled:cursor-not-allowed",
      data: { action: "suggestion-action#approve" }
    ) { "Approve" }
  end

  def reject_button
    button(
      type: "button",
      class: "inline-flex items-center rounded px-2 py-0.5 text-[11px] font-medium " \
             "border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-200 " \
             "hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors",
      data: {
        action: "click->modal#open",
        modal_target_id: "reject-suggestion-modal",
        reject_suggestion_id: @entry.suggestion_id,
        reject_framework_id: @framework_id,
        reject_entity_label: entity_word,
        reject_preview: reject_preview
      }
    ) { "Reject" }
  end

  def review_link
    a(
      href: framework_suggestion_path(@framework_id, @entry.suggestion_id),
      class: "inline-flex items-center rounded px-2 py-0.5 text-[11px] font-medium " \
             "text-primary hover:bg-primary/10 transition-colors",
      data: { turbo_frame: "_top" }
    ) { "Review" }
  end

  # The proposed value, shown in the reject modal so the reviewer sees what
  # they're declining.
  def reject_preview
    # Amendments carry the proposed value under :new_suggested_value.
    (payload_value(:suggested_value) || payload_value(:new_suggested_value)).to_s.strip.presence
  end

  def dom_safe_id
    @entry.id.to_s.gsub(/[^a-zA-Z0-9_-]/, "-")
  end

  def dot_class
    KIND_DOT[@entry.kind] || "bg-gray-400"
  end

  def kind_group
    KIND_GROUP[@entry.kind] || "lifecycle"
  end

  # Anchored entries navigate the matrix to their capability/category.
  def navigable?
    @entry.capability_id.present? || @entry.category_id.present?
  end

  def navigable_classes
    "cursor-pointer hover:bg-gray-100/60 dark:hover:bg-gray-700/40 " \
      "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60"
  end

  def entry_data
    base = { framework_activity_target: "entry", kind_group: kind_group }
    if navigable?
      base[:action] = "click->context-pane#focusSuggestion " \
                      "keydown.enter->context-pane#focusSuggestion " \
                      "keydown.space->context-pane#focusSuggestion"
      if @entry.capability_id.present?
        base[:nav_level] = "capability"
        base[:nav_capability_id] = @entry.capability_id
      else
        base[:nav_level] = "category"
      end
      base[:nav_category_id] = @entry.category_id if @entry.category_id.present?
    end
    base
  end

  def context_line
    p(class: "mt-0.5 text-[11px] text-gray-600 dark:text-gray-300") { context_text }
  end

  def secondary_line
    p(class: "mt-0.5 text-[11px] text-gray-500 dark:text-gray-400 line-clamp-2") { secondary_text }
  end

  def footer
    div(class: "mt-1 text-[10px] text-gray-500 dark:text-gray-400") do
      bits = [ actor_name, time_ago ].compact
      span { bits.join(" · ") }
    end
  end

  def time_ago
    @entry.occurred_at ? "#{time_ago_in_words(@entry.occurred_at)} ago" : nil
  end

  def actor_name
    @entry.actor_name.to_s.strip.presence
  end

  # ── Summary (the action) ──

  def summary_text
    case @entry.kind
    when "suggestion_edit"     then "Suggested an edit to #{entity_word}"
    when "suggestion_create"   then "Proposed a new #{entity_word}"
    when "suggestion_delete"   then "Proposed archiving #{entity_word}"
    when "suggestion_amended"  then "Amended a #{entity_word} suggestion"
    when "suggestion_approved" then "Approved a #{entity_word} suggestion"
    when "suggestion_rejected" then "Rejected a #{entity_word} suggestion"
    when "suggestion_withdrawn" then "Withdrew a #{entity_word} suggestion"
    when "capability_added"    then "Added a capability"
    when "capability_archived" then "Archived a capability"
    when "capability_updated"  then "Updated a capability"
    when "category_added"      then "Added a category"
    when "category_archived"   then "Archived a category"
    when "category_updated"    then "Updated a category"
    when "expectation_added"   then "Added an expectation#{expectation_level}"
    when "binding_added"       then binding_role ? "Bound to #{binding_role}" : "Bound a capability to a role"
    when "binding_updated"     then binding_role ? "Updated the #{binding_role} binding" : "Updated a capability-role binding"
    when "binding_removed"     then binding_role ? "Unbound #{binding_role}" : "Removed a capability-role binding"
    when "expectation_updated" then "Updated an expectation"
    when "illustration_added"  then "Added an illustration"
    when "illustration_updated" then "Updated an illustration"
    when "illustration_removed" then "Removed an illustration"
    when "draft_opened"        then draft_opened_summary
    when "version_published"   then "Published v#{payload_value(:version)}"
    when "migration_mapping_defined" then "Defined a migration mapping"
    when "collaborator_added"  then "Added a collaborator (#{collaborator_role})"
    when "collaborator_role_changed" then "Changed a collaborator's role to #{payload_value(:new_role)&.humanize}"
    when "collaborator_removed" then "Removed a collaborator"
    else @entry.kind.humanize
    end
  end

  def draft_opened_summary
    base = "Opened draft v#{payload_value(:target_version)}"
    payload_value(:auto_opened) ? "#{base} (auto)" : base
  end

  # Entity word for suggestion summaries — the human label of the suggestion's
  # target entity type (e.g. "Capability", "Illustration"), lowercased so it
  # reads inline.
  def entity_word
    type = payload_value(:suggestion_entity_type)
    ENTITY_TYPE_LABELS.fetch(type, type.to_s.humanize.presence || "change").downcase
  end

  def collaborator_role
    payload_value(:collaborator_role)&.humanize || "collaborator"
  end

  # ── Context line (where in the framework) — never truncated ──

  def context_text
    cap = @entry.capability_name.to_s.strip.presence
    cat = payload_value(:category_name).to_s.strip.presence
    base =
      if cap && cat then "#{cat} · #{cap}"
      elsif cap then cap
      elsif cat then cat
      end
    # Expectation entries pin the level too ("Category · Capability · L2").
    level = payload_value(:expectation_level)
    base && level.present? ? "#{base} · L#{level}" : base
  end

  # ── Secondary line (preview / detail) ──

  def secondary_text
    case @entry.kind
    when "suggestion_edit", "suggestion_amended"
      payload_value(:suggested_value) || payload_value(:new_suggested_value)
    when "suggestion_create"
      creation_preview
    when "suggestion_approved", "suggestion_rejected"
      payload_value(:comment)
    when "expectation_added"
      payload_value(:description)
    when "expectation_updated", "illustration_updated"
      payload_value(:new_description)
    when "migration_mapping_defined"
      payload_value(:reason)
    when "binding_added", "binding_updated"
      binding_change_text
    end.to_s.strip.presence
  end

  # " at L2" suffix for an authored expectation, when the level is known.
  def expectation_level
    ordinal = payload_value(:level_ordinal)
    ordinal.present? ? " at L#{ordinal}" : ""
  end

  # The role this binding entry concerns (e.g. "EM · Engineering Manager"), or
  # nil when it couldn't be resolved (binding created before the read window).
  def binding_role
    payload_value(:binding_role_label).to_s.strip.presence
  end

  # The scoring levers the add/update carried — weight and/or individual
  # tolerance. For an update the payload only carries the levers that actually
  # changed, so this reads as "what changed". Tolerance 0 means mandatory.
  def binding_change_text
    parts = []
    weight = payload_value(:binding_weight)
    tolerance = payload_value(:binding_individual_tolerance)
    parts << "Weight #{format_lever(weight)}" unless weight.nil?
    parts << "Tolerance #{tolerance_label(tolerance)}" unless tolerance.nil?
    parts.join(" · ")
  end

  def format_lever(value)
    "%g" % value.to_f
  end

  def tolerance_label(value)
    value.to_f.zero? ? "0 (mandatory)" : format_lever(value)
  end

  def payload_value(key)
    return nil unless @entry.payload.respond_to?(:[])

    @entry.payload[key] || @entry.payload[key.to_s]
  end

  # Preview of a create proposal's content — the first present of the entity's
  # human-readable attributes, so the reviewer can see what's proposed rather
  # than a bare "Proposed a new …".
  CREATE_PREVIEW_KEYS = %i[description name title].freeze

  def creation_preview
    attrs = payload_value(:proposed_attributes)
    return nil unless attrs.respond_to?(:[])

    CREATE_PREVIEW_KEYS.filter_map { |k| attrs[k] || attrs[k.to_s] }.first
  end
end
