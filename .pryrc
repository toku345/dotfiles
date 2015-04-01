## Settings
Pry.config.color = true
Pry.config.editor = 'emacsclient -c'

Pry.config.prompt = proc do |obj, level, _|
  prompt = ''
  prompt << "#{RUBY_VERSION}"
  prompt << "on#{Rails.version}" if defined?(Rails)
  "#{prompt}(#{obj})> "
end

## Alias
Pry.config.commands.alias_command 'lM', 'ls -M'
Pry.config.commands.alias_command 'w', 'whereami'
Pry.config.commands.alias_command '.clr', '.clear'
