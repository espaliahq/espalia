# frozen_string_literal: true

# Renders a single activity feed entry.
#
# Each entry kind has its own short summary line, a timestamp, and an
# optional context line (e.g. capability × level for rating events).
# The component stays read-only — clicks are handled at the list level
# in step 4 when focus-aware navigation lands.
#
class Views::Assessments::Activity::Entry < Views::Base
  include Phlex::Rails::Helpers::TimeAgoInWords

  KIND_DOT = {
    "self_rated"               => "bg-activity-self",
    "self_rating_revised"      => "bg-activity-self",
    "self_rating_cleared"      => "bg-activity-cleared",
    "manager_rated"            => "bg-activity-manager",
    "manager_rating_revised"   => "bg-activity-manager",
    "manager_rating_cleared"   => "bg-activity-cleared",
    "assessment_aligned"       => "bg-activity-attention",
    "alignment_cleared"        => "bg-activity-cleared",
    "evidence_recorded"        => "bg-activity-attention",
    "evidence_relinked"        => "bg-activity-discussion",
    "evidence_linked"          => "bg-activity-discussion",
    "evidence_unlinked"        => "bg-activity-cleared",
    "evidence_revalenced"      => "bg-activity-discussion",
    "evidence_withdrawn"       => "bg-activity-cleared",
    "alignment_started"        => "bg-activity-attention",
    "alignment_completed"      => "bg-activity-complete",
    "alignment_reopened"       => "bg-activity-attention",
    "comment_posted"           => "bg-activity-discussion",
    "evidence_link_commented"  => "bg-activity-discussion",
    "delegation_granted"       => "bg-activity-manager",
    "delegation_revoked"       => "bg-activity-cleared",
    "reporting_manager_recorded" => "bg-activity-discussion",
    "rating_revisit_requested" => "bg-activity-attention",
    "exploration_started"      => "bg-activity-discussion",
    "exploration_closed"       => "bg-activity-cleared"
  }.freeze

  # Maps each entry kind into one of the four user-facing groups that
  # the filter chips switch between. Entries without a (capability, level)
  # coordinate (alignment milestones) sit in the "alignment" group and
  # never participate in capability/cell-level focus matching.
  KIND_GROUP = {
    "self_rated"              => "ratings",
    "self_rating_revised"     => "ratings",
    "self_rating_cleared"     => "ratings",
    "manager_rated"           => "ratings",
    "manager_rating_revised"  => "ratings",
    "manager_rating_cleared"  => "ratings",
    "assessment_aligned"      => "alignment",
    "alignment_cleared"       => "alignment",
    "evidence_recorded"       => "evidence",
    "evidence_relinked"       => "evidence",
    "evidence_linked"         => "evidence",
    "evidence_unlinked"       => "evidence",
    "evidence_revalenced"     => "evidence",
    "evidence_withdrawn"      => "evidence",
    "alignment_started"       => "alignment",
    "alignment_completed"     => "alignment",
    "alignment_reopened"      => "alignment",
    # A declared exploration (ADR-22) is a step in the same conversation
    # alignment belongs to.
    "exploration_started"     => "alignment",
    "exploration_closed"      => "alignment",
    "comment_posted"          => "comments",
    "evidence_link_commented" => "comments",
    # A calibration revisit request is about the manager rating — the
    # ratings chip is where the rater will look for it.
    "rating_revisit_requested" => "ratings",
    # No filter chip — these surface under "All" only.
    "delegation_granted"        => "authority",
    "delegation_revoked"        => "authority",
    "reporting_manager_recorded" => "authority"
  }.freeze

  # @param entry [Assessments::ActivityFeedQuery::Entry]
  # @param assignment [PersonFrameworkAssignment, nil] the assessment, for
  #   entries that switch the page to another role's lens
  def initialize(entry:, assignment: nil)
    @entry = entry
    @assignment = assignment
  end

  def view_template
    li(
      id: "activity-entry-#{dom_safe_id}",
      class: "flex gap-2 text-xs text-gray-700 dark:text-gray-300 " \
             "rounded -mx-2 px-2 py-1 transition-colors " \
             "data-[match=true]:bg-amber-50/60 dark:data-[match=true]:bg-amber-900/15 " \
             "data-[match=true]:border-l-2 data-[match=true]:border-amber-400 " \
             "data-[hidden=true]:hidden " \
             "#{'cursor-pointer hover:bg-gray-100/60 dark:hover:bg-gray-700/40' if focusable?}",
      data: entry_data
    ) do
      span(class: "mt-1 w-2 h-2 rounded-full shrink-0 #{dot_class}") { }
      div(class: "min-w-0 flex-1") do
        summary
        secondary_line if secondary_text
        footer
      end
    end
  end

  private

  def dom_safe_id
    @entry.id.to_s.gsub(/[^a-zA-Z0-9_-]/, "-")
  end

  def dot_class
    KIND_DOT[@entry.kind] || "bg-activity-cleared"
  end

  def kind_group
    KIND_GROUP[@entry.kind] || "ratings"
  end

  # Rating + evidence entries are clickable — they navigate the matrix
  # to the (capability, level) they're attached to. Alignment milestones
  # have no matrix anchor and stay non-interactive.
  def focusable?
    (@entry.capability_stable_id.present? && @entry.level_ordinal.present?) || lens_href.present?
  end

  def entry_data
    base = {
      activity_feed_target: "entry",
      kind: @entry.kind,
      kind_group: kind_group
    }
    base[:category_id] = @entry.category_id if @entry.category_id
    base[:lens_href] = lens_href if lens_href
    if focusable?
      base[:capability_stable_id] = @entry.capability_stable_id if @entry.capability_stable_id
      base[:level_ordinal] = @entry.level_ordinal if @entry.level_ordinal
      base[:action] = "click->activity-feed#focusEntry"
    end
    base
  end

  # Where the entry lives when the page is read through another role
  # (ADR-22): its alignment, or a cell only that role reads. Clicking
  # switches to it when the page in front of the viewer doesn't render it.
  def lens_href
    return @lens_href if defined?(@lens_href)

    lens = @assignment && payload_value(:lens)
    @lens_href = if lens
      params = { as_role: lens[:as_role] || lens["as_role"], as_level: lens[:as_level] || lens["as_level"] }
      if @entry.capability_stable_id && @entry.level_ordinal
        params.merge!(capability: @entry.capability_stable_id, level_ordinal: @entry.level_ordinal)
      end
      assessment_path(@assignment, params.compact)
    end
  end

  def summary
    p(class: "font-medium text-gray-900 dark:text-gray-100") { summary_text }
  end

  def secondary_line
    p(class: "mt-0.5 text-[11px] text-gray-600 dark:text-gray-300 line-clamp-2") do
      secondary_text
    end
  end

  def footer
    div(class: "mt-1 flex flex-wrap items-center gap-x-1.5 text-[10px] text-gray-600 dark:text-gray-300") do
      time_ago = @entry.occurred_at ? "#{time_ago_in_words(@entry.occurred_at)} ago" : "—"
      span { time_ago }
      render Views::Evidence::OriginBadge.new(imported_reference) if imported_reference
    end
  end

  # The item's reference when the feedback was given in a peer system.
  def imported_reference
    return unless @entry.kind == "evidence_recorded" && @entry.payload.respond_to?(:external_reference)

    reference = @entry.payload.external_reference
    reference if reference&.imported?
  end

  # The summary line is the first thing the eye lands on, so it carries
  # enough context to be readable WITHOUT the secondary line: actor +
  # action + capability name + level. Frequency goes on the secondary
  # line where there's room for the full word.
  def summary_text
    case @entry.kind
    when "self_rated", "self_rating_revised"
      "Self-rated #{capability_label}#{lens_suffix}"
    when "self_rating_cleared"
      "Cleared self rating on #{capability_label}"
    when "manager_rated", "manager_rating_revised"
      "#{manager_label} rated #{capability_label}#{lens_suffix}"
    when "manager_rating_cleared"
      "#{manager_label} cleared rating on #{capability_label}"
    when "assessment_aligned"
      actor_name ? "#{actor_name} aligned #{capability_label}" : "Aligned on #{capability_label}"
    when "alignment_cleared"
      actor_name ? "#{actor_name} cleared alignment on #{capability_label}" : "Cleared alignment on #{capability_label}"
    when "evidence_recorded"     then evidence_recorded_summary
    when "evidence_relinked"     then evidence_relinked_summary
    when "evidence_linked"       then evidence_link_summary("Linked")
    when "evidence_unlinked"     then evidence_link_summary("Unlinked", preposition: "from")
    when "evidence_revalenced"   then evidence_link_summary("Reclassified", preposition: "on")
    when "evidence_withdrawn"    then evidence_withdrawn_summary
    when "alignment_started"     then "Manager started alignment#{role_suffix}"
    when "alignment_completed"   then "Marked alignment#{role_suffix} complete"
    when "alignment_reopened"    then "Re-opened alignment#{role_suffix}"
    when "comment_posted"        then comment_posted_summary
    when "evidence_link_commented" then evidence_link_commented_summary
    when "delegation_granted"    then "#{actor_name || 'Manager'} delegated rating to #{delegate_name}"
    when "delegation_revoked"    then "#{actor_name || 'Manager'} revoked #{delegate_name}'s delegation"
    when "reporting_manager_recorded" then "Reporting manager changed to #{manager_name}"
    when "rating_revisit_requested" then revisit_summary
    when "exploration_started"   then exploration_started_summary
    when "exploration_closed"    then exploration_closed_summary
    else @entry.kind.humanize
    end
  end

  # "«Facilitator» asked «rater» to revisit this rating (Engineering
  # calibration)" — value-free by design; the note rides the secondary line.
  def revisit_summary
    asker = payload_value(:requested_by_name).to_s.strip.presence || "Calibration"
    rater = payload_value(:rater_name).to_s.strip.presence || "the rater"
    session = payload_value(:session_name).to_s.strip.presence
    base = "#{asker} asked #{rater} to revisit #{capability_label}"
    session ? "#{base} (#{session})" : base
  end

  # "Alex started exploring Product Manager · PM3" when the assessee declared
  # it; "Morgan shared an exploration of …" when the manager side did — the
  # exploration is always the assessee's.
  def exploration_started_summary
    actor = actor_name || "Someone"
    return "#{actor} started exploring #{explored_role}" if payload_value(:by_assessee)

    "#{actor} shared an exploration of #{explored_role}"
  end

  # "Morgan closed the exploration of Product Manager · PM3 — not now"; with
  # no actor (a move into the role closed it) "The exploration of … closed".
  def exploration_closed_summary
    outcome = AssessmentExploration::OUTCOME_PHRASES[payload_value(:outcome)]
    base = if actor_name
      "#{actor_name} closed the exploration of #{explored_role}"
    else
      "The exploration of #{explored_role} closed"
    end
    outcome ? "#{base} — #{outcome}" : base
  end

  def explored_role
    payload_value(:role_label).to_s.strip.presence || "another role"
  end

  # " against Product Manager · PM3" for an alignment milestone against a
  # role other than home (ADR-22); empty for the home role's.
  def role_suffix
    label = payload_value(:role_label).to_s.strip.presence
    label ? " against #{label}" : ""
  end

  # " while exploring PM3" for a rating made through a role lens (ADR-22) —
  # the query resolves the code from the event's `via_role_id`.
  def lens_suffix
    code = payload_value(:via_role_code).to_s.strip.presence
    code ? " while exploring #{code}" : ""
  end

  # Name of the delegate referenced by a delegation entry, or a generic label.
  def delegate_name
    payload_value(:delegate_name).to_s.strip.presence || "a delegate"
  end

  # New reporting manager's name for a reporting_manager_recorded entry.
  def manager_name
    payload_value(:manager_name).to_s.strip.presence || "someone new"
  end

  # The resolved actor name for an attributed entry (rater / aligner /
  # clearer), or nil when unknown. The query merges it under `actor_name`;
  # historical events carry no actor id so it stays nil and callers fall back.
  def actor_name
    payload_value(:actor_name).to_s.strip.presence
  end

  # The rating manager's name when known, else the generic "Manager". When the
  # rating was recorded by a delegate (not the reporting manager), a "(delegate)"
  # badge distinguishes it — derived in the query via `via_delegation`.
  def manager_label
    base = actor_name || "Manager"
    payload_value(:via_delegation) ? "#{base} (delegate)" : base
  end

  # "<Author> commented on <Capability · Lx>", or — when the comment
  # answers another — "<Author> replied to <Parent author> on …", so the
  # feed tells the story of the conversation. The comment body renders on
  # the secondary line (see #secondary_text). Anchors the entry to whose
  # voice it is, since informal conversation makes voice primary in a way
  # ratings don't.
  def comment_posted_summary
    comment_summary(subject: capability_label)
  end

  # Shared by both comment kinds: "<Author> commented on <subject>", or
  # the reply variant when the comment answers another.
  def comment_summary(subject:)
    author_name = if @entry.payload.respond_to?(:author)
      @entry.payload.author&.name
    end
    name = author_name.to_s.strip.presence || "Someone"

    parent = @entry.payload.respond_to?(:parent) ? @entry.payload.parent : nil
    if parent
      parent_name = parent.author&.name.to_s.strip.presence || "another comment"
      "#{name} replied to #{parent_name} on #{subject}"
    else
      "#{name} commented on #{subject}"
    end
  end

  # "<Author> commented on <evidence author>'s feedback · <Capability · Lx>".
  # Names whose feedback is under discussion so the entry reads distinctly
  # from a plain cell comment; falls back to bare "feedback" when the
  # item's author no longer resolves.
  def evidence_link_commented_summary
    owner = @entry.payload.respond_to?(:evidence_author_name) &&
      @entry.payload.evidence_author_name.to_s.strip.presence
    feedback_label = owner ? "#{owner}'s feedback" : "feedback"

    comment_summary(subject: "#{feedback_label} · #{capability_label}")
  end

  # "Relinked evidence from <prev cap · L<prev>> to <new cap · L<new>>"
  # Falls back to bare ordinal when the previous capability name is
  # unknown (e.g. it was archived in a later framework version).
  def evidence_relinked_summary
    prev_cap = payload_value(:previous_capability_name).to_s.strip.presence
    prev_level = payload_value(:previous_level_ordinal)
    prev_label = if prev_cap && prev_level
      "#{prev_cap} · L#{prev_level}"
    elsif prev_cap
      prev_cap
    elsif prev_level
      "L#{prev_level}"
    else
      "previous coordinate"
    end
    if (name = actor_name)
      "#{name} relinked feedback from #{prev_label} to #{capability_label}"
    else
      "Relinked feedback from #{prev_label} to #{capability_label}"
    end
  end

  # "<Capability name> · L<n>" when both are known. Falls back to a
  # bare level when the capability name is missing (e.g. archived in a
  # later framework version), and to a generic placeholder when both
  # are missing — never produces a stray "L" or "Lnil" in copy.
  def capability_label
    cap_name = @entry.capability_name.to_s.strip.presence
    level = @entry.level_ordinal
    if cap_name && level
      "#{cap_name} · L#{level}"
    elsif cap_name
      cap_name
    elsif level
      "L#{level}"
    else
      "an unknown coordinate"
    end
  end

  def evidence_recorded_summary
    item = @entry.payload
    title = item.respond_to?(:title) ? item.title.to_s : ""
    subject = title.strip.empty? ? "feedback" : "“#{title.strip}”"
    return unplaced_evidence_summary(subject) if unplaced_entry?

    label = capability_label
    verb = placed_later?(item) ? "gave #{subject}, placed later on" : "recorded #{subject} on"
    if (name = evidence_author_name)
      "#{name} #{verb} #{label}"
    else
      "#{verb.sub(/\A\w+/, &:capitalize)} #{label}"
    end
  end

  # An item given without a cell reads from the cell its placement gave it,
  # but the author never chose that cell; the copy says so.
  def placed_later?(item)
    item.respond_to?(:recorded_unplaced) && item.recorded_unplaced
  end

  # An unplaced item has no cell to name; the entry says so rather than
  # inventing a coordinate, and stays framework-scoped until it is placed.
  def unplaced_evidence_summary(subject)
    if (name = evidence_author_name)
      "#{name} gave #{subject}, not yet placed on a capability"
    else
      "Gave #{subject}, not yet placed on a capability"
    end
  end

  # "<Actor> withdrew feedback on <cap · Lx>", falling back to a generic
  # "Withdrew …" when the withdrawer is unknown (historical / unattributed).
  def evidence_withdrawn_summary
    where = unplaced_entry? ? "that was never placed on a capability" : "on #{capability_label}"
    if (name = evidence_withdrawer_name)
      "#{name} withdrew feedback #{where}"
    else
      "Withdrew feedback #{where}"
    end
  end

  def unplaced_entry?
    @entry.capability_stable_id.nil? && @entry.level_ordinal.nil?
  end

  # "<Actor> linked feedback to <cap · Lx>" / "… unlinked feedback from …",
  # quoting the feedback title when the query resolved one. Falls back to a
  # capitalised, actor-less form when the actor is unknown.
  def evidence_link_summary(verb, preposition: "to")
    title = payload_value(:evidence_title).to_s.strip.presence
    subject = title ? "“#{title}”" : "feedback"
    if (name = actor_name)
      "#{name} #{verb.downcase} #{subject} #{preposition} #{capability_label}"
    else
      "#{verb} #{subject} #{preposition} #{capability_label}"
    end
  end

  # Author name behind an `evidence_recorded` entry (the payload is the
  # EvidenceItem itself, with its `author` association preloaded), or nil.
  def evidence_author_name
    item = @entry.payload
    return nil unless item.respond_to?(:author)

    item.author&.name.to_s.strip.presence
  end

  # Withdrawer name behind an `evidence_withdrawn` entry (the payload is the
  # EvidenceItem, with its `withdrawn_by` association preloaded), or nil —
  # mirrors {#evidence_author_name}.
  def evidence_withdrawer_name
    item = @entry.payload
    return nil unless item.respond_to?(:withdrawn_by)

    item.withdrawn_by&.name.to_s.strip.presence
  end

  # Secondary line carries the rating frequency (with comment if present)
  # for rating events, the body content for evidence-recorded, the
  # rationale for evidence-relinked, or the withdrawal reason for
  # withdraw. Empty → no secondary line renders.
  def secondary_text
    case @entry.kind
    when "self_rated", "self_rating_revised", "manager_rated", "manager_rating_revised", "assessment_aligned"
      bits = [ frequency_label_or_nil, Prose.to_plain(payload_value(:comment)).presence ].compact
      bits.any? ? bits.join(" · ") : nil
    when "evidence_recorded"
      content = @entry.payload.respond_to?(:content) ? @entry.payload.content : nil
      Prose.to_plain(content).presence
    when "evidence_relinked", "evidence_linked"
      [ valence_label_or_nil, Prose.to_plain(payload_value(:rationale)).presence, from_suggestion_note ].compact
        .join(" · ").presence
    when "evidence_unlinked"
      Prose.to_plain(payload_value(:reason)).presence
    when "evidence_revalenced"
      [ revalence_secondary, from_suggestion_note ].compact.join(" · ").presence
    when "evidence_withdrawn"
      reason = @entry.payload.respond_to?(:withdrawal_reason) ? @entry.payload.withdrawal_reason : nil
      Prose.to_plain(reason).presence
    when "comment_posted", "evidence_link_commented"
      body = @entry.payload.respond_to?(:body) ? @entry.payload.body : nil
      Prose.to_plain(body).presence
    when "rating_revisit_requested", "exploration_started", "exploration_closed"
      Prose.to_plain(payload_value(:note)).presence
    end
  end

  def frequency_label_or_nil
    label = frequency_label
    label.to_s.strip.empty? ? nil : label
  end

  # The link's valence label ("Demonstrates" / "Growth area" / …), nil for
  # pre-valence events.
  def valence_label_or_nil
    Views::Evidence::Valence::LABELS[payload_value(:valence)]
  end

  # Said when a person accepted a placement suggestion rather than choosing
  # the cell themselves; the event carries the suggestion's id.
  def from_suggestion_note
    "from a suggestion" if payload_value(:via_suggestion_id).present?
  end

  # "Growth area (was Demonstrates)" — or just the new label when the link
  # was pre-valence (nil) before this reclassification.
  def revalence_secondary
    new_label = valence_label_or_nil
    return nil unless new_label

    prev_label = Views::Evidence::Valence::LABELS[payload_value(:previous_valence)]
    prev_label ? "#{new_label} (was #{prev_label})" : new_label
  end

  # Compact label from the ONE frequency vocabulary (FrequencyPalette), so
  # the feed can't drift from the pill. `config_for` rather than `label_for`:
  # a cleared rating has no frequency and must stay nil, not "Unrated".
  def frequency_label
    freq = payload_value(:frequency) || payload_value(:aligned_frequency)
    Views::Assessments::FrequencyPalette.config_for(freq)&.dig(:label) || freq
  end

  def payload_value(key)
    return nil unless @entry.payload.respond_to?(:[])

    @entry.payload[key] || @entry.payload[key.to_s]
  end
end
