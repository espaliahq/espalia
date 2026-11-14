# frozen_string_literal: true

require "test_helper"

# Saying a fact is still true (#142), so MCP clears a stale flag through the
# same command as the drawers.
class Operations::OrgGraph::ConfirmFactTest < ActiveSupport::TestCase
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @member = create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant))
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                              .change_title(@org[:ada].id, "Engineering Manager", **PROVENANCE)
    end
  end

  def call(as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person)
      Operations::OrgGraph::ConfirmFact.call(context: context, params: params)
    end
  end

  def age(person, fact, unit_id = nil)
    ActsAsTenant.with_tenant(@tenant) { OrgFactAge.find_by(person_id: @org[person].id, fact:, unit_id:) }
  end

  should "confirm a membership today, with the caller as the one who checked" do
    travel 100.days
    result = call(person_id: @org[:brook].id, fact: "membership", unit_id: @org[:platform])

    assert_equal({ person_id: @org[:brook].id, fact: "membership", unit_id: @org[:platform], confirmed_on: Date.current.iso8601 },
                 result)
    confirmed = age(:brook, "membership", @org[:platform])
    assert_equal [ Time.current.to_i, @admin.person.id ], [ confirmed.checked_at.to_i, confirmed.checked_by_id ]
  end

  should "confirm one of the person's own facts" do
    travel 100.days
    call(person_id: @org[:ada].id, fact: "title")

    assert_equal Time.current.to_i, age(:ada, "title").checked_at.to_i
  end

  should "refuse a fact it doesn't know, and a unit on the wrong kind of fact" do
    assert_raises(Operations::Base::ParameterError) { call(person_id: @org[:ada].id, fact: "salary") }
    assert_raises(Operations::Base::ParameterError) { call(person_id: @org[:ada].id, fact: "membership") }
    assert_raises(Operations::Base::ParameterError) do
      call(person_id: @org[:ada].id, fact: "title", unit_id: @org[:platform])
    end
  end

  should "leave a membership an HRIS supplies to the HRIS" do
    ActsAsTenant.with_tenant(@tenant) do
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                              .set_membership(@org[:ada].id, @org[:engineering], provider: "hibob", effective_on: "2026-01-05")
    end

    error = assert_raises(RuntimeError) do
      call(person_id: @org[:ada].id, fact: "membership", unit_id: @org[:engineering])
    end
    assert_match(/Only a fact Espalia holds/, error.message)
  end

  should "refuse someone with no rights over the membership" do
    assert_raises(OrgGraph::Authorization::Refused) do
      call(as: @member, person_id: @org[:brook].id, fact: "membership", unit_id: @org[:platform])
    end
  end
end
