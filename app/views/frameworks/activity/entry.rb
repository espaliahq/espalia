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
    "suggestion_commented"      => "bg-sky-500",
    "clarification_requested"   => "bg-amber-500",
    "clarification_resolved"    => "bg-green-600",
    "capability_added"          => "bg-emerald-500",
    "capability_archived"       => "bg-amber-500",
    "capability_updated"        => "bg-indigo-500",
    "capability_reordered"      => "bg-indigo-500",
    "category_added"            => "bg-emerald-500",
    "category_archived"         => "bg-amber-500",
    "category_updated"          => "bg-indigo-500",
    "category_reordered"        => "bg-indigo-500",
    "binding_added"             => "bg-emerald-500",
    "binding_updated"           => "bg-indigo-500",
    "binding_removed"           => "bg-gray-400",
    "expectation_added"         => "bg-emerald-500",
    "expectation_updated"       => "bg-indigo-500",
    "illustration_added"        => "bg-indigo-500",
    "illustration_updated"      => "bg-indigo-500",
    "illustration_removed"      => "bg-gray-400",
    "illustration_reordered"    => "bg-indigo-500",
    "role_family_updated"       => "bg-indigo-500",
    "role_updated"              => "bg-indigo-500",
    "level_updated"             => "bg-indigo-500",
    "role_family_added"         => "bg-emerald-500",
    "role_added"                => "bg-emerald-500",
    "level_added"               => "bg-emerald-500",
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
    "suggestion_commented"      => "suggestions",
    "clarification_requested"   => "suggestions",
    "clarification_resolved"    => "suggestions",
    "capability_updated"        => "edits",
    "category_updated"          => "edits",
    "expectation_updated"       => "edits",
    "illustration_added"        => "edits",
    "illustration_updated"      => "edits",
    "illustration_removed"      => "edits",
    "illustration_reordered"    => "edits",
    "role_family_updated"       => "edits",
    "role_updated"              => "edits",
    "level_updated"             => "edits",
    "capability_added"          => "structural",
    "capability_archived"       => "structural",
    "capability_reordered"      => "structural",
    "category_added"            => "structural",
    "category_archived"         => "structural",
    "category_reordered"        => "structural",
    "role_family_added"         => "structural",
    "role_added"                => "structural",
    "level_added"               => "structural",
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
        resolve_row if resolvable?
        discussion_row if discussable?
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
  # A pending clarification's entry carries "Resolve…" for viewers with
  # expectation-tier authority — the non-proposal analogue of Approve/Reject.
  # There is no superseded flag to honour (clarifications aren't amended).
  def resolvable?
    @framework_id.present? &&
      @entry.kind == "clarification_requested" &&
      @entry.suggestion_status == "pending" &&
      @approval_authority.can_resolve_clarifications?
  end

  def resolve_row
    render Views::Frameworks::Activity::ClarificationActions.new(
      framework_id: @framework_id,
      suggestion_id: @entry.suggestion_id,
      question_preview: payload_value(:rationale).to_s.strip.presence
    )
  end

  def action_row
    if @entry.suggestion_id.present?
      render Views::Frameworks::Activity::SuggestionActions.new(
        framework_id: @framework_id,
        suggestion_id: @entry.suggestion_id,
        entity_label: entity_word,
        reject_preview: reject_preview
      )
    else
      div(class: "mt-1.5") { review_link }
    end
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

  # Every suggestion-anchored entry advertises its discussion and is one
  # click from the pane's suggestion card (focus=suggestion) — count +
  # latest excerpt when a thread exists, a quiet "Discuss" otherwise. The
  # affordance is a button, so the row's focusSuggestion navigation bails
  # on it (see context_pane_controller#focusSuggestion).
  def discussable?
    @framework_id.present? && @entry.suggestion_id.present?
  end

  def discussion_row
    div(class: "mt-1") do
      button(
        type: "button",
        class: "inline-flex items-center gap-1 max-w-full rounded px-1.5 py-0.5 text-[10px] " \
               "text-gray-500 dark:text-gray-400 hover:text-primary hover:bg-primary/10 " \
               "transition-colors",
        data: {
          action: "click->context-pane#openSuggestionCard",
          suggestion_id: @entry.suggestion_id
        },
        aria: { label: "Open this suggestion's discussion" }
      ) do
        discussion_icon
        span(class: "truncate") { discussion_label }
      end
    end
  end

  def discussion_label
    count = @entry.comment_count.to_i
    return "Discuss" if count.zero?

    excerpt = @entry.latest_comment.to_s.strip.truncate(60)
    "#{count} · #{excerpt}"
  end

  # Tiny speech-bubble icon (Heroicons chat-bubble-oval-left outline).
  def discussion_icon
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
        d: "M12 20.25c4.97 0 9-3.694 9-8.25s-4.03-8.25-9-8.25S3 7.444 3 12c0 2.104.859 " \
           "4.023 2.273 5.48.432.447.74 1.04.586 1.641a4.483 4.483 0 01-.923 1.785A5.969 " \
           "5.969 0 006 21c1.282 0 2.47-.402 3.445-1.087.81.22 1.668.337 2.555.337z"
      )
    end
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
        # An entry that knows its level (expectation / illustration suggestions
        # and edits) navigates to the specific cell — expand the row AND focus
        # capability × level — not just the capability row.
        level_ordinal = payload_value(:expectation_level)
        if level_ordinal.present?
          base[:nav_level] = "cell"
          base[:nav_level_ordinal] = level_ordinal
        else
          base[:nav_level] = "capability"
        end
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
    when "suggestion_amended"  then "Amended #{articled_entity_word} suggestion"
    when "suggestion_approved" then "Approved #{articled_entity_word} suggestion"
    when "suggestion_rejected" then "Rejected #{articled_entity_word} suggestion"
    when "suggestion_withdrawn" then withdrawn_summary
    when "suggestion_commented" then commented_summary
    when "clarification_requested" then "Asked for clarification"
    when "clarification_resolved"  then "Resolved a clarification"
    when "capability_added"    then "Added a capability"
    when "capability_archived" then "Archived a capability"
    when "capability_updated"  then "Updated a capability"
    when "capability_reordered" then "Reordered the capabilities"
    when "category_added"      then "Added a category"
    when "category_archived"   then "Archived a category"
    when "category_updated"    then "Updated a category"
    when "category_reordered"  then "Reordered the categories"
    when "expectation_added"   then "Added an expectation#{expectation_level}"
    when "binding_added"       then binding_role ? "Bound to #{binding_role}" : "Bound a capability to a role"
    when "binding_updated"     then binding_role ? "Updated the #{binding_role} binding" : "Updated a capability-role binding"
    when "binding_removed"     then binding_role ? "Unbound #{binding_role}" : "Removed a capability-role binding"
    when "expectation_updated" then "Updated an expectation"
    when "illustration_added"  then "Added an illustration"
    when "illustration_updated" then "Updated an illustration"
    when "illustration_removed" then "Removed an illustration"
    when "illustration_reordered" then illustration_reordered_summary
    when "role_family_updated" then org_update_summary("role family", name: "name", description: "description", department: "department")
    when "role_updated"        then org_update_summary("role", name: "name", code: "code", track: "track")
    when "level_updated"       then org_update_summary("level", title: "title", code: "code")
    when "role_family_added"   then "Added a role family"
    when "role_added"          then "Added a role"
    when "level_added"         then level_added_summary
    when "draft_opened"        then draft_opened_summary
    when "version_published"   then "Published v#{payload_value(:version)}"
    when "migration_mapping_defined" then "Defined a migration mapping"
    when "collaborator_added"  then collaborator_added_summary
    when "collaborator_role_changed" then collaborator_role_changed_summary
    when "collaborator_removed" then collaborator_removed_summary
    else @entry.kind.humanize
    end
  end

  def draft_opened_summary
    base = "Opened draft v#{payload_value(:target_version)}"
    payload_value(:auto_opened) ? "#{base} (auto)" : base
  end

  # Withdraw/comment entries read differently when their anchor is a
  # clarification — "a clarification", not "an expectation suggestion".
  def withdrawn_summary
    clarification_anchored? ? "Withdrew a clarification" : "Withdrew #{articled_entity_word} suggestion"
  end

  def commented_summary
    clarification_anchored? ? "Commented on a clarification" : "Commented on #{articled_entity_word} suggestion"
  end

  def clarification_anchored?
    payload_value(:suggestion_kind) == "clarification"
  end

  # "Added L4 to EM · Engineering Manager" — the level's ordinal plus the role
  # it belongs to, when the role label resolved (nil-safe for history).
  def level_added_summary
    base = "Added L#{payload_value(:ordinal)}"
    role = payload_value(:level_role_label)
    role.present? ? "#{base} to #{role}" : base
  end

  # Names the role whose illustration list was reordered when the query
  # resolved a label (the anchor context line locates the capability).
  def illustration_reordered_summary
    role = payload_value(:reorder_role_label).to_s.strip.presence
    role ? "Reordered the #{role} illustrations" : "Reordered illustrations"
  end

  # Summary for a direct org-structure edit (role family / role / level) that
  # names which field(s) changed — e.g. "Updated a role's name". The aggregate
  # `.compact`s these update events, so a present payload key means that field
  # actually changed; we list exactly those. Falls back to a bare "Updated a
  # <noun>" if none resolve (e.g. an older event shape).
  #
  # @param noun [String] "role family" / "role" / "level"
  # @param fields [Hash{Symbol=>String}] payload key → human label
  def org_update_summary(noun, **fields)
    changed = fields.filter_map { |key, label| label if payload_key?(key) }
    changed.empty? ? "Updated a #{noun}" : "Updated a #{noun}'s #{changed.to_sentence}"
  end

  # Whether the (compacted) update event carried this field at all — keyed
  # presence, not value presence, so a field intentionally cleared to "" still
  # counts as changed. The aggregate drops nil keys via `.compact`, so a present
  # key means the field was part of the update.
  def payload_key?(key)
    return false unless @entry.payload.respond_to?(:key?)

    @entry.payload.key?(key) || @entry.payload.key?(key.to_s)
  end

  # Entity word for suggestion summaries — the human label of the suggestion's
  # target entity type (e.g. "Capability", "Illustration"), lowercased so it
  # reads inline.
  def entity_word
    type = payload_value(:suggestion_entity_type)
    ENTITY_TYPE_LABELS.fetch(type, type.to_s.humanize.presence || "change").downcase
  end

  # "an illustration suggestion", not "a illustration suggestion".
  def articled_entity_word
    word = entity_word
    "#{word.match?(/\A[aeiou]/) ? 'an' : 'a'} #{word}"
  end

  def collaborator_role
    payload_value(:collaborator_role)&.humanize || "collaborator"
  end

  # Collaborator summaries name WHO the change concerns, not just the role —
  # `collaborator_name` is resolved by the query from the event's person_id.
  # Nil-safe: history whose person no longer resolves falls back to the
  # anonymous phrasing.
  def collaborator_name
    payload_value(:collaborator_name).to_s.strip.presence
  end

  def collaborator_added_summary
    if collaborator_name
      "Added #{collaborator_name} as #{collaborator_role.downcase}"
    else
      "Added a collaborator (#{collaborator_role})"
    end
  end

  def collaborator_role_changed_summary
    new_role = payload_value(:new_role)&.humanize
    if collaborator_name
      "Changed #{collaborator_name}'s role to #{new_role}"
    else
      "Changed a collaborator's role to #{new_role}"
    end
  end

  def collaborator_removed_summary
    collaborator_name ? "Removed #{collaborator_name} as a collaborator" : "Removed a collaborator"
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
    # Expectation and illustration entries pin the level too
    # ("Category · Capability · L2"), and illustration entries add the role
    # ("… · L2 · E · Software Engineer") — an illustration is a
    # (capability × level × role) artefact, so the entry locates all three.
    level = payload_value(:expectation_level)
    base = "#{base} · L#{level}" if base && level.present?
    role = payload_value(:suggestion_role_label).presence || payload_value(:illustration_role_label)
    base = "#{base} · #{role}" if base && role.present?
    base
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
    when "suggestion_commented"
      payload_value(:body)
    when "clarification_requested"
      payload_value(:rationale)
    when "clarification_resolved"
      payload_value(:note)
    when "expectation_added"
      payload_value(:description)
    when "expectation_updated", "illustration_updated"
      payload_value(:new_description)
    when "role_family_updated", "role_updated", "role_family_added"
      payload_value(:name)
    when "role_added"
      [ payload_value(:code), payload_value(:name) ].compact_blank.join(" · ").presence
    when "level_added"
      [ payload_value(:code), payload_value(:title) ].compact_blank.join(" · ").presence
    when "level_updated"
      payload_value(:title)
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
