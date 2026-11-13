# frozen_string_literal: true

require "test_helper"

class OrgGraph::ForgettingTest < ActiveSupport::TestCase
  PROVENANCE = { provider: "hibob", effective_on: "2026-11-01" }.freeze
  TODAY = Date.new(2033, 11, 13)

  # Stands in for the HRIS, holding whoever it still shows as employed.
  FakeHris = Struct.new(:active_external_ids)

  setup do
    @tenant = create(:tenant)
    @tenant.org_graph_config.retention_years = 7
    @tenant.save!
    ActsAsTenant.current_tenant = @tenant
    OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      .claim_facts(OrgGraph::StructureAggregate::FACTS, "hibob", effective_on: "2026-01-01")
    @leaver = leaver("hb-1", left_on: "2026-10-01")
    admin = create(:tenant_user, tenant: @tenant, role: :admin)
    @admin = AuthorizationContext.new(user: admin.user, tenant_user: admin, person: nil)
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

  def forgetting(active: [])
    OrgGraph::Forgetting.new(@tenant, hris: FakeHris.new(active))
  end

  def last_event(person)
    Rails.configuration.event_store.read.stream(EventStreamNaming.person_stream(person.id)).last
  end

  def notify(**params)
    Noticed::Event.create!(type: "FeedbackReceivedNotifier", params: { tenant_id: @tenant.id, **params })
  end

  context "#forget_due" do
    should "leave no tenant-scoped query able to name or reach the person" do
      member = create(:tenant_user, tenant: @tenant, person: @leaver, slack_user_id: "U-EXAMPLE")
      name, email = @leaver.name, @leaver.email

      report = forgetting.forget_due(on: TODAY)

      assert_equal OrgGraph::Forgetting::Report.new(count: 1, person_ids: [ @leaver.id ]), report
      row = @leaver.reload
      assert_nil row.read_attribute(:name)
      assert_nil row.email
      assert_nil row.external_id
      assert_nil row.hris_raw_data
      assert_equal OrgGraph::Forgetting.digest(@tenant, "hibob", "hb-1"), row.forgotten_external_id_digest
      assert_equal "Former member", row.name
      assert Person.where("name = ? OR email = ?", name, email).none?
      assert TenantUser.where(id: member.id).none?
      assert TenantUser.joins(:user).where(users: { email: }).none?
      tombstone = TenantUser.unscoped.find(member.id)
      assert_nil tombstone.user_id
      assert_nil tombstone.person_id
      assert_nil tombstone.slack_user_id
      assert_instance_of OrgGraph::Events::PersonForgotten, last_event(@leaver)
      assert_equal({ reason: "retention", retention_years: 7, requested_by_id: nil },
        last_event(@leaver).data.slice(:reason, :retention_years, :requested_by_id))
      assert OrgLeaver.where(person_id: @leaver.id).none?
    end

    should "take only the leavers whose period has ended" do
      recent = leaver("hb-2", left_on: "2030-01-01")

      assert_equal [ @leaver.id ], forgetting.forget_due(on: TODAY).person_ids
      assert_not recent.reload.forgotten?
    end

    should "spare a leaver the HRIS shows as employed or starting again" do
      assert_equal 0, forgetting(active: [ "hb-1" ]).forget_due(on: TODAY).count
      assert_not @leaver.reload.forgotten?
    end

    should "forget nobody when the HRIS can't be reached" do
      hris = Object.new
      def hris.active_external_ids = raise(Hris::Hibob::Errors::Error, "unreachable")

      assert_raises(Hris::Hibob::Errors::Error) { OrgGraph::Forgetting.new(@tenant, hris:).forget_due(on: TODAY) }
      assert_not @leaver.reload.forgotten?
    end

    should "forget nobody without the key" do
      ENV.stub(:[], ->(name) { name == "ORG_GRAPH_FORGETTING_KEY" ? nil : ENV.fetch(name, nil) }) do
        assert_raises(OrgGraph::Forgetting::KeyMissing) { forgetting.forget_due(on: TODAY) }
      end
      assert_not @leaver.reload.forgotten?
    end

    should "do nothing for someone already forgotten" do
      forgetting.forget_due(on: TODAY)

      assert_no_difference -> { Rails.configuration.event_store.read.stream(EventStreamNaming.person_stream(@leaver.id)).count } do
        assert_equal false, forgetting.send(:erase, @leaver.id, on: TODAY, reason: "retention")
      end
    end

    should "carry on past a person who can't be forgotten" do
      run = forgetting
      report = run.stub(:candidates, [ SecureRandom.uuid_v7, @leaver.id ]) { run.forget_due(on: TODAY) }

      assert_equal [ @leaver.id ], report.person_ids
      assert @leaver.reload.forgotten?
    end

    should "roll the person back whole when the last step fails" do
      member = create(:tenant_user, tenant: @tenant, person: @leaver)
      run = forgetting
      erase_identifiers = run.method(:erase_identifiers)
      failing = lambda do |person|
        erase_identifiers.call(person)
        raise ActiveRecord::StatementInvalid, "boom"
      end

      run.stub(:erase_identifiers, failing) { assert_equal 0, run.forget_due(on: TODAY).count }

      assert_not @leaver.reload.forgotten?
      assert_equal [ "Pat Example hb-1", "hb-1" ], [ @leaver.name, @leaver.external_id ]
      assert_equal [ @leaver.id, nil ], [ member.reload.person_id, member.forgotten_at ]
      assert_not_instance_of OrgGraph::Events::PersonForgotten, last_event(@leaver)
      assert OrgLeaver.where(person_id: @leaver.id).exists?
    end

    should "spare a leaver whose retention period grew after the run began" do
      run = forgetting
      due = run.dry_run(on: TODAY).person_ids
      Tenant.find(@tenant.id).tap { it.org_graph_config.retention_years = 10 }.save!

      report = run.stub(:candidates, due) { run.forget_due(on: TODAY) }

      assert_equal 0, report.count
      assert_not @leaver.reload.forgotten?
    end

    should "record the retention period in force when the person was forgotten" do
      Tenant.find(@tenant.id).tap { it.org_graph_config.retention_years = 6 }.save!

      forgetting.forget_due(on: TODAY)

      assert_equal 6, last_event(@leaver).data[:retention_years]
    end

    should "stop a scheduled run once the schedule is turned off" do
      second = leaver("hb-4", left_on: "2026-09-01")
      Tenant.find(@tenant.id).tap { it.org_graph_config.scheduled_forgetting = true }.save!
      run = forgetting
      due = run.dry_run(on: TODAY).person_ids
      Tenant.find(@tenant.id).tap { it.org_graph_config.scheduled_forgetting = false }.save!

      report = run.stub(:candidates, due) { run.forget_due(on: TODAY, scheduled: true) }

      assert_equal 0, report.count
      assert_not second.reload.forgotten?
      assert_not @leaver.reload.forgotten?
    end

    should "leave nothing elsewhere that names or reaches them" do
      member = create(:tenant_user, tenant: @tenant, person: @leaver)
      theirs = notify(author_name: "Someone Else").notifications.create!(recipient: member.user)
      elsewhere = Noticed::Event.create!(type: "FeedbackReceivedNotifier", params: { tenant_id: SecureRandom.uuid_v7 })
        .notifications.create!(recipient: member.user)
      report = create(:person, tenant: @tenant, hris_raw_data: {
        "work" => { "title" => "Engineer", "reportsTo" => { "id" => "hb-1", "displayName" => "Pat Example hb-1" } }
      })
      ledger = FeedbackExchangeImport.create!(tenant: @tenant, origin: "chip", external_id: "f-1", status: "skipped",
                                              skip_reason: "recipient_inactive", synced_at: Time.current,
                                              record: { "recipient" => { "email" => @leaver.email.upcase } })

      forgetting.forget_due(on: TODAY)

      assert_not Noticed::Notification.exists?(theirs.id)
      assert Noticed::Notification.exists?(elsewhere.id)
      assert_equal({ "title" => "Engineer" }, report.reload.hris_raw_data["work"])
      assert_nil ledger.reload.record
    end

    should "clear their name where a notification holds their id, and spare a namesake's" do
      namesake = create(:person, tenant: @tenant)
      theirs = notify(author_id: @leaver.id, author_name: @leaver.name,
                      assessee_id: namesake.id, assessee_name: @leaver.name)
      stranger = SecureRandom.uuid_v7
      listed = notify(skipped_ids: [ namesake.id, @leaver.id, stranger ],
                      skipped_names: [ @leaver.name, @leaver.name, "Someone Else" ])

      forgetting.forget_due(on: TODAY)

      assert_nil theirs.reload.params[:author_name]
      assert_equal "Pat Example hb-1", theirs.params[:assessee_name]
      assert_equal [ "Pat Example hb-1", "Someone Else" ], listed.reload.params[:skipped_names]
      assert_equal [ namesake.id, stranger ], listed.params[:skipped_ids]
    end

    should "match on the name, within the tenant only, where an older notification holds no id" do
      kept = notify(author_name: "Someone Else")
      named = notify(author_name: @leaver.name, assessee_name: @leaver.name)
      listed = notify(skipped_names: [ @leaver.name, "Someone Else" ])
      other_tenant = Noticed::Event.create!(type: "FeedbackReceivedNotifier",
        params: { tenant_id: create(:tenant).id, author_name: @leaver.name })

      forgetting.forget_due(on: TODAY)

      assert_equal "Someone Else", kept.reload.params[:author_name]
      assert_nil named.reload.params[:author_name]
      assert_nil named.params[:assessee_name]
      assert_equal [ "Someone Else" ], listed.reload.params[:skipped_names]
      assert_equal "Pat Example hb-1", other_tenant.reload.params[:author_name]
    end

    should "rename them in the context line of a comment on their feedback" do
      namesake = create(:person, tenant: @tenant)
      theirs = notify(feedback_author_id: @leaver.id, context: "#{@leaver.name}'s feedback · Delivery · L2")
      namesakes = notify(feedback_author_id: namesake.id, context: "#{@leaver.name}'s feedback · Delivery · L2")
      legacy = notify(context: "#{@leaver.name}'s feedback · Delivery · L2")
      unrelated = notify(context: "Delivery · L2")

      forgetting.forget_due(on: TODAY)

      assert_equal "Former member's feedback · Delivery · L2", theirs.reload.params[:context]
      assert_equal "Pat Example hb-1's feedback · Delivery · L2", namesakes.reload.params[:context]
      assert_equal "Former member's feedback · Delivery · L2", legacy.reload.params[:context]
      assert_equal "Delivery · L2", unrelated.reload.params[:context]
    end
  end

  context "notifications written from now on" do
    should "drop the names of people already forgotten, as one built before the erasure lands after it" do
      namesake = create(:person, tenant: @tenant)
      name = @leaver.name
      forgetting.forget_due(on: TODAY)

      late = notify(author_id: @leaver.id, author_name: name, assessee_id: namesake.id, assessee_name: name,
                    skipped_ids: [ @leaver.id, namesake.id ], skipped_names: [ name, name ],
                    feedback_author_id: @leaver.id, context: "#{name}'s feedback · Delivery · L2")

      params = late.reload.params
      assert_nil params[:author_name]
      assert_equal name, params[:assessee_name]
      assert_equal [ namesake.id ], params[:skipped_ids]
      assert_equal [ name ], params[:skipped_names]
      assert_equal "Former member's feedback · Delivery · L2", params[:context]
    end

    should "not reach a login resolved before the erasure and delivered after it" do
      login = create(:tenant_user, tenant: @tenant, person: @leaver).user
      colleague = create(:tenant_user, tenant: @tenant).user
      forgetting.forget_due(on: TODAY)

      FeedbackReceivedNotifier.with(tenant_id: @tenant.id).deliver([ login, colleague ])

      assert_equal [ colleague.id ], Noticed::Notification.where(recipient: [ login, colleague ]).pluck(:recipient_id)
    end

    should "carry the person's id beside every name they copy" do
      pairs = OrgGraph::Forgetting::NAME_PARAMS.merge(OrgGraph::Forgetting::NAME_LIST_PARAMS)
      writers = Rails.root.glob("app/{contexts,jobs}/**/*.rb").select { |path| path.read.include?("Notifier") }

      missing = writers.flat_map do |path|
        source = path.read
        pairs.filter_map do |name_key, id_key|
          "#{path.relative_path_from(Rails.root)}: #{name_key} without #{id_key}" if
            source.include?("#{name_key}:") && !source.include?("#{id_key}:")
        end
      end

      assert_empty missing
    end
  end

  context "#dry_run" do
    should "count who would go, after the HRIS check, and erase nothing" do
      leaver("hb-2", left_on: "2026-09-01")

      report = forgetting(active: [ "hb-2" ]).dry_run(on: TODAY)

      assert_equal OrgGraph::Forgetting::Report.new(count: 1, person_ids: [ @leaver.id ]), report
      assert_not @leaver.reload.forgotten?
    end
  end

  context "#forget" do
    setup do
      @recent = leaver("hb-2", left_on: "2033-01-01")
    end

    should "refuse anyone but a tenant admin" do
      member = create(:tenant_user, tenant: @tenant, role: :member)
      context = AuthorizationContext.new(user: member.user, tenant_user: member, person: nil)

      assert_raises(Pundit::NotAuthorizedError) { forgetting.forget(@leaver.id, requested_by: context, on: TODAY) }
    end

    should "refuse a leaver not yet due unless the admin says so, and record who asked" do
      assert_raises(OrgGraph::Forgetting::Refused) { forgetting.forget(@recent.id, requested_by: @admin, on: TODAY) }

      assert forgetting.forget(@recent.id, requested_by: @admin, before_due: true, on: TODAY)
      assert_equal({ reason: "request", requested_by_id: @admin.tenant_user.id },
        last_event(@recent).data.slice(:reason, :requested_by_id))
    end

    should "record a due leaver as retention, still naming who asked" do
      assert forgetting.forget(@leaver.id, requested_by: @admin, on: TODAY)
      assert_equal({ reason: "retention", requested_by_id: @admin.tenant_user.id },
        last_event(@leaver).data.slice(:reason, :requested_by_id))
    end

    should "refuse a global admin with no membership here, as the event could name nobody" do
      context = AuthorizationContext.new(user: create(:user, global_admin: true), tenant_user: nil, person: nil)

      assert_raises(OrgGraph::Forgetting::Refused) { forgetting.forget(@leaver.id, requested_by: context, on: TODAY) }
      assert_not @leaver.reload.forgotten?
    end

    should "answer false, not refuse, for someone already forgotten" do
      assert forgetting.forget(@leaver.id, requested_by: @admin, on: TODAY)

      assert_equal false, forgetting.forget(@leaver.id, requested_by: @admin, on: TODAY)
    end

    should "refuse someone the HRIS still employs" do
      assert_raises(OrgGraph::Forgetting::Refused) do
        forgetting(active: [ "hb-2" ]).forget(@recent.id, requested_by: @admin, before_due: true, on: TODAY)
      end
    end

    should "refuse someone who hasn't left" do
      employed = create(:person, tenant: @tenant, hris_source: "hibob", external_id: "hb-3")
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        .sync_person(employed.id, **PROVENANCE, employment_status: "employed")

      assert_raises(RuntimeError, match: /left/) do
        forgetting.forget(employed.id, requested_by: @admin, before_due: true, on: TODAY)
      end
      assert_not employed.reload.forgotten?
    end
  end
end
