# frozen_string_literal: true
require 'digest'
root = ARGV.fetch(0)
{
  'index.html' => ['d97c35b3ba08f026536cb4c469623acb9957af59fb9a9171db012958515fe990', 435_304],
  'styles.css' => ['67a6538e0b763c32ced001728ebf68f375dec497d4fb91c0ee136658ff9f2034', 279_112]
}.each do |name, (digest, bytes)|
  path = File.join(root, name)
  abort "#{name} digest/length mismatch" unless File.size(path) == bytes && Digest::SHA256.file(path).hexdigest == digest
end
puts 'Pinned homepage HTML and CSS match exactly'
