# frozen_string_literal: true

# The assessment vocabulary, defined once (#414).
#
# The calibration screens have defined their own terms in-surface since they
# shipped; the assessment side — where the same numbers are read by the
# person they describe — defined nothing. A number nobody can define is one
# people either ignore or read as an accusation.
#
# Built per request rather than frozen as constants, because almost every
# definition has to name something only this viewer's page knows: their
# level codes, their framework's configured bands, and their tenant's word
# for a state. Copy that says "80%" where the framework says 75% is worse
# than no copy at all.
#
# Rules for the wording, all deliberate:
#
# - **Never a model word.** No band, gate, tolerance, weight unit, ratio,
#   perspective, component. The reader did not build the engine.
# - **Always their own codes and numbers.** "100% is E3" and never
#   "100% is your level".
# - **Say what does NOT count**, since that is what people assume wrongly:
#   evidence does not move a score, levels below the assessed one are
#   assumed met, unrated is not zero-by-judgement, carried is not confirmed.
class Views::Assessments::Glossary
  # The scale in one sentence, without naming any level — the calibration
  # cohort view reads this, where the axis spans people standing at
  # different levels and no single code is true for the column. The
  # assessment's own copy names the reader's codes instead, which is
  # better wherever they are known.
  SCALE_SENTENCE = "100% means meeting the level; every point above is progress toward the " \
                   "next one, and 200% means demonstrating it in full."

  # The framework's own bands, from the builder's output — one reader, so
  # no surface can quietly fall back to the shipped 80/95/150 while another
  # names the framework's real numbers.
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
  def initialize(current_code:, next_code: nil, thresholds: {}, tenant: ActsAsTenant.current_tenant)
    @current_code = current_code
    @next_code = next_code
    @thresholds = thresholds
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
        definition: "How much of what #{@current_code} expects you already show, across every " \
                    "capability. #{full_scale_sentence} Feedback and comments are not part of it — " \
                    "they are how people talk about the ratings, not an input to them."
      },
      state: {
        label: "State",
        definition: state_sentence
      },
      required: {
        label: "Required",
        definition: "A capability this role cannot be short of. Doing well elsewhere does not make " \
                    "up for a gap here, and nothing you show above #{@current_code} counts until " \
                    "you are consistent at #{@current_code} itself."
      },
      blocked: {
        label: "Blocked",
        definition: "This capability is far enough below what #{@current_code} expects that the " \
                    "whole assessment is held there, whatever the other capabilities say. It is the " \
                    "one thing to talk about first."
      },
      weight: {
        label: "Weight",
        definition: "This capability counts for more than the others when the score is worked out — " \
                    "a ×2 capability moves the number twice as much as a ×1 one."
      },
      not_rated: {
        label: "Not rated",
        definition: "Nobody has recorded a rating here yet. It is not a zero and not a judgement — " \
                    "until it is rated it simply has no answer."
      },
      no_expectation: {
        label: "No expectation",
        definition: "This capability has nothing written for #{@current_code}, so nothing is asked " \
                    "of it at this level and it neither helps nor hurts the score."
      },
      carried: {
        label: "Carried",
        definition: "This rating came from the last cycle rather than from anyone this time. It " \
                    "counts towards the score, and the work this cycle is to confirm or change it."
      },
      rated_count: {
        label: "Rated",
        definition: "How many of this section's #{@current_code} capabilities carry a rating. Until " \
                    "at least half do, no score is shown — a number drawn from two answers out of " \
                    "nine says more about the missing seven."
      },
      below_levels: {
        label: "Levels below #{@current_code}",
        definition: "Levels below #{@current_code} are assumed to be met, so they neither add to the " \
                    "score nor need rating. A rating that says otherwise takes its share away again."
      }
    }.freeze
  end

  # "100% is E3 in full; 200% is E4 in full, which is promotion ready."
  def full_scale_sentence
    return "100% is #{@current_code} in full, and there is no level above it." unless @next_code

    "100% means you show all of #{@current_code}; 200% means you show all of #{@next_code} too."
  end

  def state_sentence
    "The word beside the number, from where the score falls: " \
      "#{word(:underperforming)} below #{pct(:underperforming)}%, " \
      "#{word(:progressing)} up to #{pct(:meeting)}%, " \
      "#{word(:performing)} from there, " \
      "#{word(:mastering)} from #{pct(:mastering)}%. " \
      "#{blocked_clause}"
  end

  def blocked_clause
    "A capability that is blocked holds the state back whatever the number says."
  end

  def word(state) = Views::Assessments::StateLabels.for(state, tenant: @tenant)

  def pct(key) = (@thresholds[key].to_f * 100).round(0)
end
