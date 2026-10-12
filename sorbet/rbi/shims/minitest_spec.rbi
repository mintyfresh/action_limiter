# typed: true

# minitest/spec is not loaded when tapioca generates the minitest RBI.
class Minitest::Spec < Minitest::Test
  sig { params(desc: String, block: T.proc.bind(T.attached_class).void).void }
  def self.it(desc = 'anonymous', &block); end

  sig { params(block: T.proc.bind(T.attached_class).void).void }
  def self.before(&block); end

  sig { params(block: T.proc.bind(T.attached_class).void).void }
  def self.after(&block); end
end
