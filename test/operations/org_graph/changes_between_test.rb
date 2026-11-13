# frozen_string_literal: true

require "test_helper"

class Operations::OrgGraph::ChangesBetweenTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM

  setup do
    @tenant = create(:tenant)
    @handler = OrgGraph::CommandHandler.new(actor: SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    @squads = SecureRandom.uuid_v7
    @payments, @platform = Array.new(2) { SecureRandom.uuid_v7 }

    travel_to Time.zone.parse("2026-02-01 09:00")
    as_tenant do
      @ada, @grace = create_list(:person, 2, tenant: @tenant)
      structure.define_taxonomy([ { level_id: @squads, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: @squads, effective_on: "2026-01-01")
      structure.create_unit(@platform, "Platform", level_id: @squads, effective_on: "2026-01-01")
      [ @ada, @grace ].each do |person|
        @handler.record_person(person.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed", title: "Engineer")
        @handler.set_membership(person.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0)
      end
      @handler.move_membership(@ada.id, @payments, @platform, effective_on: "2026-03-04")
      @handler.change_title(@ada.id, "Senior Engineer", **ESPALIA, effective_on: "2026-03-04")
      @handler.leave(@grace.id, **ESPALIA, effective_on: "2026-03-05")

      user = create(:user)
      @context = AuthorizationContext.new(user:, tenant_user: create(:tenant_user, user:, tenant: @tenant), person: nil)
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def call(**params) = as_tenant { Operations::OrgGraph::ChangesBetween.call(context: @context, params:) }

  should "count the changes per kind by default" do
    result = call(from: "2026-03-01", to: "2026-03-31")

    assert_equal [ "2026-03-01", "2026-03-31", "effective", nil ], result.values_at(:from, :to, :by, :known_on)
    assert_equal({ moved: 1, fact_changed: 1, left: 1, membership_ended: 1 }, result[:counts].reject { |_, count| count.zero? })
    assert_equal OrgGraph::ChangesBetween::KINDS, result[:counts].keys
    assert_equal({ "title" => 1 }, result[:fact_counts])
    assert_not result.key?(:changes)
  end

  should "list every change in full mode, by id" do
    result = call(from: "2026-03-01", to: "2026-03-31", mode: "full")

    moved = result[:changes].find { it[:kind] == "moved" }
    assert_equal [ @ada.id, @payments, @platform, "2026-03-04" ], moved.values_at(:person_id, :from_unit_id, :unit_id, :effective_on)
    assert_equal "2026-02-01T09:00:00Z", moved[:learned_at]
    assert_equal "2026-03-06", result[:changes].find { it[:kind] == "left" }[:effective_on]
    assert_not_includes result.to_s, @ada.name
  end

  should "read by learned date, a correction withdrawing the value it replaces" do
    travel_to Time.zone.parse("2026-04-10 09:00")
    as_tenant { @handler.change_title(@ada.id, "Staff Engineer", **ESPALIA, effective_on: "2026-03-04") }

    result = call(from: "2026-04-09", to: "2026-04-10", by: "learned", mode: "full")
    assert_equal [ [ "fact_changed", "2026-03-04", { "title" => "Staff Engineer" }, false ],
                   [ "fact_changed", "2026-03-04", { "title" => "Senior Engineer" }, true ] ],
                 result[:changes].map { it.values_at(:kind, :effective_on, :after, :withdrawn) }
  end

  should "refuse a malformed date, a window that ends before it starts, and known_on by learned date" do
    assert_raises(Operations::Base::ParameterError) { call(from: "2026-3-1", to: "2026-03-31") }
    assert_raises(Operations::Base::ParameterError) { call(from: "2026-03-31", to: "2026-03-01") }
    assert_raises(Operations::Base::ParameterError) { call(from: "2026-03-01", to: "2026-03-31", by: "learned", known_on: "2026-03-01") }
  end

  should "refuse someone outside the tenant" do
    @context = AuthorizationContext.new(user: create(:user), tenant_user: nil, person: nil)

    assert_raises(Pundit::NotAuthorizedError) { call(from: "2026-03-01", to: "2026-03-31") }
  end
end
