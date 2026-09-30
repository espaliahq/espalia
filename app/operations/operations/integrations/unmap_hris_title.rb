# frozen_string_literal: true

# Remove one HRIS job title from the role mappings (#436).
#
# The next sync then skips people holding the title. It does not unassign
# them — they keep their current assignment, which the result lists.
class Operations::Integrations::UnmapHrisTitle < Operations::Base
  include Operations::Integrations::HrisTitlePreview

  description "Remove an HRIS job title from the role mappings. The next sync skips people holding " \
              "it, and they keep their current framework assignment (listed in the result)."
  category :write
  approval :in_app

  parameter :title, String, required: true, allow_blank: false

  def policy_check
    authorize :integrations, :update_role_mappings?
  end

  # @return [Hash] the title and the people who now hold an unmapped title
  def perform
    title = params[:title].strip
    tenant = ActsAsTenant.current_tenant

    save_hris_config!(tenant) do |config|
      raise ParameterError, "title: '#{title}' is not mapped" if config.mapping_for(title).nil?

      config.unmap_title(title)
    end

    { title: title, people: people_payload(rows_for_title(tenant, title)) }
  end
end
