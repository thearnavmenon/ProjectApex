#!/usr/bin/env ruby
require 'xcodeproj'

project_path = 'ProjectApex.xcodeproj'
project = Xcodeproj::Project.open(project_path)

test_target = project.targets.find { |t| t.name == 'ProjectApexTests' }
raise "Test target not found" unless test_target

# Find or create the ProjectApexTests group
tests_group = project.main_group['ProjectApexTests'] ||
              project.main_group.new_group('ProjectApexTests', 'ProjectApexTests')

test_file_path = 'ProjectApexTests/EquipmentRounderTests.swift'

# Skip if already added
if tests_group.files.any? { |f| f.path == 'EquipmentRounderTests.swift' }
  puts "File already in group — skipping."
else
  file_ref = tests_group.new_file(test_file_path)
  test_target.source_build_phase.add_file_reference(file_ref)
  puts "Added EquipmentRounderTests.swift to ProjectApexTests target."
end

project.save
