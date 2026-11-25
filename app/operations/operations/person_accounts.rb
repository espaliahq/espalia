# frozen_string_literal: true

# Finds the accounts linked to the person an operation names. A person links
# to one account, but a link made before links were events can give them two
# (#562), so a grant refuses such a person and a removal reaches every one.
module Operations::PersonAccounts
  private

  # @return [Array<TenantUser>] every account linked to the person, oldest id first
  # @raise [Operations::Base::ParameterError] when the person has none
  def accounts!
    accounts = TenantUser.where(person_id: params[:person_id].to_s.downcase).order(:id).to_a
    raise Operations::Base::ParameterError, "person_id: that person has no account in this organisation" if accounts.empty?

    accounts
  end

  # @param right [String] what is being granted, as the refusal names it
  # @return [TenantUser] the person's only account
  # @raise [Operations::Base::ParameterError] when the person has none, or more than one
  def sole_account!(right)
    accounts = accounts!
    if accounts.many?
      raise Operations::Base::ParameterError,
            "person_id: that person has more than one account here, so #{right} can't be granted"
    end

    accounts.sole
  end
end
