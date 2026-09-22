# frozen_string_literal: true

# Shared HTML builders for the rating controllers' Turbo Stream
# responses. Both `capability_name_html` and `rating_wrapper_html`
# were copy-pasted across `RatingsController`, `ManagerRatingsController`,
# and `AlignmentRatingsController` — extract into a concern so the
# next view-layer change (e.g. capability contribution badge format)
# only has to land in one place.
#
# `capability_name_html` renders `Views::Assessments::CapabilityNameRow` —
# the very view the card renders — so a post-rate re-render can never
# drift from the initial one.
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
        spoken = Views::Assessments::FrequencyPalette.spoken_for(frequency)
        "#{verb} #{spoken} — #{capability_name}, #{level_code}"
      else
        cleared = verb == "Agreed" ? "Agreement" : "Rating"
        "#{cleared} cleared — #{capability_name}, #{level_code}"
      end
    turbo_stream.update("assessment-live-status", text)
  end

  # The capability's name row after a rating — rendered by the same view
  # the card renders, so the post-rate row cannot drift from the initial one.
  #
  # @param cap_data [Hash] capability data from MatrixDataBuilder
  # @param matrix_data [Hash] the rebuilt matrix data
  # @param primary [Hash] the viewer's primary scoring hash
  # @param context [Symbol] :self, :manager, or :alignment
  # @return [String] HTML
  def capability_name_html(cap_data, matrix_data, primary, context)
    stable_id = cap_data[:capability].stable_id
    cell = cap_data[:cells][matrix_data[:person_level]]
    key = Views::Assessments::Concerns::RatedCount::CONTEXT_FREQUENCY_KEYS[context] || :current_frequency
    render_to_string(
      Views::Assessments::CapabilityNameRow.new(
        capability: cap_data[:capability],
        score: primary.dig(:capability_scores, stable_id),
        rated: cell.present? && cell[key].present?,
        blocked: primary.dig(:capability_statuses, stable_id) == :blocked,
        block_reason: primary.dig(:block_reasons, stable_id),
        merged_levels: matrix_data[:merged_levels],
        person_level: matrix_data[:person_level],
        thresholds: Views::Assessments::Glossary.thresholds_from(matrix_data),
        viewer_is_manager: viewer_is_manager?
      ),
      layout: false
    )
  end

  # The explainer drawer, re-rendered after a rating.
  #
  # It is mounted on the page ROOT so an open dialog survives a frame
  # reload — which also means nothing else replaces it, and without this
  # its arithmetic would keep explaining the score the page loaded with
  # while the hero beside it showed the new one.
  #
  # @param matrix_data [Hash] the rebuilt matrix data
  # @param primary [Hash] the viewer's primary scoring hash
  # @return [Turbo::Streams::TagBuilder]
  def score_explainer_stream(matrix_data, primary, _context)
    turbo_stream.replace(
      Views::Assessments::ScoreExplainerModal::ID,
      render_to_string(
        Views::Assessments::ScoreExplainerModal.new(
          components: primary[:components],
          state: primary[:performance_state],
          subject: explainer_subject,
          merged_levels: matrix_data[:merged_levels],
          person_level: matrix_data[:person_level],
          thresholds: Views::Assessments::Glossary.thresholds_from(matrix_data),
          second_person: !viewer_is_manager?,
          emphasised: matrix_data[:emphasised_capabilities]
        ),
        layout: false
      )
    )
  end

  def explainer_subject
    return "Your score" unless viewer_is_manager?

    assessee = Person.find_by(id: @assignment.person_id)
    assessee ? "#{assessee.name}'s score" : "This score"
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
end
