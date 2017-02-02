module Queries
  module ExpansionRules
    extend self

    def expansion_fields(link_type)
      custom_fields(link_type) || default_fields
    end

    def expand_field(web_content_item)
      web_content_item.to_h.slice(*expansion_fields(web_content_item.document_type.to_sym))
    end

  private

    def next_level_recursive_types(link_path)
      level = link_path.length - 1
      last = link_path.last.to_sym
      # FIXME - this lets through some instances we should not:
      # [57] pry(main)> Queries::DependeeExpansionRules.next_level_link_types(["ordered_related_items", "mainstream_browse_pages", "blah", "parent", "parent"])
      # => [:parent]
      allowed = recursive_link_types.each_with_object([]) do |type, next_allowed|
        if type[level] == last
          next_allowed << (type[level + 1] || type[-1])
        elsif type[-1] == last
          next_allowed << type[-1]
        end
      end
      allowed.uniq
    end

    def customi_fields(link_type)
      {}[link_type]
    end

    def default_fields
      [
        :analytics_identifier,
        :api_path,
        :base_path,
        :content_id,
        :description,
        :document_type,
        :locale,
        :public_updated_at,
        :schema_name,
        :title,
        :withdrawn,
      ]
    end
  end
end
