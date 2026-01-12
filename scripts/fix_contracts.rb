#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'redis'

redis = Redis.new

# Get current contracts
contracts_raw = redis.hgetall("contracts:cache")
existing = {}
contracts_raw.each do |k, v|
  next if v.nil? || v == "{}"
  parsed = JSON.parse(v) rescue {}
  existing[k] = parsed if parsed.any?
end

puts "=== Current contracts: #{existing.size} ==="
puts ""

# Multiplied tokens mapping
multiplied_map = {
  "1000BONK" => "BONK",
  "1000PEPE" => "PEPE",
  "1000FLOKI" => "FLOKI",
  "1000SHIB" => "SHIB",
  "1000LUNC" => "LUNC",
  "1000SATS" => "SATS",
  "10000SATS" => "SATS",
  "1000RATS" => "RATS",
  "1000CAT" => "CAT",
  "1000BTT" => "BTT",
  "1000XEC" => "XEC",
  "1000CHEEMS" => "CHEEMS",
  "1000000MOG" => "MOG",
  "1000000BABYDOGE" => "BABYDOGE",
  "1MBABYDOGE" => "BABYDOGE"
}

# Copy contracts from base tokens
puts "=== Mapping multiplied tokens ==="
added = 0
multiplied_map.each do |mult, base|
  next if existing[mult]
  if existing[base]
    redis.hset("contracts:cache", mult, existing[base].to_json)
    puts "  #{mult} <- #{base}: #{existing[base].keys.join(', ')}"
    added += 1
  else
    puts "  #{mult}: missing base #{base}"
  end
end

puts ""
puts "Added #{added} multiplied token contracts"
puts ""

# Now let's check what's still missing and could be fetched
all_symbols = redis.smembers("tickers:all_symbols") || []
contracts_raw = redis.hgetall("contracts:cache")
with_contracts = []
contracts_raw.each do |k, v|
  next if v.nil? || v == "{}"
  parsed = JSON.parse(v) rescue {}
  with_contracts << k if parsed.any?
end

missing = all_symbols - with_contracts

# Native chains that don't have wrapped tokens
native_chains = %w[KAS XTZ ZEC ALGO ATOM DOT XRP XLM ADA SOL BTC ETH BNB TRX AVAX NEAR HBAR FIL ICP XMR DASH LTC BCH ETC DOGE TON SUI APT SEI INJ OSMO KAVA LUNA LUNA2 ROSE SCRT CELO GLMR ASTR CKB CSPR FLOW EGLD ONE QTUM IOTA XDC VET ICX ZIL ONT NEO GAS WAVES SC AR TFUEL THETA STX MINA XNO FLUX KSM MOVR RUNE]

fetchable = missing.reject { |s| native_chains.include?(s) || s.match?(/^1000|^10000|^1000000/) }

puts "=== Still missing (fetchable): #{fetchable.size} ==="
puts fetchable.sort.join(", ")
