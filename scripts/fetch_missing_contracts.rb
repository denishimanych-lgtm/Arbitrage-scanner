#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../config/application'
ArbitrageBot.load!

MISSING = %w[
  AIXBT ARCSOL ARK ATH BEAMX BEL BERA BLAST BOB BROCCOLI CATI CETUS CHZ
  COS DEEP DGB DOGS DUSK DYDX DYM EPT ETHW FLR FOGO GRASS HIPPO HIVE
  HMSTR HYPE IKA INIT IP JST KAIA KNC MAGMA MANA MANTA MMT MTL NEIROCTO
  NIL NMR NOT NS NTRN OG ORDER PI PIEVERSE PNUT POLYX RON RONIN RVN SATS
  SCR SOLAYER STEEM STRAX SUN SUNDOG SUPRA SYS TAO TNSR VELODROME VTHO
  WAL XCH XEC XVG ZRC ACTSOL ARIA ASR BOBBOB BROCCOLIF3B BROCCOLI714
  BSV COAI DMC EUR FIO HPOS10I MONAD PUMPFUN QUBIC REDSTONE TSTBSC US
]

puts "Fetching contracts for #{MISSING.size} symbols..."
puts ""

fetcher = ArbitrageBot::Services::ContractFetcher.new

unless fetcher.configured?
  puts "ERROR: No API keys configured"
  exit 1
end

found = 0
MISSING.each_with_index do |symbol, idx|
  # Check if already cached
  cached = ArbitrageBot.redis.hget('contracts:cache', symbol)
  if cached && cached != "{}"
    parsed = JSON.parse(cached) rescue {}
    if parsed.any?
      puts "  #{symbol}: already cached (#{parsed.keys.join(', ')})"
      found += 1
      next
    end
  end

  # Fetch from API (bypasses cache)
  begin
    # Clear cache to force fresh fetch
    ArbitrageBot.redis.hdel('contracts:cache', symbol)

    contracts = fetcher.fetch(symbol)

    if contracts && contracts.any?
      puts "  #{symbol}: FOUND (#{contracts.keys.join(', ')})"
      found += 1
    else
      puts "  #{symbol}: not found"
    end
  rescue => e
    puts "  #{symbol}: ERROR - #{e.message}"
  end

  # Progress
  if (idx + 1) % 20 == 0
    puts "--- Progress: #{idx + 1}/#{MISSING.size} (found: #{found}) ---"
  end

  # Small delay to avoid rate limits
  sleep 0.1
end

puts ""
puts "=== Complete: found #{found}/#{MISSING.size} ==="
