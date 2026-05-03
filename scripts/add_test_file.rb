#!/usr/bin/env ruby
# Adds a Swift file under ProjectApexTests/ to the ProjectApexTests target.
# Usage: ruby scripts/add_test_file.rb <RelativePathFromRepoRoot>
# Example: ruby scripts/add_test_file.rb ProjectApexTests/MovementPatternTests.swift
# Idempotent — skips silently if the file is already registered.

require 'xcodeproj'

rel_path = ARGV[0] or abort "Usage: ruby scripts/add_test_file.rb ProjectApexTests/<File>.swift"
abort "Path must start with ProjectApexTests/" unless rel_path.start_with?('ProjectApexTests/')

basename = File.basename(rel_path)
project = Xcodeproj::Project.open('ProjectApex.xcodeproj')
test_target = project.targets.find { |t| t.name == 'ProjectApexTests' } or abort "ProjectApexTests target not found"
tests_group = project.main_group['ProjectApexTests'] || project.main_group.new_group('ProjectApexTests', 'ProjectApexTests')

if tests_group.files.any? { |f| f.path == basename }
  puts "#{basename} already registered — skipping."
  exit 0
end

file_ref = tests_group.new_file(basename)
test_target.source_build_phase.add_file_reference(file_ref)
project.save
puts "Added #{basename} to ProjectApexTests target."
