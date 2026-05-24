# frozen_string_literal: true

# MCP resources surface — addressable read-only entities the LLM can pin
# to context once and reference repeatedly. Complements the tool surface
# (which is action-shaped) with stable URIs that resolve to the same
# JSON payloads the corresponding tools return:
#
#   framework://<framework_id>   → Operations::Frameworks::Get
#   assessment://<assignment_id> → Operations::Assessments::Get
#
# `list` enumerates the resources the calling context can see (subject
# to acts_as_tenant + Pundit). `read` parses the URI and dispatches to
# the underlying Operation — so a resource is exactly the tool's payload,
# no schema duplication. Pundit denial inside an Operation maps to
# JSON-RPC -32603 by the request handler.
class Mcp::ResourceRegistry
  FRAMEWORK_PREFIX  = "framework://"
  ASSESSMENT_PREFIX = "assessment://"
  private_constant :FRAMEWORK_PREFIX, :ASSESSMENT_PREFIX

  class << self
    # @param context [AuthorizationContext]
    # @return [Array<Hash>] MCP resource descriptors
    def list(context:)
      frameworks(context) + assessments(context)
    end

    # @param uri [String]
    # @param context [AuthorizationContext]
    # @return [Hash] same payload as the matching Operation
    # @raise [Mcp::RequestHandler::MethodNotFound] for unrecognised URI shapes
    def read(uri:, context:)
      case uri
      when /\A#{Regexp.escape(FRAMEWORK_PREFIX)}(?<id>[^?#]+)/o
        Operations::Frameworks::Get.call(context: context, params: { framework_id: Regexp.last_match[:id] })
      when /\A#{Regexp.escape(ASSESSMENT_PREFIX)}(?<id>[^?#]+)/o
        Operations::Assessments::Get.call(context: context, params: { assignment_id: Regexp.last_match[:id] })
      else
        raise Mcp::RequestHandler::MethodNotFound, "unknown resource uri: #{uri}"
      end
    end

    private

    def frameworks(context)
      # Mirror Operations::Frameworks::List authorization so the resource
      # surface can't be a Pundit bypass for the equivalent tool.
      return [] unless FrameworkPolicy.new(context, FrameworkState::Framework).index?

      FrameworkState::Framework.all.order(:name).map do |fw|
        {
          uri: "#{FRAMEWORK_PREFIX}#{fw.framework_id}",
          name: fw.name,
          description: "Framework v#{fw.current_published_version}",
          mimeType: "application/json"
        }
      end
    end

    def assessments(context)
      return [] if context.person.nil?

      assignments = own_and_reports(context)
      # Single query for every report person referenced below — avoids
      # an N+1 when iterating assignments to build display names.
      report_person_ids = assignments
        .reject { |a| a.person_id == context.person.id }
        .map(&:person_id).uniq
      report_people = report_person_ids.empty? ? {} : Person.where(id: report_person_ids).index_by(&:id)

      assignments.map do |a|
        {
          uri: "#{ASSESSMENT_PREFIX}#{a.id}",
          name: assessment_name(a, context, report_people),
          description: "Assessment on #{a.framework&.name}",
          mimeType: "application/json"
        }
      end
    end

    def own_and_reports(context)
      own = PersonFrameworkAssignment.for_person(context.person.id).includes(:framework).to_a
      report_ids = context.person.direct_reports.pluck(:id)
      reports = report_ids.empty? ? [] : PersonFrameworkAssignment.where(person_id: report_ids).includes(:framework).to_a
      own + reports
    end

    def assessment_name(assignment, context, report_people)
      if assignment.person_id == context.person.id
        "My assessment — #{assignment.framework&.name}"
      else
        person = report_people[assignment.person_id]
        "#{person&.name || 'Direct report'} — #{assignment.framework&.name}"
      end
    end
  end
end
