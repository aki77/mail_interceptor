# frozen_string_literal: true

require "active_support"
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/array'
require 'action_mailer'
require 'mail_interceptor/version'

module MailInterceptor
  mattr_accessor :enable_zerobounce_validation
  @@enable_zerobounce_validation = false

  def self.configure
    yield self
  end

  class Interceptor
    attr_accessor :deliver_emails_to, :forward_emails_to, :intercept_emails, :env, :recipients, :ignore_cc, :ignore_bcc

    def initialize(options = {})
      @deliver_emails_to = Array.wrap options[:deliver_emails_to]
      @forward_emails_to = Array.wrap options[:forward_emails_to]
      @intercept_emails  = options.fetch :only_intercept, []
      @ignore_cc         = options.fetch :ignore_cc, false
      @ignore_bcc        = options.fetch :ignore_bcc, false
      @env               = options.fetch :env, InterceptorEnv.new
      @recipients        = []
    end

    def delivering_email(message)
      @recipients = Array.wrap(message.to)
      to_emails_list = normalize_recipients

      to_emails_list = to_emails_list.filter { |email| zerobounce_validate_email(email) } if zerobounce_enabled?

      message.perform_deliveries = to_emails_list.present?
      message.to  = to_emails_list
      message.cc  = [] if ignore_cc
      message.bcc = [] if ignore_bcc
    end

    private

    def zerobounce_enabled?
      MailInterceptor.enable_zerobounce_validation && Zerobounce.configuration.apikey.present?
    end

    def normalize_recipients
      return recipients unless env.intercept?

      normalized_recipients = [*filter_by_intercept_emails, *filter_by_deliver_emails_to]
      forward_recipients = forward_recipients_by_normalized_recipients(normalized_recipients)

      [normalized_recipients, forward_recipients].flatten.uniq.reject(&:blank?)
    end

    def filter_by_intercept_emails
      return [] if intercept_emails.blank?

      recipients.select do |recipient|
        intercept_emails.none? { |regex| Regexp.new(regex, Regexp::IGNORECASE).match(recipient) }
      end
    end

    def filter_by_deliver_emails_to
      return [] if (deliver_emails_to.empty? && intercept_emails.empty?) || intercept_emails.present?

      recipients.select do |recipient|
        deliver_emails_to.any? { |regex| Regexp.new(regex, Regexp::IGNORECASE).match(recipient) }
      end
    end

    def forward_recipients_by_normalized_recipients(normalized_recipients)
      intercepted_recipients = recipients - normalized_recipients
      return [] if intercepted_recipients.empty?

      forward_emails_to.map { |email| ActionMailer::Base.email_address_with_name(email, "Orig to: #{intercepted_recipients.join(',').truncate(100)}") }
    end

    def zerobounce_validate_email(email)
      return true if email.end_with? "privaterelay.appleid.com"
      is_email_valid = Zerobounce.validate(email: email).valid?
      print "Zerobounce validation for #{email} is #{is_email_valid ? 'valid' : 'invalid'}\n"
      is_email_valid
    end
  end

  class InterceptorEnv
    def name
      Rails.env.upcase
    end

    def intercept?
      !Rails.env.production?
    end
  end

  require 'mail_interceptor/railtie' if defined?(Rails) && Rails::VERSION::MAJOR >= 3
end
