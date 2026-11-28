# frozen_string_literal: true

require "test_helper"

class Operations::OrgGraph::ActivityTest < ActiveSupport::TestCase
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: @org[:ada])
      @member = create(:tenant_user, tenant: @tenant, role: :member)
    end
  end

  def context_for(tenant_user)
    AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: tenant_user.person)
  end

  def call(params, tenant_user: @admin)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::OrgGraph::Activity.call(context: context_for(tenant_user), params:)
    end
  end

  def move_cyril_to_platform
    ActsAsTenant.with_tenant(@tenant) do
      OrgGraph::CommandHandler.new(actor: context_for(@admin), cause_id: "request-1")
                              .move_membership(@org[:cyril].id, @org[:checkout], @org[:platform], effective_on: "2026-02-01")
    end
  end

  should "read the unit's groups newest first, each saying who, what, when and whether it can change back" do
    move_cyril_to_platform

    groups = call({ unit_id: @org[:platform] })[:groups]

    latest = groups.first
    assert_equal [ "Moved Cyril Moss in from Checkout", "Ada Quill", "2026-02-01", true ],
      latest.values_at(:summary, :by, :effective_on, :can_change_back)
    assert_equal [ "Moved Cyril Moss in from Checkout" ], latest[:parts].map { it[:description] }
    assert_equal [ "Added Brook Tamsin", "Added Ada Quill" ], groups[1..2].map { it[:parts].first[:description] }
    assert_equal "Espalia", groups[1][:by], "the system's own change reads as its provider"
  end

  should "give the reason a change can't be changed back" do
    created = call({ unit_id: @org[:platform] })[:groups].last

    assert_equal "Created the unit", created[:parts].first[:description]
    assert_not created[:can_change_back]
    assert_equal "Unit Created can't be changed back", created[:cannot_change_back_because]
  end

  should "page the feed and say when another page follows" do
    ActsAsTenant.with_tenant(@tenant) do
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      26.times { |i| structure.rename_unit(@org[:platform], "Platform #{i}", effective_on: "2026-02-01") }
    end

    causes = ActsAsTenant.with_tenant(@tenant) { OrgUnitActivity.for_unit(@org[:platform]).distinct.count(:cause_id) }
    first = call({ unit_id: @org[:platform] })
    second = call({ unit_id: @org[:platform], page: 2 })

    assert_equal [ 25, true ], [ first[:groups].size, first[:next_page] ]
    assert_equal [ causes - 25, false ], [ second[:groups].size, second[:next_page] ]
    assert_empty first[:groups].map { it[:cause_id] } & second[:groups].map { it[:cause_id] }
  end

  should "refuse a unit the Org Graph doesn't hold" do
    assert_raises(Operations::Base::ParameterError) { call({ unit_id: SecureRandom.uuid_v7 }) }
  end

  should "refuse a member while the Org Graph is unfinished" do
    assert_raises(Pundit::NotAuthorizedError) { call({ unit_id: @org[:platform] }, tenant_user: @member) }
  end

  context "with no unit" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @brook = create(:tenant_user, tenant: @tenant, person: @org[:brook])
        @editor = create(:tenant_user, tenant: @tenant, person: @org[:cyril], org_graph_editor: true)
        grants = AccountGrants::CommandHandler.new
        grants.add(:org_graph_editor, @editor, already_held: true, effective_on: Date.new(2026, 11, 30))
        grants.add(:org_graph_editor, @brook, added_by_id: @org[:ada].id)
        grants.remove(:org_graph_editor, tenant_user_id: @brook.id, person_id: @org[:brook].id, removed_by_id: @org[:ada].id)
      end
    end

    should "read the organisation's own activity, which can't be changed back here" do
      result = call({})

      assert_nil result[:unit_id]
      assert_equal [ "Brook Tamsin is no longer an Org Graph editor", "Made Brook Tamsin an Org Graph editor",
                     "Cyril Moss was already an Org Graph editor on 30 Nov 2026" ], result[:groups].map { it[:summary] }
      assert_equal [ "Ada Quill", "Ada Quill", "Espalia" ], result[:groups].map { it[:by] }
      assert result[:groups].none? { it[:can_change_back] }
      assert_equal [ OrgGraph::ChangeBackHandler::GRANT ], result[:groups].map { it[:cannot_change_back_because] }.uniq
    end

    should "refuse a plain member, as for a unit" do
      assert_raises(Pundit::NotAuthorizedError) { call({}, tenant_user: @member) }
    end

    should "read for an Org Graph editor who isn't an admin" do
      assert_equal 3, call({}, tenant_user: @editor)[:groups].size
    end

    should "refuse to change a grant back" do
      entry = ActsAsTenant.with_tenant(@tenant) { OrgUnitActivity.for_organisation.first }

      error = assert_raises(RuntimeError) do
        ActsAsTenant.with_tenant(@tenant) { OrgGraph::ChangeBackHandler.new(actor: context_for(@admin)).change_back(entry) }
      end
      assert_equal OrgGraph::ChangeBackHandler::GRANT, error.message
    end
  end
end
