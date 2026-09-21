# frozen_string_literal: true

# The assessment vocabulary, defined once (#414).
#
# Built per request rather than frozen as constants: almost every definition
# names something only this viewer's page knows — their level codes, their
# framework's configured bands, their tenant's word for a state. Copy that
# says 80% where the framework says 75% is worse than no copy at all.
#
# The wording rules, and why each exists, are in
# docs/guidelines/assessments.md; glossary_test.rb enforces them.
class Views::Assessments::Glossary
  # Shared with the calibration cohort view, whose axis spans people at
  # different levels, so no single code is true for the column. Everywhere a
  # code IS known, the copy names it instead.
  SCALE_SENTENCE = "100% means meeting the level; every point above is progress toward the " \
                   "next, and 200% means demonstrating it in full."

  # One reader, so no surface can fall back to the shipped 80/95/150 while
  # another names the framework's real numbers.
  #
  # @param matrix_data [Hash]
  # @return [Hash]
  def self.thresholds_from(matrix_data)
    {
      underperforming: matrix_data[:underperforming_threshold],
      meeting: matrix_data[:meeting_expectation_threshold],
      mastering: matrix_data[:mastery_threshold]
    }
  end

  # @param current_code [String] the assessed level's code, e.g. "E3"
  # @param next_code [String, nil] the level above it, nil at the top
  # @param thresholds [Hash] `{ underperforming:, meeting:, mastering: }`
  #   as ratios from the framework's configuration
  # @param tenant [Tenant, nil] whose words for the states are used
  # @param second_person [Boolean] whether the reader is the person being
  #   described. A manager reading "what E3 expects you already show" about
  #   their report is being told the wrong thing, so the copy follows the
  #   same subject the hero's headline does.
  def initialize(current_code:, next_code: nil, thresholds: {}, second_person: true,
                 tenant: ActsAsTenant.current_tenant)
    @current_code = current_code
    @next_code = next_code
    @thresholds = thresholds
    @second_person = second_person
    @tenant = tenant
  end

  # @param key [Symbol]
  # @return [String]
  def label(key) = terms.fetch(key).fetch(:label)

  # @param key [Symbol]
  # @return [String]
  def definition(key) = terms.fetch(key).fetch(:definition)

  # @return [Boolean]
  def key?(key) = terms.key?(key)

  # @return [Array<Symbol>]
  def keys = terms.keys

  private

  def terms
    @terms ||= {
      score: {
        label: "Score",
        definition: "How much of what #{@current_code} expects #{subject_shows}, across every " \
                    "capability. #{full_scale_sentence} Feedback and comments are not part of it."
      },
      state: {
        label: "State",
        definition: state_sentence
      },
      required: {
        label: "Required",
        definition: "Some capabilities are marked Required: this role cannot be short of them. " \
                    "Doing well elsewhere does not make up for the gap.#{required_gate_clause}"
      },
      blocked: {
        label: "Blocked",
        definition: "This capability sits far enough below what #{@current_code} expects to hold " \
                    "the whole assessment there, whatever the others say. Talk about it first."
      },
      weight: {
        label: "Weight",
        definition: "Some capabilities count for more or less than others: a ×2 capability moves " \
                    "the number twice as much as a ×1 one, and a ×0.5 one half as much."
      },
      not_rated: {
        label: "Not rated",
        definition: "A capability nobody has rated yet has no answer. It is not a zero and not a " \
                    "judgement — it waits for a rating rather than counting as one."
      },
      no_expectation: {
        label: "No expectation",
        definition: "A capability with nothing written for #{@current_code} sits outside what " \
                    "the level asks, so it neither helps nor hurts the score."
      },
      carried: {
        label: "Carried",
        definition: "A rating carried from the last cycle still counts towards the score. The " \
                    "work this cycle is to confirm or change it."
      },
      rated_count: {
        label: "Rated",
        definition: "How many of this section's #{@current_code} capabilities carry a rating. Until " \
                    "at least half do, no score appears — a number drawn from two answers out of " \
                    "nine says more about the missing seven."
      },
      below_levels: {
        label: "Levels below #{@current_code}",
        definition: "Levels below #{@current_code} are assumed to be met, so they neither add to the " \
                    "score nor need rating. A rating that says otherwise takes that share back."
      }
    }.freeze
  end

  # Stops at the top of the ladder rather than promising a band the person
  # can never reach.
  def required_gate_clause
    return "" unless @next_code

    " Nothing above #{@current_code} counts until #{@current_code} itself is consistent."
  end

  def full_scale_sentence
    return "100% is #{@current_code} in full, and there is no level above it." unless @next_code

    "100% means all of #{@current_code} is shown; 200% means all of #{@next_code} is too."
  end

  def subject_shows = @second_person ? "you show" : "they show"

  def subject = @second_person ? "you" : "they"

  def state_sentence
    # Each band names the number it starts at: "up to 95%, then from there"
    # left 95% belonging to both.
    "The word beside the number, set by where the score falls: " \
      "#{word(:underperforming)} below #{pct(:underperforming)}%, " \
      "#{word(:progressing)} from #{pct(:underperforming)}%, " \
      "#{word(:performing)} from #{pct(:meeting)}%, " \
      "#{word(:mastering)} from #{pct(:mastering)}%. " \
      "#{blocked_clause}"
  end

  def blocked_clause
    "A blocked capability holds the state back, whatever the number says."
  end

  def word(state) = Views::Assessments::StateLabels.for(state, tenant: @tenant)

  def pct(key) = (@thresholds[key].to_f * 100).round(0)
end
