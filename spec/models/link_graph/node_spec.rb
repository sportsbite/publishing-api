require "rails_helper"

RSpec.describe LinkGraph::Node do
  let(:content_id) { SecureRandom.uuid }
  let(:link_type) { :organisation }
  let(:parent) { nil }
  let(:link_graph) { double(:link_graph) }
  let(:node) { described_class.new(content_id, link_type, parent, link_graph) }

  describe "#link_types_path" do
    subject { node.link_types_path }
    context "has no parent" do
      let(:parent) { nil }
      it { is_expected.to match_array([link_type]) }
    end

    context "has a parent" do
      let(:parent) { described_class.new(SecureRandom.uuid, :parent, nil, link_graph) }
      it { is_expected.to match_array([:parent, link_type]) }
    end
  end

  describe "#links_content_ids" do
    subject { node.links_content_ids }
    before { allow(node).to receive(:links).and_return(links) }

    context "no links" do
      let(:links) { [] }

      it { is_expected.to be_empty }
    end

    context "with links" do
      let(:a) { SecureRandom.uuid }
      let(:b) { SecureRandom.uuid }
      let(:c) { SecureRandom.uuid }
      let(:d) { SecureRandom.uuid }

      let(:links) do
        [
          double(:link, content_id: a, links_content_ids: [b, c]),
          double(:link, content_id: d, links_content_ids: [b]),
        ]
      end

      it { is_expected.to match_array([a, b, c, d]) }
    end
  end

  describe "#to_h" do
    subject { node.to_h }
    before { allow(node).to receive(:links).and_return(links) }

    context "no links" do
      let(:links) { [] }

      it { is_expected.to match(content_id: content_id, links: {}) }
    end

    context "with links" do
      let(:a) { SecureRandom.uuid }
      let(:b) { SecureRandom.uuid }
      let(:c) { SecureRandom.uuid }

      let(:links) do
        [
          double(:link, link_type: :parent, to_h: { content_id: a, links: {} }),
          double(:link, link_type: :organisation, to_h: { content_id: b, links: {} }),
          double(:link, link_type: :organisation, to_h: { content_id: c, links: {} }),
        ]
      end

      let(:expected) do
        {
          content_id: content_id,
          links: {
            parent: [{ content_id: a, links: {} }],
            organisation: [
              { content_id: b, links: {} },
              { content_id: c, links: {} },
            ],
          }
        }
      end

      it { is_expected.to match(expected) }
    end
  end
end