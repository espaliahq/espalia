# frozen_string_literal: true

# Shared "Discuss…" modal for the Framework Explorer (edit mode) — opens a
# clarification: an anchored question that proposes nothing (§12a).
#
# One instance per page on the explorer root (a pane reload must not destroy an
# open modal — Lesson 19); every "Discuss…" trigger — expectation cell,
# capability row kebab, illustration kebab — opens it, passing the anchor via
# the trigger dataset (read by the `request-clarification-form` controller).
#
# Submits to {Frameworks::ClarificationsController#create} → 204 +
# `X-Suggestion-Id`; the form controller then opens the new discussion's card in
# the context pane.
class Views::Frameworks::Explorer::RequestClarificationModal < Views::Base
  # @param framework_id [String]
  def initialize(framework_id:)
    @framework_id = framework_id
  end

  def view_template
    render Components::Kit::Modal.new(
      id: "request-clarification-modal",
      title: "Start a discussion",
      standalone: false,
      # A half-written question is real work — confirm before Esc discards it.
      dirty_guard: "Discard this question?"
    ) do |m|
      m.body { discussion_form }
    end
  end

  private

  def discussion_form
    form(
      action: framework_clarifications_path(@framework_id),
      method: "post",
      class: "space-y-4",
      data: {
        controller: "request-clarification-form",
        action: "turbo:submit-end->modal#submitted turbo:submit-end->request-clarification-form#submitted"
      }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      anchor_fields

      p(class: "text-sm text-muted") do
        "Ask a question or flag something for review. This opens a discussion others can join — " \
          "it proposes no change."
      end

      context_line
      level_field
      question_field
      actions
    end
  end

  # Filled by the form controller from the trigger's dataset.
  def anchor_fields
    input(type: "hidden", name: "clarification[capability_id]",
          data: { request_clarification_form_target: "capabilityId" })
    input(type: "hidden", name: "clarification[illustration_id]",
          data: { request_clarification_form_target: "illustrationId" })
  end

  # Where in the framework the question is anchored, e.g.
  # "Strategic Thinking · L5" or "… · L5 · Software Engineer example".
  def context_line
    p(class: "hidden rounded-md bg-subtle px-3 py-2 text-sm " \
             "font-medium text-muted",
      data: { request_clarification_form_target: "context" })
  end

  # Shown only when the trigger supplies level options (the capability row
  # kebab, which has no single cell in mind). Cell and illustration triggers
  # carry their level implicitly.
  def level_field
    div(class: "hidden", data: { request_clarification_form_target: "levelField" }) do
      label(for: "clarification_level_ordinal",
            class: "block text-sm font-medium text-default mb-1") { "Level" }
      select(
        id: "clarification_level_ordinal", name: "clarification[level_ordinal]",
        class: Components::Kit::Field::SELECT,
        data: { request_clarification_form_target: "levelSelect" }
      )
    end
  end

  def question_field
    div do
      label(for: "clarification_rationale",
            class: "block text-sm font-medium text-default mb-1") { "Your question" }
      textarea(
        id: "clarification_rationale", aria: { describedby: "clarification_rationale-hint" }, name: "clarification[rationale]", rows: "3", required: true,
        class: Components::Kit::Field::TEXTAREA,
        placeholder: "e.g. Is third-party integration the right example at this level?",
        data: { request_clarification_form_target: "question" }
      )
      p(id: "clarification_rationale-hint", class: "mt-1 text-xs text-muted") { Prose::COMPOSER_HINT }
    end
  end

  def actions
    div(class: "flex items-center gap-3 pt-1") do
      render Components::Kit::Button.new(tone: :brand, type: :submit) { "Start discussion" }
      render Components::Kit::Button.new(variant: :ghost, data: { action: "click->modal#close" }) { "Cancel" }
    end
  end
end
