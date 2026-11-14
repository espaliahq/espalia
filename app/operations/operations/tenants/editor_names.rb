# frozen_string_literal: true

# Names who last changed a tenant setting, such as a pay band or a rule default.
module Operations::Tenants::EditorNames
  private

  # The person linked to each editor in this tenant, or their email. Anyone
  # forgotten, or no longer a member, reads as a former member.
  #
  # @param records [Array<#updated_by_id>]
  # @return [Hash{String => String}] by user id
  def editor_names(records)
    ids = records.filter_map(&:updated_by_id).uniq
    members = TenantUser.where(user_id: ids, forgotten_at: nil).includes(:person, :user)
                        .to_h { [ it.user_id, it.person&.name || it.user.email ] }
    ids.to_h { [ it, members.fetch(it, Person::FORMER_MEMBER) ] }
  end
end
