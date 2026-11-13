# frozen_string_literal: true

# The level field picker on the HRIS connection form: the HRIS's fields by
# name, read from its catalogue (#67). It sits inside that form, so whatever it
# renders posts as `hris_connection[level_field_id]`.
#
# Rendered two ways. On the page it is a lazy frame whose placeholder carries
# the stored value in a hidden field, so the form keeps it while the catalogue
# loads. Loaded, it is the select, or, when the HRIS can't be read, the stored
# value kept as it is with the reason.
class Views::Integrations::HrisLevelFieldFrame < Views::Base
  include Views::Integrations::Concerns::SettingsFields

  FRAME_ID = "hris-level-field"
  LABEL = "Level field"
  NOT_CONNECTED = "Save a provider and its credentials to choose from the HRIS's fields."
  HINT = "The HRIS field holding each person's level ordinal. " \
         "Choose None when titles carry their level in the role mappings."

  # @param current [String, nil] the stored level field id
  # @param fields [Array<Hris::Field>, nil] the catalogue, once read
  # @param problem [String, nil] why the catalogue could not be read
  # @param src [String, nil] the frame's own path, given only for the lazy placeholder
  def initialize(current:, fields: nil, problem: nil, src: nil)
    @current = current.presence
    @fields = fields
    @problem = problem
    @src = src
  end

  def view_template
    turbo_frame_tag(FRAME_ID, src: @src, loading: ("lazy" if @src)) do
      if @fields
        picker
      else
        kept_value(@problem || "Loading the HRIS fields…", busy: @problem.nil?)
      end
    end
  end

  private

  def field_prefix = "hris_connection"

  def picker
    select_field(:level_field_id, LABEL, hint: HINT) do
      option(value: "", selected: @current.nil?) { "None" }
      option(value: @current, selected: true) { "#{@current} (no longer in the HRIS)" } if missing?
      @fields.sort_by { it.name.downcase }.each do |field|
        option(value: field.id, selected: field.id == @current) { "#{field.name} · #{field.list? ? 'list' : 'text'}" }
      end
    end
  end

  def missing? = @current && @fields.none? { it.id == @current }

  def kept_value(message, busy:)
    div(aria: { busy: busy.to_s }) do
      span(class: LABEL_CLASSES) { LABEL }
      input(type: "hidden", name: field_name(:level_field_id), value: @current.to_s)
      p(class: "mt-1 text-sm text-default [overflow-wrap:anywhere]") { @current || "None" }
      p(class: HINT_CLASSES, role: ("status" unless busy)) do
        plain message
        plain " Saving keeps the current level field." unless busy
      end
    end
  end
end
