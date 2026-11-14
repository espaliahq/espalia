# frozen_string_literal: true

# Which HRIS field a fact or a level is read from. An admin picks a field,
# sees what it would give, and only then chooses it. It loads after the page,
# as the field list comes from the HRIS.
class Views::Tenant::OrgGraph::Settings::FieldPickerFrame < Views::Base
  include Views::Tenant::OrgGraph::Settings::FormHelpers

  # What the frame picks a field for.
  #
  # @!attribute key [String] tells this picker's ids apart from the others on the page
  # @!attribute target [String] the preview target: "level", or a fact's part
  # @!attribute label [String] the select's label
  # @!attribute url [String] the frame's own path, which previews a field_id
  # @!attribute use_url [String] where choosing the field is saved, with PATCH
  # @!attribute field_param [String] the parameter the chosen field is saved as
  # @!attribute in_use [String] said when the previewed field is the one in use
  Picker = Data.define(:key, :target, :label, :url, :use_url, :field_param, :in_use)

  # @param picker [Picker]
  # @param current [String, nil] the field read now
  # @param chosen [String, nil] the field picked for a preview
  # @param fields [Array<Hris::Field>, nil] the HRIS's catalogue, once read
  # @param problem [String, nil] why the catalogue could not be read
  # @param preview [Hash, nil] as Operations::Integrations::HrisFieldPreview returns it
  # @param preview_problem [String, nil] why the chosen field could not be read
  # @param src [String, nil] the frame's own path, for the placeholder
  def initialize(picker:, current: nil, chosen: nil, fields: nil, problem: nil, preview: nil, preview_problem: nil, src: nil) # rubocop:disable Metrics/ParameterLists
    @picker = picker
    @current = current
    @chosen = chosen
    @fields = fields
    @problem = problem
    @preview = preview
    @preview_problem = preview_problem
    @src = src
  end

  # @param key [String]
  # @return [String]
  def self.frame_id(key) = "org-graph-field-#{key}"

  def view_template
    turbo_frame_tag(self.class.frame_id(@picker.key), src: @src) do
      if @fields
        picker
        outcome
      else
        p(class: "text-sm text-muted", role: ("status" if @problem), aria: { busy: @problem.nil?.to_s }) do
          @problem || "Loading the HRIS fields…"
        end
      end
    end
  end

  private

  def key = @picker.key

  def picker
    select_id = "org-graph-field-select-#{key}"
    form(action: @picker.url, method: "get", class: "flex flex-wrap items-end gap-2") do
      div(class: "flex min-w-0 flex-col gap-1") do
        label(for: select_id, class: "text-sm font-medium text-default") { @picker.label }
        select(id: select_id, name: "field_id", class: "#{Components::Kit::Field::SELECT} max-w-full") do
          option(value: "", selected: selected.nil?) { "Choose a field" }
          @fields.sort_by { it.name.downcase }.each do |field|
            option(value: field.id, selected: field.id == selected) { field_option(field) }
          end
        end
      end
      render Components::Kit::Button.new(variant: :outline, tone: :neutral, type: :submit, id: "org-graph-field-preview-#{key}") { "Preview" }
    end
  end

  def outcome
    if @preview_problem
      p(class: "mt-3 text-sm text-muted", role: "status") { @preview_problem }
    elsif @preview
      div(class: "mt-4 space-y-3") do
        render Views::Integrations::HrisFieldPreviewFrame.new(
          target: @picker.target, preview: @preview, frame_id: "org-graph-field-preview-frame-#{key}",
          heading_level: :h3
        )
        choose
      end
    end
  end

  def choose
    if @chosen == @current
      p(class: "text-sm text-muted") { @picker.in_use }
      return
    end

    settings_form(@picker.use_url, method: :patch, class: "mt-3", data: { turbo_frame: "_top" }) do
      input(type: "hidden", name: "provider", value: ActsAsTenant.current_tenant.hris_config.provider)
      input(type: "hidden", name: @picker.field_param, value: @chosen)
      render Components::Kit::Button.new(variant: :solid, tone: :brand, type: :submit, id: "org-graph-field-use-#{key}") do
        "Use this field"
      end
    end
  end

  def selected = @chosen || @current

  def field_option(field)
    field.id == @current ? "#{field.name} (in use)" : field.name
  end
end
