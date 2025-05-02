# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = "voice_memo"
  spec.version       = "0.1.0"
  spec.authors       = ["Mike Wheeler"]
  spec.email         = ["mike@example.com"]

  spec.summary       = "A tool to record voice memos, transcribe them with Whisper, and format them with OpenAI"
  spec.description   = "Voice Memo is a command-line tool that records audio, transcribes it using OpenAI's Whisper, and optionally reformats the text using OpenAI's GPT models."
  spec.homepage      = "https://github.com/yourusername/voice_memo"
  spec.license       = "MIT"
  spec.required_ruby_version = Gem::Requirement.new(">= 2.6.0")

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  # Specify which files should be added to the gem when it is released.
  spec.files = Dir.glob(%w[
    lib/**/*.rb
    bin/*
    LICENSE.txt
    README.md
  ])
  spec.bindir        = "bin"
  spec.executables   = ["voice"]
  spec.require_paths = ["lib"]

  # Dependencies
  spec.add_dependency "json", "~> 2.0"
  spec.add_dependency "optparse", "~> 0.1.1"
  spec.add_dependency "ruby-openai", "~> 6.0"

  spec.add_development_dependency "bundler", "~> 2.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
