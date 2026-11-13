# frozen_string_literal: true

require "test_helper"

class Operations::OrgGraph::AsOfTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM

  setup do
    @tenant = create(:tenant)
    handler = OrgGraph::CommandHandler.new(actor: SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    @departments, @squads = SecureRandom.uuid_v7, SecureRandom.uuid_v7
    @engineering, @payments, @platform, @sales = Array.new(4) { SecureRandom.uuid_v7 }

    travel_to Time.zone.parse("2026-02-01 09:00")
    as_tenant do
      @ada, @grace = create_list(:person, 2, tenant: @tenant)
      structure.define_taxonomy([ { level_id: @departments, name: "Department" }, { level_id: @squads, name: "Squad" } ],
        effective_on: "2026-01-01")
      structure.create_unit(@engineering, "Engineering", level_id: @departments, effective_on: "2026-01-01")
      structure.create_unit(@sales, "Sales", level_id: @departments, effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: @squads, parent_id: @engineering, effective_on: "2026-01-01")
      structure.create_unit(@platform, "Platform", level_id: @squads, parent_id: @engineering, effective_on: "2026-01-01")
      [ [ @ada, @payments ], [ @grace, @sales ] ].each do |person, unit|
        handler.record_person(person.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed", title: "Engineer")
        handler.set_membership(person.id, unit, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0)
      end

      user = create(:user)
      @context = AuthorizationContext.new(user:, tenant_user: create(:tenant_user, user:, tenant: @tenant), person: nil)
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def call(**params) = as_tenant { Operations::OrgGraph::AsOf.call(context: @context, params:) }

  should "summarise the units with their member counts by default" do
    result = call(date: "2026-02-15")

    assert_equal [ "2026-02-15", nil, 2 ], result.values_at(:date, :known_on, :people_count)
    assert_equal({ "Engineering" => 0, "Payments" => 1, "Platform" => 0, "Sales" => 1 },
                 result[:units].to_h { [ it[:name], it[:member_count] ] })
    assert_equal @engineering, result[:units].find { it[:id] == @payments }[:parent_id]
    assert_not result.key?(:people)
  end

  should "add people and memberships in full mode, by id" do
    result = call(date: "2026-02-15", mode: "full")

    assert_equal [ @ada.id, @grace.id ].sort, result[:people].map { it[:id] }
    assert_equal "Engineer", result[:people].first[:title]
    assert_equal [ [ @ada.id, @payments ] ], result[:memberships].select { it[:unit_id] == @payments }.map { it.values_at(:person_id, :unit_id) }
    assert_not_includes result.to_s, @ada.name
  end

  should "narrow to a unit and the units under it" do
    result = call(date: "2026-02-15", mode: "full", unit_id: @engineering)

    assert_equal %w[Engineering Payments Platform], result[:units].map { it[:name] }
    assert_equal [ @ada.id ], result[:people].map { it[:id] }
    assert_equal 1, result[:people_count]
  end

  should "refuse a unit not live on the date, and a malformed date" do
    assert_raises(Operations::Base::ParameterError) { call(date: "2025-12-31", unit_id: @engineering) }
    assert_raises(Operations::Base::ParameterError) { call(date: "2026-02-30") }
    assert_raises(Operations::Base::ParameterError) { call(date: "15/02/2026") }
  end

  should "pass known_on through" do
    assert_equal "2026-02-01", call(date: "2026-02-15", known_on: "2026-02-01")[:known_on]
  end

  should "refuse someone outside the tenant" do
    @context = AuthorizationContext.new(user: create(:user), tenant_user: nil, person: nil)

    assert_raises(Pundit::NotAuthorizedError) { call(date: "2026-02-15") }
  end
end
