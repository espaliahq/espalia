# frozen_string_literal: true

require "test_helper"

class Operations::OrgGraph::HistoryFullModeTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  TOOLS = {
    "org_graph_as_of" => [ Operations::OrgGraph::AsOf, { date: "2026-02-15" } ],
    "org_graph_changes_between" => [ Operations::OrgGraph::ChangesBetween, { from: "2026-01-31", to: "2026-02-15" } ]
  }.freeze

  setup do
    @tenant = create(:tenant)
    handler = OrgGraph::CommandHandler.new(actor: SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    squads, @payments = SecureRandom.uuid_v7, SecureRandom.uuid_v7

    travel_to Time.zone.parse("2026-02-01 09:00")
    as_tenant do
      @member, @owner, @manager, @editor, @admin = create_list(:person, 5, tenant: @tenant)
      @ada = create(:person, tenant: @tenant, manager: @manager)
      structure.define_taxonomy([ { level_id: squads, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: squads, effective_on: "2026-01-01")
      handler.record_person(@owner.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed", title: "Lead")
      structure.add_unit_owner(@payments, @owner.id, effective_on: "2026-02-01")
      handler.record_person(@ada.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed",
                                     title: "Engineer", manager_id: @manager.id)
      handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0)
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def context_for(person, **grants)
    as_tenant do
      user = create(:user)
      AuthorizationContext.new(user:, tenant_user: create(:tenant_user, user:, tenant: @tenant, person:, **grants), person:)
    end
  end

  def readers
    { "a plain member" => [ context_for(@member), false ],
      "a unit's owner" => [ context_for(@owner), false ],
      "a manager" => [ context_for(@manager), false ],
      "an Org Graph editor" => [ context_for(@editor, org_graph_editor: true), true ],
      "an admin" => [ context_for(@admin, role: :admin), true ] }
  end

  def call(operation, context, **params) = as_tenant { operation.call(context:, params:) }

  should "open full mode to admins and Org Graph editors only, on both tools" do
    readers.each do |reader, (context, full)|
      TOOLS.each do |tool, (operation, params)|
        assert_not call(operation, context, **params).key?(:people), "#{tool}: #{reader}'s summary"
        if full
          assert call(operation, context, **params, mode: "full").key?(tool == "org_graph_as_of" ? :people : :changes), "#{tool}: #{reader}"
        else
          error = assert_raises(Pundit::NotAuthorizedError, "#{tool}: #{reader}") { call(operation, context, **params, mode: "full") }
          assert_equal "Full mode is open to tenant admins and Org Graph editors.", error.message
        end
      end
    end
  end

  should "give a member's summary no person id, on both tools" do
    person_ids = [ @member, @owner, @manager, @editor, @admin, @ada ].map(&:id)
    context = context_for(@member)

    TOOLS.each do |tool, (operation, params)|
      summary = call(operation, context, **params).to_json
      person_ids.each { assert_not_includes summary, it, tool }
    end
  end

  should "keep a unit's owners for full mode" do
    context = context_for(@admin, role: :admin)

    full = call(Operations::OrgGraph::AsOf, context, date: "2026-02-15", mode: "full")
    summary = call(Operations::OrgGraph::AsOf, context, date: "2026-02-15")

    assert_equal [ @owner.id ], full[:units].find { it[:id] == @payments }[:owner_ids]
    assert_not summary[:units].first.key?(:owner_ids)
  end
end
