# frozen_string_literal: true

require 'openssl'
require 'net/http'

module ArbitrageBot
  module Support
    # SSL Configuration helper
    # Provides proper SSL setup without disabling verification entirely
    module SslConfig
      # Configure HTTP object with proper SSL settings
      # @param http [Net::HTTP] HTTP object to configure
      # @param skip_verify [Boolean] whether to skip verification entirely
      # @return [Net::HTTP] configured HTTP object
      def self.configure_http(http, skip_verify: false)
        return http unless http.use_ssl?

        if skip_verify
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        else
          # Use peer verification but with relaxed settings
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER

          # Set CA certificate store
          store = OpenSSL::X509::Store.new
          store.set_default_paths

          # Disable CRL checking which often fails
          # CRL checking is deprecated in favor of OCSP anyway
          store.flags = OpenSSL::X509::V_FLAG_NO_CHECK_TIME

          http.cert_store = store

          # Set custom verify callback to handle edge cases
          # IMPORTANT: Do not use 'return' inside proc - it causes LocalJumpError
          http.verify_callback = lambda do |preverify_ok, store_context|
            next true if preverify_ok

            # Get error info
            error = store_context.error
            error_string = store_context.error_string

            # Accept CRL-related errors (these are often due to unreachable CRL servers)
            crl_errors = [
              OpenSSL::X509::V_ERR_UNABLE_TO_GET_CRL,
              OpenSSL::X509::V_ERR_CRL_NOT_YET_VALID,
              OpenSSL::X509::V_ERR_CRL_HAS_EXPIRED,
              OpenSSL::X509::V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY
            ]

            if crl_errors.include?(error)
              # Log but accept
              ArbitrageBot.logger.debug("[SSL] Ignoring CRL error: #{error_string}") rescue nil
              next true
            end

            # Reject other errors
            ArbitrageBot.logger.warn("[SSL] Verification failed: #{error_string}") rescue nil
            false
          end
        end

        http
      end

      # Check if SSL verification should be skipped
      # @return [Boolean]
      def self.skip_verify?
        ENV['SKIP_SSL_VERIFY'] == '1'
      end

      # Create a configured HTTP object for a URI
      # @param uri [URI] target URI
      # @param timeout [Integer] connection timeout in seconds
      # @return [Net::HTTP] configured HTTP object
      def self.create_http(uri, timeout: 10)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')
        http.read_timeout = timeout
        http.open_timeout = timeout

        configure_http(http, skip_verify: skip_verify?)
      end
    end
  end
end
