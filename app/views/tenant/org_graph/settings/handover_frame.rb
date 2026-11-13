# frozen_string_literal: true

# One level's handover. For a level Espalia holds: pick a field, make a call
# for each unit, compare, then switch. For a level the HRIS supplies: what
# handing it back keeps, and the button that does it.
#
# Calls travel as one parameter per unit, `calls[<unit id>]`: `match:<value
# key>`, `into:<unit id>` or `retire`, so a unit has one select and never two
# answers.
class Views::Tenant::OrgGraph::Settings::HandoverFrame < Views::Base
  include Views::Tenant::OrgGraph::Settings::FormHelpers

  # @param level [Hash] id and name
  # @param fields [Array<Hris::Field>, nil] the HRIS's catalogue, once read
  # @param chosen [String, nil] the field compared
  # @param comparison [Hash, nil] Operations::Integrations::HrisLevelHandover's hand-over payload
  # @param handback [Hash, nil] its hand-back payload
  # @param calls [Hash{String => String}] each unit's call, as sent
  # @param compared [Boolean] whether the comparison counted the calls sent, rather than none
  # @param problem [String, nil] why the HRIS or the comparison could not be read
  # @param src [String, nil] the frame's own path, for the placeholder
  def initialize(level:, fields: nil, chosen: nil, comparison: nil, handback: nil, calls: {}, compared: false, # rubocop:disable Metrics/ParameterLists
                 problem: nil, src: nil)
    @level = level
    @fields = fields
    @chosen = chosen
    @comparison = comparison
    @handback = handback
    @calls = calls
    @compared = compared
    @problem = problem
    @src = src
  end

  # @param level_id [String]
  # @return [String]
  def self.frame_id(level_id) = "org-graph-handover-frame-#{level_id}"

  def view_template
    turbo_frame_tag(self.class.frame_id(id), src: @src) do
      if @handback then hand_back
      elsif @fields then hand_over
      else
        p(class: "text-sm text-muted", role: ("status" if @problem), aria: { busy: @problem.nil?.to_s }) do
          @problem || "Reading the HRIS…"
        end
      end
    end
  end

  private

  def id = @level[:id]

  def name = @level[:name]

  def provider_label = HrisConfig.provider_label(ActsAsTenant.current_tenant.hris_config.provider)

  def hand_back
    p(class: "text-sm text-default") do
      "#{HrisConfig.provider_label(@handback[:provider])} supplies #{name}: " \
        "#{count(@handback[:units], 'unit')} and #{count(@handback[:memberships], 'membership')}."
    end
    p(class: "mt-1 text-sm text-muted") do
      "Handing it back keeps every unit and membership as it is, and the successions and retirements the " \
        "handover made stand. People then edit its units here."
    end
    settings_form(tenant_org_graph_settings_level_handover_path(id), method: :delete, class: "mt-3",
                                                                     data: { turbo_frame: "_top" }) do
      input(type: "hidden", name: "fingerprint", value: @handback[:fingerprint])
      render Components::Kit::Button.new(variant: :outline, tone: :neutral, type: :submit, id: "org-graph-hand-back-#{id}") do
        "Hand #{name} back to Espalia"
      end
    end
    fingerprint(@handback[:fingerprint])
  end

  def hand_over
    form(action: tenant_org_graph_settings_level_handover_path(id), method: "get") do
      field_select
      unit_calls if @comparison
      div(class: "mt-3") do
        render Components::Kit::Button.new(variant: :outline, tone: :neutral, type: :submit, id: "org-graph-handover-compare-#{id}") do
          "Compare"
        end
      end
    end
    p(class: "mt-3 text-sm text-muted", role: "status") { @problem } if @problem
    return unless @comparison

    @compared ? summary : p(class: "mt-3 text-sm text-muted") { "Each call starts from a value with the unit's name. Check each, then compare." }
    switch if ready?
  end

  def field_select
    select_id = "org-graph-handover-field-#{id}"
    div(class: "flex min-w-0 flex-col gap-1") do
      label(for: select_id, class: "text-sm font-medium text-default") { "HRIS field to hand #{name} to" }
      select(id: select_id, name: "field_id", class: "#{Components::Kit::Field::SELECT} max-w-full") do
        option(value: "", selected: @chosen.nil?) { "Choose a field" }
        @fields.sort_by { it.name.downcase }.each do |field|
          option(value: field.id, selected: field.id == @chosen) { field.name }
        end
      end
    end
  end

  def unit_calls
    ul(class: "mt-4 space-y-3") do
      @comparison[:units].each { unit_call(it) }
    end
  end

  def unit_call(unit)
    select_id = "org-graph-handover-call-#{unit[:unit_id]}"
    li(id: "org-graph-handover-unit-#{unit[:unit_id]}", class: "flex min-w-0 flex-col gap-1") do
      label(for: select_id, class: "text-sm font-medium text-default") { "Call for #{unit[:name]}" }
      p(class: "text-xs text-muted") { unit_detail(unit) }
      select(id: select_id, name: "calls[#{unit[:unit_id]}]", class: "#{Components::Kit::Field::SELECT} max-w-full") do
        current = call_for(unit)
        option(value: "", selected: current.blank?) { "Choose a call" }
        optgroup(label: "Match a value") do
          @comparison[:items].each do |item|
            value = "match:#{item[:key]}"
            option(value:, selected: value == current) { "#{item[:label]} · #{count(item[:people], 'person', 'people')}" }
          end
        end
        optgroup(label: "Or, with no value of its own") do
          (@comparison[:units] - [ unit ]).each do |other|
            value = "into:#{other[:unit_id]}"
            option(value:, selected: value == current) { "Succeed into #{other[:name]}" }
          end
          option(value: Hris::LevelHandover::RETIRE, selected: current == Hris::LevelHandover::RETIRE) { "Retire it" }
        end
      end
    end
  end

  def unit_detail(unit)
    held = unit[:held].map { "#{it[:label]} (#{it[:people]})" }
    [ count(unit[:members], "member"), (held.any? ? "the HRIS says #{held.join(', ')}" : nil) ].compact.join(" · ")
  end

  def call_for(unit)
    return @calls[unit[:unit_id]] if @compared

    unit[:suggestion] && "match:#{unit[:suggestion][:key]}"
  end

  def summary
    div(id: "org-graph-handover-summary-#{id}", class: "mt-4 space-y-1 text-sm") do
      p(class: "text-default") { "With these calls, handing #{name} over would:" }
      ul(class: "list-disc pl-5 text-muted") do
        li { "move #{count(@comparison[:differing], 'person', 'people')} to the unit the HRIS names" }
        li { "end #{count(@comparison[:blank], 'membership')} the HRIS leaves blank" }
        li { "keep #{count(@comparison[:hand_added], 'membership')} added by hand, which the HRIS doesn't read" }
        li { "add #{count(@comparison[:joining], 'person', 'people')} the HRIS places at this level" }
      end
      decisions_left
    end
  end

  def decisions_left
    if @comparison[:unresolved].any?
      p(class: "text-default") { "Still to decide: #{@comparison[:unresolved].join(', ')}." }
    end
    @comparison[:blocked].each do |unit|
      p(class: "text-default") { "#{unit[:name]} can't retire yet: #{unit[:reason]}." }
    end
  end

  def ready? = @compared && @comparison[:unresolved].empty? && @comparison[:blocked].empty?

  def brake = @comparison[:brake]

  def switch
    settings_form(tenant_org_graph_settings_level_handover_path(id), method: :patch, class: "mt-4 space-y-3",
                                                                    data: { turbo_frame: "_top" }) do
      input(type: "hidden", name: "field_id", value: @chosen)
      input(type: "hidden", name: "fingerprint", value: @comparison[:fingerprint])
      @calls.each { |unit_id, call| input(type: "hidden", name: "calls[#{unit_id}]", value: call) }
      p(class: "text-sm text-default") do
        "It ends #{count(brake[:memberships_ended], 'membership')} and retires #{count(brake[:units_retired], 'unit')}."
      end
      brake_confirmation if brake[:over]
      render Components::Kit::Button.new(variant: :solid, tone: :brand, type: :submit, id: "org-graph-hand-over-#{id}") do
        "Hand #{name} over to #{provider_label}"
      end
    end
    fingerprint(@comparison[:fingerprint])
  end

  def brake_confirmation
    p(class: "text-sm text-default") { "That is more than a sync may end on its own. Type both counts to go ahead." }
    div(class: "flex flex-wrap gap-3") do
      confirm_input("confirm_memberships_ended", "Memberships it ends")
      confirm_input("confirm_units_retired", "Units it retires")
    end
  end

  def confirm_input(param, text)
    input_id = "org-graph-handover-#{param.dasherize}-#{id}"
    div(class: "flex flex-col gap-1") do
      label(for: input_id, class: "text-sm font-medium text-default") { text }
      input(id: input_id, type: "number", name: param, min: 0, required: true, class: "#{Components::Kit::Field::INPUT} w-32")
    end
  end

  def fingerprint(value)
    p(class: "mt-2 text-xs text-muted") { "Comparison #{value}" }
  end

  def count(number, one, many = "#{one}s") = "#{number} #{number == 1 ? one : many}"
end
