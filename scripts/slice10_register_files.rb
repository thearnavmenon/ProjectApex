#!/usr/bin/env ruby
# scripts/slice10_register_files.rb
#
# Registers Slice 10 (#11) test files with the Xcode project:
#   - ProjectApexTests/TraineeModelDigestTests.swift  → ProjectApexTests target
#   - ProjectApexTests/TraineeModelServiceTests.swift → ProjectApexTests target
#
# Production files (TraineeModelDigest.swift, TraineeModelService.swift) live
# inside the ProjectApex/ folder, which is a PBXFileSystemSynchronizedRootGroup
# (Xcode's synchronized-folder mode), so they're included without explicit
# registration. The test target is not synchronized — explicit registration
# is required.
#
# Idempotent — safe to re-run.

require 'xcodeproj'

PROJECT_PATH = 'ProjectApex.xcodeproj'
project = Xcodeproj::Project.open(PROJECT_PATH)

test_target = project.targets.find { |t| t.name == 'ProjectApexTests' }
raise 'ProjectApexTests target not found' unless test_target

tests_group = project.main_group['ProjectApexTests']
raise 'ProjectApexTests group not found' unless tests_group

%w[
  TraineeModelDigestTests.swift
  TraineeModelServiceTests.swift
].each do |basename|
  if tests_group.files.any? { |f| f.path == basename }
    puts "Already registered: #{basename}"
    next
  end
  ref = tests_group.new_file(basename)
  test_target.source_build_phase.add_file_reference(ref)
  puts "Registered: #{basename} → #{test_target.name}"
end

project.save
puts 'Saved ProjectApex.xcodeproj'
