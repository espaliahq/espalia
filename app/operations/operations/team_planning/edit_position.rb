# frozen_string_literal: true

# Changes some fields of a position and keeps the rest
# [#461](https://github.com/espaliahq/espalia/issues/461). It reads the
# position from the resolved map and writes it back through {SetPosition}
# with the given fields merged in. The read and the write share the plan's
# lock, so two editors changing different fields both keep their change.
#
# Its fields are SetPosition's, so a field SetPosition gains is carried here
# too. Base validation turns an omitted key into nil, so the keys the caller
# sent are kept apart: an omitted field is kept, a null one is cleared.
class Operations::TeamPlanning::EditPosition < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  OWN = %i[plan_id scenario_id position_id].freeze

  # A null is how a caller clears a field it sends, so the schema admits one.
  def self.nullable(field)
    type = Mcp::OperationToTool::TYPE_MAPPING.fetch(field.type, "string")
    schema = (field.schema || {}).merge(type: [ type, "null" ])
    enum = schema[:enum] || field.allowed
    enum ? schema.merge(enum: [ *enum, nil ]) : schema
  end
  FIELDS = (Operations::TeamPlanning::SetPosition.parameters.keys - OWN - [ :note ]).freeze

  description "Change some fields of a position in a scenario of a Team Planning plan and keep the rest. Give " \
              "position_id and only the fields to change: an omitted field keeps its value, and null clears an optional one, such as " \
              "cost_centre or target_start. Written as one PositionSet, with the same checks as " \
              "team_planning_set_position. Refused unless the caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }
  parameter :position_id, String, required: true
  Operations::TeamPlanning::SetPosition.parameters.except(*OWN).each_value do |field|
    parameter field.name, field.type, allowed: field.allowed, schema: field.required ? field.schema : nullable(field),
                                      allow_blank: field.allow_blank
  end
  prose_fields :note

  # @param context [AuthorizationContext]
  # @param params [Hash]
  def initialize(context:, params: {})
    raw = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
    @sent = raw.keys.map(&:to_sym)
    super
  end

  # @return [Hash] what {SetPosition} returns
  def perform
    editor!
    ::TeamPlanning::Repository.new.holding_plan(plan_id!) do
      Operations::TeamPlanning::SetPosition.call(
        context:, params: { plan_id: plan_id!, scenario_id: scenario_id!(:scenario_id), position_id: uuid!(:position_id),
                            **current_fields, **params.slice(*(FIELDS & @sent)), note: params[:note] }
      )
    end
  end

  private

  def editor!
    plan = Operations::TeamPlanning::Plan.call(context:, params: { plan_id: plan_id! })
    raise Operations::Base::ParameterError, "No such plan" unless plan[:role] == "editor"
  end

  def current_fields
    map = Operations::TeamPlanning::ScenarioMap.call(context:, params: { plan_id: plan_id!, scenario_id: scenario_id!(:scenario_id) })
    position = map[:positions].find { it[:position_id] == uuid!(:position_id) } or
      raise Operations::Base::ParameterError, "This scenario has no such position"

    position.slice(*FIELDS).merge(fte: position[:fte].to_f)
  end
end
