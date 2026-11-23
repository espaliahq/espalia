# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

class AccountGrants::Projections::AccountFlagsTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  PROJECTION = AccountGrants::Projections::AccountFlags

  setup do
    @tenant = create(:tenant)
    @handler = AccountGrants::CommandHandler.new
    as_tenant do
      @ada, @bo, @cy, @forgotten = Array.new(4) { create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant)) }
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def flags(account) = TenantUser.unscoped.find(account.id).slice(*PROJECTION::COLUMNS).values

  def remove(grant, account) = @handler.remove(grant, tenant_user_id: account.id, person_id: account.person_id)

  def forget(account)
    TenantUser.where(id: account.id).update_all(person_id: nil, user_id: nil, forgotten_at: Time.current)
  end

  should "set each flag as its grant is added and removed" do
    as_tenant do
      @handler.add(:org_graph_editor, @ada)
      @handler.add(:team_planner, @ada)
      assert_equal [ true, true ], flags(@ada)

      remove(:org_graph_editor, @ada)
      assert_equal [ false, true ], flags(@ada)
    end
    assert_equal [ false, false ], flags(@bo)
  end

  should "rebuild the same flags from the stream, and leave a forgotten account's as they were" do
    as_tenant do
      @handler.add(:org_graph_editor, @ada)
      @handler.add(:team_planner, @bo)
      @handler.add(:org_graph_editor, @cy)
      remove(:org_graph_editor, @cy)
      @handler.add(:org_graph_editor, @forgotten)
      forget(@forgotten)
    end
    before = snapshot_read_models(PROJECTION, @tenant)

    PROJECTION.reset!(tenant: @tenant)
    assert_equal [ false, false ], flags(@ada)
    Projections::Replayer.replay(projection_class: PROJECTION, tenant: @tenant)

    assert_equal before, snapshot_read_models(PROJECTION, @tenant)
    assert_equal [ [ true, false ], [ false, true ], [ false, false ] ], [ @ada, @bo, @cy ].map { flags(it) }
    assert_equal [ true, false ], flags(@forgotten)
  end

  should "write nothing for an account destroyed since its grant" do
    as_tenant do
      @handler.add(:team_planner, @ada)
      id, person_id = @ada.id, @ada.person_id
      @ada.destroy!

      @handler.remove(:team_planner, tenant_user_id: id, person_id:)
    end

    assert_equal [ false, false ], flags(@bo)
  end

  should "not reach another tenant's accounts on reset" do
    other = create(:tenant)
    outsider = ActsAsTenant.with_tenant(other) do
      create(:tenant_user, tenant: other, person: create(:person, tenant: other)).tap { @handler.add(:org_graph_editor, it) }
    end

    PROJECTION.reset!(tenant: @tenant)

    assert_equal [ true, false ], flags(outsider)
  end
end
