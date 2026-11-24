# frozen_string_literal: true

require "test_helper"

class OrgGraph::ForgettingLastAdminTest < ActiveSupport::TestCase
  PROVENANCE = { provider: "hibob", effective_on: "2026-11-01" }.freeze
  TODAY = Date.new(2033, 11, 13)

  FakeHris = Struct.new(:active_external_ids)

  setup do
    @tenant = create(:tenant)
    @tenant.org_graph_config.retention_years = 7
    @tenant.save!
    ActsAsTenant.current_tenant = @tenant
    OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      .claim_facts(OrgGraph::StructureAggregate::FACTS, "hibob", effective_on: "2026-01-01")
    @leaver = leaver("hb-1", left_on: "2026-10-01")
    @account = create(:tenant_user, tenant: @tenant, person: @leaver, role: :admin, slack_user_id: "U-EXAMPLE")
    @requester = AuthorizationContext.new(user: @account.user, tenant_user: @account, person: @leaver)
    TenantSettings::CommandHandler.new(Tenant.find(@tenant.id)).enable_scheduled_forgetting { 1 }
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  def leaver(external_id, left_on:)
    person = create(:person, tenant: @tenant, hris_source: "hibob", external_id:, name: "Pat Example #{external_id}")
    handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    handler.sync_person(person.id, **PROVENANCE, employment_status: "employed")
    handler.sync_person(person.id, **PROVENANCE, employment_status: "left", left_on:)
    person
  end

  def forgetting = OrgGraph::Forgetting.new(@tenant, hris: FakeHris.new([]))

  def last_event(person)
    Rails.configuration.event_store.read.stream(EventStreamNaming.person_stream(person.id)).last
  end

  def assert_whole(person, account, notification:, plan_key:)
    person.reload
    assert_not person.forgotten?
    assert_equal [ "Pat Example hb-1", "hb-1" ], [ person.name, person.external_id ]
    assert person.email.present?
    assert_equal({ feedback_author_id: person.id, feedback_author_name: "Pat Example hb-1",
                   context: "Pat Example hb-1's feedback · Delivery · L2" },
      notification.reload.params.slice(:feedback_author_id, :feedback_author_name, :context))
    assert PlanKeyStore.new.key_of(plan_key)
    account = TenantUser.unscoped.find(account.id)
    assert_equal [ person.id, "U-EXAMPLE", nil ], [ account.person_id, account.slack_user_id, account.forgotten_at ]
    assert account.user_id
    assert_not_instance_of OrgGraph::Events::PersonForgotten, last_event(person)
  end

  context "a person holding the only admin account" do
    setup do
      @notification = Noticed::Event.create!(
        type: "FeedbackReceivedNotifier",
        params: { tenant_id: @tenant.id, feedback_author_id: @leaver.id, feedback_author_name: @leaver.name,
                  context: "#{@leaver.name}'s feedback · Delivery · L2" }
      )
      @plan_key = PlanKeyStore.person_identifier(@tenant.id, SecureRandom.uuid_v7, @leaver.id)
      PlanKeyStore.new.create(@plan_key)
    end

    should "be held back by a scheduled run and left whole" do
      report = forgetting.forget_due(on: TODAY, scheduled: true)

      assert_equal [ 0, [], 1 ], [ report.count, report.person_ids, report.held_back ]
      assert_whole(@leaver, @account, notification: @notification, plan_key: @plan_key)
    end

    should "roll back a whole erase when the count under the grants lock refuses" do
      run = forgetting
      report = run.stub(:holds_every_admin?, false) { run.forget_due(on: TODAY, scheduled: true) }

      assert_equal [ 0, 1 ], [ report.count, report.held_back ]
      assert_whole(@leaver, @account, notification: @notification, plan_key: @plan_key)
    end

    should "refuse a manual forget and leave them whole" do
      error = assert_raises(OrgGraph::Forgetting::LastAdmin) do
        forgetting.forget(@leaver.id, requested_by: @requester, on: TODAY)
      end

      assert_kind_of OrgGraph::Forgetting::Refused, error
      assert_match "only admin account", error.message
      assert_whole(@leaver, @account, notification: @notification, plan_key: @plan_key)
    end

    should "refuse forgetting them before they are due and leave them whole" do
      recent = leaver("hb-2", left_on: "2032-01-01")
      @account.update!(person: recent)
      @notification.update!(params: @notification.params.merge(feedback_author_id: recent.id))
      plan_key = PlanKeyStore.person_identifier(@tenant.id, SecureRandom.uuid_v7, recent.id)
      PlanKeyStore.new.create(plan_key)

      assert_raises(OrgGraph::Forgetting::LastAdmin) do
        forgetting.forget(recent.id, requested_by: @requester, before_due: true, on: TODAY)
      end

      assert_not recent.reload.forgotten?
      assert PlanKeyStore.new.key_of(plan_key)
      assert_equal [ recent.id, "U-EXAMPLE" ], TenantUser.unscoped.find(@account.id).values_at(:person_id, :slack_user_id)
      assert_not_instance_of OrgGraph::Events::PersonForgotten, last_event(recent)
    end

    should "be forgotten once someone else is an admin" do
      create(:tenant_user, tenant: @tenant, role: :admin)

      report = forgetting.forget_due(on: TODAY, scheduled: true)

      assert_equal [ [ @leaver.id ], 0 ], [ report.person_ids, report.held_back ]
      assert @leaver.reload.forgotten?
    end
  end

  should "hold back the second of two due admins in the dry run and the scheduled run alike" do
    second = leaver("hb-3", left_on: "2026-09-01")
    create(:tenant_user, tenant: @tenant, person: second, role: :admin)

    preview = forgetting.dry_run(on: TODAY)
    report = forgetting.forget_due(on: TODAY, scheduled: true)

    assert_equal [ 1, 1 ], [ preview.count, preview.held_back ]
    assert_equal [ preview.count, preview.held_back ], [ report.count, report.held_back ]
    assert_equal preview.person_ids, report.person_ids
    assert_equal 1, [ @leaver, second ].count { it.reload.forgotten? }
  end

  should "forget everyone due when the tenant has no admin at all" do
    @account.update!(role: :member)

    assert_equal [ 1, 0 ], forgetting.dry_run(on: TODAY).then { [ it.count, it.held_back ] }
    assert_equal [ @leaver.id ], forgetting.forget_due(on: TODAY).person_ids
  end
end
