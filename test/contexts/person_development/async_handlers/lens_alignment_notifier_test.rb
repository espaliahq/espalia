# frozen_string_literal: true

require "test_helper"

# Starting alignment against another role tells the assessee (ADR-22) — the
# conversation lives under a lens they may never open. The home role's start
# sends nothing.
class PersonDevelopment::AsyncHandlers::LensAlignmentNotifierTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @fx = build_role_lens_framework(tenant: @tenant)
    @manager = create(:person, tenant: @tenant, name: "Morgan Manager")
    @user = create(:user)
    @person = create(:person, tenant: @tenant, email: @user.email, name: "Alex Assessee", manager: @manager)
    create(:tenant_user, tenant: @tenant, user: @user, person: @person)
    @assignment, @cycle_id = enrol_in_role_lens_framework(@person, @fx, tenant: @tenant)
    @handler = PersonDevelopment::CommandHandler.new
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def start(role)
    @handler.start_alignment(@person.id, @fx.framework_id, @cycle_id, started_by_id: @manager.id,
                             role_id: role.role_id, level_ordinal: 2)
  end

  should "tell the assessee, naming the role and linking into its lens" do
    perform_enqueued_jobs { start(@fx.pm) }

    notification = @user.notifications.reload.sole
    assert_equal "Morgan Manager started alignment against Product Manager · PM2", notification.inbox_title
    assert_equal "Their ratings on the PM2 capabilities are now shared with you.", notification.inbox_body
    assert_equal "/assessments/#{@assignment.id}?as_level=2&as_role=#{@fx.pm.role_id}", notification.inbox_url
  end

  should "stay silent for the home role" do
    @handler.rate_self(@person.id, @fx.framework_id, @fx.e_only.stable_id,
                       level_ordinal: 2, frequency: "some", cycle_id: @cycle_id)
    perform_enqueued_jobs { start(@fx.engineer) }

    assert_empty @user.notifications.reload
  end
end
