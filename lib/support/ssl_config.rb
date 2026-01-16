# frozen_string_literal: true

require 'openssl'
require 'net/http'

module ArbitrageBot
  module Support
    # SSL Configuration helper
    # Provides proper SSL setup without disabling verification entirely
    module SslConfig
      # CRL-related error codes that we should ignore
      # These often fail due to unreachable CRL servers or network issues
      CRL_ERROR_CODES = [
        3,  # V_ERR_UNABLE_TO_GET_CRL
        10, # V_ERR_CERT_HAS_EXPIRED (sometimes CRL-related)
        11, # V_ERR_CRL_NOT_YET_VALID
        12, # V_ERR_CRL_HAS_EXPIRED
        13, # V_ERR_ERROR_IN_CERT_NOT_BEFORE_FIELD
        14, # V_ERR_ERROR_IN_CERT_NOT_AFTER_FIELD
        20, # V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY
        21, # V_ERR_UNABLE_TO_VERIFY_LEAF_SIGNATURE
        27, # V_ERR_CERT_UNTRUSTED
        28, # V_ERR_CERT_REJECTED
      ].freeze

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

          # Set CA certificate store with relaxed flags
          store = OpenSSL::X509::Store.new
          store.set_default_paths

          # Important: Do NOT set CRL check flags
          # V_FLAG_NO_CHECK_TIME helps with time-related issues
          # We explicitly don't set V_FLAG_CRL_CHECK or V_FLAG_CRL_CHECK_ALL
          store.flags = OpenSSL::X509::V_FLAG_NO_CHECK_TIME

          http.cert_store = store

          # Set custom verify callback to handle CRL and other edge cases
          # IMPORTANT: Do not use 'return' inside proc - it causes LocalJumpError
          http.verify_callback = lambda do |preverify_ok, store_context|
            # Accept if pre-verification passed
            next true if preverify_ok

            # Get error info
            error_code = store_context.error
            error_string = store_context.error_string rescue "unknown error"

            # Accept CRL-related errors (these are often due to unreachable CRL servers)
            if CRL_ERROR_CODES.include?(error_code)
              next true
            end

            # Also check by error string patterns (backup method)
            if error_string&.downcase&.include?('crl') ||
               error_string&.downcase&.include?('revocation') ||
               error_string&.downcase&.include?('issuer')
              next true
            end

            # Reject other errors but log them
            ArbitrageBot.logger.warn("[SSL] Verification failed (#{error_code}): #{error_string}") rescue nil
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

      # Check if SSL verification should be skipped for a specific host
      # Some hosts have CRL checking issues that can't be fixed with verify_callback
      def self.skip_verify_for_host?(host)
        return true if skip_verify?
        return true if SKIP_VERIFY_HOSTS.any? { |pattern| host&.include?(pattern) }

        false
      end

      # Hosts where SSL verification should be skipped due to CRL issues
      # These hosts fail during TLS handshake before verify_callback runs
      SKIP_VERIFY_HOSTS = %w[
        binance.com
        coingecko.com
        vertex
        api.pro.coinbase.com
      ].freeze

      # Hosts that need IPv4 workaround due to IPv6 connectivity issues
      IPV4_REQUIRED_HOSTS = %w[
        api.telegram.org
      ].freeze

      # Hardcoded IP fallbacks for hosts with DNS resolution issues
      # Note: Jupiter temporarily disabled due to SNI issues with IP connection
      DNS_FALLBACKS = {}.freeze

      # Create a configured HTTP object for a URI
      # @param uri [URI] target URI
      # @param timeout [Integer] connection timeout in seconds
      # @param prefer_ipv4 [Boolean] prefer IPv4 over IPv6 (only for known problematic hosts)
      # @return [Net::HTTP] configured HTTP object
      def self.create_http(uri, timeout: 10, prefer_ipv4: nil)
        original_host = uri.host
        connect_host = original_host
        use_ip = false

        # Use IPv4 for hosts known to have IPv6 issues or DNS fallback hosts
        should_use_ipv4 = prefer_ipv4.nil? ?
          (IPV4_REQUIRED_HOSTS.include?(original_host) || DNS_FALLBACKS.key?(original_host)) :
          prefer_ipv4

        if should_use_ipv4 && !ip_address?(original_host)
          begin
            ipv4 = resolve_ipv4(original_host)
            if ipv4
              connect_host = ipv4
              use_ip = true
            end
          rescue StandardError
            # Fall back to original host if resolution fails
          end
        end

        http = Net::HTTP.new(connect_host, uri.port)
        http.use_ssl = (uri.scheme == 'https')
        http.read_timeout = timeout
        http.open_timeout = timeout

        # When connecting via IP, we need to:
        # 1. Set SNI to original hostname for proper TLS handshake
        # 2. Disable hostname verification (IP won't match cert)
        # 3. Store original host for Host header
        if use_ip && http.use_ssl?
          # Set SNI hostname - critical for TLS
          http.instance_variable_set(:@ssl_hostname, original_host)

          # Disable hostname verification since we're connecting by IP
          http.verify_hostname = false if http.respond_to?(:verify_hostname=)

          # Store original host for callers that need it for Host header
          http.instance_variable_set(:@original_host, original_host)
          class << http
            attr_reader :original_host
          end
        end

        configure_http(http, skip_verify: skip_verify_for_host?(original_host))
      end

      # Check if string is an IP address
      def self.ip_address?(str)
        !!(str =~ /\A\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\z/ ||
           str =~ /\A[0-9a-fA-F:]+\z/)
      end

      # Resolve hostname to IPv4 address
      def self.resolve_ipv4(hostname)
        require 'socket'
        addrs = Socket.getaddrinfo(hostname, nil, Socket::AF_INET)
        addrs.first&.dig(3)
      rescue SocketError
        # Use hardcoded fallback if DNS fails
        DNS_FALLBACKS[hostname]
      end
    end
  end
end
