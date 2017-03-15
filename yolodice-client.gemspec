Gem::Specification.new do |s|
  s.name        = 'yolodice-client'
  s.version     = '0.1.4'
  s.summary     = 'Ruby API client for YOLOdice.com'
  s.description = 'A simple JSON-RPC2 client dedicated for YOLOdice.com API.'
  s.authors     = ['ethan_nx']
  s.files       = Dir.glob ['lib/*.rb',
                           '[A-Z]*.md'].to_a
  s.homepage    = 'https://github.com/ethan-nx/yolodice-client'
  s.license     = 'MIT'
  s.add_runtime_dependency 'bitcoin-ruby', '~> 0.0.8'
  s.add_runtime_dependency 'ffi', '~> 1.9', '>= 1.9.10'
end
