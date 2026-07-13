# frozen_string_literal: true

# The manager's "Mark alignment complete" header control, gated on full
# current-level aligned coverage (the same gate
# {Assessments::AlignmentCompletionsController} enforces server-side).
#
# While any current-level cell lacks an agreed value the button renders
# disabled, next to a jump chip ("N to align →") that focuses the first
# unaligned cell via the `continue-assessing` window-event bridge (the
# control sits in the static header, outside the matrix controller's scope).
# Once coverage is whole it renders the live form + confirm.
#
# Wrapped in `id="alignment-completion-control"` so
# {Assessments::AlignmentRatingsController} can `turbo_stream.replace` it on
# every alignment rating — the button enables the moment the last cell is
# agreed, without a reload. Desktop-only (`hidden md:inline-flex`), matching
# the other alignment milestone buttons.
#
class Views::Assessments::AlignmentCompletionControl < Views::Base
  # @param assignment [PersonFrameworkAssignment]
  # @param matrix_data [Hash] output from Assessments::MatrixDataBuilder —
  #   used to compute current-level aligned coverage in-memory
  def initialize(assignment:, matrix_data:)
    @assignment = assignment
    @matrix_data = matrix_data
  end

  def view_template
    span(id: "alignment-completion-control", class: "hidden md:inline-flex items-center gap-2") do
      if unaligned_capabilities.empty?
        completion_form
      else
        jump_chip
        disabled_button
      end
    end
  end

  private

  def completion_form
    confirm_msg = "Marking alignment complete will lock all ratings for this cycle, " \
      "including the agreed values. Continue?"
    form(
      action: assessment_alignment_completion_path(@assignment),
      method: "post",
      data: { turbo_confirm: confirm_msg },
      class: "inline"
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      button(
        type: "submit",
        class: "text-sm font-medium px-3 py-1.5 rounded-md " \
               "bg-green-600 dark:bg-green-700 text-white " \
               "hover:bg-green-700 dark:hover:bg-green-600 cursor-pointer"
      ) { "Mark alignment complete" }
    end
  end

  def disabled_button
    button(
      type: "button",
      disabled: true,
      title: "Every current-level capability needs an agreed rating before " \
             "alignment can be marked complete.",
      class: "text-sm font-medium px-3 py-1.5 rounded-md " \
             "bg-gray-200 dark:bg-gray-700 text-gray-600 dark:text-gray-300 " \
             "cursor-not-allowed"
    ) { "Mark alignment complete" }
  end

  # Amber count chip that jumps the matrix to the first unaligned
  # current-level cell, via the shared `continue-assessing` window-event
  # bridge (the matrix controller's element doesn't enclose the header).
  def jump_chip
    render Views::Assessments::ContinueAssessingLink.new(
      capability_stable_id: unaligned_capabilities.first,
      level_ordinal: person_level,
      label: "#{unaligned_capabilities.size} to align",
      classes: "inline-flex items-center gap-1 text-xs font-medium px-2 py-1 rounded-md " \
               "bg-amber-50 dark:bg-amber-900/20 text-amber-700 dark:text-amber-400 " \
               "border border-amber-200 dark:border-amber-800 " \
               "hover:bg-amber-100 dark:hover:bg-amber-900/40"
    )
  end

  # stable_ids of current-level cells without an agreed value. Same
  # denominator as {Assessments::LevelCoverage} by construction — both
  # walk the MatrixDataBuilder cell set.
  #
  # @return [Array<String>]
  def unaligned_capabilities
    @unaligned_capabilities ||= @matrix_data[:categories]
      .flat_map { |cat| cat[:capabilities] }
      .filter_map do |cap_data|
        cell = cap_data[:cells][person_level]
        next unless cell

        cap_data[:capability].stable_id if cell[:aligned_frequency].blank?
      end
  end

  def person_level
    @matrix_data[:person_level]
  end
end
