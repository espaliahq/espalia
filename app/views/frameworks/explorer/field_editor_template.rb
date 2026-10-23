# frozen_string_literal: true

# The ONE inline-edit form for the whole Framework Explorer, parked in an inert
# `<template>` on the explorer root and cloned into place by
# `field_editor_controller.js` when a pencil is clicked.
#
# Before this existed every editable text pre-rendered its own hidden form +
# textarea + Stimulus mount (374 of each in the seeded me&u edit matrix, a
# third of the frame's bytes). Display markup now carries `data-editor-*`
# attributes only; this template supplies the shape.
#
# Width is `w-full min-w-0` deliberately: the old per-entity form was
# `w-80 sm:w-96`, which widened the table when opened in a level column and
# pushed later levels off-screen.
class Views::Frameworks::Explorer::FieldEditorTemplate < Views::Base
  # field_editor_controller stamps data-outcome; a proposal's edge turns amber.
  INPUT_CLASSES = "w-full min-w-0 text-sm rounded px-2 py-1 border border-strong " \
                  "data-[outcome=propose]:border-warning-strong bg-field text-default " \
                  "resize-y focus:outline-none focus:ring-1 focus:ring-focus"

  SUBMIT_CLASSES = "text-xs px-2 py-0.5 rounded bg-primary text-white hover:bg-primary/90"

  CANCEL_CLASSES = "text-xs px-2 py-0.5 rounded border border-gray-300 dark:border-gray-600 " \
                   "text-gray-600 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-800"

  def view_template
    template(data: { field_editor_target: "template" }) do
      form(
        class: "w-full min-w-0 mt-1",
        method: "post",
        data: {
          editor_form: true,
          turbo: "true",
          action: "turbo:submit-start->field-editor#submitStart " \
                  "turbo:submit-end->field-editor#submitted"
        }
      ) do
        # Turbo adds the CSRF header itself, but the "+ Add expectation" path
        # submits as a full navigation where the token input is the belt to
        # that braces — cheap once, here, instead of once per cell.
        input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
        input(type: "hidden", name: "_method", value: "patch", data: { editor_method_field: true })

        # Transport failures (network dropped, 5xx with no matching frame) have
        # no server-rendered message to show — the controller fills this in.
        div(
          role: "alert", hidden: true,
          class: "mb-1 #{Components::Shared::SubmitFallbackMessage::PANEL_CLASSES}",
          data: { editor_error_live: true }
        ) { }

        # cols="1" so the textarea contributes (almost) nothing to the
        # intrinsic width of an auto-layout table cell — `w-full` still sizes
        # it. Without it a level column grew ~18px the moment an editor opened,
        # which is the reflow this replaced (#379).
        textarea(
          class: INPUT_CLASSES,
          rows: "3",
          cols: "1",
          data: {
            editor_input: true,
            action: "keydown->field-editor#keydown input->field-editor#autogrow"
          }
        ) { "" }

        div(class: "flex flex-wrap items-center gap-1 mt-1") do
          button(
            type: "submit", class: SUBMIT_CLASSES,
            aria_describedby: "field-editor-outcome-hint",
            data: { editor_submit: true }
          ) { "Save" }
          button(
            type: "button", class: CANCEL_CLASSES,
            data: { action: "field-editor#cancel" }
          ) { "Cancel" }
          # sr-only: the outcome is already carried visually by the button
          # label (Save / Propose) and the amber border, and any visible text
          # here leaks into the intrinsic width of an auto-layout table cell —
          # widening the column the moment an editor opens (#379).
          # Only one editor is ever open, so a fixed id is safe — it lets the
          # submit button carry the outcome as its description.
          span(id: "field-editor-outcome-hint", class: "sr-only", data: { editor_hint: true }) { }
        end
      end
    end
  end
end
