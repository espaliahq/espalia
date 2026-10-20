# frozen_string_literal: true

# @label Definition tip
class Kit::DefinitionTipPreview < Lookbook::Preview
  WEIGHT = "Some capabilities count for more or less than others: a ×2 capability moves " \
           "the number twice as much as a ×1 one, and a ×0.5 one half as much."

  # @param term text
  # @param definition textarea
  # @param align select { choices: [left, right] }
  def playground(term: "Weight", definition: WEIGHT, align: :left)
    tip(term, definition: definition, id: "deftip-playground", align: align.to_sym)
  end

  # @!group Terms

  def carried
    tip("Carried", id: "deftip-carried",
                   definition: "A rating carried from the last cycle still counts towards the score. " \
                               "The work this cycle is to confirm or change it.")
  end

  def blocked
    tip("Blocked", id: "deftip-blocked",
                   definition: "This capability's ratings sit far enough below what E3 expects to hold " \
                               "the whole assessment there, whatever the others say. Talk about it first. " \
                               "Only a rating can block: a capability nobody has rated shows Not rated instead.")
  end

  def no_expectation
    tip("No expectation", id: "deftip-no-expectation",
                          definition: "A capability with nothing written for E3 sits outside what " \
                                      "the level asks, so it neither helps nor hurts the score.")
  end

  # A term with a look of its own: the assessment's status badge
  def badge_trigger
    render Components::Kit::DefinitionTip.new(
      "Ready for alignment",
      definition: "You've rated every capability at your level. Your manager starts alignment next.",
      id: "deftip-ready-for-alignment",
      trigger_class: "min-h-6 #{Components::Kit::Badge.classes(:success)}"
    )
  end

  # @!endgroup

  private

  def tip(term, definition:, id:, align: :left)
    render_with_template(
      template: "kit/definition_tip_preview/tip",
      locals: { component: Components::Kit::DefinitionTip.new(term, definition: definition, id: id, align: align),
                align: align }
    )
  end
end
