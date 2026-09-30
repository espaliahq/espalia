# frozen_string_literal: true

# "Aligning · PM3" — one chip per role other than home that alignment has
# started against this cycle (ADR-22), each linking into that role's lens.
# Sits beside the home status on the list cards, the home page and the
# assessment header, so starting a lens alignment is visible to both
# parties without either opening the lens.
class Views::Assessments::LensAlignmentChips < Views::Base
  STATUS_TEXT = { "aligning" => "Aligning", "aligned" => "Aligned" }.freeze

  # @param alignments [Array<#role_id, #code, #label, #level_ordinal, #status>]
  # @param assessment_id [String]
  def initialize(alignments:, assessment_id:)
    @alignments = alignments
    @assessment_id = assessment_id
  end

  def view_template
    return if @alignments.empty?

    span(class: "inline-flex flex-wrap items-center gap-1", data: { lens_alignment_chips: true }) do
      @alignments.each { |alignment| chip(alignment) }
    end
  end

  private

  def chip(alignment)
    a(
      href: assessment_path(@assessment_id, as_role: alignment.role_id, as_level: alignment.level_ordinal),
      title: "#{STATUS_TEXT.fetch(alignment.status)} against #{alignment.label}",
      data: { turbo_frame: "_top", lens_alignment: alignment.code },
      class: "inline-flex items-center whitespace-nowrap rounded-full px-2.5 py-0.5 text-xs font-medium " \
             "ring-1 ring-inset hover:underline focus-visible:outline-hidden focus-visible:ring-2 " \
             "focus-visible:ring-primary #{tone(alignment.status)}"
    ) { "#{STATUS_TEXT.fetch(alignment.status)} · #{alignment.code}" }
  end

  def tone(status)
    if status == "aligned"
      "bg-green-50 text-green-800 ring-green-200 dark:bg-green-900/30 dark:text-green-200 dark:ring-green-800"
    else
      "bg-amber-50 text-amber-800 ring-amber-200 dark:bg-amber-900/30 dark:text-amber-200 dark:ring-amber-800"
    end
  end
end
