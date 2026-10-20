# frozen_string_literal: true

# "Exploring PM3" — one chip per open declared exploration (ADR-22) on a
# team card, linking into the assessment read through that role and level.
# The sky tone is the lens chip's: an exploration is a lens someone chose to
# share.
class Views::Assessments::ExplorationChips < Views::Base
  TONE = "bg-sky-50 text-sky-800 ring-sky-200 dark:bg-sky-900/30 dark:text-sky-200 dark:ring-sky-800"

  # @param entries [Array<Assessments::OpenExplorations::Entry>]
  # @param assessment_id [String]
  def initialize(entries:, assessment_id:)
    @entries = entries
    @assessment_id = assessment_id
  end

  def view_template
    return if @entries.empty?

    span(class: "inline-flex flex-wrap items-center gap-1", data: { exploration_chips: true }) do
      @entries.each { |entry| chip(entry) }
    end
  end

  private

  def chip(entry)
    a(
      href: assessment_path(@assessment_id, entry.lens_params),
      title: "Exploring #{entry.label}",
      data: { turbo_frame: "_top", exploration: entry.code },
      class: "inline-flex items-center whitespace-nowrap rounded-full px-2.5 py-0.5 text-xs font-medium " \
             "ring-1 ring-inset hover:underline focus-visible:outline-hidden focus-visible:ring-2 " \
             "focus-visible:ring-focus #{TONE}"
    ) { "Exploring #{entry.code}" }
  end
end
