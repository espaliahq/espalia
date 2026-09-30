# frozen_string_literal: true

require "test_helper"

# Declaring or closing an exploration tells the other party (ADR-22), never
# the person who did it: the assessee's act goes to the manager side, the
# manager side's to the assessee.
class PersonDevelopment::AsyncHandlers::ExplorationNotifierTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @fx = build_role_lens_framework(tenant: @tenant)
    @manager_user = create(:user)
    @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Morgan Manager")
    create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)
    @delegate_user = create(:user)
    @delegate = create(:person, tenant: @tenant, email: @delegate_user.email, name: "Dee Delegate")
    create(:tenant_user, tenant: @tenant, user: @delegate_user, person: @delegate)
    @user = create(:user)
    @person = create(:person, tenant: @tenant, email: @user.email, name: "Alex Assessee", manager: @manager)
    create(:tenant_user, tenant: @tenant, user: @user, person: @person)
    @assignment, @cycle_id = enrol_in_role_lens_framework(@person, @fx, tenant: @tenant)
    create(:manager_assessment_delegation, tenant: @tenant, person_id: @person.id,
           framework_id: @fx.framework_id, delegate_person_id: @delegate.id)
    @handler = PersonDevelopment::CommandHandler.new
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def start(by:, note: nil)
    id = SecureRandom.uuid_v7
    @handler.start_exploration(@person.id, @fx.framework_id, id, target_role_id: @fx.pm.role_id,
                               target_level_id: @fx.pm_levels.fetch(3).level_id, target_level_ordinal: 3,
                               started_by_id: by.id, note: note)
    id
  end

  should "tell the manager side when the assessee declares it, with the note and a link into the lens" do
    perform_enqueued_jobs { start(by: @person, note: "Curious about discovery") }

    notification = @manager_user.notifications.reload.sole
    assert_equal "Alex Assessee started exploring Product Manager · PM3", notification.inbox_title
    assert_equal "“Curious about discovery”", notification.inbox_body
    assert_equal "/assessments/#{@assignment.id}?as_level=3&as_role=#{@fx.pm.role_id}", notification.inbox_url
    assert_equal 1, @delegate_user.notifications.reload.size
    assert_empty @user.notifications.reload, "never a self-ping"
  end

  should "tell the assessee when the manager shares it" do
    perform_enqueued_jobs { start(by: @manager) }

    notification = @user.notifications.reload.sole
    assert_equal "Morgan Manager shared an exploration of Product Manager · PM3 with you", notification.inbox_title
    assert_nil notification.inbox_body
    assert_empty @manager_user.notifications.reload
  end

  should "tell the other party when it closes, with the outcome" do
    id = start(by: @person)
    perform_enqueued_jobs do
      @handler.close_exploration(@person.id, @fx.framework_id, id, closed_by_id: @manager.id, outcome: "not_now",
                                 note: "After the launch")
    end

    notification = @user.notifications.reload.sole
    assert_equal "Morgan Manager closed the exploration of Product Manager · PM3: not now", notification.inbox_title
    assert_equal "“After the launch”", notification.inbox_body
  end
end
