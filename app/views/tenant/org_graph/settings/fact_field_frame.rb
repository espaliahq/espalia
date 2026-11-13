# frozen_string_literal: true

# Which HRIS field a fact is read from. An admin picks a field, sees what it
# would give, and only then chooses it. It loads after the page, as the
# field list comes from the HRIS.
class Views::Tenant::OrgGraph::Settings::FactFieldFrame < Views::Base
  include Views::Tenant::OrgGraph::Settings::FormHelpers
  include Views::Tenant::OrgGraph::Settings::FactLabels

  PART_NAMES = { "cost_centre" => "cost centre", "country" => "country" }.freeze

  # @param fact [String] a fact in OrgGraph::StructureAggregate::MAPPABLE_FIELDS
  # @param part [String] the part of it a field is chosen for
  # @param current [String, nil] the field it is read from now
  # @param chosen [String, nil] the field picked for a preview
  # @param fields [Array<Hris::Field>, nil] the HRIS's catalogue, once read
  # @param problem [String, nil] why the catalogue could not be read
  # @param preview [Hash, nil] as Operations::Integrations::HrisFieldPreview returns it
  # @param preview_problem [String, nil] why the chosen field could not be read
  # @param src [String, nil] the frame's own path, for the placeholder
  def initialize(fact:, part:, current: nil, chosen: nil, fields: nil, problem: nil, preview: nil, preview_problem: nil, src: nil) # rubocop:disable Metrics/ParameterLists
    @fact = fact
    @part = part
    @current = current
    @chosen = chosen
    @fields = fields
    @problem = problem
    @preview = preview
    @preview_problem = preview_problem
    @src = src
  end

  def self.frame_id(fact) = "org-graph-field-#{fact}"

  def view_template
    turbo_frame_tag(self.class.frame_id(@fact), src: @src) do
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

  def picker
    select_id = "org-graph-field-select-#{@fact}"
    form(action: tenant_org_graph_settings_fact_field_path(@fact), method: "get", class: "flex flex-wrap items-end gap-2") do
      div(class: "flex min-w-0 flex-col gap-1") do
        label(for: select_id, class: "text-sm font-medium text-default") { "HRIS field for the #{part_name}" }
        select(id: select_id, name: "field_id", class: "#{Components::Kit::Field::SELECT} max-w-full") do
          option(value: "", selected: selected.nil?) { "Choose a field" }
          @fields.sort_by { it.name.downcase }.each do |field|
            option(value: field.id, selected: field.id == selected) { field_option(field) }
          end
        end
      end
      render Components::Kit::Button.new(variant: :outline, tone: :neutral, type: :submit, id: "org-graph-field-preview-#{@fact}") { "Preview" }
    end
  end

  def outcome
    if @preview_problem
      p(class: "mt-3 text-sm text-muted", role: "status") { @preview_problem }
    elsif @preview
      div(class: "mt-4 space-y-3") do
        render Views::Integrations::HrisFieldPreviewFrame.new(
          target: @part, preview: @preview, frame_id: "org-graph-field-preview-frame-#{@fact}"
        )
        choose
      end
    end
  end

  def choose
    if @chosen == @current
      p(class: "text-sm text-muted") { "#{fact_label(@fact)} is read from this field now." }
      return
    end

    settings_form(tenant_org_graph_settings_fact_provider_path(@fact), method: :patch, data: { turbo_frame: "_top" }) do
      input(type: "hidden", name: "provider", value: ActsAsTenant.current_tenant.hris_config.provider)
      input(type: "hidden", name: "fields[#{@part}]", value: @chosen)
      render Components::Kit::Button.new(variant: :solid, tone: :brand, type: :submit, id: "org-graph-field-use-#{@fact}") do
        "Use this field"
      end
    end
  end

  def selected = @chosen || @current

  def part_name = PART_NAMES.fetch(@part, @part.humanize(capitalize: false))

  def field_option(field)
    field.id == @current ? "#{field.name} (in use)" : field.name
  end
end
