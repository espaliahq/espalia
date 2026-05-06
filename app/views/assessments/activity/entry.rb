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
    "evidence_withdrawn"       => "bg-gray-400",
    "alignment_started"        => "bg-amber-500",
    "alignment_completed"      => "bg-green-600"
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
      class: "flex gap-2 text-xs text-gray-700 dark:text-gray-300"
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

  def summary_text
    case @entry.kind
    when "self_rated"            then "Self-rated #{frequency_label} at L#{@entry.level_ordinal}"
    when "self_rating_revised"   then "Revised self rating to #{frequency_label} at L#{@entry.level_ordinal}"
    when "self_rating_cleared"   then "Cleared self rating at L#{@entry.level_ordinal}"
    when "manager_rated"         then "Manager rated #{frequency_label} at L#{@entry.level_ordinal}"
    when "manager_rating_revised" then "Manager revised to #{frequency_label} at L#{@entry.level_ordinal}"
    when "manager_rating_cleared" then "Manager cleared rating at L#{@entry.level_ordinal}"
    when "assessment_aligned"    then "Aligned at #{frequency_label} for L#{@entry.level_ordinal}"
    when "evidence_recorded"     then evidence_recorded_summary
    when "evidence_withdrawn"    then "Withdrew evidence at L#{@entry.level_ordinal}"
    when "alignment_started"     then "Manager started alignment"
    when "alignment_completed"   then "Marked alignment complete"
    else @entry.kind.humanize
    end
  end

  def evidence_recorded_summary
    item = @entry.payload
    title = item.respond_to?(:title) ? item.title.to_s : ""
    if title.strip.empty?
      "Recorded evidence at L#{@entry.level_ordinal}"
    else
      "Recorded “#{title}” at L#{@entry.level_ordinal}"
    end
  end

  def secondary_text
    case @entry.kind
    when "self_rated", "self_rating_revised", "manager_rated", "manager_rating_revised", "assessment_aligned"
      payload_value(:comment)
    when "evidence_recorded"
      content = @entry.payload.respond_to?(:content) ? @entry.payload.content.to_s : ""
      content.strip.presence
    when "evidence_withdrawn"
      reason = @entry.payload.respond_to?(:withdrawal_reason) ? @entry.payload.withdrawal_reason : nil
      reason.to_s.strip.presence
    end
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
