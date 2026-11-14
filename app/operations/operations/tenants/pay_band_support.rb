# frozen_string_literal: true

# What the pay band tools share: the admin-only check, reading a figure, and
# the payload each returns. A refusal never repeats a figure, so a band can't
# reach a log through an error message.
module Operations::Tenants::PayBandSupport
  FIGURE = /\A\d{1,12}(\.\d{1,2})?\z/
  FIGURE_SCHEMA = { type: "string", pattern: FIGURE.source.sub("\\A", "^").sub("\\z", "$") }.freeze
  FIGURE_HELP = "Figures are decimal strings with at most two decimal places, such as \"120000\"."

  # @raise [Pundit::NotAuthorizedError] unless the caller is a tenant admin
  def policy_check
    authorize ActsAsTenant.current_tenant, :manage_pay_bands?, policy_class: TenantPolicy
  end

  private

  # @return [Hash{Symbol => BigDecimal}] minimum, midpoint and maximum
  def figures
    PayBand::FIGURES.index_with do |name|
      value = params[name].to_s.strip
      raise Operations::Base::ParameterError, "#{name} must be a number with at most two decimal places" unless value.match?(FIGURE)

      BigDecimal(value)
    end
  end

  # @param record [PayBand, ExchangeRate, ReferenceCurrency]
  # @raise [Operations::Base::ParameterError] naming what is wrong, never a figure or a rate
  def save_setting!(record)
    record.updated_by = context.user
    return record if record.save

    raise Operations::Base::ParameterError, record.errors.full_messages.to_sentence
  rescue ActiveRecord::RecordNotUnique
    raise Operations::Base::ParameterError, record.try(:duplicate_message) || "Someone else set it at the same moment; try again"
  end

  # Names a band by its level as the framework has it now, or as it was
  # when the level left.
  #
  # @param band [PayBand]
  # @param level [FrameworkState::Level, nil]
  # @param role [FrameworkState::Role, nil]
  # @return [Hash]
  def band_payload(band, level = FrameworkState::Level.find_by(level_id: band.level_id),
                   role = level && FrameworkState::Role.find_by(role_id: level.role_id), names: editor_names([ band ]))
    band.take_names_from(level, role) if level
    {
      pay_band_id: band.id,
      level_id: band.level_id,
      role_id: level&.role_id,
      role: band.role_name,
      level_name: band.level_name,
      level: band.level_label,
      in_framework: level.present?,
      location: band.location.presence,
      currency: band.currency,
      period: band.period,
      **PayBand::FIGURES.to_h { [ it, band.figure(it) ] },
      updated_at: band.updated_at.iso8601,
      updated_by: names[band.updated_by_id]
    }
  end

  # Who last changed each band: the person linked to them in this tenant, or their email.
  # Anyone forgotten, or no longer a member, reads as a former member.
  #
  # @param bands [Array<PayBand>]
  # @return [Hash{String => String}] by user id
  def editor_names(bands)
    ids = bands.filter_map(&:updated_by_id).uniq
    members = TenantUser.where(user_id: ids, forgotten_at: nil).includes(:person, :user)
                        .to_h { [ it.user_id, it.person&.name || it.user.email ] }
    ids.to_h { [ it, members.fetch(it, Person::FORMER_MEMBER) ] }
  end

  # @param pay_band_id [String]
  # @return [PayBand]
  # @raise [Operations::Base::ParameterError] when the tenant has no such band
  def find_band(pay_band_id)
    PayBand.find_by(id: pay_band_id.to_s) || raise(Operations::Base::ParameterError, "There is no such pay band")
  end
end
