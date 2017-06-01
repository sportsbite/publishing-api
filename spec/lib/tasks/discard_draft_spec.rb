require "rails_helper"

RSpec.describe "Discard draft rake task" do
  it "runs the process to discard a draft" do
    expect(Commands::V2::DiscardDraft).to receive(:call).with({ content_id: "content_id" })

    Rake::Task['discard_draft'].invoke("content_id")
  end
end
