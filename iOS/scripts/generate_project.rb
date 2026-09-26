#!/usr/bin/env ruby
# frozen_string_literal: true

require "xcodeproj"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
PROJECT_PATH = File.join(ROOT, "Violet.xcodeproj")
FileUtils.rm_rf(PROJECT_PATH)

project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes["LastSwiftUpdateCheck"] = "2660"
project.root_object.attributes["LastUpgradeCheck"] = "2660"

app_target = project.new_target(:application, "Violet", :ios, "17.2")
test_target = project.new_target(:unit_test_bundle, "VioletTests", :ios, "17.2")

app_group = project.main_group.new_group("Violet", "Violet")
test_group = project.main_group.new_group("VioletTests", "VioletTests")

source_files = Dir.glob(File.join(ROOT, "Violet", "**", "*.swift")).sort
source_refs = source_files.map do |path|
  relative = path.delete_prefix(File.join(ROOT, "Violet") + "/")
  app_group.new_file(relative)
end
app_target.add_file_references(source_refs)

resource_paths = [
  File.join(ROOT, "Violet", "Assets.xcassets"),
  *Dir.glob(File.join(ROOT, "Violet", "Resources", "*.ttf")).sort
]
resource_refs = resource_paths.select { |path| File.exist?(path) }.map do |path|
  relative = path.delete_prefix(File.join(ROOT, "Violet") + "/")
  app_group.new_file(relative)
end
resource_refs.each { |reference| app_target.resources_build_phase.add_file_reference(reference) }

test_files = Dir.glob(File.join(ROOT, "VioletTests", "**", "*.swift")).sort
test_refs = test_files.map do |path|
  relative = path.delete_prefix(File.join(ROOT, "VioletTests") + "/")
  test_group.new_file(relative)
end
test_target.add_file_references(test_refs)
logic_refs = source_refs.select do |reference|
  %w[FrameSelector.swift WakeWordDetector.swift].include?(File.basename(reference.path))
end
test_target.add_file_references(logic_refs)

{
  "https://github.com/facebook/meta-wearables-dat-ios" => ["1.0.0", %w[MWDATCore MWDATCamera MWDATSpeech]],
  "https://github.com/orlandos-nl/MongoKitten" => ["7.16.3", %w[MongoKitten]],
  # MongoKitten supports iOS 13, but DNSClient 2.6.1+ requires iOS 16; pin the last compatible release.
  "https://github.com/orlandos-nl/DNSClient" => ["2.6.0", []]
}.each do |repository_url, (version, product_names)|
  package_ref = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  package_ref.repositoryURL = repository_url
  package_ref.requirement = { "kind" => "exactVersion", "version" => version }
  project.root_object.package_references << package_ref

  product_names.each do |product_name|
    dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    dependency.package = package_ref
    dependency.product_name = product_name
    app_target.package_product_dependencies << dependency
    build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    build_file.product_ref = dependency
    app_target.frameworks_build_phase.files << build_file
  end
end

project.build_configurations.each do |configuration|
  configuration.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "17.2"
  configuration.build_settings["SWIFT_VERSION"] = "6.0"
end

app_target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
  settings["CODE_SIGN_ENTITLEMENTS"] = "Violet/Violet.entitlements"
  settings["CODE_SIGN_STYLE"] = "Automatic"
  settings["CURRENT_PROJECT_VERSION"] = "1"
  settings["DEVELOPMENT_TEAM"] = ""
  settings["ENABLE_USER_SCRIPT_SANDBOXING"] = "NO"
  settings["GENERATE_INFOPLIST_FILE"] = "NO"
  settings["INFOPLIST_FILE"] = "Violet/Info.plist"
  settings["MARKETING_VERSION"] = "1.0"
  settings["META_APP_ID"] = "0"
  settings["META_CLIENT_TOKEN"] = ""
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.violet.patient"
  settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
  settings["SWIFT_EMIT_LOC_STRINGS"] = "YES"
  settings["SWIFT_STRICT_CONCURRENCY"] = "targeted"
  settings["TARGETED_DEVICE_FAMILY"] = "1"
end

test_target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings["CODE_SIGN_STYLE"] = "Automatic"
  settings["GENERATE_INFOPLIST_FILE"] = "YES"
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.violet.patient.tests"
  settings["SWIFT_VERSION"] = "6.0"
  settings["TARGETED_DEVICE_FAMILY"] = "1"
end

secrets_phase = app_target.new_shell_script_build_phase("Generate prototype secrets")
secrets_phase.shell_path = "/bin/sh"
secrets_phase.shell_script = <<~SH
  set -eu
  output_dir="$DERIVED_FILE_DIR/violet-secrets"
  output_file="$output_dir/Secrets.json"
  mkdir -p "$output_dir" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
  /usr/bin/ruby "$SRCROOT/scripts/generate_secrets.rb" "$SRCROOT/../.env" "$output_file"
  /bin/cp "$output_file" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Secrets.json"
  /usr/bin/xattr -cr "$TARGET_BUILD_DIR/$WRAPPER_NAME" || true
SH
secrets_phase.input_paths = [
  "$(SRCROOT)/scripts/generate_secrets.rb",
  "$(SRCROOT)/../.env"
]
secrets_phase.output_paths = ["$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/Secrets.json"]

project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app_target)
scheme.set_launch_target(app_target)
scheme.add_test_target(test_target)
scheme.save_as(PROJECT_PATH, "Violet", true)
