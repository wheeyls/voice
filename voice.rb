#!/usr/bin/env ruby
# frozen_string_literal: true

# This is a wrapper script for the voice_memo gem
# It will be replaced by the gem's executable when installed

begin
  require "voice_memo"
  VoiceMemo::Voice.new(ARGV).run
rescue LoadError
  puts "The voice_memo gem is not installed."
  puts "To install it, run: gem build voice_memo.gemspec"
  puts "Then: gem install voice_memo-0.1.0.gem"
  exit 1
end
