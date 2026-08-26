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

  # Announces the acting user's rating change into the page's pre-existing
  # polite live region (WCAG 4.1.3 — audit issue #318). Reads the POST-write
  # frequency off the fresh cell data, so the announcement is authoritative
  # for whichever branch ran (rate / revise / confirm / clear). Rides the
  # per-request Turbo Stream response only — broadcasts never touch the
  # region, so other viewers hear nothing.
  #
  # @param cap_data [Hash] capability data from MatrixDataBuilder
  # @param cell_data [Hash, nil] the post-write cell (nil = no cell at this
  #   ordinal — nothing is announced rather than announcing the wrong thing)
  # @param level_code [String] e.g. "E3"
  # @param frequency [String, nil] the post-write frequency (nil = cleared)
  # @param verb [String] "Rated" or "Agreed"
  # @return [Turbo::Streams::TagBuilder, nil] stream updating the live region
  def live_status_stream(cap_data:, cell_data:, level_code:, frequency:, verb: "Rated")
    return nil if cell_data.nil?

    # Capability names are user-authored and turbo_stream.update marks string
    # content html_safe — escape, as every other helper in this concern does.
    capability_name = ERB::Util.html_escape(cap_data[:capability].name)
    text =
      if frequency.present?
        phrase = Views::Assessments::FrequencyPalette.phrase_for(frequency) ||
          frequency.to_s.humanize
        "#{verb} #{phrase.downcase} — #{capability_name}, #{level_code}"
      else
        cleared = verb == "Agreed" ? "Agreement" : "Rating"
        "#{cleared} cleared — #{capability_name}, #{level_code}"
      end
    turbo_stream.update("assessment-live-status", text)
  end

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
  def rating_wrapper_html(stable_id, ordinal, frequency, context, category_id,
                          interactive: true, carried: false)
    pill_html = render_to_string(
      Views::Assessments::FrequencyPill.new(
        capability_stable_id: stable_id,
        level_ordinal: ordinal,
        current_frequency: frequency,
        assessment_id: @assignment.id,
        context: context,
        category_id: category_id,
        interactive: interactive,
        carried: carried
      ),
      layout: false
    )
    # Must match the wrapper rendered by
    # `CapabilityCardExpansion#expectation_sentence` — same element
    # type, same id, same classes. Otherwise the turbo_stream replace
    # swaps the inline pill wrapper for a block element and the
    # surrounding sentence rewraps to the next line.
    %(<span id="rating-#{stable_id}-#{ordinal}" class="inline-block">#{pill_html}</span>)
  end

  # Renders the divergent-secondaries strip for a (capability, level)
  # cell. `cell_data` carries the fresh frequencies for all three
  # perspectives; the line view drops perspectives that aren't visible
  # to the viewer (handled inside `secondary_entries_for`) and the
  # render itself drops anything that agrees with the primary.
  def secondaries_wrapper_html(stable_id, ordinal, cell_data, primary_freq, context)
    lines = secondary_entries_for(cell_data, context).map do |entry|
      render_to_string(
        Views::Assessments::SecondaryRatingLine.new(
          label: entry[:label],
          frequency: entry[:frequency],
          primary_frequency: primary_freq
        ),
        layout: false
      )
    end
    # Must match the wrapper in
    # `CapabilityCardExpansion#diverging_secondaries` — inline-flex
    # span so the secondaries flow on the same line as the pill,
    # without left margin so when the line wraps on mobile the
    # secondary starts flush against the new line's left edge
    # (gap to the pill is owned by `mr-6` on the pill wrapper).
    %(<span id="secondaries-#{stable_id}-#{ordinal}" class="inline-flex flex-wrap items-center gap-4">#{lines.join}</span>)
  end

  def secondary_entries_for(cell_data, context)
    case context
    when :manager
      [ { label: "Self", frequency: cell_data[:current_frequency] } ]
    when :alignment
      [
        { label: "Self", frequency: cell_data[:current_frequency] },
        { label: "Manager", frequency: cell_data[:manager_frequency] }
      ]
    else []
    end
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
