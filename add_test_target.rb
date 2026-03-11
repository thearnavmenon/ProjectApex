#!/usr/bin/env ruby
require 'xcodeproj'

project_path = 'ProjectApex.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# ── Skip if test target already exists ──────────────────────────────────────
if project.targets.any? { |t| t.name == 'ProjectApexTests' }
  puts "Test target already exists — skipping."
  exit 0
end

main_target = project.targets.find { |t| t.name == 'ProjectApex' }
raise "Main target not found" unless main_target

# ── Create the unit test target ─────────────────────────────────────────────
test_target = project.new_target(
  :unit_test_bundle,
  'ProjectApexTests',
  :ios,
  '17.0'
)

# Point the test target at the main app target
test_target.add_dependency(main_target)

# ── Create the Tests group / folder ─────────────────────────────────────────
tests_group = project.main_group.find_subpath('ProjectApexTests') ||
              project.main_group.new_group('ProjectApexTests', 'ProjectApexTests')

# ── Wire up build settings to match the main target's style ─────────────────
['Debug', 'Release'].each do |config_name|
  config = test_target.build_configuration_list[config_name]
  config.build_settings['SWIFT_VERSION']                   = '5.0'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET']      = '17.0'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER']       = 'RTG.ProjectApexTests'
  config.build_settings['TEST_HOST']                       = '$(BUILT_PRODUCTS_DIR)/ProjectApex.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/ProjectApex'
  config.build_settings['BUNDLE_LOADER']                   = '$(TEST_HOST)'
  config.build_settings['SWIFT_DEFAULT_ACTOR_ISOLATION']   = 'MainActor'
  config.build_settings['ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES'] = 'NO'
end

project.save
puts "Test target 'ProjectApexTests' created successfully."
