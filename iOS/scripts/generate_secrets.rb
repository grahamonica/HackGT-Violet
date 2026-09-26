#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "fileutils"

input_path = ARGV.fetch(0)
output_path = ARGV.fetch(1)

allowed_keys = %w[
  OPENAI_API_KEY
  OPENAI_MODEL
  ELEVEN_LABS_API_KEY
  ELEVEN_LABS_VOICE_ID
  MONGO_DB_ENDPOINT
  MONGO_DB_API_KEY
  MONGO_RELATIONSHIPS_PATH
  MONGO_LOGS_PATH
  META_APP_ID
  META_CLIENT_TOKEN
].freeze

values = {}
if File.file?(input_path)
  File.foreach(input_path) do |line|
    stripped = line.strip
    next if stripped.empty? || stripped.start_with?("#") || !stripped.include?("=")

    key, value = stripped.split("=", 2)
    next unless allowed_keys.include?(key)

    value = value.strip
    value = value[1...-1] if value.length >= 2 && %w[' "].include?(value[0]) && value[-1] == value[0]
    values[key] = value
  end
end

values["OPENAI_MODEL"] = "gpt-4.1-mini" if values.fetch("OPENAI_MODEL", "").empty?
values["MONGO_RELATIONSHIPS_PATH"] = "relationships" if values.fetch("MONGO_RELATIONSHIPS_PATH", "").empty?
values["MONGO_LOGS_PATH"] = "logs" if values.fetch("MONGO_LOGS_PATH", "").empty?

FileUtils.mkdir_p(File.dirname(output_path))
File.write(output_path, JSON.pretty_generate(values))

