# frozen_string_literal: true

# The one modal every HRIS mapping edit opens (#436) — "Map…" on an unmapped
# title, a mapping chip, and "Add mapping" all prefill it through the
# `hris-mapping-form` controller from their trigger's dataset.
#
# Embedded: the HRIS page root carries the `modal` controller.
class Views::Integrations::HrisMappingModal < Views::Base
  ID = "hris-mapping-modal"

  FIELD_CLASSES = "#{Components::Kit::Field::INPUT} read-only:bg-subtle"
  LABEL_CLASSES = "block text-sm font-medium text-default mb-1"
  HINT_CLASSES = "mt-1 text-xs text-muted"

  # @param roles [Array<FrameworkState::Role>]
  # @param level_ordinals_by_role_code [Hash{String => Array<Integer>}]
  # @param hris_titles [Array<String>] titles HRIS people hold, offered as suggestions
  # @param level_column_configured [Boolean] whether "from the HRIS level column" is a choice
  def initialize(roles: [], level_ordinals_by_role_code: {}, hris_titles: [], level_column_configured: false)
    @roles = roles
    @level_ordinals_by_role_code = level_ordinals_by_role_code
    @hris_titles = hris_titles
    @level_column_configured = level_column_configured
  end

  def view_template
    render Components::Kit::Modal.new(id: ID, title: "Map an HRIS title", standalone: false) do |modal|
      modal.body { mapping_form }
    end
  end

  private

  def mapping_form
    form(
      action: tenant_hris_title_mapping_path,
      method: "post",
      class: "space-y-4",
      data: {
        controller: "hris-mapping-form",
        hris_mapping_form_levels_value: @level_ordinals_by_role_code.to_json,
        hris_mapping_form_modal_id_value: ID
      }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      title_field
      role_field
      level_field
      p(class: "text-sm text-muted") do
        "Nobody moves until the next HRIS sync. Sync now on this page applies it straight away."
      end
      actions
    end
  end

  def title_field
    div do
      label(for: "hris-mapping-title", class: LABEL_CLASSES) { "HRIS job title" }
      input(
        id: "hris-mapping-title", type: "text", name: "hris_title_mapping[title]",
        required: true, maxlength: Operations::Integrations::MapHrisTitle::MAX_TITLE_LENGTH,
        autocomplete: "off", list: "hris-mapping-title-options", class: FIELD_CLASSES,
        aria: { describedby: "hris-mapping-title-hint" },
        data: { hris_mapping_form_target: "title" }
      )
      datalist(id: "hris-mapping-title-options") do
        @hris_titles.each { |title| option(value: title) }
      end
      p(id: "hris-mapping-title-hint", class: HINT_CLASSES) do
        "Matched ignoring case and surrounding spaces, but otherwise exactly: " \
        "“Engineering Manager (EM3)” is a different title from “Engineering Manager”."
      end
    end
  end

  def role_field
    div do
      label(for: "hris-mapping-role", class: LABEL_CLASSES) { "Framework role" }
      select(
        id: "hris-mapping-role", name: "hris_title_mapping[framework_role_code]", required: true,
        class: Components::Kit::Field::SELECT,
        data: { hris_mapping_form_target: "role", action: "change->hris-mapping-form#roleChanged" }
      ) do
        option(value: "") { "Choose a role…" }
        @roles.each { |role| option(value: role.code) { "#{role.name} (#{role.code})" } }
      end
    end
  end

  def level_field
    div do
      label(for: "hris-mapping-level", class: LABEL_CLASSES) { "Level" }
      select(
        id: "hris-mapping-level", name: "hris_title_mapping[level_ordinal]",
        required: !@level_column_configured, class: Components::Kit::Field::SELECT,
        aria: { describedby: "hris-mapping-level-hint" },
        data: { hris_mapping_form_target: "level" }
      ) do
        if @level_column_configured
          option(value: "") { "From the HRIS level column" }
        else
          option(value: "") { "Choose a level…" }
        end
        all_ordinals.each { |ordinal| option(value: ordinal) { "Everyone at L#{ordinal}" } }
      end
      p(id: "hris-mapping-level-hint", class: HINT_CLASSES) do
        "The HRIS level column gives each person their own level; a fixed level suits a title that " \
        "names one. Only the chosen role’s levels are offered."
      end
    end
  end

  def actions
    div(class: "flex justify-end gap-2 pt-2") do
      render Components::Kit::Button.new(variant: :outline, touch: true, data: { action: "click->modal#close" }) { "Cancel" }
      render Components::Kit::Button.new(tone: :brand, type: :submit, touch: true, data: { turbo_submits_with: "Saving…" }) do
        "Save mapping"
      end
    end
  end

  def all_ordinals
    @level_ordinals_by_role_code.values.flatten.uniq.sort
  end
end
