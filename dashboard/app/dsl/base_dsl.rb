class BaseDSL
  def initialize
    @hash = {}
  end

  # TODO(asher): Remove the need for this disabling of rubocop. Note that this
  # requires some amount of work, as usage would change from name('xyz') to
  # name = 'xyz'.
  # rubocop:disable Style/TrivialAccessors
  def name(text)
    @name = text
  end
  # rubocop:enable Style/TrivialAccessors

  def skip_validation
    @skip_validation = true
  end

  def encrypted(text)
    @hash['encrypted'] = '1'

    begin
      instance_eval(Encryption.decrypt_object(text))
    rescue OpenSSL::Cipher::CipherError, Encryption::KeyMissingError
      puts "warning: unable to decrypt level #{@name}, skipping"
      return
    end
  end

  # returns 'xyz' from 'XyzDSL' subclasses
  def prefix
    self.class.to_s.tap {|s| s.slice!('DSL')}.underscore
  end

  def self.parse_file(filename, name=nil, skip_validation=false)
    text = File.read(filename)
    parse(text, filename, name, skip_validation)
  end

  def self.parse(str, filename, name=nil, skip_validation=false)
    object = new
    object.name(name) if name.present?
    object.skip_validation if skip_validation
    object.instance_eval(str.to_ascii, filename)
    [object.parse_output, object.i18n_hash]
  end

  # override in subclass
  def parse_output
    @hash
  end

  # after parse has been done, this function returns a hash of all the user-visible strings from this instance
  def i18n_hash
    # Filter out any entries with nil key or value
    hash = i18n_strings.select {|key, value| key && value}
    {"en" => {"data" => {prefix => hash}}}
  end

  # Implement in subclass
  def i18n_strings
  end

  def self.boolean(name)
    define_method(name) do |val|
      instance_variable_set "@#{name}", ActiveModel::Type::Boolean.new.deserialize(val)
    end
  end

  def self.string(name)
    define_method(name) do |val|
      instance_variable_set "@#{name}", val
    end
  end

  def self.integer(name)
    define_method(name) do |val|
      instance_variable_set "@#{name}", ActiveModel::Type::Integer.new.deserialize(val)
    end
  end
end
