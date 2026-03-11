#!/usr/bin/env ruby
require 'xcodeproj'

project_path = 'ProjectApex.xcodeproj'
project = Xcodeproj::Project.open(project_path)

main_target = project.targets.find { |t| t.name == 'ProjectApex' }
test_target = project.targets.find { |t| t.name == 'ProjectApexTests' }

raise "Main target not found"  unless main_target
raise "Test target not found"  unless test_target

# ── Create a shared scheme ────────────────────────────────────────────────────
scheme_path = Xcodeproj::XCScheme.shared_data_dir(project_path)
FileUtils.mkdir_p(scheme_path)

scheme = Xcodeproj::XCScheme.new

# Build action
build_action_entry = Xcodeproj::XCScheme::BuildAction::Entry.new(main_target)
build_action_entry.build_for_testing   = true
build_action_entry.build_for_running   = true
build_action_entry.build_for_profiling = true
build_action_entry.build_for_archiving = true
build_action_entry.build_for_analyzing = true
scheme.build_action.add_entry(build_action_entry)

test_build_entry = Xcodeproj::XCScheme::BuildAction::Entry.new(test_target)
test_build_entry.build_for_testing   = true
test_build_entry.build_for_running   = false
test_build_entry.build_for_profiling = false
test_build_entry.build_for_archiving = false
test_build_entry.build_for_analyzing = false
scheme.build_action.add_entry(test_build_entry)

# Test action — add the test target
test_action_entry = Xcodeproj::XCScheme::TestAction::TestableReference.new(test_target)
test_action_entry.skipped = false
scheme.test_action.add_testable(test_action_entry)
scheme.test_action.build_configuration = 'Debug'

# Launch action
launch_action = scheme.launch_action
launch_action.build_configuration = 'Debug'

scheme.save_as(project_path, 'ProjectApex', true)
puts "Shared scheme 'ProjectApex' created/updated with test target."
