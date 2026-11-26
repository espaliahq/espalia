# frozen_string_literal: true

require "test_helper"
require "rake"
require_relative "../../lib/tasks/example_seed"

class ExampleSeedTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @admin = create(:user, global_admin: true)
  end

  should "seed the demo tenant and converge on a second run" do
    io = StringIO.new
    tenant = ExampleSeed.new(admin_user: @admin, io: io).call

    counts = ActsAsTenant.with_tenant(tenant) { snapshot }
    assert_equal 21, counts[:people]
    assert_equal 20, counts[:assignments], "everyone but the VP is assigned"
    assert_equal 20, counts[:enrollments]
    assert_equal 0, counts[:snapshotless_enrollments], "every enrollment carries its role/level snapshot"
    assert_operator counts[:ratings], :>, 0
    assert_equal 2, counts[:aligned], "two assessments are fully aligned"
    assert_operator counts[:evidence], :>=, 7
    assert_equal 1, counts[:withdrawn_evidence]
    assert_equal 4, counts[:pending_suggestions]
    assert counts[:draft_in_progress], "a v2 draft stays open for the explorer to show"
    assert_equal 1, counts[:pending_requests]
    assert Tenant.exists?(slug: ExampleSeed::SECOND_TENANT[:slug]), "the switcher has a second workspace"
    assert_equal "Ladder", tenant.product_name, "the demo tenant brands its own instance"

    rerun = ExampleSeed.new(admin_user: @admin, io: StringIO.new).call
    assert_equal counts, ActsAsTenant.with_tenant(rerun) { snapshot }, "a re-run converges"
  end

  should "record everyone in the Org Graph and cut the demo tenant over" do
    tenant = ExampleSeed.new(admin_user: @admin, io: StringIO.new).call

    assert tenant.reload.org_graph_people_projected?
    ActsAsTenant.with_tenant(tenant) do
      assert_equal Person.pluck(:id).sort, OrgGraph::Projections::PeopleColumns.recorded_person_ids(tenant).sort
      assert_equal Person.find_by!(email: "imogen@nullisland.example").id,
                   Person.find_by!(email: "theo@nullisland.example").manager.manager_id
    end
  end

  should "leave a reporting line the Org Graph moved on a re-run" do
    tenant = ExampleSeed.new(admin_user: @admin, io: StringIO.new).call
    theo, june = ActsAsTenant.with_tenant(tenant) do
      %w[theo june].map { Person.find_by!(email: "#{it}@nullisland.example") }
    end
    ActsAsTenant.with_tenant(tenant) do
      SeedOrgGraph.as_system do |org_graph|
        org_graph.change_manager(theo.id, june.id, provider: OrgGraph::StructureAggregate::ESPALIA, effective_on: Date.current)
      end
    end

    ExampleSeed.new(admin_user: @admin, io: StringIO.new).call

    assert_equal june.id, theo.reload.manager_id
  end

  should "record someone added to the seed after the cut-over in the Org Graph" do
    tenant = ExampleSeed.new(admin_user: @admin, io: StringIO.new).call
    with_people("wren" => [ "Wren Ashby", "Engineer", "Engineering", "marisol", nil, nil, false ]) do
      ExampleSeed.new(admin_user: @admin, io: StringIO.new).call
    end

    ActsAsTenant.with_tenant(tenant) do
      wren = Person.find_by!(email: "wren@nullisland.example")
      assert_includes OrgGraph::Projections::PeopleColumns.recorded_person_ids(tenant), wren.id
      assert_equal [ "Engineer", Person.find_by!(email: "marisol@nullisland.example").id, "active" ],
                   [ wren.job_title, wren.manager_id, wren.status ]
    end
  end

  should "record someone on a re-run whose recording failed on an earlier one" do
    tenant = ExampleSeed.new(admin_user: @admin, io: StringIO.new).call
    wren = ActsAsTenant.with_tenant(tenant) do
      Person.create!(email: "wren@nullisland.example", name: "Wren Ashby", department: "Engineering")
    end

    with_people("wren" => [ "Wren Ashby", "Engineer", "Engineering", "marisol", nil, nil, false ]) do
      ExampleSeed.new(admin_user: @admin, io: StringIO.new).call
    end

    ActsAsTenant.with_tenant(tenant) do
      assert_includes OrgGraph::Projections::PeopleColumns.recorded_person_ids(tenant), wren.id
      assert_equal [ "Engineer", Person.find_by!(email: "marisol@nullisland.example").id ],
                   [ wren.reload.job_title, wren.manager_id ]
    end
  end

  should "record the manager the Org Graph holds when someone is first assigned on a re-run" do
    tenant = ExampleSeed.new(admin_user: @admin, io: StringIO.new).call
    with_people("wren" => [ "Wren Ashby", "Engineer", "Engineering", "marisol", nil, nil, false ]) do
      ExampleSeed.new(admin_user: @admin, io: StringIO.new).call
    end
    wren, june = ActsAsTenant.with_tenant(tenant) do
      %w[wren june].map { Person.find_by!(email: "#{it}@nullisland.example") }
    end
    ActsAsTenant.with_tenant(tenant) do
      SeedOrgGraph.as_system do |org_graph|
        org_graph.change_manager(wren.id, june.id, provider: OrgGraph::StructureAggregate::ESPALIA, effective_on: Date.current)
      end
    end

    with_people("wren" => [ "Wren Ashby", "Engineer", "Engineering", "marisol", "E", 2, false ]) do
      ExampleSeed.new(admin_user: @admin, io: StringIO.new).call
    end

    ActsAsTenant.with_tenant(tenant) do
      assert_equal june.id, RecordedReportingManager.find_by!(person_id: wren.id).manager_id
    end
  end

  should "leave the demo cycle alone once the calibration seed has closed it" do
    tenant = ExampleSeed.new(admin_user: @admin, io: StringIO.new).call
    ActsAsTenant.with_tenant(tenant) do
      cycle = AssessmentCycle.find_by!(name: ExampleSeed::CYCLE_NAME)
      AssessmentCycles::CommandHandler.new.close_cycle(cycle.cycle_id, closed_by: Person.find_by!(manager_id: nil).id)
      # A person added to the seed since: the re-run sees them unenrolled.
      AssessmentCycleEnrollment.where(cycle_id: cycle.cycle_id).first.delete
    end

    io = StringIO.new
    ExampleSeed.new(admin_user: @admin, io: io).call
    assert_match "is closed — leaving it alone", io.string
  end

  private

  def with_people(extra)
    original = ExampleSeed::PEOPLE
    ExampleSeed.send(:remove_const, :PEOPLE)
    ExampleSeed.const_set(:PEOPLE, original.merge(extra))
    yield
  ensure
    ExampleSeed.send(:remove_const, :PEOPLE)
    ExampleSeed.const_set(:PEOPLE, original)
  end

  def snapshot
    framework = FrameworkState::Framework.first
    {
      people: Person.count,
      assignments: PersonFrameworkAssignment.count,
      enrollments: AssessmentCycleEnrollment.count,
      snapshotless_enrollments: AssessmentCycleEnrollment.where(role_id: nil).count,
      ratings: AssessmentLevelRating.across_all_roles.count,
      aligned: AssessmentCycleProgress.where(status: "aligned").count,
      evidence: EvidenceItem.count,
      withdrawn_evidence: EvidenceItem.where(link_status: "withdrawn").count,
      pending_suggestions: FrameworkState::SuggestedEdit.where(status: "pending").count,
      draft_in_progress: framework.reload.draft_in_progress,
      pending_requests: EvidenceRequest.where(status: "pending").count
    }
  end
end
