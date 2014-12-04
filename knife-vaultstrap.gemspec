$:.unshift(File.dirname(__FILE__) + '/lib')
require 'knife-vaultstrap/version'

Gem::Specification.new do |s|
  s.name        = 'knife-vaultstrap'
  s.version     = KnifeVaultstrap::VERSION
  s.date        = '2014-12-04'
  s.summary     = 'Knife plugin for bootstrapping nodes using chef-vault'
  s.description = s.summary
  s.authors     = ["Paul Mooring"]
  s.email       = ['paul@chef.io']
  s.homepage    = "https://github.com/opscode/knife-vaultstrap"

  s.add_dependency "chef"
  s.add_dependency "chef-vault"
  s.add_dependency "knife-ec2"
  s.require_paths = ["lib"]
  s.files = `git ls-files`.split("\n").select {|i| i !~ /.*\.gem$/}
end
