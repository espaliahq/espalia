# frozen_string_literal: true

require "test_helper"
require_relative "../../support/rebuild_lock"

class OrgGraph::PersonDevelopmentFeedTest < ActiveSupport::TestCase
  include RebuildLock

  HIBOB = { provider: "hibob", effective_on: "2026-02-01" }.freeze

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    @tenant.claim_hris_facts!
    @people = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @development = PersonDevelopment::CommandHandler.new

    as_tenant do
      @framework = create(:framework_state)
      @e_role = create(:framework_role, code: "E", name: "Software Engineer")
      @e5 = create(:framework_level, role_id: @e_role.role_id, ordinal: 5, code: "E5", title: "Senior SWE")
      @e6 = create(:framework_level, role_id: @e_role.role_id, ordinal: 6, code: "E6", title: "Lead SWE")
      @lead = create(:person, tenant: @tenant, hris_source: "hibob", external_id: "hb-lead")
      @ada = create(:person, tenant: @tenant, hris_source: "hibob", external_id: "hb-ada")
      @people.record_person(@lead.id, **HIBOB, employment_status: "employed")
      @people.record_person(@ada.id, **HIBOB, employment_status: "employed", title: "Software Engineer", level: "5",
                                     manager_id: @lead.id)
    end
  end

  should "assign and record the manager, then find nothing more to do" do
    assert_equal %i[assign record_manager], reconcile(@ada)
    assert_empty reconcile(@ada)

    held = held(@ada)
    assert_equal [ @e_role.role_id, @e5.level_id, @lead.id ], [ held.role_id, held.level_id, held.manager_id ]
  end

  should "report what it would do without doing it" do
    assert_equal %i[assign record_manager], reconcile(@ada, apply: false)
    assert_not held(@ada).assigned?
  end

  should "change the level alone when only the level moved" do
    reconcile(@ada)
    as_tenant { @people.change_level(@ada.id, "6", **HIBOB) }

    assert_equal %i[change_level], reconcile(@ada)
    assert_equal @e6.level_id, held(@ada).level_id
  end

  should "keep the assignment when the new title maps to nothing" do
    reconcile(@ada)
    as_tenant { @people.change_title(@ada.id, "Chef", **HIBOB) }

    assert_empty reconcile(@ada)
    assert_equal @e5.level_id, held(@ada).level_id
  end

  should "reassign someone who returns, keeping the manager on record" do
    reconcile(@ada)
    as_tenant { @people.leave(@ada.id, provider: "hibob", effective_on: "2026-06-30") }
    assert_equal %i[unassign], reconcile(@ada)

    as_tenant { @people.return_to_work(@ada.id, provider: "hibob", effective_on: "2026-09-01") }
    assert_equal %i[assign], reconcile(@ada)
    assert_equal @lead.id, held(@ada).manager_id
  end

  should "offboard a leaver from every framework and every open cycle" do
    reconcile(@ada)
    as_tenant do
      other = create(:framework_state)
      other_role = create(:framework_role, code: "D", name: "Designer")
      other_level = create(:framework_level, role_id: other_role.role_id, ordinal: 1, code: "D1", title: "Designer")
      @development.assign_to_framework(@ada.id, other.framework_id, other_role.role_id, other_level.level_id)
      cycles = AssessmentCycles::CommandHandler.new
      [ @framework, other ].each do |framework|
        cycle_id = SecureRandom.uuid_v7
        cycles.define_cycle(cycle_id, framework.framework_id, "Q1", "regular", 1)
        cycles.enroll(cycle_id, @ada.id)
      end
      @people.leave(@ada.id, provider: "hibob", effective_on: "2026-06-30")
    end

    assert_equal %i[withdraw withdraw unassign unassign], reconcile(@ada)
    as_tenant do
      assert_not PersonFrameworkAssignment.exists?(person_id: @ada.id)
      assert_not AssessmentCycleEnrollment.active.exists?(person_id: @ada.id)
    end
  end

  should "clear a manager only when the HRIS recorded none" do
    reconcile(@ada)
    as_tenant { @people.change_manager(@ada.id, nil, **HIBOB) }

    assert_equal %i[clear_manager], reconcile(@ada)
    assert_nil held(@ada).manager_id
  end

  should "keep a manager no provider has supplied" do
    as_tenant do
      @people.record_person(grace = create(:person, tenant: @tenant, hris_source: "hibob", external_id: "hb-grace").id, **HIBOB,
                            employment_status: "employed", title: "Software Engineer", level: "5")
      @development.assign_to_framework(grace, @framework.framework_id, @e_role.role_id, @e5.level_id)
      @development.record_reporting_manager(grace, @framework.framework_id, @lead.id)

      assert_empty OrgGraph::PersonDevelopmentFeed.new(@tenant).reconcile(grace)
      assert_equal @lead.id, @development.load(grace, @framework.framework_id).manager_id
    end
  end

  should "leave someone Espalia holds alone" do
    as_tenant { @ada.update_columns(hris_source: nil) }

    assert_empty reconcile(@ada)
  end

  should "do nothing for someone the Org Graph has forgotten" do
    as_tenant do
      @people.leave(@ada.id, provider: "hibob", effective_on: "2026-06-30")
      @people.forget_person(@ada.id, effective_on: "2026-07-01", reason: "request", requested_by_id: @lead.id)
    end

    assert_empty reconcile(@ada)
  end

  should "refuse while the assignments it plans from are rebuilt" do
    while_rebuilding(@tenant, PersonDevelopment::Projections::CurrentAssessment) do
      assert_raises(ProjectionVersion::Rebuilding) { reconcile(@ada) }
    end
    assert_not held(@ada).assigned?
  end

  context "the handler" do
    setup { @tenant.update!(person_development_fed_at: Time.current) }

    should "reconcile on an Org Graph change and count it" do
      counts = OrgGraph::SyncHandlers::PersonDevelopmentFeed.tally do
        as_tenant { @people.change_level(@ada.id, "6", **HIBOB) }
      end

      assert_equal({ assign: 1, record_manager: 1 }, counts)
      assert_equal @e6.level_id, held(@ada).level_id
    end

    should "count a refusal without failing the Org Graph write" do
      refusing = Object.new.tap { |feed| feed.define_singleton_method(:reconcile) { |_| raise "refused" } }
      counts = OrgGraph::PersonDevelopmentFeed.stub(:new, refusing) do
        OrgGraph::SyncHandlers::PersonDevelopmentFeed.tally do
          as_tenant { @people.change_level(@ada.id, "6", **HIBOB) }
        end
      end

      assert_equal({ errors: 1 }, counts)
      as_tenant { assert_equal "6", OrgGraph::Repository.new.load_person(@ada.id).fact(:level) }
    end
  end

  private

  def reconcile(person, apply: true)
    as_tenant { OrgGraph::PersonDevelopmentFeed.new(@tenant, apply:).reconcile(person.id) }
  end

  def held(person)
    as_tenant { @development.load(person.id, @framework.framework_id) }
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)
end
