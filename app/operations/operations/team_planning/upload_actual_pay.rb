# frozen_string_literal: true

# Holds actual pay for many people in a scenario from one CSV file
# ([#323](https://github.com/espaliahq/espalia/issues/323)). Called without a
# signature it previews: it reads and matches the file and signs exactly what
# it read and whom each row named. Called again with that signature and the same file, basis and
# scenario, it writes one `data:pay` change per row, all or none.
#
# Web only for now. The csv is pay, and an MCP client would hand it to a model
# in clear, so a tool waits for its own design. The shape (csv text, basis,
# scenario and an optional signature) is kept so one can follow.
#
# Nothing is stored between the two calls. The file comes back with the
# confirm, so the bytes never rest on the server.
class Operations::TeamPlanning::UploadActualPay < Operations::Base
  include Operations::TeamPlanning::PlanRead

  NOTE = "From an upload"
  CHANGED = "The file, basis, scenario or the people it names changed since the preview"

  description "Preview, then hold, actual pay for many people in a scenario of a Team Planning plan from a CSV file " \
              "with columns person, amount, currency and period. Without signature it previews and returns one; " \
              "with it, the same file, basis and scenario are written, all rows or none. Refused unless the caller " \
              "is one of the plan's editors and holds the see-pay right."
  category :write
  approval :mcp_client
  mcp false

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }
  parameter :csv, String, required: true, allow_blank: true
  parameter :basis, String, required: true, allowed: ::TeamPlanning::Events::PlanDataSet::PAY_BASES, schema: { enum: ::TeamPlanning::Events::PlanDataSet::PAY_BASES }
  parameter :signature, String

  # @return [Hash] `{ plan_id, scenario_id, basis, problem, line, rows_read, failures, matched_ids, missing_ids,
  #   newly_priced_ids, replaced_ids, unchanged_ids, names, signature }` for a preview, and `written` once confirmed
  def perform
    plan = plan!(:update?)
    raise Operations::Base::ParameterError, "No such plan" unless PlanPolicy.new(context, plan).see_pay?

    scenario_id = scenario_id!(:scenario_id)
    inputs = { plan_id: plan.id, scenario_id:, basis: params[:basis], csv: params[:csv] }
    upload = ::TeamPlanning::PayUpload.new(csv: params[:csv], basis: params[:basis])
    params[:signature].nil? ? preview(plan, scenario_id, upload, inputs) : confirm(plan, scenario_id, upload, inputs)
  end

  private

  def preview(plan, scenario_id, upload, inputs)
    map = refusing_bad_plans { ::TeamPlanning::Resolution.new(context:, plan:, scenario_id:).call }
    report = upload.against(map)
    payload(plan, scenario_id, report, held(map), names: map.names)
      .merge(signature: (::TeamPlanning::PayUpload.signature(**inputs, matches: report.matches) if report.ok?))
  end

  def confirm(plan, scenario_id, upload, inputs)
    report = held_now = signed = nil
    written = 0
    refusing_bad_plans do
      handler.set_changes(plan.id) do |aggregate|
        plan.reload
        map = ::TeamPlanning::Resolution.new(context:, plan:, scenario_id:).structure(aggregate)
        report = upload.against(map)
        held_now = held(map)
        next [] unless report.ok?

        signed = ::TeamPlanning::PayUpload.signed?(params[:signature], **inputs, matches: report.matches)
        next [] unless signed

        changes = report.matches.reject { held_now[it.person_id] == it.pay }.map do |match|
          { kind: ::TeamPlanning::Events::PlanDataSet, scenario_id:, subject_id: match.person_id,
            end_state: { field: "pay", value: match.pay }, note: NOTE }
        end
        written = changes.size
        changes
      end
    end
    raise Operations::Base::ParameterError, "The scenario changed since the preview, so check the file again" unless report.ok?
    raise Operations::Base::ParameterError, CHANGED unless signed

    payload(plan, scenario_id, report, held_now, names: {}).merge(written:)
  end

  def payload(plan, scenario_id, report, held_now, names:)
    matched = report.matches.map(&:person_id)
    pay = report.matches.to_h { [ it.person_id, it.pay ] }
    { plan_id: plan.id, scenario_id:, basis: params[:basis], problem: report.problem, line: report.line,
      rows_read: report.rows_read, failures: report.failures.map(&:to_h), matched_ids: matched,
      missing_ids: report.missing_ids,
      newly_priced_ids: matched.select { held_now[it].nil? },
      replaced_ids: matched.select { held_now[it] && held_now[it] != pay[it] },
      unchanged_ids: matched.select { held_now[it] == pay[it] },
      names: names.slice(*matched, *report.missing_ids) }
  end

  # @return [Hash{String => Hash}] each person's pay as the scenario holds it now, readable ones only
  def held(map)
    map.people.each_with_object({}) do |member, held|
      value = member.plan_data&.dig(:pay)
      held[member.id] = value.reveal if value && !value.removed?
    end
  end
end
