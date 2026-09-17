# frozen_string_literal: true

require "test_helper"

# The word a performance state wears (#415). The state is scoring policy
# and stays internal; the word is culture and belongs to the tenant.
class Views::Assessments::StateLabelsTest < ActiveSupport::TestCase
  setup { @tenant = create(:tenant) }

  context ".for" do
    should "ship a word for every state the engine can produce" do
      %i[underperforming progressing performing top_of_ladder mastering eligible].each do |state|
        label = Views::Assessments::StateLabels.for(state, tenant: @tenant)

        assert label.present?, "no label for #{state}"
      end
    end

    should "prefer the tenant's own word" do
      ActsAsTenant.with_tenant(@tenant) { @tenant.update!(mastering_label: "Advancing") }

      assert_equal "Advancing", Views::Assessments::StateLabels.for(:mastering, tenant: @tenant)
    end

    should "fall back to the shipped word when the tenant has not chosen one" do
      assert_equal "Mastering", Views::Assessments::StateLabels.for(:mastering, tenant: @tenant)
    end

    should "give the top of the ladder the same word as meeting" do
      # It is "meeting, with nothing above" — one idea, so renaming one
      # renames both rather than leaving two words for the same thing.
      ActsAsTenant.with_tenant(@tenant) { @tenant.update!(performing_label: "On track") }

      assert_equal "On track", Views::Assessments::StateLabels.for(:performing, tenant: @tenant)
      assert_equal "On track", Views::Assessments::StateLabels.for(:top_of_ladder, tenant: @tenant)
    end

    should "survive an unknown or missing state" do
      assert_equal "Below expectations", Views::Assessments::StateLabels.for(nil, tenant: @tenant)
      assert_equal "Below expectations", Views::Assessments::StateLabels.for(:invented, tenant: @tenant)
    end

    should "survive having no tenant at all" do
      assert_equal "Mastering", Views::Assessments::StateLabels.for(:mastering, tenant: nil)
    end
  end

  context ".default_for" do
    should "ignore the tenant's override, for copy that names the default" do
      ActsAsTenant.with_tenant(@tenant) { @tenant.update!(mastering_label: "Advancing") }

      assert_equal "Mastering", Views::Assessments::StateLabels.default_for(:mastering)
    end
  end

  context "Tenant" do
    should "reject a label longer than the badge can carry" do
      @tenant.mastering_label = "A" * 25

      assert_not @tenant.valid?
      assert_includes @tenant.errors.full_messages.join, "too long"
    end

    should "accept a label at the limit" do
      @tenant.mastering_label = "A" * 24

      assert @tenant.valid?
    end
  end
end
