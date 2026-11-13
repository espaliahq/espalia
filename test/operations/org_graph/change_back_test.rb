# frozen_string_literal: true

require "test_helper"

class Operations::OrgGraph::ChangeBackTest < ActiveSupport::TestCase
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: @org[:ada])
      @member = create(:tenant_user, tenant: @tenant, role: :member)
      OrgGraph::CommandHandler.new(actor: context_for(@admin), cause_id: "request-1").tap do |handler|
        handler.move_membership(@org[:cyril].id, @org[:checkout], @org[:platform], effective_on: "2026-02-01")
        handler.end_membership(@org[:dot].id, @org[:payments], provider: "espalia", effective_on: "2026-02-01")
      end
    end
  end

  def context_for(tenant_user)
    AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: tenant_user.person)
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def run_op(op, params, tenant_user: @admin)
    as_tenant { op.call(context: context_for(tenant_user), params:) }
  end

  def units_of(person) = as_tenant { OrgMembership.where(person:).pluck(:unit_id) }

  should "change back one entry, leaving the rest of its group" do
    entry = as_tenant { OrgUnitActivity.for_unit(@org[:platform]).first }

    result = run_op(Operations::OrgGraph::ChangeBack, { entry_id: entry.id })

    assert_equal({ entry_id: entry.id, unit_id: @org[:platform] }, result)
    assert_equal [ @org[:checkout] ], units_of(@org[:cyril])
    assert_empty units_of(@org[:dot])
  end

  should "change a group back in every unit it touched" do
    result = run_op(Operations::OrgGraph::ChangeBackGroup, { cause_id: "request-1" })

    assert_equal [ @org[:checkout], @org[:payments], @org[:platform] ].sort, result[:unit_ids].sort
    assert_equal [ @org[:checkout] ], units_of(@org[:cyril])
    assert_equal [ @org[:payments] ], units_of(@org[:dot])
  end

  should "refuse, with the reason, a change that can't be changed back" do
    created = as_tenant { OrgUnitActivity.for_unit(@org[:platform]).last }

    error = assert_raises(Operations::Base::ParameterError) do
      run_op(Operations::OrgGraph::ChangeBack, { entry_id: created.id })
    end
    assert_equal "Unit Created can't be changed back", error.message
    assert_raises(Operations::Base::ParameterError) { run_op(Operations::OrgGraph::ChangeBack, { entry_id: SecureRandom.uuid_v7 }) }
  end

  should "refuse a member while the Org Graph is unfinished, and write nothing" do
    entry = as_tenant { OrgUnitActivity.for_unit(@org[:platform]).first }

    assert_raises(Pundit::NotAuthorizedError) do
      run_op(Operations::OrgGraph::ChangeBack, { entry_id: entry.id }, tenant_user: @member)
    end
    assert_raises(Pundit::NotAuthorizedError) do
      run_op(Operations::OrgGraph::ChangeBackGroup, { cause_id: "request-1" }, tenant_user: @member)
    end
    assert_equal [ @org[:platform] ], units_of(@org[:cyril])
  end
end
