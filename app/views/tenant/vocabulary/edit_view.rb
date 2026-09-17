# frozen_string_literal: true

# Tenant vocabulary editor — the word each performance state wears (#415).
#
# Only the mastering state is editable today: it is the one that reads
# oddly out of the box ("Mastering E3 · 62% of the way to E4" lands as
# faint praise in some teams and as overclaiming in others). The column
# exists for all five, so adding another field here is a view change.
#
# The page shows what the word does rather than describing it: the state's
# own band on the scale, and the sentence the hero will render.
class Views::Tenant::Vocabulary::EditView < Views::Base
  include Phlex::Rails::Helpers::Routes
  include Phlex::Rails::Helpers::FormWith

  # @param tenant [Tenant]
  # @param user [User]
  # @param current_tenant [Tenant]
  # @param tenants [Array<Tenant>]
  def initialize(tenant:, user:, current_tenant:, tenants: [])
    @tenant = tenant
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::TenantAdminLayout.new(
      active_section: :vocabulary,
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      render Components::Kit::SectionHeading.new(
        "Vocabulary",
        subtitle: "The words your team reads for each performance state. " \
                  "Scoring is unchanged — only the label moves."
      )

      form_with(url: tenant_vocabulary_path, method: :patch, scope: :tenant, class: "space-y-6") do |form|
        mastering_card(form)
        unchanged_note
        actions(form)
      end
    end
  end

  private

  def mastering_card(form)
    render Components::Kit::Card.new(title: "Past the halfway mark") do |card|
      card.body do
        p(class: "text-sm text-gray-600 dark:text-gray-300 mb-4") do
          plain "The state past the halfway point to the next level. "
          plain "GrowthOS calls it "
          strong { Views::Assessments::StateLabels.default_for(:mastering) }
          plain ". Leave this empty to keep that word."
        end

        div(class: "flex flex-col gap-2 max-w-sm") do
          label(for: "tenant_mastering_label",
                class: "text-sm font-medium text-gray-900 dark:text-white") { "Label" }
          form.text_field(
            :mastering_label,
            id: "tenant_mastering_label",
            value: @tenant.mastering_label,
            maxlength: Tenant::STATE_LABEL_MAX_LENGTH,
            placeholder: Views::Assessments::StateLabels.default_for(:mastering),
            class: "w-full rounded-md border border-gray-300 dark:border-gray-600 " \
                   "bg-white dark:bg-gray-900 px-3 py-2 text-sm " \
                   "text-gray-900 dark:text-white focus-visible:outline-hidden " \
                   "focus-visible:ring-2 focus-visible:ring-primary"
          )
          span(class: "text-xs text-gray-600 dark:text-gray-300") do
            "Up to #{Tenant::STATE_LABEL_MAX_LENGTH} characters. It reads as a badge beside the score."
          end
        end

        preview
      end
    end
  end

  # What the word will actually look like, in the shape the hero renders it
  # — a label alone tells an admin nothing about where it lands.
  def preview
    div(class: "mt-4 rounded-lg border border-purple-300 dark:border-purple-700 " \
               "bg-gray-50/50 dark:bg-gray-800/30 p-3") do
      span(class: "text-xs font-semibold uppercase tracking-wide text-purple-700 dark:text-purple-300") do
        "#{Views::Assessments::StateLabels.for(:mastering, tenant: @tenant)} E3 · 62% of the way to E4"
      end
    end
  end

  def unchanged_note
    p(class: "text-sm text-gray-600 dark:text-gray-300") do
      "Renaming a state changes nobody's score. The thresholds each state starts at belong to " \
      "the framework, not here."
    end
  end

  def actions(form)
    div(class: "flex justify-end") do
      form.submit "Save",
        class: "px-4 py-2 rounded-md bg-primary text-white text-sm font-medium " \
               "hover:bg-secondary focus:outline-hidden focus:ring-2 focus:ring-primary " \
               "focus:ring-offset-2 cursor-pointer"
    end
  end
end
