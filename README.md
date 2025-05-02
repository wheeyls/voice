# Voice Memo

A command-line tool that records audio, transcribes it using OpenAI's Whisper, and optionally reformats the text using OpenAI's GPT models.

## Installation

```bash
gem install voice_memo
```

## Dependencies

This gem requires the following external dependencies:

- sox (for audio recording)
- ffmpeg (required by whisper)
- whisper (OpenAI's transcription tool)
- OpenAI API key (for tone formatting)

### Installing Dependencies

```bash
# Install sox and ffmpeg
brew install sox ffmpeg

# Install whisper
pip install -U openai-whisper

# Set your OpenAI API key
export OPENAI_API_KEY='your-api-key'
```

## Usage

```bash
# Basic usage - record and transcribe
voice

# Apply a tone to the transcription
voice --tone business_casual
voice --tone formal
voice --tone email
voice --tone slack
voice --tone direct_message
voice --tone social_media
voice --tone article

# You can also use custom tone instructions
voice --tone "write this as a haiku"
voice --tone "format this as a bullet-point list of action items"
```

The tool will open your default editor (set by the EDITOR environment variable) to allow you to make final edits to the transcription before copying it to the clipboard. If EDITOR is not set, it will default to nano.

You can set your preferred editor with:

```bash
export EDITOR=vim  # or any editor you prefer
```

## Configuration

You can customize the core prompt by editing the file at `~/.voice-default-prompt`.

## Output

Voice memos are saved to `~/voicememos/` with timestamps in the filename.
Temporary files and logs are stored in `~/voicememos/tmp/` and `~/voicememos/logs/` respectively.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
