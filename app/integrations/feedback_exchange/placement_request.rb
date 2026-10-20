# frozen_string_literal: true

# Asks the people who place a report's feedback (the recorded reporting manager
# and active rating delegates) to place one imported item: which capabilities
# it speaks to and what it shows. Its link lands on the item's hub card.
#
# The author is never asked about their own feedback. A retried import does
# not ask twice: one notification per (person, item).
#
# @example
#   FeedbackExchange::PlacementRequest.new(item).deliver
class FeedbackExchange::PlacementRequest
  include PersonDevelopment::AsyncHandlers::AssessmentNotificationRecipients

  # @param item [EvidenceItem] an unplaced item imported from a peer
  def initialize(item)
    @item = item
  end

  # @return [Array<String>] the person ids asked
  def deliver
    params = presentation
    manager_side_ids_for(@item.person_id, @item.framework_id).reject { |id| id == @item.author_id }.select do |person_id|
      user = user_for(person_id)
      next false if user.nil? || already_delivered?(FeedbackPlacementNotifier, user, @item)

      FeedbackPlacementNotifier.with(record: @item, tenant_id: @item.tenant_id, **params).deliver(user)
      true
    end
  end

  private

  def presentation
    {
      author_name: @item.author&.name,
      assessee_name: Person.where(id: @item.person_id).pick(:name),
      peer_label: Reporting::OriginLabels.label(@item.external_reference&.system),
      content: @item.content,
      url: EvidenceItem.hub_path(@item.id)
    }
  end
end
