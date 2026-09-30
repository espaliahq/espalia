# frozen_string_literal: true

require "test_helper"

# Declared explorations through the Operations the web and MCP share
# (ADR-22): declare with a lens's params, close with an outcome, list, and
# find them on assessments_mine and assessments_get.
class Operations::Assessments::ExplorationOperationsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @fx = build_role_lens_framework(tenant: @tenant)
    @manager = create(:person, tenant: @tenant, name: "Morgan Reyes")
    @person = create(:person, tenant: @tenant, manager: @manager, name: "Alex Kim")
    @delegate = create(:person, tenant: @tenant)
    @skip_level = create(:person, tenant: @tenant)
    @manager.update!(manager: @skip_level)
    @assignment, @cycle_id = enrol_in_role_lens_framework(@person, @fx, tenant: @tenant)
    create(:manager_assessment_delegation, tenant: @tenant, person_id: @person.id,
           framework_id: @fx.framework_id, delegate_person_id: @delegate.id)
    @pm = { as_role_id: @fx.pm.role_id, as_level_ordinal: 3 }
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def context_for(person)
    user = create(:user)
    tenant_user = create(:tenant_user, tenant: @tenant, user: user, person: person)
    AuthorizationContext.new(user: user, tenant_user: tenant_user, person: person)
  end

  def call(operation, as: @person, **params)
    operation.call(context: context_for(as), params: { assignment_id: @assignment.id, **params })
  end

  def start(as: @person, **params)
    call(Operations::Assessments::StartExploration, as: as, **@pm, **params)
  end

  context Operations::Assessments::StartExploration do
    should "declare an exploration named like a lens" do
      result = start(note: "  Loves discovery  ")

      assert_equal "open", result[:status]
      assert_equal({ role_id: @fx.pm.role_id, role_code: "PM", role_name: "Product Manager", level_ordinal: 3,
                     code: "PM3" }, result[:target])
      assert_equal({ as_role_id: @fx.pm.role_id, as_level_ordinal: 3 }, result[:lens])
      assert_equal({ id: @person.id, name: "Alex Kim" }, result[:started_by])
      assert_equal "Loves discovery", result[:note]
      assert AssessmentExploration.exists?(result[:id])
    end

    should "let the manager and a delegate declare one" do
      assert_equal @manager.id, start(as: @manager)[:started_by][:id]
      other = call(Operations::Assessments::StartExploration, as: @delegate, as_level_ordinal: 3)
      assert_equal "E3", other[:target][:code]
    end

    should "refuse a view-only ancestor" do
      assert_raises(Pundit::NotAuthorizedError) { start(as: @skip_level) }
    end

    should "refuse the role and level the assessment is of" do
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::Assessments::StartExploration, as_role_id: @fx.engineer.role_id, as_level_ordinal: 2)
      end
      assert_match(/E2 is the role and level/, error.message)
    end

    should "refuse a second open exploration of the same role" do
      start
      error = assert_raises(Operations::Base::ParameterError) { start(as_level_ordinal: 2) }
      assert_match(/Product Manager · PM3 is already open/, error.message)
    end

    should "refuse a call that names no target" do
      assert_raises(Operations::Base::ParameterError) { call(Operations::Assessments::StartExploration) }
    end

    should "work between cycles" do
      AssessmentCycles::CommandHandler.new.close_cycle(@cycle_id)

      assert_equal "open", start[:status]
    end
  end

  context Operations::Assessments::CloseExploration do
    setup { @exploration_id = start[:id] }

    should "close with the outcome and the note, whoever declared it" do
      result = call(Operations::Assessments::CloseExploration, as: @manager, exploration_id: @exploration_id,
                    outcome: "not_now", note: "After the launch")

      assert_equal "closed", result[:status]
      assert_equal "not_now", result[:outcome]
      assert_equal "After the launch", result[:close_note]
      assert_equal @manager.id, result[:closed_by][:id]
    end

    should "refuse to close twice" do
      call(Operations::Assessments::CloseExploration, exploration_id: @exploration_id, outcome: "pursue")

      assert_raises(Operations::Base::ParameterError) do
        call(Operations::Assessments::CloseExploration, exploration_id: @exploration_id, outcome: "pursue")
      end
    end

    should "refuse an outcome outside the three" do
      assert_raises(Operations::Base::ParameterError) do
        call(Operations::Assessments::CloseExploration, exploration_id: @exploration_id, outcome: "abandoned")
      end
    end

    should "not reach another assessment's exploration" do
      other_person = create(:person, tenant: @tenant, manager: @manager)
      PersonDevelopment::CommandHandler.new.assign_to_framework(
        other_person.id, @fx.framework_id, @fx.engineer.role_id, @fx.e_levels.fetch(2).level_id
      )
      other = PersonFrameworkAssignment.find_by!(person_id: other_person.id, framework_id: @fx.framework_id)
      assert_raises(ActiveRecord::RecordNotFound) do
        Operations::Assessments::CloseExploration.call(
          context: context_for(@manager),
          params: { assignment_id: other.id, exploration_id: @exploration_id, outcome: "pursue" }
        )
      end
    end

    should "refuse a view-only ancestor" do
      assert_raises(Pundit::NotAuthorizedError) do
        call(Operations::Assessments::CloseExploration, as: @skip_level, exploration_id: @exploration_id,
             outcome: "pursue")
      end
    end
  end

  context Operations::Assessments::ExplorationsList do
    setup do
      closed = start[:id]
      call(Operations::Assessments::CloseExploration, exploration_id: closed, outcome: "moved")
      @open = call(Operations::Assessments::StartExploration, as_level_ordinal: 3)[:id]
    end

    should "list every exploration newest first, or filter by status" do
      all = call(Operations::Assessments::ExplorationsList)[:explorations]
      assert_equal [ @open ], all.first(1).pluck(:id)
      assert_equal %w[open closed], all.pluck(:status)
      assert_equal [ @open ], call(Operations::Assessments::ExplorationsList, status: "open")[:explorations].pluck(:id)
    end

    should "be readable by a view-only ancestor" do
      assert_equal 2, call(Operations::Assessments::ExplorationsList, as: @skip_level)[:explorations].size
    end
  end

  context "assessments_mine" do
    should "list open explorations on the caller's own assessments and their team's" do
      id = start[:id]

      own = Operations::Assessments::Mine.call(context: context_for(@person))[:explorations]
      assert_equal [ id ], own[:own].pluck(:id)
      assert_equal @assignment.id, own[:own].first[:assignment_id]
      assert_empty own[:team]

      team = Operations::Assessments::Mine.call(context: context_for(@manager))[:explorations]
      assert_empty team[:own]
      assert_equal [ id ], team[:team].pluck(:id)
      assert_equal "Alex Kim", team[:team].first[:assessee][:name]
    end

    should "leave closed explorations out" do
      call(Operations::Assessments::CloseExploration, exploration_id: start[:id], outcome: "pursue")

      assert_empty Operations::Assessments::Mine.call(context: context_for(@person))[:explorations][:own]
    end
  end

  context "assessments_get" do
    should "carry the lens role's open exploration" do
      id = start[:id]

      assert_equal id, call(Operations::Assessments::Get, **@pm)[:current_exploration][:id]
      assert_equal id, call(Operations::Assessments::Get, as_role_id: @fx.pm.role_id, as_level_ordinal: 2)
        .dig(:current_exploration, :id), "any level of the explored role"
      assert_nil call(Operations::Assessments::Get)[:current_exploration]
    end
  end
end
