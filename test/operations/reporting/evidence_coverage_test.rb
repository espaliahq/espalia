# frozen_string_literal: true

require "test_helper"

class Operations::Reporting::EvidenceCoverageTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      framework_id = SecureRandom.uuid_v7
      role = create(:framework_role, name: "Engineer")
      @cycle = create(:assessment_cycle,
        tenant: @tenant, name: "Q1 2026", framework_id: framework_id)

      @manager_user = create(:user)
      @manager = create(:person,
        tenant: @tenant, email: @manager_user.email, name: "Manager")
      @manager_tu = create(:tenant_user,
        tenant: @tenant, user: @manager_user, person: @manager, role: :member)
      @report = create(:person, tenant: @tenant, name: "Report", manager: @manager)
      @other = create(:person, tenant: @tenant, name: "Other")
      @author = create(:person, tenant: @tenant, name: "Author")

      [ @report, @other ].each do |person|
        direction = person == @report ? "report_to_manager" : "peer_to_peer"
        create(:assessment_cycle_enrollment,
          tenant: @tenant, cycle: @cycle, person_id: person.id,
          role_id: role.role_id, level_ordinal: 2, enrolled_at: 1.day.ago)
        create(:evidence_item, with_link: false,
          tenant: @tenant, author: @author, person_id: person.id,
          framework_id: framework_id, cycle_id: @cycle.cycle_id,
          source: "peer", feedback_direction: direction)
      end
    end
    @manager_ctx = AuthorizationContext.new(
      user: @manager_user, tenant_user: @manager_tu, person: @manager
    )
  end

  should "return subtree metrics in summary mode without groups" do
    result = call_op(context: @manager_ctx, params: { cycle_id: @cycle.cycle_id })

    assert_equal 1, result.dig(:metrics, :participant_count)
    assert_equal 1, result.dig(:metrics, :feedback_provided)
    assert_equal 100, result.dig(:metrics, :participant_coverage_pct)
    assert_empty result[:groups]
    assert_equal 1, result.dig(:metrics, :feedback_directionality, :report_to_manager)
    assert_equal 100, result.dig(:metrics, :feedback_directionality, :report_to_manager_pct)
    assert_equal 0, result.dig(:metrics, :feedback_directionality, :self_provided)
  end

  should "return aggregate groups in full mode without feedback content or contributors" do
    result = call_op(
      context: @manager_ctx,
      params: { cycle_id: @cycle.cycle_id, mode: "full" }
    )

    assert_equal 1, result.dig(:groups, :role).size
    payload = result.dig(:groups, :role, 0)
    assert_equal 1, payload.dig(:metrics, :feedback_provided)
    assert_equal 1, payload.dig(:metrics, :feedback_directionality, :report_to_manager)
    refute payload.key?(:participants)
    refute result[:metrics].key?(:content)
    refute result[:metrics].key?(:author_id)
  end

  should "let an admin view the whole cycle or narrow to their subtree" do
    admin_user = create(:user)
    admin_tu = ActsAsTenant.with_tenant(@tenant) do
      person = create(:person,
        tenant: @tenant, email: admin_user.email, name: "Admin")
      create(:tenant_user,
        tenant: @tenant, user: admin_user, person: person, role: :admin)
    end
    context = AuthorizationContext.new(
      user: admin_user, tenant_user: admin_tu, person: admin_tu.person
    )

    whole = call_op(context: context, params: { cycle_id: @cycle.cycle_id })
    assert_equal 2, whole.dig(:metrics, :participant_count)

    mine = call_op(
      context: context,
      params: { cycle_id: @cycle.cycle_id, scope: "mine" }
    )
    assert_equal 0, mine.dig(:metrics, :participant_count)
  end

  context "month filter" do
    setup do
      @this_month = Time.current.beginning_of_month
      @last_month = @this_month.prev_month
      ActsAsTenant.with_tenant(@tenant) do
        @cycle.update!(opened_at: @last_month)
        create(:evidence_item, with_link: false,
          tenant: @tenant, author: @author, person_id: @report.id,
          framework_id: @cycle.framework_id, cycle_id: @cycle.cycle_id,
          source: "peer", feedback_direction: "peer_to_peer",
          recorded_at: @last_month + 2.days)
      end
    end

    should "narrow the counts to one month and describe the period" do
      result = call_op(
        context: @manager_ctx,
        params: { cycle_id: @cycle.cycle_id, month: @last_month.strftime("%Y-%m") }
      )

      assert_equal 1, result.dig(:metrics, :feedback_provided)
      assert_equal 1, result.dig(:metrics, :feedback_directionality, :peer_to_peer)
      assert_equal @last_month.strftime("%Y-%m"), result.dig(:period, :month)
      assert_equal @last_month.strftime("%B %Y"), result.dig(:period, :label)
      assert_equal @last_month.iso8601, result.dig(:period, :starts_at)
      assert_equal @last_month.end_of_month.iso8601, result.dig(:period, :ends_at)
    end

    should "report the whole cycle and list the available months without a month" do
      result = call_op(context: @manager_ctx, params: { cycle_id: @cycle.cycle_id })

      assert_equal 2, result.dig(:metrics, :feedback_provided)
      assert_nil result[:period]
      assert_equal [ @this_month, @last_month ].map { |m| m.strftime("%Y-%m") },
        result[:available_months].map { |m| m[:month] }
      assert_equal @this_month.strftime("%B %Y"), result[:available_months].first[:label]
    end

    should "reject a malformed month" do
      error = assert_raises(Operations::Base::ParameterError) do
        call_op(context: @manager_ctx, params: { cycle_id: @cycle.cycle_id, month: "June 2026" })
      end
      assert_match(/YYYY-MM/, error.message)
    end

    should "reject a month the cycle never spanned" do
      error = assert_raises(Operations::Base::ParameterError) do
        call_op(context: @manager_ctx, params: { cycle_id: @cycle.cycle_id, month: "2001-01" })
      end
      assert_match(/outside the cycle/, error.message)
    end
  end

  should "deny a member with no reports in the cycle" do
    outsider_user = create(:user)
    outsider_tu = ActsAsTenant.with_tenant(@tenant) do
      person = create(:person,
        tenant: @tenant, email: outsider_user.email, name: "Outsider")
      create(:tenant_user,
        tenant: @tenant, user: outsider_user, person: person, role: :member)
    end
    context = AuthorizationContext.new(
      user: outsider_user, tenant_user: outsider_tu, person: outsider_tu.person
    )

    assert_raises(Pundit::NotAuthorizedError) do
      call_op(context: context, params: { cycle_id: @cycle.cycle_id })
    end
  end

  private

  def call_op(context:, params:)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Reporting::EvidenceCoverage.call(context: context, params: params)
    end
  end
end
