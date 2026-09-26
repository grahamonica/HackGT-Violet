#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "fileutils"
require "timeout"

input_path = ARGV.fetch(0)
output_path = ARGV.fetch(1)

allowed_keys = %w[
  ELEVEN_LABS_API_KEY
  ELEVEN_LABS_VOICE_ID
  MONGO_URI
  MONGO_DB_NAME
  MONGO_RELATIONSHIPS_PATH
  MONGO_LOGS_PATH
  AWS_REKOGNITION_ACCESS_KEY_ID
  AWS_REKOGNITION_SECRET_ACCESS_KEY
  AWS_REKOGNITION_REGION
  AWS_REKOGNITION_COLLECTION_ID
].freeze

values = {}
begin
  Timeout.timeout(10) do
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
  end
rescue Timeout::Error
  abort "Could not read #{input_path}. If it is stored in iCloud, choose Download Now in Finder and rebuild."
end

values["MONGO_DB_NAME"] = "violet" if values.fetch("MONGO_DB_NAME", "").empty?
values["MONGO_RELATIONSHIPS_PATH"] = "relationships" if values.fetch("MONGO_RELATIONSHIPS_PATH", "").empty?
values["MONGO_LOGS_PATH"] = "logs" if values.fetch("MONGO_LOGS_PATH", "").empty?

required_keys = %w[
  ELEVEN_LABS_API_KEY
  ELEVEN_LABS_VOICE_ID
  MONGO_URI
  AWS_REKOGNITION_ACCESS_KEY_ID
  AWS_REKOGNITION_SECRET_ACCESS_KEY
  AWS_REKOGNITION_REGION
  AWS_REKOGNITION_COLLECTION_ID
]
missing_keys = required_keys.select { |key| values.fetch(key, "").empty? }
abort "Missing required .env keys: #{missing_keys.join(", ")}" unless missing_keys.empty?

FileUtils.mkdir_p(File.dirname(output_path))
File.write(output_path, JSON.pretty_generate(values))
