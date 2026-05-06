#!/usr/bin/env ruby
# scripts/slice6_register_files.rb
#
# Registers Slice 6 (#10) source files with the Xcode project:
#   - ProjectApex/Features/Workout/SetCompletionFormState.swift  → ProjectApex target
#   - ProjectApexTests/SetCompletionFormStateTests.swift          → ProjectApexTests target
#   - ProjectApexTests/SetPrescriptionIntentValidationTests.swift → ProjectApexTests target
#
# Also fixes a pre-existing pbxproj path bug introduced in Slice 7 (b7ae033):
# EquipmentCatalogSeedTests.swift has `path = ProjectApexTests/...` instead of
# just the basename, which makes it resolve to a doubled path inside the
# ProjectApexTests group. The bug was undetected on main because no recent
# commit ran the test target. Slice 6 needs the test target to build.
#
# Idempotent — safe to re-run.

require 'xcodeproj'

PROJECT_PATH = 'ProjectApex.xcodeproj'
project = Xcodeproj::Project.open(PROJECT_PATH)

main_target  = project.targets.find { |t| t.name == 'ProjectApex' }
test_target  = project.targets.find { |t| t.name == 'ProjectApexTests' }
raise 'ProjectApex target not found'      unless main_target
raise 'ProjectApexTests target not found' unless test_target

# ── 1. Fix the EquipmentCatalogSeedTests path bug ────────────────────────────
project.files.each do |f|
  next unless f.path == 'ProjectApexTests/EquipmentCatalogSeedTests.swift'
  puts "Fixing pbxproj path for EquipmentCatalogSeedTests.swift " \
       "('#{f.path}' → 'EquipmentCatalogSeedTests.swift')"
  f.path = 'EquipmentCatalogSeedTests.swift'
end

# ── 2. Helper: ensure a file is registered with a target/group ───────────────
def ensure_file(project:, target:, group:, relpath:, basename:)
  if group.files.any? { |f| f.path == basename }
    puts "Already registered: #{basename}"
    return
  end
  ref = group.new_file(relpath)
  target.source_build_phase.add_file_reference(ref)
  puts "Registered: #{basename} → #{target.name}"
end

# NOTE: SetCompletionFormState.swift in the main app target is picked up
# automatically — the ProjectApex group is a PBXFileSystemSynchronizedRootGroup
# (Xcode's synchronized-folder mode), so any file placed in the on-disk
# folder structure is included without explicit registration.

# ── 3. Register new test files in test target ────────────────────────────────
tests_group = project.main_group['ProjectApexTests']
raise 'ProjectApexTests group not found' unless tests_group

%w[
  SetCompletionFormStateTests.swift
  SetPrescriptionIntentValidationTests.swift
].each do |name|
  ensure_file(
    project:  project,
    target:   test_target,
    group:    tests_group,
    relpath:  name,
    basename: name
  )
end

project.save
puts 'Saved ProjectApex.xcodeproj'
