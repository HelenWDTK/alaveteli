class AdminOutgoingMessageController < AdminController

  before_action :set_outgoing_message, :only => [:edit, :destroy, :update, :resend]
  before_action :set_info_request, :check_info_request
  before_action :set_is_initial_message, :only => [:edit, :destroy]

  def edit
  end

  def destroy
    if !@is_initial_message && @outgoing_message.destroy
      @outgoing_message.info_request.log_event(
        'destroy_outgoing',
        editor: admin_current_user,
        deleted_outgoing_message_id: @outgoing_message.id
      )

      flash[:notice] = 'Outgoing message successfully destroyed.'
      redirect_to admin_request_url(@outgoing_message.info_request)
    else
      flash[:error] = 'Could not destroy the outgoing message.'
      redirect_to edit_admin_outgoing_message_path(@outgoing_message)
    end
  end

  def update
    old_body = @outgoing_message.raw_body
    old_prominence = @outgoing_message.prominence
    old_prominence_reason = @outgoing_message.prominence_reason
    old_tag_string = @outgoing_message.tag_string
    if @outgoing_message.update(outgoing_message_params)
      @outgoing_message.info_request.log_event(
        'edit_outgoing',
        outgoing_message_id: @outgoing_message.id,
        editor: admin_current_user,
        old_body: old_body,
        body: @outgoing_message.raw_body,
        old_prominence: old_prominence,
        prominence: @outgoing_message.prominence,
        old_prominence_reason: old_prominence_reason,
        prominence_reason: @outgoing_message.prominence_reason,
        old_tag_string: old_tag_string,
        tag_string: @outgoing_message.tag_string
      )
      flash[:notice] = 'Outgoing message successfully updated.'
      @outgoing_message.info_request.expire
      redirect_to admin_request_url(@outgoing_message.info_request)
    else
      render :action => 'edit'
    end
  end

  def resend
    @outgoing_message.prepare_message_for_resend

    mail_message = case @outgoing_message.message_type
    when 'initial_request'
      OutgoingMailer.initial_request(
        @outgoing_message.info_request,
        @outgoing_message
      ).deliver_now
    when 'followup'
      OutgoingMailer.followup(
        @outgoing_message.info_request,
        @outgoing_message,
        @outgoing_message.incoming_message_followup
      ).deliver_now
    else
      raise "Message id #{id} has type '#{message_type}' which cannot be resent"
    end

    @outgoing_message.record_email_delivery(
      mail_message.to_addrs.join(', '),
      mail_message.message_id,
      'resent'
    )
    @outgoing_message.info_request.reopen_to_new_responses

    flash[:notice] = "Outgoing message resent"
    redirect_to admin_request_url(@outgoing_message.info_request)
  end

  private

  def outgoing_message_params
    if params[:outgoing_message]
      params.require(:outgoing_message).
        permit(:prominence, :prominence_reason, :body, :tag_string)
    else
      {}
    end
  end

  def set_outgoing_message
    @outgoing_message = OutgoingMessage.find(params[:id])
  end

  def set_info_request
    @info_request = @outgoing_message.info_request
  end

  def check_info_request
    return if can? :admin, @info_request

    raise ActiveRecord::RecordNotFound
  end

  def set_is_initial_message
    @is_initial_message = @outgoing_message == last_event_message
  end

  def last_event_message
    @outgoing_message.
      info_request.
        last_event_forming_initial_request.
          try(:outgoing_message)
  end
end
