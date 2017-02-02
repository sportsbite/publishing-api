module Presenters
  module Queries
    class LinkGraph
      def self.build_link_nodes(graph, node = nil)
        content_id = node ? node.content_id : graph.root_content_id
        link_type_path = node ? node.link_type_path : []
        parent_content_ids = node ? node.parent_content_ids : []
        graph.controller
          .links_by_link_type(content_id, link_type_path, parent_content_ids)
          .each_with_object({}) do |(link_type, link_content_ids), memo|
            memo[link_type] = link_content_ids.map do |link_content_id|
              LinkNode.new(link_content_id, node, graph)
            end
          end
      end

      attr_reader :root_content_id, :controller

      def initialize(root_content_id, controller)
        @root_content_id = root_content_id
        @controller = controller
      end

      def links
        @links ||= LinkGraph.build_link_nodes(self)
      end

      def link_type_of(node)
        links.find { |_, nodes| nodes.include?(node) }.try(:first)
      end

      def links_content_ids
        content_ids = links.flat_map do |_, link_collection|
          link_collection.map(&:links_content_ids).inject(&:+) + link_collection.map(&:content_id)
        end
        content_ids.uniq
      end
    end

    class LinkNode
      attr_reader :content_id, :parent, :graph

      def initialize(content_id, parent, graph)
        @content_id = content_id
        @parent = parent
        @graph = graph
      end

      def links
        @links ||= LinkGraph.build_link_nodes(graph, self)
      end

      def link_type_path
        if parent
          parent.link_type_path + [parent.link_type_of(self)]
        else
          [graph.link_type_of(self)]
        end
      end

      def link_type_of(node)
        links.find { |_, nodes| nodes.include?(node) }.try(:first)
      end

      def parent_content_ids
        parents.map(&:content_id)
      end

      def parents
        parent ? parent.parents + [parent] : []
      end

      def links_content_ids
        children = links.flat_map do |_, link_collection|
          link_collection.map(&:links_content_ids).inject(&:+) + link_collection.map(&:content_id)
        end
        children.uniq
      end
    end
  end
end
