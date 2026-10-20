# frozen_string_literal: true

# "Aligning · PM3" — one chip per role other than home that alignment has
# started against this cycle (ADR-22), each linking into that role's lens.
# Sits beside the home status on the list cards, the home page and the
# assessment header, so starting a lens alignment is visible to both
# parties without either opening the lens.
class Views::Assessments::LensAlignmentChips < Views::Base
  STATUS_TEXT = { "aligning" => "Aligning", "aligned" => "Aligned" }.freeze
  TONES = { "aligning" => :warning, "aligned" => :success }.freeze

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
      class: "#{Components::Kit::Badge.classes(tone: TONES.fetch(alignment.status))} hover:underline"
    ) { "#{STATUS_TEXT.fetch(alignment.status)} · #{alignment.code}" }
  end
end
