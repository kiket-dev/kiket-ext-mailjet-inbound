# frozen_string_literal: true

require_relative 'app'

extension = MailjetInboundExtension.new
run extension.app
