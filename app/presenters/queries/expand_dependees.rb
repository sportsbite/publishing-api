module Presenters
  module Queries
    class ExpandDependees
      def initialize(content_id, controller)
        @content_id = content_id
        @controller = controller
      end

      # FIXME: maybe move this into a new private class
      def links_by_link_type(content_id, link_types_path = [], parent_content_ids = [])
        unless link_types_path.empty?
          next_level_link_types = rules.next_level_link_types(link_types_path)
          return {} if next_level_link_types && next_level_link_types.empty?
        end

        where = { "link_sets.content_id": content_id }
        where[:link_type] = next_level_link_types if next_level_link_types
        links = Link
          .joins(:link_set)
          .where(where)
          .where.not(target_content_id: parent_content_ids)
          .order(link_type: :asc, position: :asc)
          .pluck(:link_type, :target_content_id)

        grouped = links
          .group_by(&:first)
          .map { |type, values| [type.to_sym, values.map(&:last)] }
        Hash[grouped]
      end

      def expand
        links_with_content(link_graph)
      end

    private

      attr_reader :content_id, :controller

      def web_content_items
        @web_content_items ||= controller
          .web_content_items(link_graph.links_content_ids)
          .each_with_object({}) do |content_item, memo|
            memo[content_item.content_id] = content_item
          end
      end

      def link_graph
        @link_graph ||= LinkGraph.new(content_id, self)
      end

      def links_with_content(link_source)
        link_source.links.each_with_object({}) do |(link_type, links), memo|
          links_with_content = links.map { |node| link_content(link_type, node) }.compact
          memo[link_type] = links_with_content unless links_with_content.empty?
        end
      end

      def link_content(link_type, node)
        content_item = web_content_items[node.content_id]
        return if !content_item || !should_link?(link_type, content_item)
        rules.expand_field(content_item).tap do |expanded|
          expanded.merge!(links: links_with_content(node))
        end
      end

      def should_link?(link_type, content_item)
        link_type == :parent || content_item.state != "unpublished"
      end

      def rules
        ::Queries::DependeeExpansionRules
      end
    end
  end
end
