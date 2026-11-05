# frozen_string_literal: true

# Returns the top-level structure of one framework — role families with
# their roles, and capability categories with their capabilities (id +
# name + stable_id). Read-only; scoped by acts_as_tenant and
# FrameworkPolicy#show?.
#
# Disclosure depth: one level beyond the children (roles inside families,
# capabilities inside categories). No inline expectations, illustrations,
# or bindings — those live behind `framework_capability_get`. Keeps the
# payload bounded (~5-15 KB for a real framework) while giving the LLM
# enough to choose what to drill into next.
class Operations::Frameworks::Get < Operations::Base
  description "Fetch one framework's top-level structure (role families, categories, child IDs and names) " \
              "and every published version, newest first, with when and by whom it was published."
  category :read
  approval :none

  parameter :framework_id, String, required: true

  def policy_check
    authorize framework, :show?
  end

  # @return [Hash] as defined by {Mcp::FrameworkSerializer.framework}.
  def perform
    Mcp::FrameworkSerializer.framework(framework)
  end

  private

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
