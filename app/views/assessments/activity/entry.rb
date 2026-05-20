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
    "self_rated"               => "bg-emerald-500",
    "self_rating_revised"      => "bg-emerald-500",
    "self_rating_cleared"      => "bg-gray-400",
    "manager_rated"            => "bg-indigo-500",
    "manager_rating_revised"   => "bg-indigo-500",
    "manager_rating_cleared"   => "bg-gray-400",
    "assessment_aligned"       => "bg-amber-500",
    "evidence_recorded"        => "bg-amber-500",
    "evidence_relinked"        => "bg-sky-500",
    "evidence_withdrawn"       => "bg-gray-400",
    "alignment_started"        => "bg-amber-500",
    "alignment_completed"      => "bg-green-600"
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
    "evidence_recorded"       => "evidence",
    "evidence_relinked"       => "evidence",
    "evidence_withdrawn"      => "evidence",
    "alignment_started"       => "alignment",
    "alignment_completed"     => "alignment"
  }.freeze

  FREQUENCY_LABEL = {
    "none"        => "None",
    "some"        => "Some",
    "occasional"  => "Most",
    "consistent"  => "Consistently"
  }.freeze

  # @param entry [Assessments::ActivityFeedQuery::Entry]
  def initialize(entry:)
    @entry = entry
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
    KIND_DOT[@entry.kind] || "bg-gray-400"
  end

  def kind_group
    KIND_GROUP[@entry.kind] || "ratings"
  end

  # Rating + evidence entries are clickable — they navigate the matrix
  # to the (capability, level) they're attached to. Alignment milestones
  # have no matrix anchor and stay non-interactive.
  def focusable?
    @entry.capability_stable_id.present? && @entry.level_ordinal.present?
  end

  def entry_data
    base = {
      activity_feed_target: "entry",
      kind: @entry.kind,
      kind_group: kind_group
    }
    base[:category_id] = @entry.category_id if @entry.category_id
    if focusable?
      base[:capability_stable_id] = @entry.capability_stable_id
      base[:level_ordinal] = @entry.level_ordinal
      base[:action] = "click->activity-feed#focusEntry"
    end
    base
  end

  def summary
    p(class: "font-medium text-gray-900 dark:text-gray-100") { summary_text }
  end

  def secondary_line
    p(class: "mt-0.5 text-[11px] text-gray-500 dark:text-gray-400 line-clamp-2") do
      secondary_text
    end
  end

  def footer
    div(class: "mt-1 text-[10px] text-gray-400 dark:text-gray-500") do
      time_ago = @entry.occurred_at ? "#{time_ago_in_words(@entry.occurred_at)} ago" : "—"
      span { time_ago }
    end
  end

  # The summary line is the first thing the eye lands on, so it carries
  # enough context to be readable WITHOUT the secondary line: actor +
  # action + capability name + level. Frequency goes on the secondary
  # line where there's room for the full word.
  def summary_text
    case @entry.kind
    when "self_rated", "self_rating_revised"
      "Self-rated #{capability_label}"
    when "self_rating_cleared"
      "Cleared self rating on #{capability_label}"
    when "manager_rated", "manager_rating_revised"
      "Manager rated #{capability_label}"
    when "manager_rating_cleared"
      "Manager cleared rating on #{capability_label}"
    when "assessment_aligned"
      "Aligned on #{capability_label}"
    when "evidence_recorded"     then evidence_recorded_summary
    when "evidence_relinked"     then evidence_relinked_summary
    when "evidence_withdrawn"    then "Withdrew evidence on #{capability_label}"
    when "alignment_started"     then "Manager started alignment"
    when "alignment_completed"   then "Marked alignment complete"
    else @entry.kind.humanize
    end
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
    "Relinked evidence from #{prev_label} to #{capability_label}"
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
    label = capability_label
    if title.strip.empty?
      "Recorded evidence on #{label}"
    else
      "Recorded “#{title}” on #{label}"
    end
  end

  # Secondary line carries the rating frequency (with comment if present)
  # for rating events, the body content for evidence-recorded, the
  # rationale for evidence-relinked, or the withdrawal reason for
  # withdraw. Empty → no secondary line renders.
  def secondary_text
    case @entry.kind
    when "self_rated", "self_rating_revised", "manager_rated", "manager_rating_revised", "assessment_aligned"
      bits = [ frequency_label_or_nil, payload_value(:comment).to_s.strip.presence ].compact
      bits.any? ? bits.join(" · ") : nil
    when "evidence_recorded"
      content = @entry.payload.respond_to?(:content) ? @entry.payload.content.to_s : ""
      content.strip.presence
    when "evidence_relinked"
      payload_value(:rationale).to_s.strip.presence
    when "evidence_withdrawn"
      reason = @entry.payload.respond_to?(:withdrawal_reason) ? @entry.payload.withdrawal_reason : nil
      reason.to_s.strip.presence
    end
  end

  def frequency_label_or_nil
    label = frequency_label
    label.to_s.strip.empty? ? nil : label
  end

  def frequency_label
    freq = payload_value(:frequency) || payload_value(:aligned_frequency)
    FREQUENCY_LABEL[freq] || freq
  end

  def payload_value(key)
    return nil unless @entry.payload.respond_to?(:[])

    @entry.payload[key] || @entry.payload[key.to_s]
  end
end
