# frozen_string_literal: true

# What changed in the tenant's pay bands, exchange rates, budget lines or rule
# defaults, newest first: the read behind each screen's history. Admins only,
# as the tables are, and never shown inside a plan.
#
# A change shows its row before and after with the fields the table's own read
# tool lists, so a figure here reads as it does there.
class Operations::Tenants::PlanningInputsHistory < Operations::Base
  INPUTS = TenantPlanningInputs::History::INPUTS.keys.map(&:to_s).freeze
  POLICIES = { "pay_bands" => :manage_pay_bands?, "exchange_rates" => :manage_pay_bands?,
               "budget_lines" => :manage_budget_lines?, "planning_rules" => :manage_planning_rules? }.freeze

  description "Read what changed in the active tenant's planning inputs, newest first, " \
              "#{TenantPlanningInputs::History::PAGE_SIZE} changes a page. inputs picks which: pay_bands, " \
              "exchange_rates (the rates and the reference currency), budget_lines or planning_rules (the tenant's " \
              "rule defaults). Each change gives its table, what happened (added, changed, removed or, for pay " \
              "bands, reordered), the row's id, when, who made it (a person's name, \"Former member\" once " \
              "forgotten, or null when no one is recorded), and the row before and after; null where there was " \
              "no row. A row carries the fields tenants_pay_bands, tenants_exchange_rates, tenants_budget_lines " \
              "and tenants_planning_rules give, with figures written the same way, less the row's id (it is the " \
              "change's id), its position and who last changed it. Role and level names are as recorded then, " \
              "not renamed since. A reorder has no row: tenants_pay_bands gives the order now. " \
              "already_held marks a row recorded as the table held it when this history began, or as an " \
              "earlier release changed it; its time and person are then the row's last change before that. " \
              "Refused unless the caller is a tenant admin."
  category :read
  approval :none

  parameter :inputs, String, required: true, schema: { enum: INPUTS }
  parameter :page, Integer, required: false

  # @raise [Pundit::NotAuthorizedError] unless the caller is a tenant admin
  def policy_check
    authorize ActsAsTenant.current_tenant, POLICIES.fetch(params[:inputs].to_s, :manage_pay_bands?), policy_class: TenantPolicy
  end

  # @return [Hash] `:inputs`, `:page`, `:next_page` and `:changes`, newest first
  # @raise [Operations::Base::ParameterError] for inputs it doesn't know
  def perform
    raise ParameterError, "inputs must be one of #{INPUTS.join(', ')}" unless INPUTS.include?(params[:inputs].to_s)

    history = TenantPlanningInputs::History.new(inputs: params[:inputs].to_sym, page: params[:page] || 1)
    changes = history.changes
    names = person_names(changes)
    { inputs: params[:inputs].to_s, page: history.page, next_page: history.next_page?,
      changes: changes.map { change_payload(it, names) } }
  end

  private

  def person_names(changes)
    ids = changes.filter_map(&:by_person_id).uniq
    Person.remembered.where(id: ids).pluck(:id, :name).to_h.then { |found| ids.index_with { found.fetch(it, Person::FORMER_MEMBER) } }
  end

  def change_payload(change, names)
    {
      table: change.table.to_s.singularize,
      change: change.change.to_s,
      id: change.row_id,
      at: change.at.iso8601,
      by: change.by_person_id && names.fetch(change.by_person_id),
      already_held: change.already_held,
      before: change.before && row_payload(change.table, change.before),
      after: change.after && row_payload(change.table, change.after)
    }
  end

  def row_payload(table, row)
    record = TenantPlanningInputs::Rows.model(table).new(row)
    case table
    when :pay_bands then band_fields(record)
    when :exchange_rates
      { from_currency: record.from_currency, to_currency: record.to_currency, rate: record.figure,
        applies_from: record.applies_from.iso8601 }
    when :reference_currencies then { currency: record.currency }
    when :budget_lines then line_fields(record)
    when :planning_rule_defaults then { rule: record.rule, value: record.value }
    end
  end

  def band_fields(band)
    {
      role_family_id: band.role_family_id, role_id: band.role_id, level_ordinal: band.level_ordinal,
      level_id: band.level_id, role: band.role_name, level_name: band.level_name, location: band.location.presence,
      currency: band.currency, period: band.period, **PayBand::FIGURES.to_h { [ it, band.figure(it) ] }
    }
  end

  def line_fields(line)
    {
      starts_on: line.starts_on.iso8601, ends_on: line.ends_on.iso8601, origin: line.origin,
      approved_on: line.approved_on&.iso8601, amount: line.figure(:amount), currency: line.currency,
      period: line.period, head_count: line.figure(:head_count), role_id: line.role_id, level_id: line.level_id,
      role: line.role_name, level_name: line.level_name, location: line.location.presence,
      cost_centre: line.cost_centre.presence
    }
  end
end
