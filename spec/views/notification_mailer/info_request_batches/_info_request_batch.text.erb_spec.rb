require 'spec_helper'

RSpec.describe(
  "notification_mailer/info_request_batches/_info_request_batch") do
  let!(:public_body_1) { FactoryBot.create(:public_body) }
  let!(:public_body_2) { FactoryBot.create(:public_body) }
  let!(:batch_request) do
    batch = FactoryBot.create(:info_request_batch,
                              public_bodies: [public_body_1, public_body_2])
    batch.create_batch!
    batch
  end
  let!(:batch_requests) { batch_request.info_requests.order(:created_at) }
  let!(:incoming_1) do
    FactoryBot.create(:incoming_message, info_request: batch_requests.first)
  end
  let!(:incoming_2) do
    FactoryBot.create(:incoming_message, info_request: batch_requests.second)
  end
  let!(:batch_notifications) do
    notifications = []

    event_1 = FactoryBot.create(:response_event,
                                incoming_message: incoming_1)
    notification_1 = FactoryBot.create(:daily_notification,
                                       info_request_event: event_1)
    notifications << notification_1

    event_2 = FactoryBot.create(:response_event,
                                incoming_message: incoming_2)
    notification_2 = FactoryBot.create(:daily_notification,
                                       info_request_event: event_2)
    notifications << notification_2

    notifications
  end
  let(:template) do
    "notification_mailer/info_request_batches/info_request_batch"
  end

  before do
    render partial: template,
           formats: [:text],
           locals: { info_request_batch: batch_request,
                     notifications: batch_notifications }
  end

  it "renders the authority list partial" do
    expected_partial = "alaveteli_pro/info_request_batches/authority_list"
    expected_locals = { public_bodies: [public_body_1, public_body_2] }
    expect(response).
      to render_template(partial: expected_partial, locals: expected_locals)
  end

  it "renders the progress bar partial" do
    expected_partial = "alaveteli_pro/info_request_batches/progress_bar"
    expected_locals = { phases: batch_request.request_phases_summary,
                        batch: batch_request }
    expect(response).
      to render_template(partial: expected_partial, locals: expected_locals)
  end

  it "renders the notification partial for each event type" do
    expected_partial =
      "notification_mailer/info_request_batches/messages/response"
    expected_locals = { notifications: batch_notifications,
                        info_request_batch: batch_request }
    expect(response).
      to render_template(partial: expected_partial, locals: expected_locals)
  end
end
