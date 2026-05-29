# frozen_string_literal: true

# Shared HTML builders for the rating controllers' Turbo Stream
# responses. Both `capability_name_html` and `rating_wrapper_html`
# were copy-pasted across `RatingsController`, `ManagerRatingsController`,
# and `AlignmentRatingsController` — extract into a concern so the
# next view-layer change (e.g. capability contribution badge format)
# only has to land in one place.
#
# `capability_name_html` mirrors `Views::Assessments::CapabilityCard`'s
# `capability_name` + `contribution_badge` — signed delta (`±N.N`),
# colour-tiered, never hidden when negative. The previous version
# rendered the contribution as a percentage AND skipped it for
# negative values; keep this in sync with the Phlex card so post-rate
# re-renders don't regress.
module Assessments::TurboStreamHelpers
  extend ActiveSupport::Concern

  private

  # @param cap_data [Hash] capability data from MatrixDataBuilder
  # @param blocked [Boolean]
  # @param block_reason [String, nil]
  # @param contribution [Float, nil] raw signed contribution from Scoring
  # @return [String] HTML
  def capability_name_html(cap_data, blocked, block_reason, contribution)
    cap = cap_data[:capability]
    parts = []
    parts << %(<h3 class="text-sm font-semibold text-gray-900 dark:text-white">#{ERB::Util.html_escape(cap.name)}</h3>)
    parts << blocked_badge_html(block_reason) if blocked
    parts << contribution_badge_html(contribution) if contribution
    %(<div id="capability-name-#{cap.stable_id}" class="flex items-center gap-2">#{parts.join}</div>)
  end

  # @return [String] HTML
  def rating_wrapper_html(stable_id, ordinal, frequency, context, category_id)
    selector_html = render_to_string(
      Views::Assessments::FrequencySelector.new(
        capability_stable_id: stable_id,
        level_ordinal: ordinal,
        current_frequency: frequency,
        assessment_id: @assignment.id,
        context: context,
        category_id: category_id
      ),
      layout: false
    )
    %(<div id="rating-#{stable_id}-#{ordinal}">#{selector_html}</div>)
  end

  def blocked_badge_html(block_reason)
    %(<span class="text-[10px] font-medium text-red-600 dark:text-red-400 ) +
      %(bg-red-50 dark:bg-red-900/20 px-1.5 py-0.5 rounded" ) +
      %(title="#{ERB::Util.html_escape(block_reason)}">Blocked</span>)
  end

  # Matches `CapabilityCard#contribution_badge` — signed `±N.N` with
  # green/gray/amber/red tiers.
  def contribution_badge_html(contribution)
    value = contribution.to_f
    label = sprintf("%+.1f", value)
    color = if value >= 0.5
              "text-green-600 dark:text-green-400"
    elsif value > -0.5
              "text-gray-500 dark:text-gray-400"
    elsif value > -1.5
              "text-amber-600 dark:text-amber-400"
    else
              "text-red-600 dark:text-red-400"
    end
    %(<span class="text-base font-bold tabular-nums #{color} ml-auto">#{label}</span>)
  end
end
